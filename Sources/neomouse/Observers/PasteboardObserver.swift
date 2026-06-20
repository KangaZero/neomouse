import AppKit
import Combine
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Wire the clipboard watcher to `appState.mode`: it polls only while
    /// NeoMouse is active (mode != .disabled) and cycles numbered registers.
    @MainActor
    static func installPasteboardModeObserver(appState: NeoMouseState) {
        // Pasteboard watcher tied to NeoMouse activation: it runs only when
        // mode != .disabled. `@Published`'s projected publisher fires the
        // current value to new subscribers, so this also sets the correct
        // initial state. Polling changeCount is the standard macOS clipboard
        // monitor pattern (Maccy/Flycut/Clipy) — no notification API exists.
        NeoMouse.modeObserver = appState.$mode.sink { newMode in
            MainActor.assumeIsolated {
                if case .disabled = newMode {
                    NeoMouse.pasteboardWatcher?.invalidate()
                    NeoMouse.pasteboardWatcher = nil
                } else if NeoMouse.pasteboardWatcher == nil {
                    NeoMouse.pasteboardWatcher = Pasteboard.watch {
                        Pasteboard.dump()
                        if let item = Pasteboard.getFirst() {
                            debug("Clipboard changed: \(Pasteboard.preview(item))")
                            if let sessionId = NeoMouse.sharedState.currentSession?.id {
                                // Vim-style numbered-register cycle: shifts
                                // "1"–"9" up by one slot, drops "9", writes
                                // the new item to both "1" and "0" in a
                                // single transaction. See Register
                                // .cycleNumbered for the full contract.
                                Register.cycleNumbered(item: item, sessionId: sessionId)
                                RegisterMenu.shared.refresh()
                            } else {
                                debug("No current session id; skipping numbered-register cycle")
                            }
                        }
                    }
                }
            }
        }
    }
}
