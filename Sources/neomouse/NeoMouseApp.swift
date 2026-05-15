import AppKit
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseUtils

class NeoMouseState: ObservableObject {
    @Published var mode: Mode = .disabled
    @Published var gridInset: CGFloat
    //TODO Eventually use Session.Operations Table for the below Published var
    @Published var isVisual: Bool = false
    @Published var previousVisualStartCGXPoint: CGFloat? = nil
    @Published var previousVisualStartCGYPoint: CGFloat? = nil
    @Published var previousVisualEndCGXPoint: CGFloat? = nil
    @Published var previousVisualEndCGYPoint: CGFloat? = nil
    @Published var startCGXPoint: CGFloat? = nil
    @Published var startCGYPoint: CGFloat? = nil
    @Published var endCGXPoint: CGFloat? = nil
    @Published var endCGYPoint: CGFloat? = nil

    @Published var operationCountAsString: String? = nil
    @Published var currentSession: Session? = nil

    let commands: [String]
    //WARNING: Until a good dynamic solution is found, do not allow these 2 to be mutable, could be a headache as divisionCharacters may
    //need to added in to take in account if gridDivisions increased
    let gridDivisions: Int
    let innerGridDivisions: Int
    let findModeGridDivisionCharacters: [String]
    let findModeInnerGridDivisionCharacters: [String]
    let linesOnScreen: Int
    let minimumHighlightWidth: Int
    let rangeX: CGFloat
    let rangeY: CGFloat

    // Gesture related settings
    let zoomStepValue: Double
    let incrementsPerGesture: UInt
    let degreesToRotate: Double
    let isAlwaysShowInnerGridCharacters: Bool
    let isClampCursorToCurrentScreen: Bool

    // Single init covers both paths: when neomouseConfig finds settings.toml,
    // every property comes from there; otherwise each falls back to the same
    // hardcoded values this class used before config wiring.
    init(config: Config? = nil) {
        self.gridInset = config?.grid.inset ?? 10
        self.commands = config?.commands.available ?? ["numbers", "relativenumbers"]
        self.gridDivisions = config?.grid.divisions ?? 5
        self.innerGridDivisions = config?.grid.innerDivisions ?? 3
        self.findModeGridDivisionCharacters =
            (config?.grid.findModeCharacters ?? "abcdefghijklmnopqrstuvwxyz").map { String($0) }
        self.findModeInnerGridDivisionCharacters =
            (config?.grid.findModeInnerCharacters ?? "abcdefghijklmnopqrstuvwxyz").map { String($0) }
        self.linesOnScreen = config?.motion.linesOnScreen ?? 50
        self.minimumHighlightWidth = config?.visual.minimumHighlightWidth ?? 5
        self.rangeX = config?.motion.rangeX ?? 20
        self.rangeY = config?.motion.rangeY ?? 20
        self.zoomStepValue = config?.gesture.zoomStepValue ?? 0.1
        self.incrementsPerGesture = config?.gesture.incrementsPerGesture ?? 5
        self.degreesToRotate = config?.gesture.degreesToRotate ?? 90
        self.isAlwaysShowInnerGridCharacters = config?.grid.isAlwaysShowInnerCharacters ?? true
        self.isClampCursorToCurrentScreen = config?.motion.isClampCursorToCurrentScreen ?? false
    }
}

@main
struct NeoMouse: App {
    static var keyMonitor: Any?
    static var mouseMonitor: Any?
    static let sharedState: NeoMouseState = {
        guard let url = Config.resolvedURL else {
            debug("No settings.toml found at any resolved path; using built-in defaults")
            return NeoMouseState()
        }
        do {
            let config = try Config.loadConfig(from: url)
            debug("Loaded config from \(url.path)")
            return NeoMouseState(config: config)
        } catch {
            debug("Config load failed (\(error)); falling back to built-in defaults")
            return NeoMouseState()
        }
    }()
    @StateObject private var appState = NeoMouse.sharedState
    // Bridges SwiftUI's value-type App into AppKit's reference-type lifecycle
    // so we receive applicationWillTerminate before the process exits.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        //TODO add checks to make sure no unintended behavior of out of bounds access happens
        // eg.. gridDivisions * gridDivisions <=findModeGridDivisionCharacters.count, and similar for
        // innerGridDivisions
        initializeDB(forceReIntialize: false)
        appState.currentSession = Session.getLast()
        guard let currentSession = appState.currentSession else {
            debug("No session was found")
            showFatalAlertAndQuit(
                title: "NeoMouse failed to start",
                message: """
                    No session was found in the database. This is unexpected — \
                    please report it so we can fix it.
                    """
            )
            return
        }

        debug("currentSession: \(String(describing: currentSession))")
        let _allScreensBoundingRect = getAllScreensBoundingRect()
        debug("allScreensRect: \(String(describing: _allScreensBoundingRect))")
        let appState = NeoMouse.sharedState
        // KeyCast.shared.passAppState(state: appState)
        NeoMouse.keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let _currentCGPoint = getCurrentMouseLocation()
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
                // currentCGPoint is global CG space (top-left of primary = origin).
                // Subtract display origin to get screen-local CG coords.
                let localCGPoint = CGPoint(
                    x: currentCGPoint.x - currentDisplayBounds.origin.x,
                    y: currentCGPoint.y - currentDisplayBounds.origin.y
                )
                //INFO: Set as a CGFloat instead of Double or UInt as to be compatible with
                //CGWarpMouseCursorPosition
                let operationCount: CGFloat
                if case .normal = appState.mode,
                    let operationCountAsString = appState.operationCountAsString,
                    let currentPendingNormalOperationAsFloat: Float =
                        Float(
                            operationCountAsString.filter {
                                $0.isNumber || $0 == "."
                            },
                        ),
                    currentPendingNormalOperationAsFloat > 0
                {
                    operationCount = CGFloat(currentPendingNormalOperationAsFloat)
                } else {
                    operationCount = 1
                }
                let _key = keyCodeToCharMap.first(where: { $0.value == event.keyCode })?.key ?? "?"
                debug(
                    """
                    [keyDown]
                      key = \(_key)(keyCode=\(event.keyCode))
                      characters = \(String(describing: event.characters))
                      modifiers = \(event.modifierFlags.rawValue)
                      mode = \(appState.mode)
                      cgPoint = (\(Int(currentCGPoint.x)), \(Int(currentCGPoint.y)))
                      localCGPoint = (\(Int(localCGPoint.x)), \(Int(localCGPoint.y)))
                      display = \(currentDisplayBounds)
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
                            currentPendingOperation: .none
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
                            currentPendingOperation: .none
                        )
                        appState.operationCountAsString = nil
                        return
                    default: break
                    }
                    switch currentPendingNormalOperation {
                    case .setMark:
                        guard
                            event.modifierFlags.rawValue == 256
                                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                            event.characters?.count == 1,
                            event.characters?.first?.isLetter == true || event.characters?.first?.isNumber == true
                        else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("setMark mark contains a non-shift modifiers, or it is not a single letter/digit")
                            return
                        }
                        Mark.set(
                            mark: event.characters!,
                            isVisual: appState.isVisual,
                            startCGXPoint: appState.isVisual ? Double(appState.startCGXPoint ?? currentCGPoint.x) : nil,
                            startCGYPoint: appState.isVisual ? Double(appState.startCGYPoint ?? currentCGPoint.y) : nil,
                            endCGXPoint: Double(currentCGPoint.x),
                            endCGYPoint: Double(currentCGPoint.y),
                            sessionId: currentSession.id!  // It should be autogenerated by sqlite
                        )
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        return
                    case .goToMark, .goToMarkExactState:
                        guard
                            event.modifierFlags.rawValue == 256
                                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                            event.characters?.count == 1,
                            event.characters?.first?.isLetter == true || event.characters?.first?.isNumber == true
                        else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("goToMark mark contains a non-shift modifiers, or it is not a single letter/digit")
                            return
                        }
                        guard let mark = Mark.get(mark: event.characters!, sessionId: currentSession.id!) else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("No mark found for goToMark with given character: \(event.characters!)")
                            return
                        }

                        if currentPendingNormalOperation == .goToMarkExactState {
                            appState.isVisual = mark.isVisual
                            if mark.isVisual {
                                appState.startCGXPoint = CGFloat(mark.startCGXPoint!)
                                appState.startCGYPoint = CGFloat(mark.startCGYPoint!)
                                appState.endCGXPoint = CGFloat(mark.endCGXPoint)
                                appState.endCGYPoint = CGFloat(mark.endCGYPoint)
                                VisualHighlightOverlay.shared.passAppState(state: appState)
                                // moveMouseByExactGlobalCGPoint(x: mark.startCGXPoint!, y: mark.startCGYPoint!)
                            }
                        }
                        moveMouseByExactGlobalCGPoint(
                            x: mark.endCGXPoint,
                            y: mark.endCGYPoint)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        return
                    default:
                        break
                    }
                    // Second keystroke after "m": save current cursor as a mark.
                    // Intercepts here so letters like "v"/"g" don't fall through to
                    // their normal handlers when armed by a preceding "m".
                    if currentPendingNormalOperation == .setMark,
                        event.modifierFlags.rawValue == 256,
                        let markChar = event.characters,
                        markChar.count == 1,
                        let first = markChar.first,
                        first.isLetter || first.isNumber
                    {
                        Mark.set(
                            mark: markChar,
                            isVisual: appState.isVisual,
                            startCGXPoint: Double(currentCGPoint.x),
                            startCGYPoint: Double(currentCGPoint.y),
                            endCGXPoint: Double(currentCGPoint.x),
                            endCGYPoint: Double(currentCGPoint.y),
                            sessionId: appState.currentSession?.id ?? 1
                        )
                        ToastManager.shared.show("Mark '\(markChar)' set")
                        appState.mode = .normal(currentPendingOperation: .none)
                        //INFO: Return early here to avoid the mark char being processed by the normal flow below, which could cause unintended behavior (eg.. "mm" would trigger both the mark setting and the "go to start of line" behavior)
                        return
                    }
                    switch event.characters {
                    case "e":
                        appState.operationCountAsString = nil
                        guard
                            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                == .command
                        else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
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
                        appState.operationCountAsString = nil
                        //INFO: 256 means no modifier is pressed, do not use .isEmpty method
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
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
                                currentPendingOperation: .none
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
                            currentPendingOperation: .none
                        )
                        break
                    case "'":  //goToMark
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        appState.mode = .normal(
                            currentPendingOperation: .goToMark
                        )
                        break
                    case "`":  //goToMarkExact
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        appState.mode = .normal(
                            currentPendingOperation: .goToMarkExactState
                        )
                        break
                    //INFO: No need to do modifierFlags checks for captizalized chars, as a
                    //modifierFlag will trigger the lowercase char equivalent
                    case "G":
                        let target = MotionTarget.bottom(
                            localX: localCGPoint.x,
                            screenHeight: currentScreenSize.height,
                            gridInset: appState.gridInset)
                        moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                        break
                    case "g":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        if currentPendingNormalOperation == .none {
                            appState.mode = .normal(
                                currentPendingOperation: .g
                            )
                            break
                        }
                        // "g" instead of "gg" as the following "g" is only appended/updated onto appState after current MainActor event
                        if operationCount > 0 && currentPendingNormalOperation == .g {
                            let target = MotionTarget.toLineCount(
                                localX: localCGPoint.x,
                                screenHeight: currentScreenSize.height,
                                gridInset: appState.gridInset,
                                linesOnScreen: appState.linesOnScreen,
                                count: operationCount)
                            moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            appState.operationCountAsString = nil
                            break
                        } else if currentPendingNormalOperation == .g {
                            let target = MotionTarget.top(
                                localX: localCGPoint.x,
                                gridInset: appState.gridInset)
                            moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                            appState.mode = .normal(
                                currentPendingOperation: .gg
                            )
                            //TODO dont reset normal mode just yet, need to account for ggvG
                            //TODO Remove below when v is added
                            // appState.mode = .normal(
                            //     currentPendingOperation: .none
                            // )
                            break
                        }
                        break
                    case "w", "W", "\u{17}":
                        if currentPendingNormalOperation == .ctrlW {
                            guard let adjacentScreenRect = getAdjacentScreenRect() else {
                                debug("No adjacent screen found for Ctrl-w w")
                                appState.mode = .normal(currentPendingOperation: .none)
                                break
                            }
                            debug("\(adjacentScreenRect), adj")
                            moveMouseByExactGlobalCGPoint(
                                x: adjacentScreenRect.midX,
                                y: adjacentScreenRect.midY)
                            appState.mode = .normal(currentPendingOperation: .none)
                        } else if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                            == .control
                        {
                            appState.mode = .normal(currentPendingOperation: .ctrlW)
                        } else {
                            appState.mode = .normal(currentPendingOperation: .none)
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
                        let lineHeight = currentScreenSize.height / CGFloat(appState.linesOnScreen)
                        let startCGPoint = CGPoint(
                            x: currentDisplayBounds.origin.x + appState.gridInset,
                            y: currentCGPoint.y)
                        let endCGPoint = CGPoint(
                            x: currentDisplayBounds.origin.x + currentScreenSize.width
                                - appState.gridInset,
                            y: currentCGPoint.y + lineHeight)
                        moveMouseByExactGlobalCGPoint(x: startCGPoint.x, y: startCGPoint.y)
                        // mouseDown(.left, at: startCGPoint)
                        moveMouseByExactGlobalCGPoint(x: endCGPoint.x, y: endCGPoint.y)
                        appState.startCGXPoint = startCGPoint.x
                        appState.startCGYPoint = startCGPoint.y
                        appState.endCGXPoint = endCGPoint.x
                        appState.endCGYPoint = endCGPoint.y
                        VisualHighlightOverlay.shared.passAppState(state: appState)
                        break
                    case "v":
                        appState.operationCountAsString = nil
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(currentPendingOperation: .none)
                        }
                        appState.isVisual.toggle()
                        guard appState.isVisual else {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                            return
                        }
                        if currentPendingNormalOperation == .g
                            && appState.previousVisualStartCGXPoint != nil
                            && appState.previousVisualStartCGYPoint != nil
                            && appState.previousVisualEndCGXPoint != nil
                            && appState.previousVisualEndCGYPoint != nil
                        {
                            // mouseDown(.left, at: currentCGPoint)
                            appState.startCGXPoint = appState.previousVisualStartCGXPoint
                            appState.startCGYPoint = appState.previousVisualStartCGYPoint
                            appState.endCGXPoint = appState.previousVisualEndCGXPoint
                            appState.endCGYPoint = appState.previousVisualEndCGYPoint
                            VisualHighlightOverlay.shared.passAppState(state: appState)
                            moveMouseByExactGlobalCGPoint(
                                x: appState.endCGXPoint!,
                                y: appState.endCGYPoint!)
                            appState.mode = .normal(currentPendingOperation: .none)
                        } else {
                            //Go to Visual state
                            // mouseDown(.left, at: currentCGPoint)
                            appState.startCGXPoint = currentCGPoint.x
                            appState.startCGYPoint = currentCGPoint.y
                            appState.endCGXPoint = currentCGPoint.x
                            appState.endCGYPoint = currentCGPoint.y
                            VisualHighlightOverlay.shared.passAppState(state: appState)
                            appState.mode = .normal(currentPendingOperation: .none)
                        }
                        break
                    case "y":
                        appState.operationCountAsString = nil
                        guard
                            event.modifierFlags.rawValue == 256,
                            appState.isVisual,
                            let startX = appState.startCGXPoint,
                            let startY = appState.startCGYPoint,
                            let endX = appState.endCGXPoint,
                            let endY = appState.endCGYPoint
                        else {
                            appState.mode = .normal(currentPendingOperation: .none)
                            return
                        }
                        let currentVisualHighlightWidth: CGFloat = abs(endX - startX)
                        let currentVisualHighlightHeight: CGFloat = abs(endY - startY)
                        let currentVisualHighlightCGRect = CGRect(
                            x: min(startX, endX),
                            y: min(startY, endY),
                            width: currentVisualHighlightWidth,
                            height: currentVisualHighlightHeight
                        )
                        let rect = currentVisualHighlightCGRect
                        let excludedIDs: [CGWindowID] = [
                            VisualHighlightOverlay.shared.windowID,
                            GridOverlay.shared.windowID,
                        ].compactMap { $0 }
                        Task { @MainActor in
                            do {
                                guard
                                    let screenshotTaken = try await screenshotMultiDisplay(
                                        rect: rect, excluding: excludedIDs)
                                else {
                                    debug("No screenshotTaken for operation: y")
                                    appState.mode = .normal(currentPendingOperation: .none)
                                    appState.isVisual = false
                                    return
                                }
                                let image = NSImage(cgImage: screenshotTaken, size: .zero)
                                NSSound(named: "Screen Capture")?.play()
                                NSPasteboard.general.clearContents()
                                let isCopiedToPasteBoard = NSPasteboard.general.writeObjects([image])
                                if isCopiedToPasteBoard {
                                    ToastManager.shared.show("Screenshot copied to clipboard")
                                }
                                appState.mode = .normal(currentPendingOperation: .none)
                                appState.isVisual = false
                            } catch {
                                debug("For operation 'y' screenshot failed: \(error)")
                                appState.mode = .normal(currentPendingOperation: .none)
                                appState.isVisual = false
                            }
                        }
                        break
                    case "o", "O":
                        appState.operationCountAsString = nil
                        guard appState.isVisual,
                            let sx = appState.startCGXPoint,
                            let sy = appState.startCGYPoint,
                            let ex = appState.endCGXPoint,
                            let ey = appState.endCGYPoint
                        else {
                            return appState.mode = .normal(currentPendingOperation: .none)
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
                        appState.mode = .normal(currentPendingOperation: .none)
                        break
                    case "M":
                        appState.operationCountAsString = nil
                        let target = MotionTarget.verticalMiddle(
                            localX: localCGPoint.x,
                            screenHeight: currentScreenSize.height)
                        moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "m":
                        appState.operationCountAsString = nil
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }

                        if currentPendingNormalOperation == .none {
                            // First press: arm "m" so the next key becomes the mark name.
                            // The actual addMark call lives at the top of the outer
                            // `switch event.characters` so it can intercept any a–z/0–9.
                            appState.mode = .normal(currentPendingOperation: .setMark)
                            break
                        } else if currentPendingNormalOperation == .g {
                            let target = MotionTarget.horizontalMiddle(
                                localY: localCGPoint.y,
                                screenWidth: currentScreenSize.width)
                            moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            break
                        }
                        // "mm" (and similar self-targeted marks) is caught by the
                        // pending-"m" branch above this switch, not here.
                        break
                    //INFO: Instead of vim's replace single char, this is the rotate gesture
                    case "r":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        rotate(
                            degrees: appState.degreesToRotate, at: currentCGPoint,
                            incrementsPerGesture:
                                appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "R":
                        rotate(
                            degrees: -appState.degreesToRotate, at: currentCGPoint,
                            incrementsPerGesture:
                                appState.incrementsPerGesture)
                        // Always reset pendingOperation as to reset the operationCount
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    //TODO change to current focused app and add in for g0
                    case "0":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(currentPendingOperation: .none)
                        }
                        //Not a count-based operation, so execute "go to start of current
                        //x-axis-line (Similar to Vim's go to start of line)
                        guard
                            currentPendingNormalOperation == .none,
                            appState.operationCountAsString == nil
                        else {
                            appState.operationCountAsString =
                                (appState.operationCountAsString ?? "") + event.characters!
                            appState.mode = .normal(currentPendingOperation: .none)
                            return
                        }
                        let target = MotionTarget.leftEdge(
                            localY: localCGPoint.y,
                            gridInset: appState.gridInset)
                        moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                    case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        appState.operationCountAsString = (appState.operationCountAsString ?? "") + event.characters!
                        appState.mode = .normal(currentPendingOperation: .none)
                        return
                    // TODO change to current focused app and add in for g$
                    case "$":
                        let target = MotionTarget.rightEdge(
                            localY: localCGPoint.y,
                            screenWidth: currentScreenSize.width,
                            gridInset: appState.gridInset)
                        moveMouseByExactCoordinatesOnCurrentScreen(x: target.x, y: target.y)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "+":
                        pinchZoom(
                            .in, at: currentCGPoint,
                            stepValue: operationCount * appState.zoomStepValue,
                            incrementsPerGesture: appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "-":
                        pinchZoom(
                            .out, at: currentCGPoint,
                            stepValue: operationCount * appState.zoomStepValue,
                            incrementsPerGesture: appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: .none
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
                //INFO: after every non-integer keypress, excluding 0 which can be both a command and a count, we reset the operationCountAsString to nil to reset the count for the next operation
                //Non-integer keypress generally needs to break at the end, while integer keypress will return early before reaching this point, so the operationCountAsString is only updated for integer keypress and reset for non-integer keypress
                switch appState.mode {
                case .normal(.none), .find:
                    appState.operationCountAsString = nil
                default:
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
        MenuBar()
    }
    static func enterNormalMode(appState: NeoMouseState) {
        //TODO: NICE TO HAVE use previous session's
        appState.mode = .normal(currentPendingOperation: .none)
        GridOverlay.shared.hideGrid()
        ToastManager.shared.show(
            "Normal Mode")
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
            enterNormalMode(appState: appState)

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

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

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
    // func currentHighlightCGRect() -> CGRect? {
    //         guard state.isVisual, width > 0, height > 0 else { return nil }
    //         return CGRect(
    //             x: (state. + endX) / 2 - getAllScreensBoundingRect().origin.x,
    //             y: (startY + endY) / 2 - getAllScreensBoundingRect().origin.y,
    //             width: width,
    //             height: height
    //         )
    //     }
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

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

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
