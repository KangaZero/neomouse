import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

@MainActor
final class CommandLine {
    static let shared = CommandLine()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    // Single source of truth for command-mode derived state. Every read goes
    // through the singleton so the view, the Tab-cycle handler, and the
    // executor cannot disagree about what's typed or what's filtered.

    var commandText: String {
        guard let appState, case .command(let s, _) = appState.mode else { return "" }
        return s
    }

    var suggestionIndex: Int? {
        guard let appState, case .command(_, let idx) = appState.mode else { return nil }
        return idx
    }

    var filtered: [Config.Command] {
        guard let appState else { return [] }
        let text = commandText
        return text.isEmpty
            ? appState.commands
            : appState.commands.filter { $0.rawValue.localizedCaseInsensitiveContains(text) }
    }

    func toggle() {
        if let window, window.isVisible {
            hide()
        } else {
            show()
        }
    }

    func passAppState(state: NeoMouseState) {
        appState = state
    }

    func hide() {
        window?.orderOut(nil)
    }

    func executeSuggestionCommand(at suggestionIndex: Int) {
        guard let appState, case .command = appState.mode else {
            return debug("executeSuggestionCommand called but appState.mode is not .command")
        }
        guard suggestionIndex >= 0 && suggestionIndex < filtered.count else {
            return debug(
                "executeSuggestionCommand called with out-of-bounds suggestionIndex \(suggestionIndex) for filtered commands count \(filtered.count)"
            )
        }
        let commandToExecute: Config.Command = filtered[suggestionIndex]
        debug("executeSuggestionCommand: \(commandToExecute)")
        switch commandToExecute {
        case .help, .h:
            HelpDialog.shared.toggle()
            appState.mode = .normal(currentPendingOperation: .none)
            return
        case .numbers, .nu:
            NumbersOverlay.shared.passAppState(state: appState)
            NumbersOverlay.shared.toggle(mode: .absolute)
            appState.mode = .normal(currentPendingOperation: .none)
            return
        case .relativenumbers, .rnu:
            NumbersOverlay.shared.passAppState(state: appState)
            NumbersOverlay.shared.toggle(mode: .relative)
            appState.mode = .normal(currentPendingOperation: .none)
            return
        case .quit, .q:
            NSApp.terminate(nil)
        default: return
        }
    }

    private func show() {

        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState,
            case .command = appState.mode
        else {
            return debug(
                "Could not retrieve current screen in CommandLine.show and/or appState is \(appState == nil ? "nil" : "not nil")"
            )
        }
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 60),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        // Without .clear, AppKit fills the panel backing under the SwiftUI
        // material → invisible (or grey) window.
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: CommandLineView(state: appState))
        // Auto-resize the panel to whatever SwiftUI wants. Without this
        // option the NSHostingView fills a fixed 60pt-tall panel and the
        // wildmenu list is clipped off-screen.
        hosting.sizingOptions = .preferredContentSize
        panel.contentView = hosting

        // Bottom-left of the display under the cursor. visibleFrame already
        // excludes the menu bar + Dock.
        let x = currentScreen.visibleFrame.minX + 20
        let y = currentScreen.visibleFrame.maxY - 80
        panel.setFrameOrigin(CGPoint(x: x, y: y))

        panel.orderFront(nil)
        window = panel
    }
    struct CommandLineView: View {
        // `state` triggers redraws when appState.mode changes; the actual
        // commandText / suggestionIndex / filtered values are pulled from
        // CommandLine.shared so there's exactly one place that derives them.
        @ObservedObject var state: NeoMouseState

        var body: some View {
            let cli = CommandLine.shared
            let hits = cli.filtered
            let highlighted = cli.suggestionIndex
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(":").foregroundColor(.secondary)
                    Text(cli.commandText).font(.system(.body, design: .monospaced))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if !hits.isEmpty {
                    Divider()
                    // nvim-style wildmenu: list always visible while typing,
                    // Tab / Shift-Tab cycles the highlight (driven by
                    // suggestionIndex on the .command mode payload).
                    ForEach(Array(hits.enumerated()), id: \.element) { idx, suggestion in
                        Text(suggestion.rawValue)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(idx == highlighted ? Color.accentColor.opacity(0.35) : .clear)
                    }
                }
            }
            .frame(minWidth: 400, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
