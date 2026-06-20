import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// One-shot dense find: Esc cancels; any cell-character keystroke warps
    /// the cursor to that cell's CG-global center, then exits to normal mode.
    /// Modifier chords are rejected so Cmd-* / Ctrl-* still flow to the OS.
    @MainActor
    static func handleSpecialFindMode(ctx: KeyEventContext) {
        let event = ctx.event
        let appState = ctx.appState
        if event.keyCode == charToKeyCodeMap["Esc"] {
            guard event.modifierFlags.rawValue == 256 else { return }
            CursorSurroundedGridOverlay.shared.hide()
            Zoom.zoomOut()
            NeoMouse.enterNormalMode(appState: appState)
            return
        }
        guard
            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isSubset(of: [.shift, .capsLock])
        else { return }
        guard let keyChar = charToKeyCodeMap.keyChar(forKeyCode: event.keyCode) else {
            debug(".specialFind: no charToKeyCodeMap entry for keyCode \(event.keyCode)")
            return
        }
        guard
            let cellIndex = appState.findModeInnerGridDivisionCharacters.firstIndex(
                of: keyChar)
        else {
            debug(
                ".specialFind: '\(keyChar)' not in findModeInnerGridDivisionCharacters")
            return
        }
        let divisions = CursorSurroundedGridOverlay.shared.currentDivisions
        guard cellIndex < divisions * divisions else {
            debug(
                ".specialFind: cellIndex \(cellIndex) exceeds grid capacity \(divisions * divisions)"
            )
            return
        }
        let col = cellIndex % divisions
        let row = cellIndex / divisions
        guard
            let target = CursorSurroundedGridOverlay.shared.cellCenterCG(
                col: col, row: row)
        else {
            debug(".specialFind: cellCenterCG returned nil — overlay not shown?")
            return
        }
        Mouse.moveToGlobal(x: target.x, y: target.y)
        Zoom.zoomOut()
        CursorSurroundedGridOverlay.shared.hide()
        if let displayID = Screen.activeDisplays().first(where: {
            CGDisplayBounds($0).contains(target)
        }) {
            Zoom.focus(on: CGDisplayBounds(displayID))
        }
        NeoMouse.enterNormalMode(appState: appState)
    }
}
