import AppKit
import Combine
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseUtils
import neomouseTypes

class NeoMouseState: ObservableObject {
    @Published var mode: NeomouseType.Mode = .disabled
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

    //TODO change to a single source of truth so use Config

    let commands: [Config.Command]
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

    // Configuration settings
    let isDisableKeyInput: Bool
    let modeOnStart: NeomouseType.ConfigMode
    //TODO add the rest

    // Single init covers both paths: when neomouseConfig finds settings.toml,
    // every property comes from there; otherwise each falls back to the same
    // hardcoded values this class used before config wiring.
    init(config: Config? = nil) {
        self.gridInset = config?.grid.inset ?? Config.Grid.defaultInset
        self.commands = config?.commands.available ?? Config.Commands.defaultAvailable
        self.gridDivisions = config?.grid.divisions ?? Config.Grid.defaultDivisions
        self.innerGridDivisions = config?.grid.innerDivisions ?? Config.Grid.defaultInnerDivisions
        self.findModeGridDivisionCharacters =
            (config?.grid.findModeCharacters ?? Config.Grid.defaultFindModeCharacters).map { String($0) }
        self.findModeInnerGridDivisionCharacters =
            (config?.grid.findModeInnerCharacters ?? Config.Grid.defaultFindModeInnerCharacters).map {
                String($0)
            }
        self.linesOnScreen = config?.motion.linesOnScreen ?? Config.Motion.defaultLinesOnScreen
        self.minimumHighlightWidth =
            config?.visual.minimumHighlightWidth ?? Config.Visual.defaultMinimumHighlightWidth
        self.rangeX = config?.motion.rangeX ?? Config.Motion.defaultRangeX
        self.rangeY = config?.motion.rangeY ?? Config.Motion.defaultRangeY
        self.zoomStepValue = config?.gesture.zoomStepValue ?? Config.Gesture.defaultZoomStepValue
        self.incrementsPerGesture =
            config?.gesture.incrementsPerGesture ?? Config.Gesture.defaultIncrementsPerGesture
        self.degreesToRotate = config?.gesture.degreesToRotate ?? Config.Gesture.defaultDegreesToRotate
        self.isAlwaysShowInnerGridCharacters =
            config?.grid.isAlwaysShowInnerCharacters ?? Config.Grid.defaultIsAlwaysShowInnerCharacters
        self.isClampCursorToCurrentScreen =
            config?.motion.isClampCursorToCurrentScreen ?? Config.Motion.defaultIsClampCursorToCurrentScreen
        self.isDisableKeyInput =
            config?.configuration.isDisableKeyInput ?? Config.Configuration.defaultIsDisableKeyInput
        self.modeOnStart =
            config?.configuration.modeOnStart ?? Config.Configuration.defaultModeOnStart

        mode = {
            switch self.modeOnStart {
            case .normal:
                return .normal(currentPendingOperation: .none)
            case .find:
                return .find(currentPendingOperation: nil, findState: NeomouseType.FindState())
            case .command:
                return .command(command: "", suggestionIndex: nil)
            case .disabled:
                return .disabled
            //TODO not sure if this option should be needed
            case .menu:
                return .menu
            }
        }()
    }
}

@main
struct NeoMouse: App {
    static var keyEventTap: CFMachPort?
    static var keyEventTapRunLoopSource: CFRunLoopSource?
    static var keyHandler: ((NSEvent) -> Void)?
    static var mouseMonitor: Any?
    static var pasteboardWatcher: Timer?
    static var modeObserver: AnyCancellable?
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
        // Dev seed gate. Run with `FORCE_REINTIALIZE=1 swift run` to force reinitialization of the DB and seeding of extra sessions and marks. This is useful for testing and development, but should not be used in production as it will delete existing data.
        initializeDB(forceReIntialize: ProcessInfo.processInfo.environment["FORCE_REINTIALIZE"] == "1" ? true : false)
        // extra sessions + random marks. No-op otherwise.
        if ProcessInfo.processInfo.environment["NEOMOUSE_SEED"] == "1" {
            seedAll()
        }

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

        // Seed register "0" with whatever's on the clipboard at launch.
        if let currentPasteboardItem = Pasteboard.getFirst() {
            Register.set(
                register: "0",
                item: currentPasteboardItem,
                sessionId: currentSession.id!)
            debug("Pasteboard: \(Pasteboard.preview(currentPasteboardItem))")
        }
        debug("currentSession: \(String(describing: currentSession))")
        let _allScreensBoundingRect = Screen.allBoundingRect()
        debug("allScreensRect: \(String(describing: _allScreensBoundingRect))")
        let appState = NeoMouse.sharedState
        // KeyCast.shared.passAppState(state: appState)

        NeoMouse.installKeyEventTap()

        NeoMouse.keyHandler = { event in
            MainActor.assumeIsolated {
                let _currentCGPoint = Mouse.location()
                //IMPORTANT: both _currentScreenSize && currentDisplayBounds will default to main screen if nothing is found
                let _currentScreenSize = Screen.currentSize()
                let currentDisplayBounds =
                    _currentCGPoint.flatMap { pt in
                        Screen.activeDisplays().first(where: { CGDisplayBounds($0).contains(pt) })
                            .map { CGDisplayBounds($0) }
                    } ?? Screen.mainRect()
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
                let _key = charToKeyCodeMap.first(where: { $0.value == event.keyCode })?.key ?? "?"
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
                if event.characters == "e" && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                {
                    if case .disabled = appState.mode {
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        ToastManager.shared.show(
                            "Neomouse Activated - Normal Mode")
                        return
                    } else {
                        if appState.isVisual {
                            exitVisualMode(
                                appState: appState,
                                visualHighlightOverlay:
                                    VisualHighlightOverlay.shared)
                        }
                        appState.mode = .disabled
                        GridOverlay.shared.hideGrid()
                        HelpDialog.shared.hide()
                        CommandLine.shared.hide()
                        ToastManager.shared.show("NeoMouse Deactivated")
                        return
                    }
                }
                //TODO take in account of other keyboard layouts
                switch appState.mode {
                case .disabled:
                    return
                // switch event.characters {
                // case "e":
                //     guard
                //         event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                //             == .command
                //     else {
                //         return
                //     }
                //     appState.mode = .normal(
                //         currentPendingOperation: .none
                //     )
                //     ToastManager.shared.show(
                //         "Neomouse Activated - Normal Mode")
                //     return
                // default:
                //     return
                // }
                case .normal(let currentPendingNormalOperation):
                    switch event.keyCode {
                    case charToKeyCodeMap["Esc"]:
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
                        HelpDialog.shared.hide()
                        CommandLine.shared.hide()
                        appState.operationCountAsString = nil
                        return
                    default: break
                    }
                    switch currentPendingNormalOperation {
                    case .setMark:
                        guard
                            event.modifierFlags.rawValue == 256
                                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
                        else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("setMark mark contains a non-shift modifier")
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
                                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
                        else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("goToMark mark contains a non-shift modifier")
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
                                // Mouse.moveToGlobal(x: mark.startCGXPoint!, y: mark.startCGYPoint!)
                            }
                        }
                        Mouse.moveToGlobal(
                            x: mark.endCGXPoint,
                            y: mark.endCGYPoint)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        return
                    case .goToRegister:
                        guard
                            event.modifierFlags.rawValue == 256
                                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
                        else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("goToRegister register contains a non-shift modifier")
                            return
                        }
                        appState.mode = .normal(currentPendingOperation: .registerAction(register: event.characters!))
                        return
                    case .registerAction:
                        guard
                            (event.modifierFlags.rawValue == 256
                                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift),
                            case .normal(.registerAction(let activeRegister)) = appState.mode
                        else {
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            debug("registerAction register contains a non-shift modifier or no activeRegister")
                            return
                        }
                        switch event.characters {
                        // case "c", "x":
                        //     guard
                        //         event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        //             == .command
                        //     else {
                        //         break
                        //     }
                        //
                        //     break
                        case "y", "Y":
                            System.simulate(.copy)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if let pasteboardItem = NSPasteboard.general.pasteboardItems?.first {
                                    debug("Copied item to clipboard: \(Pasteboard.preview(pasteboardItem))")
                                    Register.set(
                                        register: activeRegister, item: pasteboardItem, sessionId: currentSession.id!)
                                }
                            }
                            break
                        case "d", "D":
                            System.simulate(.cut)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if let pasteboardItem = NSPasteboard.general.pasteboardItems?.first {
                                    debug(
                                        "Copied item to clipboard from deletion: \(Pasteboard.preview(pasteboardItem))")
                                    Register.set(
                                        register: activeRegister, item: pasteboardItem, sessionId: currentSession.id!)
                                }
                            }
                            break
                        case "p", "P":
                            guard
                                let item = Register.get(register: activeRegister, sessionId: currentSession.id!)?
                                    .pasteboardItem
                            else {
                                debug("paste: register '\(activeRegister)' empty")
                                break
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([item])
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                System.simulate(.paste)
                            }
                            break
                        default:
                            break
                        }
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
                    // case "e":
                    //     appState.operationCountAsString = nil
                    //     guard
                    //         event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    //             == .command
                    //     else {
                    //         return appState.mode = .normal(
                    //             currentPendingOperation: .none
                    //         )
                    //     }
                    //     //TODO make this into a reusable fn disableNeoMouse
                    //     if appState.isVisual {
                    //         exitVisualMode(
                    //             appState: appState,
                    //             visualHighlightOverlay:
                    //                 VisualHighlightOverlay.shared)
                    //     }
                    //     appState.mode = .disabled
                    //     HelpDialog.shared.hide()
                    //     CommandLine.shared.hide()
                    //     ToastManager.shared.show(
                    //         "Neomouse Deactivated")
                    //     return
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
                            findState: NeomouseType.FindState()
                        )
                        HelpDialog.shared.hide()
                        CommandLine.shared.hide()
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
                        Mouse.moveRelative(
                            x: delta.dx, y: delta.dy,
                            clampToScreen:
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
                    case "`":  //goToMarkExactState
                        guard event.modifierFlags.rawValue == 256 else {
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        appState.mode = .normal(
                            currentPendingOperation: .goToMarkExactState
                        )
                        break
                    case "\"":
                        guard event.charactersIgnoringModifiers == "\"" else {
                            debug(
                                "Expected '\"' for register operations, got \(String(describing: event.charactersIgnoringModifiers))"
                            )
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        appState.mode = .normal(
                            currentPendingOperation: .goToRegister
                        )
                        break
                    case "?":
                        guard event.charactersIgnoringModifiers == "?" else {
                            debug(
                                "Expected '?' for help, got \(String(describing: event.charactersIgnoringModifiers))"
                            )
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        HelpDialog.shared.toggle()
                        appState.mode = .normal(currentPendingOperation: .none)
                        break
                    case ":":
                        guard event.charactersIgnoringModifiers == ":" else {
                            debug(
                                "Expected ':' for command line, got \(String(describing: event.charactersIgnoringModifiers))"
                            )
                            return appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                        }
                        HelpDialog.shared.hide()
                        appState.mode = .command(command: "", suggestionIndex: nil)
                        CommandLine.shared.passAppState(state: appState)
                        CommandLine.shared.toggle()
                        break
                    // INFO: No need to do modifierFlags checks for captizalized chars, as a
                    //modifierFlag will trigger the lowercase char equivalent
                    case "G":
                        let target = MotionTarget.bottom(
                            localX: localCGPoint.x,
                            screenHeight: currentScreenSize.height,
                            gridInset: appState.gridInset)
                        Mouse.moveToScreenLocal(x: target.x, y: target.y)
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
                            Mouse.moveToScreenLocal(x: target.x, y: target.y)
                            appState.mode = .normal(
                                currentPendingOperation: .none
                            )
                            appState.operationCountAsString = nil
                            break
                        } else if currentPendingNormalOperation == .g {
                            let target = MotionTarget.top(
                                localX: localCGPoint.x,
                                gridInset: appState.gridInset)
                            Mouse.moveToScreenLocal(x: target.x, y: target.y)
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
                            guard let adjacentScreenRect = Screen.adjacentRect() else {
                                debug("No adjacent screen found for Ctrl-w w")
                                appState.mode = .normal(currentPendingOperation: .none)
                                break
                            }
                            debug("\(adjacentScreenRect), adj")
                            Mouse.moveToGlobal(
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
                        Mouse.moveToGlobal(x: startCGPoint.x, y: startCGPoint.y)
                        // Mouse.down(.left, at: startCGPoint)
                        Mouse.moveToGlobal(x: endCGPoint.x, y: endCGPoint.y)
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
                            // Mouse.down(.left, at: currentCGPoint)
                            appState.startCGXPoint = appState.previousVisualStartCGXPoint
                            appState.startCGYPoint = appState.previousVisualStartCGYPoint
                            appState.endCGXPoint = appState.previousVisualEndCGXPoint
                            appState.endCGYPoint = appState.previousVisualEndCGYPoint
                            VisualHighlightOverlay.shared.passAppState(state: appState)
                            Mouse.moveToGlobal(
                                x: appState.endCGXPoint!,
                                y: appState.endCGYPoint!)
                            appState.mode = .normal(currentPendingOperation: .none)
                        } else {
                            //Go to Visual state
                            // Mouse.down(.left, at: currentCGPoint)
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
                            //Normal copy to register
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

                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    if case .normal(.registerAction(let activeRegister)) = appState.mode,
                                        let pasteboardItem = NSPasteboard.general.pasteboardItems?.first
                                    {
                                        Register.set(
                                            register: activeRegister,
                                            item: pasteboardItem,
                                            sessionId: currentSession.id!
                                        )
                                        debug(
                                            "Copied screenshot item to register '\(activeRegister)': \(Pasteboard.preview(pasteboardItem))"
                                        )
                                    }
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
                        Mouse.moveToGlobal(x: sx, y: sy)
                        appState.mode = .normal(currentPendingOperation: .none)
                        break
                    case "M":
                        appState.operationCountAsString = nil
                        let target = MotionTarget.verticalMiddle(
                            localX: localCGPoint.x,
                            screenHeight: currentScreenSize.height)
                        Mouse.moveToScreenLocal(x: target.x, y: target.y)
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
                            Mouse.moveToScreenLocal(x: target.x, y: target.y)
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
                        Gesture.rotate(
                            degrees: appState.degreesToRotate, at: currentCGPoint,
                            incrementsPerGesture:
                                appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "R":
                        Gesture.rotate(
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
                        Mouse.moveToScreenLocal(x: target.x, y: target.y)
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
                        Mouse.moveToScreenLocal(x: target.x, y: target.y)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "+":
                        Gesture.pinchZoom(
                            .in, at: currentCGPoint,
                            stepValue: operationCount * appState.zoomStepValue,
                            incrementsPerGesture: appState.incrementsPerGesture)
                        appState.mode = .normal(
                            currentPendingOperation: .none
                        )
                        break
                    case "-":
                        Gesture.pinchZoom(
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
                    case charToKeyCodeMap["Esc"]:
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
                    // if appState.isVisual {
                    //     exitVisualMode(
                    //         appState: appState,
                    //         visualHighlightOverlay:
                    //             VisualHighlightOverlay.shared)
                    // }
                    // appState.mode = .disabled
                    // GridOverlay.shared.hideGrid()
                    // HelpDialog.shared.hide()
                    // CommandLine.shared.hide()
                    // ToastManager.shared.show("NeoMouse Deactivated")
                    // return
                    default:
                        NeoMouse.executeFindModeOperation(
                            event: event, appState: appState, currentScreenSize: currentScreenSize)
                        break
                    }
                case .command(let currentCommand, let suggestionIndex):
                    switch event.keyCode {
                    case charToKeyCodeMap["Esc"]:
                        guard event.modifierFlags.rawValue == 256 else {
                            break
                        }
                        HelpDialog.shared.hide()
                        CommandLine.shared.hide()
                        appState.operationCountAsString = nil
                        appState.mode = .normal(currentPendingOperation: .none)
                        return
                    case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
                        if let suggestionIndex {
                            CommandLine.shared.hide()
                            CommandLine.shared.executeSuggestionCommand(at: suggestionIndex)
                        } else {
                            CommandLine.shared.hide()
                            debug("execute command: \(currentCommand)")
                            appState.mode = .normal(currentPendingOperation: .none)
                        }
                        return
                    case charToKeyCodeMap["Backspace"], charToKeyCodeMap["Delete"]:
                        appState.mode = .command(
                            command: String(currentCommand.dropLast()),
                            suggestionIndex: nil
                        )
                        return
                    default:
                        break
                    }
                    // Tab / Shift-Tab → round-robin cycle through filtered hits.
                    // Mirrors nvim wildmenu: list always visible, Tab moves
                    // the highlight; the command text itself doesn't change
                    // until the user accepts via Enter.
                    if event.keyCode == charToKeyCodeMap["Tab"] {
                        // Single source of truth: ask CommandLine for the
                        // current filtered list (same code path the view +
                        // executor use).
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
                    }
                    // Plain key: append. Allow Shift for capitals, reject
                    // Cmd / Ctrl / Opt chords (let those flow to the OS).
                    guard let character = event.characters else { return }
                    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard !mods.contains(.command),
                        !mods.contains(.control),
                        !mods.contains(.option)
                    else { return }
                    // IMPORTANT: write back to appState.mode so @Published fires
                    // and the SwiftUI CommandLineView redraws. Mutating a local
                    // `var currentCommand` only touches a snapshot. Typing
                    // resets the cycle position.
                    appState.mode = .command(
                        command: currentCommand + character,
                        suggestionIndex: nil
                    )
                    return
                // default:
                //     debug(
                //         "Should not happen: Reached default case in keyMonitor with mode:\(appState.mode) and keyCode:\(event.keyCode)"
                //     )
                //     break
                case .menu:
                    switch event.keyCode {
                    default:
                        break
                    }
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
                guard appState.isVisual, let loc = Mouse.location() else { return }
                appState.endCGXPoint = loc.x
                appState.endCGYPoint = loc.y
            }
        }
        // Pasteboard watcher tied to NeoMouse activation: it runs only when
        // mode != .disabled. `@Published`'s projected publisher fires the
        // current value to new subscribers, so this also sets the correct
        // initial state. Polling changeCount is the standard macOS clipboard
        // monitor pattern (Maccy/Flycut/Clipy) — no notification API exists.
        NeoMouse.modeObserver = appState.$mode.sink { newMode in
            MainActor.assumeIsolated {
                if case .disabled = newMode {
                    NeoMouse.pasteboardWatcher?.invalidate()
                    NeoMouse.pasteboardWatcher = nil
                } else if NeoMouse.pasteboardWatcher == nil {
                    NeoMouse.pasteboardWatcher = Pasteboard.watch {
                        Pasteboard.dump()
                        if let item = Pasteboard.getFirst() {
                            debug("Clipboard changed: \(Pasteboard.preview(item))")
                        }
                    }
                }
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
        let keyCodeAsChar: String? = charToKeyCodeMap.first(where: {
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
            let updatedFindState = NeomouseType.FindState(
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

            let updatedFindState = NeomouseType.FindState(
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
            Mouse.moveToScreenLocal(x: targetX, y: targetY)
            enterNormalMode(appState: appState)

        }
    }
}
