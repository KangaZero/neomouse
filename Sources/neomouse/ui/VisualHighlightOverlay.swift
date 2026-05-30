import AppKit
import SwiftUI

import neomouseUtils

@MainActor
final class VisualHighlightOverlay {
    static let shared = VisualHighlightOverlay()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    func passAppState(state: NeoMouseState) {
        appState = state
        toggle()
    }
    func toggle() {
        guard let appState, appState.isVisual == true else { return }
        let unionAppKit = Screen.cgToAppKit(Screen.allBoundingRect())
        if window == nil {
            let win = NSWindow(
                contentRect: unionAppKit,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver  // 101
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: VisualHighlightOverlayView(state: appState))
            window = win
        }
        window?.setFrame(unionAppKit, display: true)
        window?.orderFrontRegardless()
    }

    func hideOverlay() {
        window?.orderOut(nil)
    }
    // func currentHighlightCGRect() -> CGRect? {
    //         guard state.isVisual, width > 0, height > 0 else { return nil }
    //         return CGRect(
    //             x: (state. + endX) / 2 - Screen.allBoundingRect().origin.x,
    //             y: (startY + endY) / 2 - Screen.allBoundingRect().origin.y,
    //             width: width,
    //             height: height
    //         )
    //     }
}

struct VisualHighlightOverlayView: View {
    @ObservedObject var state: NeoMouseState

    let currentCGPoint = Mouse.location()
    private var startX: CGFloat { state.startCGXPoint ?? 0 }
    private var startY: CGFloat { state.startCGYPoint ?? 0 }
    private var endX: CGFloat { state.endCGXPoint ?? startX }
    private var endY: CGFloat { state.endCGYPoint ?? startY }

    private var width: CGFloat { abs(endX - startX) }
    private var height: CGFloat { abs(endY - startY) }

    var body: some View {
        guard state.isVisual, width > 0, height > 0 else { return AnyView(EmptyView()) }

        // state.*CG*Point are CG-global. The SwiftUI view's (0,0) is the top-left of the
        // window, which spans Screen.allBoundingRect(). Subtract that origin to land
        // in view-local coords.
        let unionOrigin = Screen.allBoundingRect().origin
        let centerX = (startX + endX) / 2 - unionOrigin.x
        let centerY = (startY + endY) / 2 - unionOrigin.y

        return AnyView(
            GeometryReader { _ in
                Rectangle()
                    .fill(state.theme.visualHighlight.fill.swiftUI)
                    .frame(width: width, height: height)
                    .position(x: centerX, y: centerY)
            }
        )
    }
}
