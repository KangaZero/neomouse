import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

@MainActor
final class CommandLine {

    static let shared = CommandLine()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }
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

    // var filtered: [Config.Command] {
    //     guard let appState else {
    //         debug("filtered computed property accessed but appState is nil")
    //         return []
    //     }
    //     let text = commandText
    //     //NOTE: This is to not show shorthand commands (like `:h` for `:help`)
    //     let filteredOutShorthandCommands = appState.commands.filter { $0.rawValue.count >= 4 }
    //     return text.isEmpty
    //         ? filteredOutShorthandCommands
    //     //IMPORTANT: case insensitive match just like vim
    //         : filteredOutShorthandCommands.filter { $0.rawValue.localizedCaseInsensitiveContains(text) }
    // }
    var filtered: [Config.Command] {
        guard let appState else {
            debug("filtered computed property accessed but appState is nil")
            return []
        }
        let text = commandText
        let filteredOutShorthandCommands = appState.commands.filter { $0.rawValue.count >= 4 }
        guard !text.isEmpty else { return filteredOutShorthandCommands }

        return
            filteredOutShorthandCommands
            .compactMap { cmd -> (cmd: Config.Command, score: Int)? in
                guard let score = fuzzyScore(query: text, candidate: cmd.rawValue) else { return nil }
                return (cmd, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.cmd)
    }

    /// Returns a score if `query` is a subsequence of `candidate`, nil otherwise.
    /// Higher score = better match. Rewards:
    ///   - Consecutive character runs
    ///   - Matches at word boundaries (after `-`, `_`, ` `)
    ///   - Match starting at index 0
    private func fuzzyScore(query: String, candidate: String) -> Int? {
        let query = query.lowercased()
        let candidate = candidate.lowercased()

        var score = 0
        var consecutiveBonus = 0
        var prevMatchIdx: String.Index? = nil
        var searchFrom = candidate.startIndex

        for qChar in query {
            guard let matchIdx = candidate[searchFrom...].firstIndex(of: qChar) else {
                return nil  // query char not found — not a subsequence
            }

            // Consecutive run bonus (grows the longer the run)
            if let prev = prevMatchIdx, candidate.index(after: prev) == matchIdx {
                consecutiveBonus += 5
                score += consecutiveBonus
            } else {
                consecutiveBonus = 0
            }

            // Word boundary bonus
            if matchIdx == candidate.startIndex {
                score += 10
            } else {
                //TODO Not sure if this is even needed as no commands current have separators, but keeping for now just incase
                let charBefore = candidate[candidate.index(before: matchIdx)]
                if charBefore == "-" || charBefore == "_" || charBefore == " " {
                    score += 8
                }
            }

            prevMatchIdx = matchIdx
            searchFrom = candidate.index(after: matchIdx)
        }

        return score
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

    func commandExecutionHandler(command: Config.Command) {
        guard let appState else {
            return debug("commandExecutionHandler called but appState is nil")
        }
        switch command {
        case .help, .h:
            //NOTE: Order is important here: the help dialog is only available in normal mode
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            HelpDialog.shared.toggle()
            return
        case .numbers, .nu:
            NumbersOverlay.shared.passAppState(state: appState)
            NumbersOverlay.shared.toggle(mode: .absolute)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            return
        case .relativenumbers, .rnu:
            NumbersOverlay.shared.passAppState(state: appState)
            NumbersOverlay.shared.toggle(mode: .relative)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            return
        case .cursorline, .cul:
            NumbersOverlay.shared.passAppState(state: appState)
            NumbersOverlay.shared.toggleOption(.cursorline)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            return
        case .cursorcolumn, .cuc:
            NumbersOverlay.shared.passAppState(state: appState)
            NumbersOverlay.shared.toggleOption(.cursorcolumn)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            return
        case .marks, .m:
            appState.mode = .menu
            MarksMenu.shared.passAppState(state: appState)
            MarksMenu.shared.toggle()
            return
        case .quit, .q:
            NSApp.terminate(nil)
        default: return
        }
    }

    func executeCommand(at command: String) {
        guard let appState, case .command = appState.mode else {
            return debug("executeSuggestionCommand called but appState.mode is not .command")
        }
        //IMPORTANT: case insensitive just like vim
        guard let commandToExecute = Config.Command(rawValue: command.localizedLowercase) else {
            ToastManager.shared.show("not a valid command: \(command)")
            return debug("executeCommand called with invalid command string: \(command)")
        }
        commandExecutionHandler(command: commandToExecute)
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
        commandExecutionHandler(command: commandToExecute)
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
