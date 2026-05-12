import AppKit
import SwiftUI

import neomouseUtils

@MainActor
final class KeyCast {
    static let shared = KeyCast()
    private var window: NSPanel?
    private weak var appState: NeoMouseState?
    private var lastScreenNumber: UInt32?

    private let panelWidth: CGFloat = 240
    private let panelHeight: CGFloat = 48
    private let topInset: CGFloat = 12

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
        if window == nil {
            let panel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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
        let frame = screen.visibleFrame
        let x = frame.midX - panelWidth / 2
        let y = frame.maxY - panelHeight - topInset
        window?.setFrame(
            CGRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: true
        )
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
        case .normal(let op): return op
        case .find(let op, _): return op
        case .command(let op, _): return op
        case .disabled: return nil
        }
    }

    var body: some View {
        if let pending, !pending.isEmpty {
            // Solid (non-translucent) backdrop is critical: text rendered against an
            // alpha-blended layer falls back from subpixel to grayscale antialiasing,
            // which reads as blurry/faint on Retina displays. The shadow + thin border
            // give the pill definition without sacrificing legibility.
            Text(pending)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 2)
                .frame(
                    minWidth: 100 as CGFloat, maxWidth: .infinity, minHeight: 40 as CGFloat,
                    maxHeight: .infinity)

        } else {
            EmptyView()
        }
    }
}
