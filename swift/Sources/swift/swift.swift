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
                    switch event.keyCode {
                    case keyCodeToCharMap["e"]:
                        guard event.modifierFlags.contains(.command) else { return }
                        // debug(
                        //     "modifierFlags:true, modifier: \(event.modifierFlags), mode:\(appState.mode), key:e, keyCode:\(event.keyCode)"
                        // )
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
                    case keyCodeToCharMap["e"]:
                        guard event.modifierFlags.contains(.command) else { return }
                        // debug(
                        //     "modifierFlags:true, modifier: \(event.modifierFlags), mode:\(appState.mode), key:e, keyCode:\(event.keyCode)"
                        // )
                        appState.mode = .disabled
                        ToastManager.shared.show(
                            "Neomouse Deactivated")
                        return
                    //TODO: Add "$", "^ : where it will go to the most left/right of the current
                    //focused window", "g$" for most right, hjkl, counters,
                    case keyCodeToCharMap["f"]:
                        // debug(
                        //     "modifierFlags:\(event.modifierFlags.rawValue), isNeomouseMode:true, key:f, keyCode:\(event.keyCode) - not activating find mode because modifier is pressed"
                        // )
                        //INFO: 256 means no modifier is pressed, do not use .isEmpty method
                        guard event.modifierFlags.rawValue == 256 else {
                            return
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
                    case keyCodeToCharMap["h"]:
                        guard event.modifierFlags.rawValue == 256 else { return }
                        // appState.mode = .normal(
                        //     currentPendingOperation: "\(operationCount)h",
                        // )
                        moveMouseRelatively(
                            x: -appState.rangeX * operationCount, y: 0,
                            enableClampToCurrentScreen:
                                appState.isClampCursorToCurrentScreen)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    //TODO check that if the operation except the lastIndex are only nums
                    case keyCodeToCharMap["j"]:
                        guard event.modifierFlags.rawValue == 256 else { return }
                        moveMouseRelatively(
                            x: 0, y: appState.rangeY * operationCount,
                            enableClampToCurrentScreen:
                                appState.isClampCursorToCurrentScreen)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case keyCodeToCharMap["k"]:
                        guard event.modifierFlags.rawValue == 256 else { return }
                        moveMouseRelatively(
                            x: 0, y: -appState.rangeY * operationCount,
                            enableClampToCurrentScreen:
                                appState.isClampCursorToCurrentScreen)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case keyCodeToCharMap["l"]:
                        guard event.modifierFlags.rawValue == 256 else { return }
                        // appState.mode = .normal(
                        //     currentPendingOperation: "\(operationCount)h",
                        // )
                        moveMouseRelatively(
                            x: appState.rangeX * operationCount, y: 0,
                            enableClampToCurrentScreen:
                                appState.isClampCursorToCurrentScreen)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case keyCodeToCharMap["g"]:
                        if event.modifierFlags.contains(.shift)
                            || event.modifierFlags.contains(.capsLock)
                        {

                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: localCGPoint.x,
                                y: currentScreenSize.height - appState.gridInset)
                            break
                        }
                        guard event.modifierFlags.rawValue == 256 else { return }

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
                    case keyCodeToCharMap["v"]:
                        appState.isVisual.toggle()
                        guard appState.isVisual else {
                            appState.startCGXPoint = nil
                            appState.startCGYPoint = nil
                            appState.endCGXPoint = nil
                            appState.endCGYPoint = nil
                            VisualHighlightOverlay.shared.hideOverlay()
                            return
                        }
                        if event.modifierFlags.contains(.shift) {
                            let lineHeight = currentScreenSize.height / appState.linesOnScreen
                            let startCGPoint = CGPoint(x: 0 + appState.gridInset, y: localCGPoint.y)
                            let endCGPoint = CGPoint(
                                x: currentScreenSize.width - appState.gridInset,
                                y: localCGPoint.y + lineHeight)
                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: startCGPoint.x, y: startCGPoint.y)
                            mouseDown(.left, at: startCGPoint)
                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: endCGPoint.x, y: endCGPoint.y)
                            appState.startCGXPoint = startCGPoint.x
                            appState.startCGYPoint = startCGPoint.y
                            appState.endCGXPoint = endCGPoint.x
                            appState.endCGYPoint = endCGPoint.y
                            VisualHighlightOverlay.shared.passAppState(state: appState)
                            break
                        }
                        guard event.modifierFlags.rawValue == 256 else { return }

                        mouseDown(.left, at: CGPoint(x: localCGPoint.x, y: localCGPoint.y))
                        appState.startCGXPoint = localCGPoint.x
                        appState.startCGYPoint = localCGPoint.y
                        appState.endCGXPoint = localCGPoint.x
                        appState.endCGYPoint = localCGPoint.y
                        VisualHighlightOverlay.shared.passAppState(state: appState)
                        break
                    case keyCodeToCharMap["m"]:
                        if event.modifierFlags.contains(.shift)
                            || event.modifierFlags.contains(.capsLock)
                        {
                            moveMouseByExactCoordinatesOnCurrentScreen(
                                x: localCGPoint.x,
                                y:
                                    currentScreenSize.height / 2)
                            appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                            break
                        }
                        guard event.modifierFlags.rawValue == 256 else { return }

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
                    //TODO change to current focused app and add in for g0
                    case keyCodeToCharMap["0"]:
                        guard event.modifierFlags.rawValue == 256 else { return }
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
                    case keyCodeToCharMap["1"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "1"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["2"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "2"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["3"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "3"
                            )
                            return
                        }
                        break
                    // TODO change to current focused app and add in for g$
                    case keyCodeToCharMap["4"]:
                        guard event.modifierFlags.contains(.shift) else {
                            if event.modifierFlags.rawValue == 256 {
                                appState.mode = .normal(
                                    currentPendingOperation: (currentPendingNormalOperation ?? "")
                                        + "4"
                                )
                            }
                            //NOTE: pendingOperations (eg. not yet executed operations) will use
                            //return instead of break as after the break we should record the execution
                            return
                        }
                        //"$" operator
                        moveMouseByExactCoordinatesOnCurrentScreen(
                            x: currentScreenSize.width - appState.gridInset, y: localCGPoint.y)
                        appState.mode = .normal(
                            currentPendingOperation: nil
                        )
                        break
                    case keyCodeToCharMap["5"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "5"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["6"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "6"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["7"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "7"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["8"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "8"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["9"]:
                        if event.modifierFlags.rawValue == 256 {
                            appState.mode = .normal(
                                currentPendingOperation: (currentPendingNormalOperation ?? "") + "9"
                            )
                            return
                        }
                        break
                    case keyCodeToCharMap["="]:
                        if event.modifierFlags.contains(.shift) {
                            pinchZoom(
                                .in, at: currentCGPoint,
                                stepValue: operationCount * appState.gestureSteps)
                            appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        break
                    case keyCodeToCharMap["-"]:
                        if event.modifierFlags.rawValue == 256 {
                            pinchZoom(
                                .out, at: currentCGPoint,
                                stepValue: operationCount * appState.gestureSteps)
                            appState.mode = .normal(
                                currentPendingOperation: nil
                            )
                        }
                        break
                    default: break
                    }
                case .find:
                    switch event.keyCode {
                    case keyCodeToCharMap["e"]:
                        guard event.modifierFlags.contains(.command) else {
                            return NeoMouse.executeFindModeOperation(
                                event: event, appState: appState,
                                currentScreenSize:
                                    currentScreenSize)
                        }
                        // debug(
                        //     "modifierFlags:true, modifier: \(event.modifierFlags), mode:\(appState.mode), key:e, keyCode:\(event.keyCode)"
                        // )
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
                    case keyCodeToCharMap["Esc"]:
                        NeoMouse.enterNormalMode(appState: appState)
                        break
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
                guard
                    let display = getActiveDisplays().first(where: {
                        CGDisplayBounds($0).contains(loc)
                    })
                else { return }
                let bounds = CGDisplayBounds(display)
                appState.endCGXPoint = loc.x - bounds.origin.x
                appState.endCGYPoint = loc.y - bounds.origin.y
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
        guard let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState,
            appState.isVisual == true
        else { return }
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
            win.contentView = NSHostingView(rootView: VisualHighlightOverlayView(state: appState))
            window = win
        }
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
    }

    func hideOverlay() {
        window?.orderOut(nil)
    }
}

struct VisualHighlightOverlayView: View {
    @ObservedObject var state: NeoMouseState

    private var startX: CGFloat { state.startCGXPoint ?? 0 }
    private var startY: CGFloat { state.startCGYPoint ?? 0 }
    private var endX: CGFloat { state.endCGXPoint ?? startX }
    private var endY: CGFloat { state.endCGYPoint ?? startY }

    private var width: CGFloat { abs(endX - startX) }
    private var height: CGFloat { abs(endY - startY) }

    var body: some View {
        guard state.isVisual, width > 0, height > 0 else { return AnyView(EmptyView()) }

        return AnyView(
            GeometryReader { _ in
                Rectangle()
                    .fill(.yellow.opacity(0.3))
                    .frame(width: width, height: height)
                    .position(
                        x: (startX + endX) / 2,
                        y: (startY + endY) / 2
                    )
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
