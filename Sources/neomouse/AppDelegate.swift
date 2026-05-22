import AppKit

import neomouseUtils

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Fires after NSApp exists but before SwiftUI evaluates `body` and
        // builds scenes — the right window to suppress the auto-injected
        // https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let appState = NeoMouse.sharedState

        if let tap = NeoMouse.keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = NeoMouse.keyEventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
                NeoMouse.keyEventTapRunLoopSource = nil
            }
            NeoMouse.keyEventTap = nil
        }
        NeoMouse.keyHandler = nil
        if let mouseMonitor = NeoMouse.mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            NeoMouse.mouseMonitor = nil
        }
        NeoMouse.modeObserver?.cancel()
        NeoMouse.modeObserver = nil
        NeoMouse.pasteboardWatcher?.invalidate()
        NeoMouse.pasteboardWatcher = nil

        // Release any button we may have synthesized .mouseDown for (visual
        // mode does this) so the user doesn't inherit a stuck-drag after quit.
        // mouseUp is safe to post even when nothing is held — the system
        // ignores the event when the button state is already up.
        if let loc = Mouse.location() {
            Mouse.up(.left, at: loc)
            Mouse.up(.right, at: loc)
        }

        if appState.isVisual {
            NeoMouse.CoreOperations.exitVisualState(
                appState: appState,
                visualHighlightOverlay: VisualHighlightOverlay.shared)
        }
        GridOverlay.shared.hideGrid()

        appState.mode = .disabled
        appState.startCGXPoint = nil
        appState.startCGYPoint = nil
        appState.endCGXPoint = nil
        appState.endCGYPoint = nil
        appState.previousVisualStartCGXPoint = nil
        appState.previousVisualStartCGYPoint = nil
        appState.previousVisualEndCGXPoint = nil
        appState.previousVisualEndCGYPoint = nil
    }
}
