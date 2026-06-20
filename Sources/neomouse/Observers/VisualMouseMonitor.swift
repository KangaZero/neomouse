import AppKit
import Combine
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Wire the visual-mode global mouse monitor to `appState.isVisual`:
    /// install the monitor on visual-enter, remove it on visual-exit.
    @MainActor
    static func installVisualModeObserver(appState: NeoMouseState) {
        // Global mouse monitor: installed only while visual mode is active.
        //
        // Why conditional: keeping `NSEvent.addGlobalMonitorForEvents` for
        // `.mouseMoved` / `.leftMouseDragged` registered at app launch
        // interferes with `MenuBarExtra` status-item click handling — the
        // dropdown never opens. Reproducible with a minimal SwiftUI sample
        // (see ~/Documents/swiftUITest): adding a global mouse monitor to
        // an LSUIElement app kills menu-bar interaction even though the
        // monitor is a passive observer that can't modify or block events.
        //
        // We only need the monitor during visual mode (it drags the
        // selection rectangle's end-point), so install on visual-enter,
        // remove on visual-exit. Outside of visual mode, the menu bar
        // dropdown stays clickable.
        NeoMouse.isVisualObserver = appState.$isVisual
            .removeDuplicates()
            .sink { isVisual in
                MainActor.assumeIsolated {
                    if isVisual {
                        NeoMouse.installVisualMouseMonitor(appState: appState)
                    } else {
                        NeoMouse.removeVisualMouseMonitor()
                    }
                }
            }
    }

    /// Install the global mouse monitor used by visual-mode selection
    /// tracking. Idempotent — no-op if already installed. See the comment
    /// at the install site for why this is conditional rather than always-on.
    @MainActor
    static func installVisualMouseMonitor(appState: NeoMouseState) {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { _ in
            MainActor.assumeIsolated {
                guard appState.isVisual, let loc = Mouse.location() else { return }
                appState.endCGXPoint = loc.x
                appState.endCGYPoint = loc.y
            }
        }
    }

    /// Remove the visual-mode global mouse monitor if installed. Idempotent.
    @MainActor
    static func removeVisualMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
}
