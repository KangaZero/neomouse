import Foundation

// `debug(...)` routes output to two independent sinks:
//
//   stdout — enabled if EITHER
//     * the binary was built in debug configuration (SwiftPM defines DEBUG for
//       `swift build` / `swift run`; `swift build -c release` does not), OR
//     * the env var DEBUG is set to a non-empty, non-falsy value.
//
//   file   — enabled if the env var LOG is set to a non-empty, non-falsy value.
//     Destination is LOG_LOCATION (default: /tmp/neomouse/logs). If
//     LOG_LOCATION ends in `.log` it is treated as the full file path;
//     otherwise it is treated as a directory and `neomouse.log` is appended.
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

private let stdoutEnabled: Bool = {
    #if DEBUG
        return true
    #else
        return isTruthy(ProcessInfo.processInfo.environment["DEBUG"])
    #endif
}()

private let logWriteQueue = DispatchQueue(label: "neomouse.debug.log", qos: .utility)

private let logFileHandle: FileHandle? = {
    guard isTruthy(ProcessInfo.processInfo.environment["LOG"]) else { return nil }

    let location = ProcessInfo.processInfo.environment["LOG_LOCATION"]
    let filePath: String
    if let location, location.hasSuffix(".log") {
        filePath = location
    } else {
        let dir = location ?? "/tmp/neomouse/logs"
        filePath = (dir as NSString).appendingPathComponent("neomouse.log")
    }

    let url = URL(fileURLWithPath: filePath)
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
        let warning = "neomouse: failed to open log file \(filePath): \(error)\n"
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
