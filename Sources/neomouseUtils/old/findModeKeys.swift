//
// import AppKit
// func executeFindModeKeys(event: NSEvent, appState: NeoMouseState, neoMouse: App) {
// switch event.keyCode {
//                     case keyCodeToCharMap["Esc"]:
//                         NeoMouse.exitFindMode(appState: appState)
//                     default:
//                         //First get the convert of the keyCode to its equivalent character (as String)
//                         let keyCodeAsChar: String? = keyCodeToCharMap.first(where: {
//                             $0.value == event.keyCode
//                         })?.key
//                         guard let keyCodeAsChar = keyCodeAsChar else {
//                             debug("Not a recognized keyCode, cannot find character (key)")
//                             break
//                         }
//
//                         //TODO: check if this is the best place to put this
//                         appState.pendingOperation.operation.append(keyCodeAsChar)
//                         // First keypress
//                         if appState.pendingOperation.pendingGridDivisionIndex == nil {
//                             //If there is a first index match for the character in
//                             //findModeGridDivisionCharacters, we set the pendingGridDivisionIndex to the
//                             //matching index
//                             guard
//                                 let gridDivisionCharactersIndex = appState
//                                     .findModeGridDivisionCharacters.firstIndex(of: keyCodeAsChar)
//                             else {
//                                 return debug(
//                                     "\(keyCodeAsChar) is not part of findModeGridDivisionCharacters"
//                                 )
//                             }
//                             appState.pendingOperation.pendingGridDivisionIndex =
//                                 gridDivisionCharactersIndex
//                             GridOverlay.shared.passAppState(state: appState)
//                             GridOverlay.shared.highlightCurrentGridDivision()
//                             // Second keypress
//                         } else {
//                             guard
//                                 let innerGridDivisionCharactersIndex =
//                                     appState.findModeInnerGridDivisionCharacters.firstIndex(
//                                         of: keyCodeAsChar)
//                             else {
//                                 return debug(
//                                     "\(keyCodeAsChar) is not part of findModeInnerGridDivisionCharacters"
//                                 )
//                             }
//                             appState.pendingOperation.pendingInnerGridDivisionIndex =
//                                 innerGridDivisionCharactersIndex
//                             appState.pendingOperation.operation.append(keyCodeAsChar)
//                             let col =
//                                 appState.pendingOperation.pendingGridDivisionIndex!
//                                 % appState.gridDivisions
//                             let row =
//                                 appState.pendingOperation.pendingGridDivisionIndex!
//                                 / appState.gridDivisions
//                             let innerCol =
//                                 appState.pendingOperation.pendingInnerGridDivisionIndex!
//                                 % appState.innerGridDivisions
//                             let innerRow =
//                                 appState.pendingOperation.pendingInnerGridDivisionIndex!
//                                 / appState.innerGridDivisions
//                             let cellWidth =
//                                 (NSScreen.main!.frame.width - 2 * appState.gridInset)
//                                 / CGFloat(appState.gridDivisions)
//                             let cellHeight =
//                                 (NSScreen.main!.frame.height - 2 * appState.gridInset)
//                                 / CGFloat(appState.gridDivisions)
//                             let innerCellWidth = cellWidth / CGFloat(appState.innerGridDivisions)
//                             let innerCellHeight = cellHeight / CGFloat(appState.innerGridDivisions)
//                             let targetX =
//                                 appState.gridInset + CGFloat(col) * cellWidth + CGFloat(innerCol)
//                                 * innerCellWidth + innerCellWidth / 2
//                             let targetY =
//                                 appState.gridInset + CGFloat(row) * cellHeight + CGFloat(innerRow)
//                                 * innerCellHeight + innerCellHeight / 2
//                             moveMouseByExactCoordinates(x: targetX, y: targetY)
//                             NeoMouse.exitFindMode(appState: appState)
//
//                         }
//                     }
//                 }
//
// }
