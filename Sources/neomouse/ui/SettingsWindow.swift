import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

/// Apple-style preferences window. Lives in its own NSWindow (not NSPanel)
/// so it gets a proper titlebar / resize / close button and can be moved
/// around like any other macOS window. The whole window contents is one
/// SwiftUI `SettingsView` — bindings into the @Published `NeoMouseState`
/// `theme` field, so dragging a slider or picking a color updates every
/// overlay live (no separate "Apply" step). A trailing "Save" button
/// rewrites the `[theme.*]` section of the resolved `settings.toml` so
/// changes persist across restarts.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    func passAppState(state: NeoMouseState) {
        appState = state
    }

    func toggle() {
        if let window, window.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        guard let appState else {
            debug("SettingsWindow.show: appState was never passed")
            return
        }
        // Force neomouse into .disabled while the Settings panel is open.
        // Live overlays (visual highlight, marks menu, etc.) would otherwise
        // fight the Settings window for mouse / focus, and changes to the
        // theme would race with whatever overlay is already on screen — much
        // simpler to hand the user a clean slate.
        //
        // We mirror the deactivation sequence in MenuBar.toggleActivation:
        // exit visual if it was active, reset gridDivisions, drop every
        // overlay, set .disabled. Re-activation is on the user (Cmd-E) after
        // closing Settings.
        if case .disabled = appState.mode {
            // Already disabled — nothing to tear down.
        } else {
            if appState.isVisual {
                NeoMouse.CoreOperations.exitVisualState(
                    appState: appState,
                    visualHighlightOverlay: VisualHighlightOverlay.shared
                )
            }
            appState.gridDivisions = Config.Grid.defaultDivisions
            appState.mode = .disabled
            GridOverlay.shared.hideGrid()
            CursorSurroundedGridOverlay.shared.hide()
            HelpDialog.shared.hide()
            CommandLine.shared.hide()
            MarksMenu.shared.hide()
            RegisterMenu.shared.hide()
            ToastManager.shared.show("Settings open — NeoMouse paused (⌘E to re-enable after)")
        }
        if window == nil {
            let win = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "NeoMouse Settings"
            win.level = .normal
            // The titlebar's red close button should hide the window, not
            // tear it down — toggle() can re-show without reconstructing.
            win.isReleasedWhenClosed = false
            win.hidesOnDeactivate = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView(state: appState))
            window = win
        }
        // Bring to the front; activating the app makes the close/menu work
        // normally (NSApp is .accessory most of the time, so settings panels
        // need a kick to receive focus events).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}
