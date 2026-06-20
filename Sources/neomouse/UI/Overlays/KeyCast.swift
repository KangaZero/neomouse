import AppKit
import Combine
import SwiftUI

import neomouseTypes
import neomouseUtils

/// Vim-style `showcmd` analog. A small pill above the screen displays the
/// partial pending operation in normal mode (e.g. "g", "5", "m", "5gg")
/// and disappears as soon as nothing is pending. Gated globally by
/// `state.isShowKeyCast` — when false, the panel never appears.
///
/// Wiring: `passAppState(state:)` subscribes to `state.$mode`. Every mode
/// change re-evaluates `shouldShow` and either orders the panel front or
/// orders it out. No per-frame SwiftUI polling — the NSPanel is genuinely
/// hidden when there's nothing to show.
@MainActor
final class KeyCast {
    static let shared = KeyCast()
    private var window: NSPanel?
    private weak var appState: NeoMouseState?
    private var lastScreenNumber: UInt32?
    private var modeCancellable: AnyCancellable?

    func passAppState(state: NeoMouseState) {
        appState = state
        // React to every mode change. `removeDuplicates` would require Mode:
        // Equatable, which the enum doesn't currently conform to — and the
        // update path is cheap (just a switch + window-state check), so
        // dropping duplicates buys little.
        modeCancellable = state.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.update(for: mode)
            }
    }

    // Cheap per-event check: only re-positions the panel when the cursor actually
    // crosses to a different screen. Safe to call from the global mouse monitor.
    func repositionIfScreenChanged() {
        guard window?.isVisible == true,
            let screen = currentScreen(),
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

    /// Single decision point for "should the pill be visible right now?".
    /// Gated globally by `isShowKeyCast`; otherwise mirrors `pendingText`
    /// — anything that would render to non-empty text triggers show().
    private func update(for mode: NeomouseType.Mode) {
        guard let appState else { return }
        guard appState.isShowKeyCast else {
            hide()
            return
        }
        if KeyCast.pendingText(for: mode) != nil {
            show()
        } else {
            hide()
        }
    }

    private func hide() {
        window?.orderOut(nil)
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

    // MARK: - Rendering

    /// String to display for a given mode, or nil to hide the pill entirely.
    /// Format mirrors vim's showcmd: count first, then operator/pending key
    /// (e.g. "5gg", "10 " for `10<Space>`, "\"a" for register selection).
    /// Only normal mode contributes — find/command/menu have their own
    /// dedicated overlays and would be redundant here.
    fileprivate static func pendingText(for mode: NeomouseType.Mode) -> String? {
        guard case .normal(let op, let countString) = mode else { return nil }
        let count = (countString?.isEmpty == false) ? countString! : ""
        let opText = pendingOpText(op)
        let combined = count + opText
        return combined.isEmpty ? nil : combined
    }

    /// Human-readable key sequence for each pending operation. Matches the
    /// physical key that triggered the state where possible so the pill
    /// reads like a literal keystroke log.
    private static func pendingOpText(_ op: NeomouseType.NormalModePendingOperation) -> String {
        switch op {
        case .none: return ""
        case .g: return "g"
        case .gg: return "gg"
        case .ggy: return "ggy"
        case .ggv: return "ggv"
        case .special: return "<Space>"
        case .window: return "⌃w"
        case .setMark: return "m"
        case .goToMark: return "'"
        case .goToMarkExactState: return "`"
        case .goToRegister: return "\""
        case .registerAction(let register): return "\"\(register)"
        }
    }
}

private struct KeyCastView: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        if let pending = KeyCast.pendingText(for: state.mode) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyView()
        }
    }
}
