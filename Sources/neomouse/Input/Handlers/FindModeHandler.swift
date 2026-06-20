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

    static func executeFindModeOperation(
        event: NSEvent, appState: NeoMouseState,
        currentScreenSize: CGSize
    ) {
        debug(
            "modifier: \(event.modifierFlags.rawValue), mode:\(appState.mode), keyCode:\(event.keyCode)"
        )
        guard case .find = appState.mode, event.modifierFlags.rawValue == 256 else {
            debug(
                "Cannot executeFindModeOperation as mode is \(appState.mode) or \(event.modifierFlags.rawValue) != 256"
            )
            return
        }
        //First get the convert of the keyCode to its equivalent character (as String)
        let keyCodeAsChar: String? = charToKeyCodeMap.keyChar(forKeyCode: event.keyCode)
        // debug(
        //     "executeFindModeOperation: keyCode: \(event.keyCode), keyCodeAsChar: \(keyCodeAsChar)")
        guard let keyCodeAsChar = keyCodeAsChar else {
            debug("Not a recognized keyCode, cannot find character for keyCode:\(event.keyCode)")
            return
        }

        guard
            case .find(let currentPendingOperation, let findState, let isQuickFind) =
                appState.mode
        else {
            return
        }
        //TODO: check if this is the best place to put this
        // appState.mode = .find(
        //     currentPendingOperation: (currentPendingOperation ?? "") + keyCodeAsChar,
        //     findState: findState,
        // )
        // First keypress
        if findState.pendingGridDivisionIndex == nil {
            //If there is a first index match for the character in
            //findModeGridDivisionCharacters, we set the pendingGridDivisionIndex to the
            //matching index
            // guard appState.findModeGridDivisionCharacters.contains(keyCodeAsChar) else {
            //     return ToastManager.shared.show(
            //         "Key: \(keyCodeAsChar) is not part of findModeGridDivisionCharacters:\(appState.findModeGridDivisionCharacters)"
            //     )
            // }
            guard
                let gridDivisionCharactersIndex = appState
                    .findModeGridDivisionCharacters.firstIndex(of: keyCodeAsChar)
            else {
                return debug(
                    "\(keyCodeAsChar) is not part of findModeGridDivisionCharacters"
                )
            }
            guard gridDivisionCharactersIndex < (appState.gridDivisions * appState.gridDivisions)
            else {
                return debug(
                    "\(keyCodeAsChar)'s gridDivisionCharactersIndex: \(gridDivisionCharactersIndex) is greater/equal \((appState.gridDivisions * appState.gridDivisions))"
                )
            }
            debug(
                "\(keyCodeAsChar) is in gridDivisionCharactersIndex: \(gridDivisionCharactersIndex)"
            )
            // Quick-find: one keypress lands the cursor on the picked cell.
            // Bounds check above already guarantees the index is < gridDivisions².
            if isQuickFind {
                let col = gridDivisionCharactersIndex % appState.gridDivisions
                let row = gridDivisionCharactersIndex / appState.gridDivisions
                let cellWidth =
                    (currentScreenSize.width - 2 * appState.gridInset)
                    / CGFloat(appState.gridDivisions)
                let cellHeight =
                    (currentScreenSize.height - 2 * appState.gridInset)
                    / CGFloat(appState.gridDivisions)
                let targetX = appState.gridInset + CGFloat(col) * cellWidth + cellWidth / 2
                let targetY = appState.gridInset + CGFloat(row) * cellHeight + cellHeight / 2
                Mouse.moveToScreenLocal(x: targetX, y: targetY)
                //IMPORTANT: Reset to defaultDivisions once done, this is also applied in cmd + e and Esc keypress in find mode
                appState.gridDivisions = Config.Grid.defaultDivisions
                enterNormalMode(appState: appState)
                return
            }
            let updatedFindState = NeomouseType.FindState(
                pendingGridDivisionIndex: gridDivisionCharactersIndex,
                pendingInnerGridDivisionIndex: nil
            )
            appState.mode = .find(
                currentPendingOperation: (currentPendingOperation ?? "") + keyCodeAsChar,
                findState: updatedFindState,
                isQuickFind: isQuickFind
            )

            // findState.pendingGridDivisionIndex =
            // gridDivisionCharactersIndex
            GridOverlay.shared.passAppState(state: appState)
            // Second keypress
        } else {
            // Normal find mode flow — second keypress, picking the inner cell.
            // `pendingGridDivisionIndex` must already be set (the outer cell
            // was selected on the first keypress). Bail out rather than crash
            // if the state somehow got out of sync.
            guard let outerIndex = findState.pendingGridDivisionIndex else {
                return debug(
                    "find inner-grid keypress arrived without a pendingGridDivisionIndex; ignoring"
                )
            }
            guard
                let innerGridDivisionCharactersIndex =
                    appState.findModeInnerGridDivisionCharacters.firstIndex(
                        of: keyCodeAsChar)
            else {
                return debug(
                    "\(keyCodeAsChar) is not part of findModeInnerGridDivisionCharacters"
                )
            }
            guard
                innerGridDivisionCharactersIndex
                    < (appState.innerGridDivisions * appState.innerGridDivisions)
            else {
                return debug(
                    "\(keyCodeAsChar)'s innerGridDivisionCharactersIndex: \(innerGridDivisionCharactersIndex) is greater/equal to \((appState.innerGridDivisions * appState.innerGridDivisions))"
                )
            }
            debug(
                "\(keyCodeAsChar) is in innerGridDivisionCharactersIndex: \(innerGridDivisionCharactersIndex)"
            )

            let updatedFindState = NeomouseType.FindState(
                pendingGridDivisionIndex: outerIndex,
                pendingInnerGridDivisionIndex: innerGridDivisionCharactersIndex
            )

            appState.mode = .find(
                currentPendingOperation: (currentPendingOperation ?? "") + keyCodeAsChar,
                findState: updatedFindState,
                isQuickFind: false
            )

            let col = outerIndex % appState.gridDivisions
            let row = outerIndex / appState.gridDivisions
            let innerCol =
                innerGridDivisionCharactersIndex
                // findState.pendingInnerGridDivisionIndex!
                % appState.innerGridDivisions
            let innerRow =
                innerGridDivisionCharactersIndex
                // findState.pendingInnerGridDivisionIndex!
                / appState.innerGridDivisions
            let cellWidth =
                (currentScreenSize.width - 2 * appState.gridInset)
                / CGFloat(appState.gridDivisions)
            let cellHeight =
                (currentScreenSize.height - 2 * appState.gridInset)
                / CGFloat(appState.gridDivisions)
            let innerCellWidth = cellWidth / CGFloat(appState.innerGridDivisions)
            let innerCellHeight = cellHeight / CGFloat(appState.innerGridDivisions)
            let targetX =
                appState.gridInset + CGFloat(col) * cellWidth + CGFloat(innerCol)
                * innerCellWidth + innerCellWidth / 2
            let targetY =
                appState.gridInset + CGFloat(row) * cellHeight + CGFloat(innerRow)
                * innerCellHeight + innerCellHeight / 2
            Mouse.moveToGlobal(x: targetX, y: targetY)
            // Mouse.moveToScreenLocal(x: targetX, y: targetY)
            enterNormalMode(appState: appState)
        }
    }
}
