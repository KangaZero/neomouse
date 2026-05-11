import AppKit
import SwiftUI

//
// struct PendingOperation {
//     var operation: String
//     var pendingGridDivisionIndex: Int?
//     var pendingInnerGridDivisionIndex: Int?
// }

class NeoMouseState: ObservableObject {
    @Published var mode: Mode = .disabled
    // @Published var isNeomouseMode = false
    // @Published var isFindMode = false
    // @Published var isCommandLineMode = false
    @Published var gridInset: CGFloat = 10
    //TODO Eventually use Session.Operations Table for the below Published var
    @Published var isVisual: Bool = false
    @Published var previousStartCGXPoint: CGFloat? = nil
    @Published var previousStartCGYPoint: CGFloat? = nil
    @Published var previousEndCGXPoint: CGFloat? = nil
    @Published var previousEndCGYPoint: CGFloat? = nil
    @Published var startCGXPoint: CGFloat? = nil
    @Published var startCGYPoint: CGFloat? = nil
    @Published var endCGXPoint: CGFloat? = nil
    @Published var endCGYPoint: CGFloat? = nil

    let commands: [String] = ["numbers, relativenumbers"]
    //WARNING: Until a good dynamic solution is found, do not allow these 2 to be mutable, could be a headache as divisionCharacters may
    //need to added in to take in account if gridDivisions increased
    let gridDivisions: Int = 5
    let innerGridDivisions: Int = 3
    let findModeGridDivisionCharacters: [String] = "abcdefghijklmnopqrstuvwxyz".map {
        String($0)
    }
    let findModeInnerGridDivisionCharacters: [String] = "abcdefghijklmnopqrstuvwxyz".map {
        String($0)
    }
    let linesOnScreen: CGFloat = 50
    let minimumHighlightWidth = 5
    let rangeX: CGFloat = 20
    let rangeY: CGFloat = 20

    // Gesture related settings
    let zoomStepValue: Double = 0.1  // from 0.01 to 10
    let incrementsPerGesture: UInt = 5
    let degreesToRotate: Double = 90
    // let isIgnoresSafeArea = true
    let isAlwaysShowInnerGridCharacters = true
    let isClampCursorToCurrentScreen = false
}

@main
struct NeoMouse: App {
    private static var keyMonitor: Any?
    private static var mouseMonitor: Any?
    private static let sharedState = NeoMouseState()
    @StateObject private var appState = NeoMouse.sharedState

    init() {
        //TODO add checks to make sure no unintended behavior of out of bounds access happens
        // eg.. gridDivisions * gridDivisions <=findModeGridDivisionCharacters.count, and similar for
        // innerGridDivisions
        initializeDB(forceReSeed: false)

        let appState = NeoMouse.sharedState
        // KeyCast.shared.passAppState(state: appState)
        NeoMouse.keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let _currentCGPoint = getCurrentMouseLocation()
                let _allScreensBoundingRect = getAllScreensBoundingRect()
                let _currentScreenSize = getCurrentScreenSize()
                let _currentDisplayBounds = _currentCGPoint.flatMap { pt in
                    getActiveDisplays().first(where: { CGDisplayBounds($0).contains(pt) })
                        .map { CGDisplayBounds($0) }
                }
                guard let currentCGPoint = _currentCGPoint,
                    let currentScreenSize = _currentScreenSize,
                    let currentDisplayBounds = _currentDisplayBounds
                else {
                    debug(
                        """
                        [guard fail]
                          currentCGPoint    = \(String(describing: _currentCGPoint))
                          currentScreenSize = \(String(describing: _currentScreenSize))
                          currentDisplay    = \(String(describing: _currentDisplayBounds))
                        """
                    )
                    return
                }
                debug("allScreensRect: \(String(describing: _allScreensBoundingRect))")
                // currentCGPoint is global CG space (top-left of primary = origin).
                // Subtract display origin to get screen-local CG coords.
                let localCGPoint = CGPoint(
                    x: currentCGPoint.x - currentDisplayBounds.origin.x,
                    y: currentCGPoint.y - currentDisplayBounds.origin.y
                )
                //INFO: Set as a CGFloat instead of Double or UInt as to be compatible with
                //CGWarpMouseCursorPosition
                var operationCount: CGFloat = 1
                if case .normal(let currentPendingNormalOperation) = appState.mode,
                    let currentPendingNormalOperation,
                    let currentPendingNormalOperationAsFloat =
                        Float(
                            currentPendingNormalOperation.filter {
                                $0.isNumber || $0 == "."
                            },

                        ),
                    currentPendingNormalOperationAsFloat != 0
                {
                    operationCount = CGFloat(currentPendingNormalOperationAsFloat)
                }
                let _key = keyCodeToCharMap.first(where: { $0.value == event.keyCode })?.key ?? "?"
                debug(
                    """
                    [keyDown]
                      key            = \(_key) (keyCode=\(event.keyCode))
                      modifiers      = \(event.modifierFlags.rawValue)
                      mode           = \(appState.mode)
                      cgPoint        = (\(Int(currentCGPoint.x)), \(Int(currentCGPoint.y)))
                      localCGPoint   = (\(Int(localCGPoint.x)), \(Int(localCGPoint.y)))
                      display        = \(currentDisplayBounds)
                      operationCount = \(operationCount)
                    """
                )
                //TODO take in account of other keyboard layouts
                switch appState.mode {
                case .disabled:
                    switch event.characters {
                    case "e":
                        guard
                            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                == .command
                        else {
                            return
                        }
                        appState.mode = .normal(
                            //TODO get session's last mode and pending operation and set to that instead of always resetting to normal mode with no pending operation
                            currentPendingOperation: nil,
                        )
                        ToastManager.shared.show(
                            "Neomouse Activated - Normal Mode")
                        return
                    default:
                        return
                    }
                case .normal(let currentPendingNormalOperation):
                    switch event.keyCode {
                    case keyCodeToCharMap["Esc"]:
                        guard event.modifierFlags.rawValue == 256 else {
                            break
                        }
                        if appState.isVisual {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                        }
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    default: break
                    }
                    switch event.characters {
                    case "e":
                        guard
                            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                == .command
                        else {

                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        //TODO make this into a reusable fn disableNeoMouse
                        if appState.isVisual {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                        }
                        appState.mode = .disabled
                        ToastManager.shared.show(
                            "Neomouse Deactivated")
                        return
                    //TODO: Add "$", "^ : where it will go to the most left/right of the current
                    //focused window", "g$" for most right, hjkl, counters,
                    case "f":
                        // debug(
                        //     "modifierFlags:\(event.modifierFlags.rawValue), isNeomouseMode:true, key:f, keyCode:\(event.keyCode) - not activating find mode because modifier is pressed"
                        // )
                        //INFO: 256 means no modifier is pressed, do not use .isEmpty method
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        appState.mode = .find(
                            currentPendingOperation: nil,
                            findState: FindState()
                        )
                        GridOverlay.shared.passAppState(state: appState)
                        GridOverlay.shared.showGrid()
                        ToastManager.shared.show(
                            "Find Mode")
                        return
                    // INFO: Here starts VIM-like motions on the cursor
                    //TODO check that if the operation except the lastIndex are only nums
                    case "h", "j", "k", "l":
                        guard
                            event.modifierFlags.rawValue == 256,
                            let key = event.characters,
                            let direction = HJKLDirection(key)
                        else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        let delta = direction.delta(
                            stepX: appState.rangeX,
                            stepY: appState.rangeY,
                            count: operationCount)
                        moveMouseRelatively(
                            x: delta.dx, y: delta.dy,
                            enableClampToCurrentScreen:
                                appState.isClampCursorToCurrentScreen)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    //INFO: No need to do modifierFlags checks for captizalized chars, as a
                    //modifierFlag will trigger the lowercase char equivalent
                    case "G":
                        moveMouseByExactCoordinatesOnCurrentScreen(
                            x: localCGPoint.x,
                            y: currentScreenSize.height - appState.gridInset)
                        break
                    case "g":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        appState.mode = .normal(
                            currentPendingOperation: (currentPendingNormalOperation ?? "") + "g",
                        )
                        // "g" instead of "gg" as the following "g" is only appended/updated onto appState after current MainActor event
                        if operationCount > 0 && currentPendingNormalOperation?.last == "g" {
                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: localCGPoint.x,
                                y: ((currentScreenSize.height - appState.gridInset)
                                    / appState.linesOnScreen)
                                    * operationCount)
                            // y: appState.gridInset + currentScreenSize.height
                            //     - ((currentScreenSize.height / appState.linesOnScreen)
                            //         * operationCount))
                            appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                            break
                        } else if currentPendingNormalOperation == "g" {
                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: localCGPoint.x, y: 0 + appState.gridInset)
                            appState.mode = .normal(
                                currentPendingOperation: "gg",
                            )
                            //TODO dont reset normal mode just yet, need to account for ggvG
                            //TODO Remove below when v is added
                            appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                            break
                        }
                        break
                    case "V":
                        appState.isVisual.toggle()
                        guard appState.isVisual else {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                            return
                        }
                        let lineHeight = currentScreenSize.height / appState.linesOnScreen
                        let startCGPoint = CGPoint(
                            x: currentDisplayBounds.origin.x + appState.gridInset,
                            y: currentCGPoint.y)
                        let endCGPoint = CGPoint(
                            x: currentDisplayBounds.origin.x + currentScreenSize.width
                                - appState.gridInset,
                            y: currentCGPoint.y + lineHeight)
                        moveMouseByExactGlobalCGPoint(x: startCGPoint.x, y: startCGPoint.y)
                        mouseDown(.left, at: startCGPoint)
                        moveMouseByExactGlobalCGPoint(x: endCGPoint.x, y: endCGPoint.y)
                        appState.startCGXPoint = startCGPoint.x
                        appState.startCGYPoint = startCGPoint.y
                        appState.endCGXPoint = endCGPoint.x
                        appState.endCGYPoint = endCGPoint.y
                        VisualHighlightOverlay.shared.passAppState(state: appState)
                        break
                    case "v":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(currentPendingOperation: nil)
                        }
                        appState.isVisual.toggle()
                        guard appState.isVisual else {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                            return
                        }
                        if currentPendingNormalOperation == "g"
                            && appState.previousStartCGXPoint != nil
                            && appState.previousStartCGYPoint != nil
                            && appState.previousEndCGXPoint != nil
                            && appState.previousEndCGYPoint != nil
                        {
                            mouseDown(.left, at: currentCGPoint)
                            appState.startCGXPoint = appState.previousStartCGXPoint
                            appState.startCGYPoint = appState.previousStartCGYPoint
                            appState.endCGXPoint = appState.previousEndCGXPoint
                            appState.endCGYPoint = appState.previousEndCGYPoint
                            VisualHighlightOverlay.shared.passAppState(state: appState)
                            moveMouseByExactGlobalCGPoint(
                                x: appState.previousEndCGXPoint!,
                                y: appState.previousEndCGYPoint!)
                            appState.mode = .normal(currentPendingOperation: nil)
                        } else {
                            //Go to Visual state
                            mouseDown(.left, at: currentCGPoint)
                            appState.startCGXPoint = currentCGPoint.x
                            appState.startCGYPoint = currentCGPoint.y
                            appState.endCGXPoint = currentCGPoint.x
                            appState.endCGYPoint = currentCGPoint.y
                            VisualHighlightOverlay.shared.passAppState(state: appState)
                            appState.mode = .normal(currentPendingOperation: nil)
                        }
                        break
                    case "o", "O":
                        guard appState.isVisual,
                            let sx = appState.startCGXPoint,
                            let sy = appState.startCGYPoint,
                            let ex = appState.endCGXPoint,
                            let ey = appState.endCGYPoint
                        else {
                            return appState.mode = .normal(currentPendingOperation: nil)
                        }
                        // Pure anchor↔cursor swap. The mouse monitor is the single source
                        // of truth for endCG* — after the cursor warp dispatches, it'll
                        // overwrite endCG* with the cursor's new position (= old start),
                        // which matches what we set here.
                        appState.startCGXPoint = ex
                        appState.startCGYPoint = ey
                        appState.endCGXPoint = sx
                        appState.endCGYPoint = sy
                        moveMouseByExactGlobalCGPoint(x: sx, y: sy)
                        appState.mode = .normal(currentPendingOperation: nil)
                        break
                    case "M":
                        moveMouseByExactCoordinatesOnCurrentScreen(
                            x: localCGPoint.x,
                            y: currentScreenSize.height / 2)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case "m":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }

                        if currentPendingNormalOperation == nil {
                            //TODO add mark fn
                        } else if currentPendingNormalOperation == "g" {
                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: currentScreenSize.width / 2,
                                y: localCGPoint.y)
                            appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                            break
                        }
                        debug(
                            "Should not happen: operation 'm' should not fall through to execute nothing"
                        )
                        break
                    //INFO: Instead of vim's replace single char, this is the rotate gesture
                    case "r":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        rotate(
                            degrees: appState.degreesToRotate, at: currentCGPoint,
                            incrementsPerGesture:
                                appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case "R":
                        rotate(
                            degrees: -appState.degreesToRotate, at: currentCGPoint,
                            incrementsPerGesture:
                                appState.incrementsPerGesture)
                        // Always reset pendingOperation as to reset the operationCount
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    //TODO change to current focused app and add in for g0
                    case "0":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        //Not a count-based operation, so execute "go to start of current
                        //x-axis-line (Similar to Vim's go to start of line)
                        guard
                            currentPendingNormalOperation == nil
                        else {
                            debug(
                                ""
                            )
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "0",
                            )
                            //TODO: Add to counter operation
                            break
                        }
                        moveMouseByExactCoordinatesOnCurrentScreen(
                            x: 0 + appState.gridInset, y: localCGPoint.y)
                    case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        appState.mode = .normal(
                            currentPendingOperation: (currentPendingNormalOperation ?? "")
                                + event.characters!
                        )
                        break
                    // TODO change to current focused app and add in for g$
                    case "$":
                        moveMouseByExactCoordinatesOnCurrentScreen(
                            x: currentScreenSize.width - appState.gridInset, y: localCGPoint.y)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case "+":
                        pinchZoom(
                            .in, at: currentCGPoint,
                            stepValue: operationCount * appState.zoomStepValue,
                            incrementsPerGesture: appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case "-":
                        pinchZoom(
                            .out, at: currentCGPoint,
                            stepValue: operationCount * appState.zoomStepValue,
                            incrementsPerGesture: appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    default: break
                    }
                case .find:
                    switch event.keyCode {
                    case keyCodeToCharMap["Esc"]:
                        guard event.modifierFlags.rawValue == 256 else {
                            break
                        }
                        NeoMouse.enterNormalMode(appState: appState)
                        break
                    default: break
                    }
                    switch event.characters {
                    case "e":
                        guard
                            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                == .command
                        else {
                            return NeoMouse.executeFindModeOperation(
                                event: event, appState: appState,
                                currentScreenSize:
                                    currentScreenSize)
                        }
                        if appState.isVisual {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                        }
                        appState.mode = .disabled
                        GridOverlay.shared.hideGrid()
                        ToastManager.shared.show("NeoMouse Deactivated")
                        return

                    // case keyCodeToCharMap["f"]:
                    //     guard event.modifierFlags.isEmpty else { return }
                    //     debug(
                    //         "modifierFlags:false, modifier: \(event.modifierFlags), isNeomouseMode:\(appState.isNeomouseMode), key:f, keyCode:\(event.keyCode)"
                    //     )
                    //     if !appState.isFindMode {
                    //         appState.isFindMode.toggle()
                    //         GridOverlay.shared.passAppState(state: appState)
                    //         GridOverlay.shared.toggle()
                    //         ToastManager.shared.show(
                    //             "Find Mode \(appState.isFindMode ? "On" : "Off")")
                    //     } else {
                    //         NeoMouse.executeFindModeOperation(event: event, appState: appState)
                    //     }
                    //
                    default:
                        NeoMouse.executeFindModeOperation(
                            event: event, appState: appState, currentScreenSize: currentScreenSize)
                        break
                    }
                default:
                    debug(
                        "Should not happen: Reached default case in keyMonitor with mode:\(appState.mode) and keyCode:\(event.keyCode)"
                    )
                    break
                }
            }
        }
        NeoMouse.mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { _ in
            MainActor.assumeIsolated {
                guard appState.isVisual, let loc = getCurrentMouseLocation() else { return }
                appState.endCGXPoint = loc.x
                appState.endCGYPoint = loc.y
            }
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
    private static func enterNormalMode(appState: NeoMouseState) {
        //TODO: NICE TO HAVE use previous session's
        appState.mode = .normal(currentPendingOperation: nil)
        GridOverlay.shared.hideGrid()
        ToastManager.shared.show(
            "Normal Mode")
    }
    private static func executeFindModeOperation(
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
        let keyCodeAsChar: String? = keyCodeToCharMap.first(where: {
            $0.value == event.keyCode
        })?.key
        // debug(
        //     "executeFindModeOperation: keyCode: \(event.keyCode), keyCodeAsChar: \(keyCodeAsChar)")
        guard let keyCodeAsChar = keyCodeAsChar else {
            debug("Not a recognized keyCode, cannot find character for keyCode:\(event.keyCode)")
            return
        }

        guard
            case .find(let currentPendingOperation, let findState) =
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
            let updatedFindState = FindState(
                pendingGridDivisionIndex: gridDivisionCharactersIndex,
                pendingInnerGridDivisionIndex: nil
            )
            appState.mode = .find(
                currentPendingOperation: (currentPendingOperation ?? "") + keyCodeAsChar,
                findState: updatedFindState,
            )
            // findState.pendingGridDivisionIndex =
            // gridDivisionCharactersIndex
            GridOverlay.shared.passAppState(state: appState)
            GridOverlay.shared.highlightCurrentGridDivision()
            // Second keypress
        } else {
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

            let updatedFindState = FindState(
                pendingGridDivisionIndex: findState.pendingGridDivisionIndex,
                pendingInnerGridDivisionIndex: innerGridDivisionCharactersIndex
            )

            appState.mode = .find(
                currentPendingOperation: (currentPendingOperation ?? "") + keyCodeAsChar,
                findState: updatedFindState,
            )
            // findState.pendingInnerGridDivisionIndex =
            //     innerGridDivisionCharactersIndex
            // currentPendingOperation.append(keyCodeAsChar)

            let col =
                findState.pendingGridDivisionIndex!
                % appState.gridDivisions
            let row =
                findState.pendingGridDivisionIndex!
                / appState.gridDivisions
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
            moveMouseByExactCoordinatesOnCurrentScreen(x: targetX, y: targetY)
            NeoMouse.enterNormalMode(appState: appState)

        }
    }
}

// MARK: - Toast

@MainActor
final class ToastManager {
    static let shared = ToastManager()
    private var window: NSPanel?

    func show(_ message: String) {

        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) })
        else {
            return debug("Could not retrieve current screen in ToastManager.show")
        }
        window?.close()

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: ToastView(message: message))

        let x = currentScreen.visibleFrame.maxX - 320
        let y = currentScreen.visibleFrame.minY + 20
        panel.setFrameOrigin(CGPoint(x: x, y: y))

        panel.orderFront(nil)
        window = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .foregroundColor(.white)
            Text(message)
                .foregroundColor(.white)
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(10)
    }
}

@MainActor
final class VisualHighlightOverlay {
    static let shared = VisualHighlightOverlay()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    func passAppState(state: NeoMouseState) {
        appState = state
        toggle()
    }
    func toggle() {
        guard let appState, appState.isVisual == true else { return }
        let unionAppKit = cgRectToAppKitRect(getAllScreensBoundingRect())
        if window == nil {
            let win = NSWindow(
                contentRect: unionAppKit,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver  // 101
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: VisualHighlightOverlayView(state: appState))
            window = win
        }
        window?.setFrame(unionAppKit, display: true)
        window?.orderFrontRegardless()
    }

    func hideOverlay() {
        window?.orderOut(nil)
    }
}

struct VisualHighlightOverlayView: View {
    @ObservedObject var state: NeoMouseState

    let currentCGPoint = getCurrentMouseLocation()
    private var startX: CGFloat { state.startCGXPoint ?? 0 }
    private var startY: CGFloat { state.startCGYPoint ?? 0 }
    private var endX: CGFloat { state.endCGXPoint ?? startX }
    private var endY: CGFloat { state.endCGYPoint ?? startY }

    private var width: CGFloat { abs(endX - startX) }
    private var height: CGFloat { abs(endY - startY) }

    var body: some View {
        guard state.isVisual, width > 0, height > 0 else { return AnyView(EmptyView()) }

        // state.*CG*Point are CG-global. The SwiftUI view's (0,0) is the top-left of the
        // window, which spans getAllScreensBoundingRect(). Subtract that origin to land
        // in view-local coords.
        let unionOrigin = getAllScreensBoundingRect().origin
        let centerX = (startX + endX) / 2 - unionOrigin.x
        let centerY = (startY + endY) / 2 - unionOrigin.y

        return AnyView(
            GeometryReader { _ in
                Rectangle()
                    .fill(.yellow.opacity(0.3))
                    .frame(width: width, height: height)
                    .position(x: centerX, y: centerY)
            }
        )
    }
}

// MARK: - Grid Overlay

@MainActor
final class GridOverlay {
    static let shared = GridOverlay()
    private var window: NSWindow?
    private var isVisible = false
    private weak var appState: NeoMouseState?

    func toggle() {
        // appState = state
        isVisible ? hide() : show()
        isVisible.toggle()
    }

    func passAppState(state: NeoMouseState) {
        appState = state
    }

    func showGrid() {
        isVisible = true
        show()
    }

    func hideGrid() {
        isVisible = false
        hide()
    }

    func highlightCurrentGridDivision() {

    }

    private func show() {
        guard let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState,
            case .find = appState.mode
        else {
            return
                debug("Should not happen: not in find mode within GridOverlayView")
        }
        if window == nil {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver  // 101
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: GridOverlayView(state: appState))
            window = win
        }
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
    }

    private func hide() {
        window?.orderOut(nil)
    }
}

// MARK: - Grid View

struct GridOverlayView: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.15)
                Canvas { ctx, _ in
                    let inset = state.gridInset
                    let startX = inset
                    let endX = geo.size.width - inset
                    let startY = inset
                    let endY = geo.size.height - inset
                    let cellWidth = (endX - startX) / CGFloat(state.gridDivisions)
                    let cellHeight = (endY - startY) / CGFloat(state.gridDivisions)
                    let innerCellWidth = cellWidth / CGFloat(state.innerGridDivisions)
                    let innerCellHeight = cellHeight / CGFloat(state.innerGridDivisions)
                    guard case .find(_, let findState) = state.mode else {
                        return
                    }
                    if let outerIndex = findState.pendingGridDivisionIndex {
                        // Narrow to selected outer cell after first keypress
                        let selectedCol = outerIndex % state.gridDivisions
                        let selectedRow = outerIndex / state.gridDivisions
                        let cellOriginX = startX + cellWidth * CGFloat(selectedCol)
                        let cellOriginY = startY + cellHeight * CGFloat(selectedRow)

                        var focusedPath = Path()
                        for i in 0...state.innerGridDivisions {
                            let x = cellOriginX + innerCellWidth * CGFloat(i)
                            focusedPath.move(to: CGPoint(x: x, y: cellOriginY))
                            focusedPath.addLine(to: CGPoint(x: x, y: cellOriginY + cellHeight))
                            let y = cellOriginY + innerCellHeight * CGFloat(i)
                            focusedPath.move(to: CGPoint(x: cellOriginX, y: y))
                            focusedPath.addLine(to: CGPoint(x: cellOriginX + cellWidth, y: y))
                        }
                        ctx.stroke(focusedPath, with: .color(.white.opacity(0.6)), lineWidth: 1)

                        for innerCol in 0..<state.innerGridDivisions {
                            for innerRow in 0..<state.innerGridDivisions {
                                let innerIndex = innerRow * state.innerGridDivisions + innerCol
                                let innerMiddleX =
                                    cellOriginX + innerCellWidth * CGFloat(innerCol)
                                    + innerCellWidth / 2
                                let innerMiddleY =
                                    cellOriginY + innerCellHeight * CGFloat(innerRow)
                                    + innerCellHeight / 2
                                let label = Text(
                                    "\(state.findModeInnerGridDivisionCharacters[innerIndex])"
                                )
                                .accessibilityLabel(
                                    "Inner Row \(innerRow) Inner Col \(innerCol) \(state.findModeInnerGridDivisionCharacters[innerIndex])"
                                )
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                ctx.draw(
                                    label, at: CGPoint(x: innerMiddleX, y: innerMiddleY),
                                    anchor: .center)
                            }
                        }
                    } else {
                        // Default: outer grid + faint inner grid
                        let totalInner = state.gridDivisions * state.innerGridDivisions
                        var innerPath = Path()
                        for i in 1..<totalInner {
                            guard i % state.innerGridDivisions != 0 else { continue }
                            let x = startX + innerCellWidth * CGFloat(i)
                            innerPath.move(to: CGPoint(x: x, y: startY))
                            innerPath.addLine(to: CGPoint(x: x, y: endY))
                            let y = startY + innerCellHeight * CGFloat(i)
                            innerPath.move(to: CGPoint(x: startX, y: y))
                            innerPath.addLine(to: CGPoint(x: endX, y: y))
                        }
                        ctx.stroke(innerPath, with: .color(.white.opacity(0.3)), lineWidth: 0.5)

                        var outerPath = Path()
                        for i in 0...state.gridDivisions {
                            let x = startX + cellWidth * CGFloat(i)
                            outerPath.move(to: CGPoint(x: x, y: startY))
                            outerPath.addLine(to: CGPoint(x: x, y: endY))
                            let y = startY + cellHeight * CGFloat(i)
                            outerPath.move(to: CGPoint(x: startX, y: y))
                            outerPath.addLine(to: CGPoint(x: endX, y: y))
                        }
                        ctx.stroke(outerPath, with: .color(.white.opacity(0.6)), lineWidth: 1)

                        for col in 0..<state.gridDivisions {
                            for row in 0..<state.gridDivisions {
                                let x = startX + cellWidth * CGFloat(col)
                                let y = startY + cellHeight * CGFloat(row)
                                let index = row * state.gridDivisions + col
                                let charLabel = Text(
                                    "\(state.findModeGridDivisionCharacters[index])"
                                )
                                .accessibilityLabel(
                                    "Row \(row) Col \(col) \(state.findModeGridDivisionCharacters[index])"
                                )
                                .font(.system(size: 60, weight: .bold))
                                .foregroundColor(.blue)

                                ctx.draw(
                                    charLabel,
                                    at: CGPoint(x: x + cellWidth / 2, y: y + cellHeight / 2),
                                    anchor: .center)
                                if state.isAlwaysShowInnerGridCharacters {
                                    for innerCol in 0..<state.innerGridDivisions {
                                        for innerRow in 0..<state.innerGridDivisions {
                                            let innerX = x + innerCellWidth * CGFloat(innerCol)
                                            let innerY = y + innerCellHeight * CGFloat(innerRow)
                                            let middleInnerX = innerX + (innerCellWidth / 2)
                                            let middleInnerY = innerY + (innerCellHeight / 2)
                                            let innerIndex =
                                                innerRow * state.innerGridDivisions + innerCol
                                            let findCharInnerGridDivisionText = Text(
                                                "\(state.findModeInnerGridDivisionCharacters[innerIndex])"
                                            )
                                            .font(.system(size: 12))
                                            .foregroundColor(.white)
                                            ctx.draw(
                                                findCharInnerGridDivisionText,
                                                at: CGPoint(
                                                    x: middleInnerX,
                                                    y: middleInnerY),
                                                anchor: .topLeading)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.all)
    }
}

// MARK: - Menu Bar View

// struct CustomMenuBarView: View {
//     @ObservedObject var state: NeoMouseState
//
//     var body: some View {
//         VStack(spacing: 0) {
//             // Header
//             HStack {
//                 Image(systemName: "cursorarrow.motionlines")
//                     .font(.title2)
//                 Text("NeoMouse")
//                     .font(.headline)
//                 Spacer()
//                 Circle()
//                     .fill(case state.mod = .normal ? .green : .red)
//                     .frame(width: 8, height: 8)
//             }
//             .padding()
//             .background(.ultraThinMaterial)
//
//             Divider()
//
//             // Mouse position
//             VStack(alignment: .leading, spacing: 4) {
//                 Label("x: \(Int(state.mouseX))", systemImage: "arrow.left.and.right")
//                 Label("y: \(Int(state.mouseY))", systemImage: "arrow.up.and.down")
//             }
//             .frame(maxWidth: .infinity, alignment: .leading)
//             .padding()
//
//             Divider()
//
//             // Toggle
//             Toggle("NeoMouse Mode", isOn: $state.isNeomouseMode)
//                 .padding()
//                 .toggleStyle(.switch)
//
//             Divider()
//
//             Button("Send Notification") {
//                 ToastManager.shared.show("Hello from NeoMouse!")
//             }
//             .buttonStyle(.borderless)
//             .padding(.vertical, 6)
//
//             Divider()
//
//             Button("Quit") { NSApp.terminate(nil) }
//                 .foregroundColor(.red)
//                 .buttonStyle(.borderless)
//                 .padding(.vertical, 6)
//         }
//         .frame(width: 220)
//     }
// }
