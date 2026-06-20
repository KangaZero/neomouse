import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Command-line mode dispatch. Owns the `:command` buffer + wildmenu
    /// suggestion cycling. Tab / Shift-Tab and Ctrl-n / Ctrl-p cycle
    /// suggestions; Return executes the highlighted entry (or the typed
    /// command if nothing is highlighted); printable chars accumulate into
    /// the buffer; Cmd/Ctrl/Opt chords are rejected so the OS still sees them.
    @MainActor
    static func handleCommandMode(
        ctx: KeyEventContext, currentCommand: String, suggestionIndex: Int?
    ) {
        let event = ctx.event
        let appState = ctx.appState
        let asciiKey = ctx.asciiKey
        let asciiKeyBase = ctx.asciiKeyBase

        //TODO move to neomouseUtils
        func appendCharacterToCommand() {
            guard let character = asciiKey else { return }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.contains(.command),
                !mods.contains(.control),
                !mods.contains(.option)
            else { return }
            appState.mode = .command(command: currentCommand + character, suggestionIndex: nil)
        }
        switch event.keyCode {
        case charToKeyCodeMap["Esc"]:
            guard event.modifierFlags.rawValue == 256 else {
                break
            }
            HelpDialog.shared.hide()
            CommandLine.shared.hide()
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            return
        case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
            if let suggestionIndex {
                CommandLine.shared.executeSuggestionCommand(at: suggestionIndex)
                CommandLine.shared.hide()
            } else {
                debug("execute command: \(currentCommand)")

                CommandLine.shared.executeCommand(at: currentCommand)
                CommandLine.shared.hide()
                appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            }
            return
        case charToKeyCodeMap["Backspace"], charToKeyCodeMap["Delete"]:
            appState.mode = .command(
                command: String(currentCommand.dropLast()),
                suggestionIndex: nil
            )
            return
        case charToKeyCodeMap["Tab"]:
            let matches = CommandLine.shared.filtered
            guard !matches.isEmpty else { return }
            let isReverse = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            let next: Int
            if let currentSuggestionIndex = suggestionIndex {
                next =
                    isReverse
                    ? (currentSuggestionIndex - 1 + matches.count) % matches.count
                    : (currentSuggestionIndex + 1) % matches.count
            } else {
                next = isReverse ? matches.count - 1 : 0
            }
            appState.mode = .command(command: currentCommand, suggestionIndex: next)
            return
        default:
            break
        }
        switch asciiKeyBase {
        case "n", "N":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .control, .shift, .capsLock,
                    ])
            else {
                return appendCharacterToCommand()
            }
            let matches = CommandLine.shared.filtered
            guard !matches.isEmpty else { return }
            let next: Int
            if let currentSuggestionIndex = suggestionIndex {
                next = (currentSuggestionIndex + 1) % matches.count
            } else {
                next = 0
            }
            appState.mode = .command(command: currentCommand, suggestionIndex: next)
            return
        case "p", "P":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .control, .shift, .capsLock,
                    ])
            else {
                return appendCharacterToCommand()
            }
            let matches = CommandLine.shared.filtered
            guard !matches.isEmpty else { return }
            let next: Int
            if let currentSuggestionIndex = suggestionIndex {
                next = (currentSuggestionIndex - 1 + matches.count) % matches.count
            } else {
                next = matches.count - 1
            }
            appState.mode = .command(command: currentCommand, suggestionIndex: next)
            return
        default:
            return appendCharacterToCommand()
        }
    }
}
