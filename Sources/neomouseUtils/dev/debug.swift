import Foundation

// `debug(...)` routes output to two independent sinks:
//
//   stdout — enabled if EITHER
//     * the binary was built in debug configuration (SwiftPM defines DEBUG for
//       `swift build` / `swift run`; `swift build -c release` does not), OR
//     * the env var DEBUG is set to a non-empty, non-falsy value.
//
//   file   — enabled in any of these cases:
//     * the env var LOG is set to a non-empty, non-falsy value (explicit
//       opt-in — primarily a dev override), OR
//     * the process is running from a bundled .app (Bundle.main has a
//       CFBundleIdentifier) AND the env var LOG is not explicitly "0"/"false".
//       This is what `just run` / brew / nix / manual-tarball launches look
//       like in practice. Bare `swift run` falls outside this — Bundle.main
//       has no identifier there, so file logging stays opt-in.
//
//     Destination resolution order:
//       1. $LOG_LOCATION (full file path if it ends in `.log`, else dir +
//          `neomouse.log`)
//       2. ~/Library/Logs/neomouse/neomouse.log  (default when bundled)
//       3. /tmp/neomouse/logs/neomouse.log       (legacy dev fallback when
//                                                 LOG=1 is set without
//                                                 LOG_LOCATION outside an .app)
//
//     File is opened append-only at module load and the parent directory is
//     created if missing. Writes are serialized on a background queue. Open
//     failures are reported once to stderr and disable file logging.
//
// Both sinks may be active at once (DEBUG=1 LOG=1).
//
// All env-var checks are evaluated once at module load; per-call overhead is
// a Bool check plus formatting.

private func isTruthy(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    return value != "0" && value.lowercased() != "false"
}

private func isFalsy(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    return value == "0" || value.lowercased() == "false"
}

private let stdoutEnabled: Bool = {
    #if DEBUG
        return true
    #else
        return isTruthy(ProcessInfo.processInfo.environment["DEBUG"])
    #endif
}()

private let logWriteQueue = DispatchQueue(label: "neomouse.debug.log", qos: .utility)

/// The resolved log-file path used by this process, or nil if file logging
/// is disabled. Other code (e.g. the menu-bar "Show Debug Log" item) can
/// read this to expose the log location to the user.
public let currentLogFileURL: URL? = {
    let env = ProcessInfo.processInfo.environment
    let envLogValue = env["LOG"]
    let isBundled = Bundle.main.bundleIdentifier != nil

    // Enable file logging when explicitly requested OR when running from a
    // bundled .app. Allow LOG=0/false to disable even in the bundled case.
    let enabled: Bool
    if isFalsy(envLogValue) {
        enabled = false
    } else if isTruthy(envLogValue) || isBundled {
        enabled = true
    } else {
        enabled = false
    }
    guard enabled else { return nil }

    if let location = env["LOG_LOCATION"] {
        if location.hasSuffix(".log") {
            return URL(fileURLWithPath: location)
        }
        return URL(fileURLWithPath: (location as NSString).appendingPathComponent("neomouse.log"))
    }
    if isBundled {
        // ~/Library/Logs/neomouse/neomouse.log — standard Apple-recommended
        // location for user-visible app logs; opens directly in Console.app.
        if let libraryLogs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            return libraryLogs.appendingPathComponent("Logs/neomouse/neomouse.log")
        }
    }
    // Last-resort fallback (LOG=1 set, no LOG_LOCATION, bare `swift run`).
    return URL(fileURLWithPath: "/tmp/neomouse/logs/neomouse.log")
}()

private let logFileHandle: FileHandle? = {
    guard let url = currentLogFileURL else { return nil }
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    } catch {
        let warning = "neomouse: failed to open log file \(url.path): \(error)\n"
        FileHandle.standardError.write(Data(warning.utf8))
        return nil
    }
}()

//INFO: There is also this way of formatting: https://stackoverflow.com/questions/50712354/converting-utc-date-time-to-local-date-time-in-ios
private func formatDateToLocaleTime(date: Date) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale.current
    dateFormatter.timeStyle = .medium
    return dateFormatter.string(from: date)
}

public func debug(_ message: Any...) {
    guard stdoutEnabled || logFileHandle != nil else { return }

    let timestamp = formatDateToLocaleTime(date: Date())
    let line = "date: \(timestamp)\n \(message)"

    if stdoutEnabled {
        print(line)
    }

    if let handle = logFileHandle, let data = (line + "\n").data(using: .utf8) {
        logWriteQueue.async {
            try? handle.write(contentsOf: data)
        }
    }
}
