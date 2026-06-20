import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Menu mode dispatch — Esc closes whichever menu is on-screen.
    /// MarksMenu uses ↑/↓/Return; RegisterMenu uses ←/→/Return + a search
    /// buffer that accumulates printable characters.
    @MainActor
    static func handleMenuMode(ctx: KeyEventContext, window: NeomouseType.MenuWindow) {
        let event = ctx.event
        let appState = ctx.appState
        if event.keyCode == charToKeyCodeMap["Esc"] {
            guard event.modifierFlags.rawValue == 256 else { return }
            MarksMenu.shared.hide()
            RegisterMenu.shared.hide()
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            return
        }
        switch window {
        case .marks:
            switch event.keyCode {
            case charToKeyCodeMap["UpArrow"]:
                MarksMenu.shared.selectPrev()
            case charToKeyCodeMap["DownArrow"]:
                MarksMenu.shared.selectNext()
            case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
                MarksMenu.shared.activateSelected()
            case charToKeyCodeMap["Backspace"], charToKeyCodeMap["Delete"]:
                MarksMenu.shared.deleteLastSearchChar()
            default:
                // Same printable-character gate as the .register branch:
                // reject Cmd/Ctrl/Opt chords, allow Shift+Caps, skip C0
                // controls + DEL so arrow / function keys don't leak into
                // the search buffer.
                guard
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .isSubset(of: [.shift, .capsLock])
                else { return }
                guard let chars = event.characters, !chars.isEmpty else { return }
                guard
                    chars.unicodeScalars.allSatisfy({
                        $0.value >= 0x20 && $0.value != 0x7F
                    })
                else { return }
                MarksMenu.shared.appendSearchChar(chars)
            }
        case .register:
            switch event.keyCode {
            case charToKeyCodeMap["LeftArrow"]:
                RegisterMenu.shared.selectPrev()
            case charToKeyCodeMap["RightArrow"]:
                RegisterMenu.shared.selectNext()
            case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
                RegisterMenu.shared.activateSelected()
            case charToKeyCodeMap["Backspace"], charToKeyCodeMap["Delete"]:
                RegisterMenu.shared.deleteLastSearchChar()
            default:
                guard
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .isSubset(of: [.shift, .capsLock])
                else { return }
                guard let chars = event.characters, !chars.isEmpty else { return }
                guard
                    chars.unicodeScalars.allSatisfy({
                        $0.value >= 0x20 && $0.value != 0x7F
                    })
                else { return }
                RegisterMenu.shared.appendSearchChar(chars)
            }
        }
    }
}
