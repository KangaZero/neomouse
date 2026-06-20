import AppKit
import Combine
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Build the global key-event handler closure that the CGEventTap
    /// invokes on every keydown. Computes the per-keystroke derived values
    /// (cursor position, active display, operation count, ASCII-normalized
    /// characters), handles the Cmd-E enable/disable toggle, then bundles a
    /// `KeyEventContext` and dispatches into the matching per-mode handler.
    static func makeKeyHandler(
        appState: NeoMouseState,
        currentSession: Session,
        sessionId: Int64
    ) -> (NSEvent) -> Void {
        return { event in
            MainActor.assumeIsolated {
                let _currentCGPoint = Mouse.location()
                //IMPORTANT: both _currentScreenSize && currentDisplayBounds will default to main screen if nothing is found
                let _currentScreenSize = Screen.currentSize()
                let currentDisplayBounds =
                    _currentCGPoint.flatMap { pt in
                        Screen.activeDisplays().first(where: { CGDisplayBounds($0).contains(pt) })
                            .map { CGDisplayBounds($0) }
                    } ?? CGDisplayBounds(CGMainDisplayID())
                guard let currentCGPoint = _currentCGPoint,
                    let currentScreenSize = _currentScreenSize
                    // let currentDisplayBounds = _currentDisplayBounds
                else {
                    debug(
                        """
                        [guard fail]
                          currentCGPoint    = \(String(describing: _currentCGPoint))
                          currentScreenSize = \(String(describing: _currentScreenSize))
                          currentDisplay    = \(String(describing: currentDisplayBounds))
                          activeDisplays    = \(Screen.activeDisplays())
                        """
                    )
                    return
                }
                // currentCGPoint is global CG space (top-left of primary = origin).
                // Subtract display origin to get screen-local CG coords.
                let localCGPoint = CGPoint(
                    x: currentCGPoint.x - currentDisplayBounds.origin.x,
                    y: currentCGPoint.y - currentDisplayBounds.origin.y
                )
                //INFO: Set as a CGFloat instead of Double or UInt as to be compatible with
                //CGWarpMouseCursorPosition
                let operationCount: CGFloat
                if case .normal(_, let operationCountAsString) = appState.mode,
                    let operationCountStringed = operationCountAsString,
                    let currentPendingNormalOperationAsFloat: Float =
                        Float(
                            operationCountStringed.filter {
                                $0.isNumber || $0 == "."
                            },
                        ),
                    currentPendingNormalOperationAsFloat > 0
                {
                    operationCount = CGFloat(currentPendingNormalOperationAsFloat)
                } else {
                    operationCount = 1
                }
                // Layout-independent ASCII characters for keybind matching, so
                // Vim motions resolve while the user is on Cyrillic / Greek /
                // Pinyin / Hangul / etc. `asciiKey` mirrors NSEvent.characters
                // (shift+option applied); `asciiKeyBase` mirrors
                // NSEvent.charactersIgnoringModifiers (only shift respected).
                // User-supplied data (mark/register names, free-form text
                // typed in menus) intentionally keeps reading
                // `event.characters` so users can name things in their native
                // script.
                let asciiKey = asciiChar(forEvent: event)
                let asciiKeyBase = asciiCharIgnoringModifiers(forEvent: event)
                let _key = charToKeyCodeMap.keyChar(forKeyCode: event.keyCode) ?? "?"
                debug(
                    """
                    [keyDown]
                      key = \(_key)(keyCode=\(event.keyCode))
                      characters = \(String(describing: event.characters))
                      charactersIgnoringModifiers = \(String(describing: event.charactersIgnoringModifiers))
                      modifiers = \(event.modifierFlags.rawValue)
                      mode = \(appState.mode)
                      cgPoint = (\(Int(currentCGPoint.x)), \(Int(currentCGPoint.y)))
                      localCGPoint = (\(Int(localCGPoint.x)), \(Int(localCGPoint.y)))
                      display = \(currentDisplayBounds)
                      operationCount = \(operationCount)
                    """
                )
                if asciiKey == "e" && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    debug("appState = \(appState.mode)")
                    if case .disabled = appState.mode {
                        appState.mode = .normal(
                            currentPendingOperation: .none,
                            operationCountAsString: nil
                        )
                        ToastManager.shared.show(
                            "Neomouse Activated - Normal Mode")
                        return
                    } else {
                        if appState.isVisual {
                            CoreOperations.exitVisualState(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                        }
                        appState.gridDivisions = Config.Grid.defaultDivisions
                        appState.mode = .disabled
                        GridOverlay.shared.hideGrid()
                        CursorSurroundedGridOverlay.shared.hide()
                        HelpDialog.shared.hide()
                        CommandLine.shared.hide()
                        MarksMenu.shared.hide()
                        RegisterMenu.shared.hide()
                        ToastManager.shared.show("NeoMouse Deactivated")
                        return
                    }
                }
                //TODO take in account of other keyboard layouts for event.keyCode
                // Bundle everything the per-mode handlers need into a single
                // value, then dispatch. Each handler lives in KeyHandlers.swift.
                let ctx = KeyEventContext(
                    event: event,
                    appState: appState,
                    currentSession: currentSession,
                    sessionId: sessionId,
                    currentCGPoint: currentCGPoint,
                    localCGPoint: localCGPoint,
                    currentDisplayBounds: currentDisplayBounds,
                    currentScreenSize: currentScreenSize,
                    operationCount: operationCount,
                    asciiKey: asciiKey,
                    asciiKeyBase: asciiKeyBase
                )
                switch appState.mode {
                case .disabled:
                    NeoMouse.handleDisabledMode(ctx: ctx)
                    return
                case .normal(let op, let countString):
                    NeoMouse.handleNormalMode(
                        ctx: ctx,
                        currentPendingNormalOperation: op,
                        operationCountAsString: countString
                    )
                    NeoMouse.autoSnapToCursorBandIfNeeded(appState: appState)
                    CoreOperations.setFrontMostAppOnCursorAsActiveIfNeeded(appState)
                case .find:
                    NeoMouse.handleFindMode(ctx: ctx)
                    CoreOperations.setFrontMostAppOnCursorAsActiveIfNeeded(appState)
                case .command(let command, let suggestionIndex):
                    NeoMouse.handleCommandMode(
                        ctx: ctx, currentCommand: command, suggestionIndex: suggestionIndex
                    )
                case .menu(let window):
                    NeoMouse.handleMenuMode(ctx: ctx, window: window)
                case .specialFind:
                    NeoMouse.handleSpecialFindMode(ctx: ctx)
                    CoreOperations.setFrontMostAppOnCursorAsActiveIfNeeded(appState)
                }

                //INFO: after every non-integer keypress, excluding 0 which can be both a command and a count, we reset the operationCountAsString to nil to reset the count for the next operation
                //Non-integer keypress generally needs to break at the end, while integer keypress will return early before reaching this point, so the operationCountAsString is only updated for integer keypress and reset for non-integer keypress
                // switch appState.mode {
                // case .normal(.none), .find:
                //     appState.operationCountAsString = nil
                // default:
                //     break
                // }
            }
        }
    }

    /// Auto-snap: when `is_auto_snap` is enabled warp the cursor
    /// to the centre of the grid cell it sits in so it lines up exactly with
    /// the highlighted band. Reuses `NumbersOverlay.snapCursor()` — the same
    /// path the manual `s` keybind uses — which recomputes the cell index from
    /// the live cursor position first, so it's safe to call right after a
    /// motion has warped the cursor. No-op when auto-snap is off or no band is
    /// active.
    @MainActor
    static func autoSnapToCursorBandIfNeeded(appState: NeoMouseState) {
        guard appState.isAutoSnap else {
            return
            //             debug(
            // """
            // autoSnapToCursorBandIfNeeded fn - isAutoSnap : \(String(describing:appState.isAutoSnap))\
            //                                   hasActiveCursorBand : \(String(describing: NumbersOverlay.shared.hasActiveCursorBand))
            // """)
        }
        NumbersOverlay.shared.snapCursor()
    }

    static func enterNormalMode(appState: NeoMouseState) {
        //TODO: NICE TO HAVE use previous session's
        appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
        GridOverlay.shared.hideGrid()
        ToastManager.shared.show(
            "Normal Mode")
    }
}
