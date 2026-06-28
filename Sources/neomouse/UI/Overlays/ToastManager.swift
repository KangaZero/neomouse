import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

enum ToastType {
    case info;
    case error;
    case warning;
}

@MainActor
final class ToastManager {
    static let shared = ToastManager()
    private var window: NSPanel?

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    /// Trigger the ToastManager UI with the following params:
    /// message: String ( Message to show )
    /// type: ToastType<.info | .error | .warning> [optional] ( Determines SF symbol to show, defaults to .info)
    func show(_ message: String, _ type: ToastType = ToastType.info) {

        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) })
        else {
            return debug("Could not retrieve current screen in ToastManager.show")
        }
        window?.close()

        // Theme is read off the singleton state — ToastManager doesn't get
        // passAppState'd by callers (every other overlay does), so we fetch
        // it directly here. Falls back to defaults if state isn't built yet.
        let theme = NeoMouse.sharedState.theme.toast
        let panelSize = CGSize(width: theme.width, height: theme.height)
        // See https://github.com/andrewtavis/sf-symbols-online for other SF symbols
        let systemName: String =
            switch type {
            case .info:
                "bell.fill"
            case .error:
                "xmark.shield.fill"
            case .warning:
                "exclamationmark.triangle.fill"
            }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: ToastView(message: message, systemName: systemName, theme: theme))

        let origin = theme.anchor.origin(
            in: currentScreen.visibleFrame,
            panelSize: panelSize,
            offsetX: theme.xOffset,
            offsetY: theme.yOffset
        )
        panel.setFrameOrigin(origin)

        panel.orderFront(nil)
        window = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
    }

    func hide() {
        window?.close()
        window = nil
    }
}

struct ToastView: View {
    let message: String
    let systemName: String
    let theme: ToastTheme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .foregroundColor(theme.textColor.swiftUI)
            Text(message)
                .foregroundColor(theme.textColor.swiftUI)
                .font(theme.textFont.swiftUI)
            Spacer()
        }
        .padding(.horizontal, theme.paddingX)
        .padding(.vertical, theme.paddingY)
        .background(theme.background.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .padding(theme.outerPadding)
    }
}
