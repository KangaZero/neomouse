import AppKit

import neomouseUtils

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // NeoMouse is a background input tool — no Dock icon, no focus
        // stealing, no Settings window auto-shown on launch. Without this,
        // the default `.regular` policy surfaces the empty Settings scene
        // because it's the only scene the App declares.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let appState = NeoMouse.sharedState

        if let keyMonitor = NeoMouse.keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            NeoMouse.keyMonitor = nil
        }
        if let mouseMonitor = NeoMouse.mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            NeoMouse.mouseMonitor = nil
        }

        // Release any button we may have synthesized .mouseDown for (visual
        // mode does this) so the user doesn't inherit a stuck-drag after quit.
        // mouseUp is safe to post even when nothing is held — the system
        // ignores the event when the button state is already up.
        if let loc = getCurrentMouseLocation() {
            mouseUp(.left, at: loc)
            mouseUp(.right, at: loc)
        }

        if appState.isVisual {
            exitVisualMode(
                appState: appState,
                visualHighlightOverlay: VisualHighlightOverlay.shared)
        }
        GridOverlay.shared.hideGrid()
        appState.mode = .disabled
        appState.startCGXPoint = nil
        appState.startCGYPoint = nil
        appState.endCGXPoint = nil
        appState.endCGYPoint = nil
        appState.previousStartCGXPoint = nil
        appState.previousStartCGYPoint = nil
        appState.previousEndCGXPoint = nil
        appState.previousEndCGYPoint = nil
    }
}
