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

    func commandExecutionHandler(command: Config.Command, args: String? = nil) {
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
        // INFO: Actual logic execution in executeCommand fn
        case .cursor, .c:
            ToastManager.shared.show("e.g. c[ursor](Int,Int)")
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            return
        case .marks, .m:
            appState.mode = .menu(window: .marks)
            MarksMenu.shared.passAppState(state: appState)
            MarksMenu.shared.toggle()
            return
        case .registers, .reg:
            appState.mode = .menu(window: .register)
            RegisterMenu.shared.passAppState(state: appState)
            RegisterMenu.shared.toggle()
            return
        case .restart, .r:
            // Detached relaunch via System.restart() — picks `open` for
            // bundled .apps (brew / nix / manual / `just release-test`) or
            // `swift run` from the package root for bare-binary `swift run`
            // dev launches. We can't exec-in-place because `swift run` does a
            // build step first, and `open` is detached anyway; spawning a
            // shell child that sleeps just long enough for *this* process to
            // exit cleanly (pasteboard timer, event tap, etc.) before
            // relaunching gives both paths a clean handoff. TCC permissions
            // carry across because the relaunched binary keeps the same path.
            if let err = System.restart() {
                return ToastManager.shared.show("restart: \(err)")
            }
            ToastManager.shared.show("Restarting…")
            // Defer the exit so the toast renders and the executor returns
            // before we yank the process out from under AppKit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Release any held synthesized mouse button before exit —
                // applicationWillTerminate normally handles this, but exit(0)
                // bypasses it. Without this, `:restart` mid-visual-mode leaves
                // the user with a stuck drag after the rebuild lands. mouseUp
                // is safe to post even when nothing is held — the system
                // ignores the event when button state is already up.
                if let loc = Mouse.location() {
                    Mouse.up(.left, at: loc)
                    Mouse.up(.right, at: loc)
                }
                // exit(0) instead of NSApp.terminate(nil) because terminate
                // routes through applicationShouldTerminate → applicationWill
                // Terminate, and any in-flight Task / Timer / runloop source
                // can stall that path long enough for the spawned successor
                // to bring up the new process alongside the still-dying old
                // one — net result is two CGEventTaps catching every keystroke
                // and every keyDown firing twice. exit(0) skips the AppKit
                // shutdown ceremony and guarantees the kernel reaps our event
                // tap before the successor process boots.
                exit(0)
            }
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
        // If the command is exactly "cursor" or "c" (case-insensitive), show the usage toast.
        // This is to handle the case where the user types ":cursor" or ":c" without coordinates, as the regex-based parsing below only matches when coordinates are present.
        if command.wholeMatch(of: /(?i)cursor|c/) != nil {
            commandExecutionHandler(command: .cursor)
            return
        }
        // Check to see if the .c or .cursor command is being executed
        /// ### Supported Syntaxes
        /// 1. **Bracketed format:** `cursor(X,Y)` or `c(X,Y)`
        /// 2. **Space-separated format:** `cursor X Y` or `c X Y`
        ///
        /// ### Capture Groups
        /// Because regex engines require unique names across alternative evaluation branches,
        /// the extracted coordinates are split into two sets of named capture groups:
        ///
        /// - **command**: The command name, either "cursor" or "c", captured case-insensitively.
        /// - **x**: The X-coordinate if the string uses the *bracketed* format.
        /// - **y**: The Y-coordinate if the string uses the *bracketed* format.
        /// - **x2**: The X-coordinate if the string uses the *space-separated* format.
        /// - **y2**: The Y-coordinate if the string uses the *space-separated* format.
        let fullCursorCommandRegex =
            /(?i)\b(?<command>cursor|c)\b(?:\s*\(\s*(?<x>\d+)\s*,\s*(?<y>\d+)\s*\)|\s+(?<x2>\d+)\s+(?<y2>\d+))/
        if let match = command.firstMatch(of: fullCursorCommandRegex) {
            // Typed regex literals expose named captures via dot syntax
            // (match.x, match.y, …). The string-subscript form match["x"] is
            // only available when Output == AnyRegexOutput — i.e., regexes
            // built at runtime via `Regex("...")`. We have a literal here, so
            // the typed accessor is what's available.
            let xString = match.x ?? match.x2
            let yString = match.y ?? match.y2
            if let x = xString.flatMap({ Int($0) }), let y = yString.flatMap({ Int($0) }) {
                debug("Parsed cursor command with coordinates: (\(x), \(y))")
                guard let currentScreenSize = Screen.currentSize() else {
                    return debug("Current screen size is unavailable in appState when executing cursor command")
                }
                let usable = CGRect(
                    x: appState.gridInset,
                    y: appState.gridInset,
                    width: max(0, currentScreenSize.width - 2 * appState.gridInset),
                    height: max(0, currentScreenSize.height - 2 * appState.gridInset)
                )
                let target = MotionTarget.toLineAndColumnCount(
                    screenWidth: currentScreenSize.width,
                    screenHeight: currentScreenSize.height,
                    gridInset: appState.gridInset,
                    columnsOnScreen: appState.resolvedGrid(usable: usable).cols,
                    rowsOnScreen: appState.resolvedGrid(usable: usable).rows,
                    columnCount: CGFloat(x),
                    lineCount: CGFloat(y)
                )
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
                CommandLine.shared.hide()
                appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
                return
            } else {
                debug("Failed to parse coordinates from command: \(command)")
            }
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
        let theme = appState.theme.commandLine
        let panelSize = CGSize(width: theme.width, height: theme.height)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
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

        let origin = theme.anchor.origin(
            in: currentScreen.visibleFrame,
            panelSize: panelSize,
            offsetX: theme.xOffset,
            offsetY: theme.yOffset
        )
        panel.setFrameOrigin(origin)

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
            let theme = state.theme.commandLine
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(":").foregroundColor(theme.prefixColor.swiftUI)
                    Text(cli.commandText)
                        .font(theme.textFont.swiftUI)
                        .foregroundColor(theme.textColor.swiftUI)
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
                            .font(theme.suggestionFont.swiftUI)
                            .foregroundColor(theme.suggestionTextColor.swiftUI)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                idx == highlighted
                                    ? theme.suggestionHighlight.swiftUI : Color.clear
                            )
                    }
                }
            }
            .frame(minWidth: CGFloat(theme.width - 20), alignment: .leading)
            .background(theme.material.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }
}
