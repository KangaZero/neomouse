import AppKit

public enum System {
    /// Sentinel written to `eventSourceUserData` on every event we synthesize.
    /// Lets the CGEventTap in `NeoMouseApp` recognise neomouse-originated keys
    /// and pass them through unconditionally — otherwise our own Cmd+C/V/X
    /// would re-enter the tap, get swallowed (mode is active), and never reach
    /// the focused app.
    public static let synthesizedEventUserData: Int64 = 0x4E_4D_4F_55_53_45  // "NMOUSE"

    /// Standard clipboard shortcut to synthesize via Cmd + key.
    public enum ClipboardAction {
        case copy, paste, cut

        fileprivate var keyChar: String {
            switch self {
            case .copy: return "c"
            case .paste: return "v"
            case .cut: return "x"
            }
        }
    }

    public static func getActiveApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    public static func getActiveAppName() -> String? {
        getActiveApp()?.localizedName
    }

    /// Kick off a detached relaunch of this process. Returns nil on success or
    /// a short failure description (no `restart: ` prefix) suitable for a toast
    /// / status line. Caller should call `exit(0)` after a brief asyncAfter so
    /// the toast renders and AppKit returns to its run loop before the process
    /// dies — otherwise the old event tap may still be installed when the new
    /// process tries to install its own.
    ///
    /// Two execution paths, picked by whether we're running from a bundled .app:
    ///   * Bundled (`Bundle.main.bundleIdentifier != nil`) — `open` the bundle
    ///     URL. Covers brew / nix / manual install / `just run` /
    ///     `just release-test`.
    ///   * Bare-binary `swift run` — walk up from the executable path to find
    ///     `Package.swift`, then re-`swift run` from there. The release / `.app`
    ///     install paths cannot rebuild themselves (no toolchain, no source) so
    ///     they intentionally don't fall through to this branch.
    @discardableResult
    public static func restart() -> String? {
        let shellCommand: String
        let shellArg: String

        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            // Bundled launch — re-`open` the .app.
            shellCommand = "sleep 0.5 && open \"$1\""
            shellArg = Bundle.main.bundleURL.path
        } else {
            // Bare-binary dev path — find the package root + `swift run`.
            guard let executablePath = Bundle.main.executablePath else {
                return "Bundle.main.executablePath is nil"
            }
            var root = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            while root.path != "/"
                && !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Package.swift").path)
            {
                root = root.deletingLastPathComponent()
            }
            guard root.path != "/" else {
                return
                    "could not locate Package.swift — run from a bundled .app (just run / just release-test) or under the repo"
            }
            shellCommand = "sleep 0.5 && cd \"$1\" && swift run"
            shellArg = root.path
        }

        let task = Process()
        task.launchPath = "/bin/sh"
        // Argv-passed root (`$1`) rather than string-interpolated so paths
        // with spaces don't break the script. macOS reparents the orphaned
        // shell to launchd, so it survives our exit(0).
        task.arguments = ["-c", shellCommand, "sh", shellArg]
        do {
            try task.run()
        } catch {
            return "failed to spawn — \(error)"
        }
        return nil
    }

    /// Post a Cmd+<key> shortcut to the frontmost app. Used as the fallback
    /// when AX direct-action APIs are unavailable (which is basically always
    /// for copy/paste/cut — AppKit doesn't expose them as AX actions).
    public static func simulate(_ action: ClipboardAction) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Tag every event from this source so the neomouse CGEventTap can spot
        // its own synthesized keys and let them through.
        source?.userData = synthesizedEventUserData
        guard let keyCode = charToKeyCodeMap[action.keyChar] else {
            debug("System.simulate: no keyCode for '\(action.keyChar)'")
            return
        }
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            debug("System.simulate: failed to create CGEvent for '\(action.keyChar)'")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Session tap (not HID) so HID-level keyboard accessibility services
        // (Sticky Keys, Slow Keys, key-repeat delay) can't mutate the
        // synthesized chord. Our own CGEventTap is also at the session level
        // with .headInsertEventTap, so it still sees these events and the
        // sentinel-userData check passes them through.
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
