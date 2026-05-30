import AppKit
import SwiftUI

import neomouseUtils

@MainActor
final class KeyCast {
    static let shared = KeyCast()
    private var window: NSPanel?
    private weak var appState: NeoMouseState?
    private var lastScreenNumber: UInt32?

    func passAppState(state: NeoMouseState) {
        appState = state
        show()
    }

    // Cheap per-event check: only re-positions the panel when the cursor actually
    // crosses to a different screen. Safe to call from the global mouse monitor.
    func repositionIfScreenChanged() {
        guard let screen = currentScreen(),
            let n = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else { return }
        if lastScreenNumber != n.uint32Value {
            show()
        }
    }

    private func currentScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func show() {
        guard let appState, let screen = currentScreen() else {
            return debug("KeyCast.show: no screen available or appState was never passed")
        }
        let theme = appState.theme.keyCast
        let panelSize = CGSize(width: theme.width, height: theme.height)
        if window == nil {
            let panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: panelSize),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: KeyCastView(state: appState))
            window = panel
        }
        let origin = theme.anchor.origin(
            in: screen.visibleFrame,
            panelSize: panelSize,
            offsetX: theme.xOffset,
            offsetY: theme.yOffset
        )
        window?.setFrame(CGRect(origin: origin, size: panelSize), display: true)
        window?.orderFrontRegardless()
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            lastScreenNumber = n.uint32Value
        }
    }
}

private struct KeyCastView: View {
    @ObservedObject var state: NeoMouseState

    private var pending: String? {
        switch state.mode {
        case .normal(let op, _, ): return "\(op)"
        case .find(let op, _, _): return op
        case .command(let op, _): return op
        case .disabled: return nil
        case .menu: return nil
        case .specialFind: return nil
        }
    }

    var body: some View {
        if let pending, !pending.isEmpty {
            // Solid (non-translucent) backdrop is critical: text rendered against an
            // alpha-blended layer falls back from subpixel to grayscale antialiasing,
            // which reads as blurry/faint on Retina displays. The shadow + thin border
            // give the pill definition without sacrificing legibility.
            let theme = state.theme.keyCast
            Text(pending)
                .font(theme.textFont.swiftUI)
                .foregroundColor(theme.textColor.swiftUI)
                .padding(.horizontal, theme.paddingX)
                .padding(.vertical, theme.paddingY)
                .background(theme.background.swiftUI)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(theme.borderColor.swiftUI, lineWidth: 1)
                )
                .shadow(color: theme.shadowColor.swiftUI, radius: 8, x: 0, y: 2)
                .frame(
                    minWidth: 100 as CGFloat, maxWidth: .infinity, minHeight: 40 as CGFloat,
                    maxHeight: .infinity)

        } else {
            EmptyView()
        }
    }
}
