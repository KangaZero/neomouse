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
