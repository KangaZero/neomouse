import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

extension NeoMouse {
    /// Normal-mode dispatch — the original 1100+ line case body, lifted out
    /// of the keyHandler closure unchanged. Owns Vim-style motion + visual
    /// + register / mark / window / setMark / goToMark / goToRegister state
    /// machine. Internal nested switches are deliberately preserved as-is;
    /// per-sub-case extraction (handleNormalRegisterAction, handleNormalWindow,
    /// etc.) is a follow-up refactor.
    @MainActor
    static func handleNormalMode(
        ctx: KeyEventContext,
        currentPendingNormalOperation: NeomouseType.NormalModePendingOperation,
        operationCountAsString: String?
    ) {
        // Re-bind every closure-captured local the case body referenced so
        // the verbatim body below compiles without a global find/replace.
        let event = ctx.event
        let appState = ctx.appState
        let currentSession = ctx.currentSession
        let sessionId = ctx.sessionId
        let currentCGPoint = ctx.currentCGPoint
        let localCGPoint = ctx.localCGPoint
        let currentDisplayBounds = ctx.currentDisplayBounds
        let currentScreenSize = ctx.currentScreenSize
        let operationCount = ctx.operationCount
        let asciiKey = ctx.asciiKey
        let asciiKeyBase = ctx.asciiKeyBase
        switch event.keyCode {
        case charToKeyCodeMap["Esc"]:
            guard event.modifierFlags.rawValue == 256 else {
                break
            }
            if appState.isVisual {
                debug("Esc pressed in visual mode, exiting visual state")
                CoreOperations.exitVisualState(
                    appState: appState,
                    visualHighlightOverlay:
                        VisualHighlightOverlay.shared)
            }
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            HelpDialog.shared.hide()
            CommandLine.shared.hide()
            GridOverlay.shared.hideGrid()
            CursorSurroundedGridOverlay.shared.hide()
            MarksMenu.shared.hide()
            RegisterMenu.shared.hide()
            return
        default: break
        }
        //Only allow count input in these conditions
        if currentPendingNormalOperation == .none || currentPendingNormalOperation == .special {
            switch asciiKey {
            //TODO change to current focused app and add in for g0
            case "0":
                guard event.modifierFlags.rawValue == 256 else {
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                // "0" pressed with no pending op and no count typed yet →
                // motion: go to start of current x-axis line (vim ^).
                // Otherwise: append "0" as a digit to the count buffer.
                guard
                    // currentPendingNormalOperation == currentPendingNormalOperation,
                    operationCountAsString == nil
                else {
                    appState.mode = .normal(
                        currentPendingOperation: currentPendingNormalOperation,
                        operationCountAsString: (operationCountAsString ?? "") + (asciiKey ?? "")
                    )
                    return
                }
                let target = MotionTarget.leftEdge(
                    localY: localCGPoint.y,
                    gridInset: appState.gridInset)
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
                return
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                guard event.modifierFlags.rawValue == 256, asciiKey?.count == 1 else {
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                appState.mode = .normal(
                    currentPendingOperation: currentPendingNormalOperation,
                    operationCountAsString: (operationCountAsString ?? "") + (asciiKey ?? ""))
                return
            default: break
            }
        }
        switch currentPendingNormalOperation {
        case .special:
            switch asciiKey {
            case "d", "D":
                guard
                    event.modifierFlags.rawValue == 256
                        || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                            .shift, .capsLock,
                        ])
                else {
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                Gesture.scroll(
                    direction: NeomouseType.Direction.down,
                    at: currentCGPoint,
                    stepValue: Int32(operationCount) * 30,  //TODO move to config
                    incrementsPerGesture: 10
                )
                appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
                return
            case "u", "U":
                guard
                    event.modifierFlags.rawValue == 256
                        || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                            .shift, .capsLock,
                        ])
                else {
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                Gesture.scroll(
                    direction: NeomouseType.Direction.up,
                    at: currentCGPoint,
                    stepValue: Int32(operationCount) * 30,  //TODO move to config
                    incrementsPerGesture: 10
                )
                appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
                return
            case "w", "W":
                guard
                    event.modifierFlags.rawValue == 256
                        || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                            .shift, .capsLock,
                        ])
                else {
                    debug(
                        "w/W contains wrong modifiers: \(event.modifierFlags)")
                    return appState.mode = .normal(
                        currentPendingOperation: .none, operationCountAsString: nil)
                }
                appState.mode = .normal(currentPendingOperation: .window, operationCountAsString: nil)
                return
            case "f", "F":
                guard
                    event.modifierFlags.rawValue == 256
                        || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                            .shift, .capsLock,
                        ])
                else {
                    debug(
                        "f/F contains wrong modifiers: \(event.modifierFlags)")
                    return appState.mode = .normal(
                        currentPendingOperation: .none, operationCountAsString: nil)
                }
                // Cursor-local dense find. Mode flip *before* show()
                // so the overlay's `case .specialFind = appState
                // .mode` guard matches.
                appState.mode = .specialFind
                Zoom.zoomIn()
                CursorSurroundedGridOverlay.shared.toggle()
                return
            default:
                //TODO Add indicator, and have Esc reset special instead
                break
            }
        case .g:
            switch asciiKey {
            case "g":
                guard event.modifierFlags.rawValue == 256 else {
                    return debug("gg contains a modifier, ignoring")
                }
                if operationCount > 1 {
                    debug(
                        ".g - with operationCount=\(operationCount) > 1, operation gg and currentPendingOperation set to .none"
                    )
                    let _ggUsable = CGRect(
                        x: appState.gridInset,
                        y: appState.gridInset,
                        width: max(0, currentScreenSize.width - 2 * appState.gridInset),
                        height: max(0, currentScreenSize.height - 2 * appState.gridInset)
                    )
                    let target = MotionTarget.toLineCount(
                        localX: localCGPoint.x,
                        screenHeight: currentScreenSize.height,
                        gridInset: appState.gridInset,
                        rowsOnScreen: appState.resolvedGrid(usable: _ggUsable).rows,
                        count: operationCount)
                    Mouse.moveToScreenLocal(x: target.x, y: target.y)
                    appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                    // appState.operationCountAsString = nil
                    return
                } else {
                    debug(
                        ".g - with operationCount=\(operationCount) <= 1, operation gg and currentPendingOperation set to .gg"
                    )
                    let target = MotionTarget.top(
                        localX: localCGPoint.x,
                        gridInset: appState.gridInset)
                    Mouse.moveToScreenLocal(x: target.x, y: target.y)
                    appState.mode = .normal(
                        currentPendingOperation: .gg,
                        operationCountAsString: nil
                    )
                    return
                }
            case "v":
                if appState.isVisual {
                    debug(
                        ".g - operation gv and isVisual=true, exiting visual state and setting currentPendingOperation to .none, operationCount reset to nil"
                    )
                    CoreOperations.exitVisualState(
                        appState: appState,
                        visualHighlightOverlay:
                            VisualHighlightOverlay.shared)
                } else {
                    debug(".g - operation gv and isVisual=false, goToPreviousVisualState")
                    CoreOperations.goToPreviousVisualState(
                        event: event, appState: appState,
                        currentPendingNormalOperation: currentPendingNormalOperation)
                }
                return
            case "m":
                guard event.modifierFlags.rawValue == 256 else {
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                let target = MotionTarget.horizontalMiddle(
                    localY: localCGPoint.y,
                    screenWidth: currentScreenSize.width)
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
                appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
                return
            default:
                break
            }
            break
        case .gg:
            switch (asciiKey, appState.isVisual) {
            case ("y", false):
                guard event.modifierFlags.rawValue == 256 else {
                    return
                }
                // appState.operationCountAsString = nil
                appState.mode = .normal(
                    currentPendingOperation: .ggy,
                    operationCountAsString: nil
                )
                return
            case ("v", false):
                CoreOperations.toggleVisualState(
                    event: event, appState: appState,
                    currentPendingNormalOperation: currentPendingNormalOperation,
                    currentCGPoint: currentCGPoint,
                    visualHighlightOverlay: VisualHighlightOverlay.shared
                )
                appState.mode = .normal(
                    currentPendingOperation: .ggv,
                    operationCountAsString: nil
                )
                return
            case ("\"", false):
                guard asciiKeyBase == "\"" else {
                    debug(
                        "Expected '\"' for register operations, got \(String(describing: asciiKeyBase))"
                    )
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                appState.mode = .normal(
                    currentPendingOperation: .goToRegister,
                    operationCountAsString: nil
                )
                return
            default:
                break
            }
            break
        case .ggy:
            guard
                asciiKey == "G"
            else {
                // go to .normal switch statement
                break
            }
            guard
                // INFO: This should never happen as .ggy can only be set in !appState.isVisual, but added in just in case
                !appState.isVisual
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])
            else {
                // appState.operationCountAsString = nil
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            Task { @MainActor in
                do {
                    let screenshotTaken = try await Screenshot.capture(
                        rect: currentDisplayBounds, excluding: CoreOperations.excludedWindowIDsForScreenshot
                    )
                    guard let screenshot = screenshotTaken else {
                        debug("ggyG screenshot failed: \(String(describing: screenshotTaken))")
                        return
                    }
                    debug("ggvG screenshot success: \(screenshot)")
                    let image = NSImage(cgImage: screenshot, size: .zero)
                    NSSound(named: "Screen Capture")?.play()
                    NSPasteboard.general.clearContents()
                    let isCopiedToPasteBoard = NSPasteboard.general.writeObjects([image])
                    if isCopiedToPasteBoard {
                        ToastManager.shared.show("Screenshot copied to clipboard")
                    }
                    if let pendingRegisterCharacter = appState.pendingRegisterCharacter {
                        CoreOperations.registerCurrentPasteboardItem(
                            currentSession: currentSession,
                            activeRegister: pendingRegisterCharacter)
                        debug(
                            "ggyG registered screenshot to register \(pendingRegisterCharacter)"
                        )
                        appState.pendingRegisterCharacter = nil
                    }
                } catch {
                    debug("ggy screenshot failed: \(error)")
                }
            }
            return
        case .ggv:
            guard
                asciiKey == "G"
            else {
                // go to .normal switch statement
                break
            }
            guard
                // INFO: This should happen as .ggv will set appState.isVisual to true, but added in just in case
                appState.isVisual
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])
            else {
                // appState.operationCountAsString = nil
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            appState.startCGXPoint = currentDisplayBounds.origin.x
            appState.startCGYPoint = currentDisplayBounds.origin.y
            appState.endCGXPoint = currentDisplayBounds.origin.x + currentDisplayBounds.size.width
            appState.endCGYPoint = currentDisplayBounds.origin.y + currentDisplayBounds.size.height
            let target = MotionTarget.bottomRightEdge(
                screenWidth: currentScreenSize.width,
                screenHeight: currentScreenSize.height,
                gridInset: appState.gridInset)
            Mouse.moveToScreenLocal(x: target.x, y: target.y)
            debug(
                "ggvG visual state: start(\(appState.startCGXPoint!), \(appState.startCGYPoint!)) end(\(appState.endCGXPoint!), \(appState.endCGYPoint!))"
            )
            return
        case .window:
            switch asciiKeyBase {
            case "w", "W":
                guard
                    event.modifierFlags.rawValue == 256
                        || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                            .shift, .capsLock,
                        ]), let adjacentScreenRect = Screen.adjacentRect()
                else {
                    debug("No adjacent screen found for Special-w-w")
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                Mouse.moveToGlobal(
                    x: adjacentScreenRect.midX,
                    y: adjacentScreenRect.midY)
                return appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            case "h", "j", "k", "l":
                guard
                    // With shift or capslock, would swap over the 2 buffers in vim,
                    // TODO: find a way to swap screens with the shift/capslock variant??
                    event.modifierFlags.rawValue == 256
                        || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                            .shift, .capsLock,
                        ])
                else {
                    debug(
                        "Special-w-\(asciiKeyBase ?? "?") contains an unexpected modifier"
                    )
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                let direction: NeomouseType.Direction
                switch asciiKeyBase {
                case "h": direction = .left
                case "j": direction = .down
                case "k": direction = .up
                case "l": direction = .right
                default:
                    debug("Unexpected character for Special-w-\(asciiKeyBase ?? "?")")
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                guard let nextScreenRect = Screen.adjacentDisplayRectByDirection(at: direction) else {
                    debug(
                        "No adjacent screen found in direction \(direction) for Special-w-\(asciiKeyBase ?? "?")"
                    )
                    return appState.mode = .normal(
                        currentPendingOperation: .none,
                        operationCountAsString: nil
                    )
                }
                Mouse.moveToGlobal(
                    x: nextScreenRect.midX,
                    y: nextScreenRect.midY)
                return appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            default: break
            }
            break
        case .setMark:
            guard
                event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            else {
                appState.mode = .normal(
                    currentPendingOperation: .none, operationCountAsString: nil
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
                sessionId: sessionId
            )
            MarksMenu.shared.refresh()
            appState.mode = .normal(
                currentPendingOperation: .none, operationCountAsString: nil
            )
            return
        case .goToMark, .goToMarkExactState:
            guard
                event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            else {
                appState.mode = .normal(
                    currentPendingOperation: .none, operationCountAsString: nil
                )
                debug("goToMark mark contains a non-shift modifier")
                return
            }
            guard let mark = Mark.get(mark: event.characters!, sessionId: sessionId) else {
                appState.mode = .normal(
                    currentPendingOperation: .none, operationCountAsString: nil
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
                currentPendingOperation: .none, operationCountAsString: nil
            )
            return
        case .goToRegister:
            guard
                event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])
            else {
                appState.mode = .normal(
                    currentPendingOperation: .none, operationCountAsString: nil
                )
                debug("goToRegister register contains a non-shift modifier")
                return
            }
            //INFO: unlike setMark/goToMarkExactState/goToMark which has this guard clause in their respective fns,
            //goToRegister needs a manual check
            guard let register = event.characters, register.count == 1,
                register.first!.isLetter || register.first!.isNumber
            else {
                appState.mode = .normal(
                    currentPendingOperation: .none, operationCountAsString: nil
                )
                debug(
                    "goToRegister expected a single letter or number for register, got \(String(describing: event.characters))"
                )
                return
            }
            debug("goToRegister with register \(register)")
            appState.mode = .normal(
                currentPendingOperation: .registerAction(register: event.characters!),
                operationCountAsString: nil)
            return
        case .registerAction:
            guard
                (event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])),
                case .normal(.registerAction(let activeRegister), _) = appState.mode
            else {
                appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
                debug("registerAction register contains a non-shift modifier or no activeRegister")
                return
            }
            switch asciiKey {
            case "y", "Y":
                if appState.isVisual {
                    CoreOperations.normalYank(
                        event: event, currentSession: currentSession, appState: appState)
                    CoreOperations.registerCurrentPasteboardItem(
                        currentSession: currentSession,
                        activeRegister: activeRegister)
                } else {
                    debug(
                        "event char charactersIgnoringModifiers = \(String(describing: asciiKeyBase))"
                    )
                    //This allows the display to be screenshot with ggyG or "[register]yG or gg"[register]yG
                    if asciiKeyBase == "y" {
                        appState.mode = .normal(currentPendingOperation: .ggy, operationCountAsString: nil)
                        appState.pendingRegisterCharacter = activeRegister
                        return
                    } else {
                        CoreOperations.registerYank(
                            event: event, currentSession: currentSession, activeRegister: activeRegister)
                    }
                }
                break
            case "d", "D":
                CoreOperations.delete(
                    event: event, appState: appState, currentSession: currentSession)
                CoreOperations.registerCurrentPasteboardItem(
                    currentSession: currentSession,
                    activeRegister: activeRegister)
                break
            case "p", "P":
                CoreOperations.pasteFromRegister(
                    event: event, appState: appState, currentSession: currentSession,
                    activeRegister: activeRegister)
                break
            default:
                break
            }
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
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
            MarksMenu.shared.refresh()
            ToastManager.shared.show("Mark '\(markChar)' set")
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            //INFO: Return early here to avoid the mark char being processed by the normal flow below, which could cause unintended behavior (eg.. "mm" would trigger both the mark setting and the "go to start of line" behavior)
            return
        }
        switch asciiKey {
        case " ":
            guard
                event.modifierFlags.rawValue == 256
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                        .shift, .capsLock,
                    ])
            else {
                return appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            }
            //INFO: This is one of the few speical times when operationCount is transfered over to a pending operation
            //To do stuff like 10-space-d or even space-10-d to Scroll Down 10 times
            appState.mode = .normal(
                currentPendingOperation: .special,
                operationCountAsString: operationCountAsString)
            return
        //TODO: Add "$", "^ : where it will go to the most left/right of the current
        //focused window", "g$" for most right, hjkl, counters,
        case "F":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            appState.gridDivisions =
                operationCount > 1 ? min(appState.maxGridDivisions, Int(operationCount)) : 2
            debug(
                "Entering find mode with gridDivisions = \(appState.gridDivisions) based on operationCount = \(operationCount)"
            )
            appState.mode = .find(
                currentPendingOperation: nil,
                findState: NeomouseType.FindState(),
                isQuickFind: true
            )
            HelpDialog.shared.hide()
            CommandLine.shared.hide()
            GridOverlay.shared.passAppState(state: appState)
            GridOverlay.shared.showGrid()
            ToastManager.shared.show(
                "Find Mode")
            return
        case "f":
            //INFO: 256 means no modifier is pressed, do not use .isEmpty method
            guard event.modifierFlags.rawValue == 256 else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            appState.mode = .find(
                currentPendingOperation: nil,
                findState: NeomouseType.FindState(),
                isQuickFind: false
            )
            HelpDialog.shared.hide()
            CommandLine.shared.hide()
            GridOverlay.shared.passAppState(state: appState)
            GridOverlay.shared.showGrid()
            ToastManager.shared.show(
                "Find Mode")
            return
        case "H", "J", "K", "L":
            // Switch-expression (Swift 5.9+) needs the explicit
            // `NeomouseType.Direction?` annotation so the `nil`
            // default unifies with the `.left/.down/.up/.right`
            // cases under the optional type. Don't wrap this in a
            // closure — that flips the parser into statement-mode
            // and the cases become Void, which is what made `nil`
            // unassignable in the earlier version.
            let pendingDirection: NeomouseType.Direction? =
                switch asciiKey {
                case "H": .right  // swapped to match the intuitive direction of the scroll
                case "J": .down
                case "K": .up
                case "L": .left  // swapped to match the intuitive direction of the scroll
                default: nil
                }
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ]),
                let direction = pendingDirection
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            Gesture.scroll(
                direction: direction,
                at: currentCGPoint,
                stepValue: Int32(operationCount) * 30,  //TODO move to config
                incrementsPerGesture: 1
            )
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        // INFO: Here starts VIM-like motions on the cursor
        //TODO check that if the operation except the lastIndex are only nums
        case "h", "j", "k", "l":
            guard
                event.modifierFlags.rawValue == 256,
                let key = asciiKey,
                let direction = HJKLDirection(key)
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            // Step = one cell of the rows×cols grid laid over
            // the inset-adjusted screen. Same formula as
            // NumbersOverlay → cursor lands exactly on cell
            // boundaries every `j`/`k`/`h`/`l` press.
            let _hjklUsable = CGRect(
                x: appState.gridInset,
                y: appState.gridInset,
                width: max(0, currentScreenSize.width - 2 * appState.gridInset),
                height: max(0, currentScreenSize.height - 2 * appState.gridInset)
            )
            let _hjklGrid = appState.resolvedGrid(usable: _hjklUsable)
            let _hjklStepX = _hjklUsable.width / CGFloat(_hjklGrid.cols)
            let _hjklStepY = _hjklUsable.height / CGFloat(_hjklGrid.rows)
            let delta = direction.delta(
                stepX: _hjklStepX,
                stepY: _hjklStepY,
                count: operationCount)
            Mouse.moveRelative(
                x: delta.dx, y: delta.dy, clampToScreen: true
            )
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "'":  //goToMark
            guard event.modifierFlags.rawValue == 256 else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            appState.mode = .normal(
                currentPendingOperation: .goToMark,
                operationCountAsString: nil
            )
            break
        case "`":  //goToMarkExactState
            guard event.modifierFlags.rawValue == 256 else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            appState.mode = .normal(
                currentPendingOperation: .goToMarkExactState,
                operationCountAsString: nil
            )
            break
        case "\"":
            guard asciiKeyBase == "\"" else {
                debug(
                    "Expected '\"' for register operations, got \(String(describing: asciiKeyBase))"
                )
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            appState.mode = .normal(
                currentPendingOperation: .goToRegister,
                operationCountAsString: nil
            )
            break
        case "?":
            guard asciiKeyBase == "?" else {
                debug(
                    "Expected '?' for help, got \(String(describing: asciiKeyBase))"
                )
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            HelpDialog.shared.toggle()
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            break
        case ":":
            guard asciiKeyBase == ":" else {
                debug(
                    "Expected ':' for command line, got \(String(describing: asciiKeyBase))"
                )
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            HelpDialog.shared.hide()
            appState.mode = .command(command: "", suggestionIndex: nil)
            CommandLine.shared.passAppState(state: appState)
            CommandLine.shared.toggle()
            break
        case "s":
            guard event.modifierFlags.rawValue == 256 else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            NumbersOverlay.shared.snapCursor()
            break
        // INFO: No need to do modifierFlags checks for captizalized chars, as a
        //modifierFlag will trigger the lowercase char equivalent
        case "G":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            if operationCount > 1 {
                debug(
                    "G - with operationCount=\(operationCount) > 1, operation G, same as [count]gg"
                )
                let _ggUsable = CGRect(
                    x: appState.gridInset,
                    y: appState.gridInset,
                    width: max(0, currentScreenSize.width - 2 * appState.gridInset),
                    height: max(0, currentScreenSize.height - 2 * appState.gridInset)
                )
                let target = MotionTarget.toLineCount(
                    localX: localCGPoint.x,
                    screenHeight: currentScreenSize.height,
                    gridInset: appState.gridInset,
                    rowsOnScreen: appState.resolvedGrid(usable: _ggUsable).rows,
                    count: operationCount)
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
            } else {
                debug("G - with operationCount 1, go to bottom of the screen")
                let target = MotionTarget.bottom(
                    localX: localCGPoint.x,
                    screenHeight: currentScreenSize.height,
                    gridInset: appState.gridInset)
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
            }
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "g":
            guard event.modifierFlags.rawValue == 256 else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            if currentPendingNormalOperation == .none {
                appState.mode = .normal(
                    currentPendingOperation: .g,
                    operationCountAsString: operationCountAsString
                )
                break
            }
            break
        case "|":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            if operationCount > 1 {
                debug(
                    "| - with operationCount=\(operationCount) > 1"
                )
                let _usable = CGRect(
                    x: appState.gridInset,
                    y: appState.gridInset,
                    width: max(0, currentScreenSize.width - 2 * appState.gridInset),
                    height: max(0, currentScreenSize.height - 2 * appState.gridInset)
                )
                let target = MotionTarget.toColumnCount(
                    localY: localCGPoint.y,
                    screenWidth: currentScreenSize.width,
                    gridInset: appState.gridInset,
                    columnsOnScreen: appState.resolvedGrid(usable: _usable).cols,
                    count: operationCount)
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
            } else {
                debug("| - with operationCount 1, go to left of the screen")
                let target = MotionTarget.leftEdge(
                    localY: localCGPoint.y,
                    gridInset: appState.gridInset)
                Mouse.moveToScreenLocal(x: target.x, y: target.y)
            }
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "V":
            appState.isVisual.toggle()
            guard appState.isVisual,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                CoreOperations.exitVisualState(
                    appState: appState,
                    visualHighlightOverlay:
                        VisualHighlightOverlay.shared)
                return
            }
            // Line height = one row of the inset-adjusted grid,
            // same as hjkl + NumbersOverlay.
            let _vUsable = CGRect(
                x: appState.gridInset,
                y: appState.gridInset,
                width: max(0, currentScreenSize.width - 2 * appState.gridInset),
                height: max(0, currentScreenSize.height - 2 * appState.gridInset)
            )
            let lineHeight =
                _vUsable.height
                / CGFloat(appState.resolvedGrid(usable: _vUsable).rows)
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
            CoreOperations.toggleVisualState(
                event: event, appState: appState,
                currentPendingNormalOperation: currentPendingNormalOperation,
                currentCGPoint: currentCGPoint,
                visualHighlightOverlay: VisualHighlightOverlay.shared
            )
            break
        case "y", "Y":
            CoreOperations.normalYank(
                event: event, currentSession: currentSession, appState: appState)
            break
        case "o":
            guard appState.isVisual,
                event.modifierFlags.rawValue == 256,
                let sx = appState.startCGXPoint,
                let sy = appState.startCGYPoint,
                let ex = appState.endCGXPoint,
                let ey = appState.endCGYPoint
            else {
                return appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
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
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            break
        //Capital O
        case "O":
            guard appState.isVisual,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ]),
                let sx = appState.startCGXPoint,
                let sy = appState.startCGYPoint,
                let ex = appState.endCGXPoint,
                let ey = appState.endCGYPoint
            else {
                return appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            }
            appState.startCGXPoint = sx
            appState.startCGYPoint = ey
            appState.endCGXPoint = ex
            appState.endCGYPoint = sy
            Mouse.moveToGlobal(x: ex, y: sy)
            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            break
        case "M":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            let target = MotionTarget.verticalMiddle(
                localX: localCGPoint.x,
                screenHeight: currentScreenSize.height)
            Mouse.moveToScreenLocal(x: target.x, y: target.y)
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "m":
            guard event.modifierFlags.rawValue == 256, currentPendingNormalOperation == .none else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            // First press: arm "m" so the next key becomes the mark name.
            // The actual addMark call lives at the top of the outer
            // `switch event.characters` so it can intercept any a–z/0–9.
            appState.mode = .normal(currentPendingOperation: .setMark, operationCountAsString: nil)
            break
        //INFO: Instead of vim's replace single char, this is the rotate gesture
        case "r":
            guard event.modifierFlags.rawValue == 256 else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            Gesture.rotate(
                degrees: appState.degreesToRotate, at: currentCGPoint,
                incrementsPerGesture:
                    appState.incrementsPerGesture)
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "R":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            Gesture.rotate(
                degrees: -appState.degreesToRotate, at: currentCGPoint,
                incrementsPerGesture:
                    appState.incrementsPerGesture)
            // Always reset pendingOperation as to reset the operationCount
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        // TODO change to current focused app and add in for g$
        case "$":
            let target = MotionTarget.rightEdge(
                localY: localCGPoint.y,
                screenWidth: currentScreenSize.width,
                gridInset: appState.gridInset)
            Mouse.moveToScreenLocal(x: target.x, y: target.y)
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "+":
            Gesture.pinchZoom(
                .in, at: currentCGPoint,
                stepValue: operationCount * appState.zoomStepValue,
                incrementsPerGesture: appState.incrementsPerGesture)
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "-":
            Gesture.pinchZoom(
                .out, at: currentCGPoint,
                stepValue: operationCount * appState.zoomStepValue,
                incrementsPerGesture: appState.incrementsPerGesture)
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        case "S":
            guard
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                    .shift, .capsLock,
                ])
            else {
                return appState.mode = .normal(
                    currentPendingOperation: .none,
                    operationCountAsString: nil
                )
            }
            Gesture.smartMagnify(at: currentCGPoint)
            appState.mode = .normal(
                currentPendingOperation: .none,
                operationCountAsString: nil
            )
            break
        default: break
        }
    }
}
