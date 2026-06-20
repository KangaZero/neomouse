import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Find mode dispatch — Esc bails to normal; every other key flows into
    /// `executeFindModeOperation` which owns the grid-cell + inner-cell
    /// selection state machine.
    @MainActor
    static func handleFindMode(ctx: KeyEventContext) {
        let event = ctx.event
        let appState = ctx.appState
        switch event.keyCode {
        case charToKeyCodeMap["Esc"]:
            guard event.modifierFlags.rawValue == 256 else {
                break
            }
            appState.gridDivisions = Config.Grid.defaultDivisions
            NeoMouse.enterNormalMode(appState: appState)
        default: break
        }
        switch ctx.asciiKey {
        case "e":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    == .command
            else {
                return NeoMouse.executeFindModeOperation(
                    event: event, appState: appState,
                    currentScreenSize: ctx.currentScreenSize
                )
            }
        default:
            NeoMouse.executeFindModeOperation(
                event: event, appState: appState, currentScreenSize: ctx.currentScreenSize
            )
        }
    }
}
