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

    // @Published var operationCountAsString: String? = nil
    @Published var currentSession: Session? = nil

    @Published var pendingRegisterCharacter: String? = nil

    //TODO change to a single source of truth so use Config
    let commands: [Config.Command]
    //WARNING: Until a good dynamic solution is found, do not allow these 2 to be mutable, could be a headache as divisionCharacters may
    //need to added in to take in account if gridDivisions increased
    @Published var gridDivisions: Int
    let maxGridDivisions: Int = 6
    let innerGridDivisions: Int
    let findModeGridDivisionCharacters: [String]
    let findModeInnerGridDivisionCharacters: [String]
    /// Either explicit or `.automatic` → derive at use time. Resolve via
    /// `resolvedGrid(usable:)`, never read directly. Auto rows fall back to
    /// a 20pt baseline cell height; auto cols then square the cells.
    let rowsOnScreen: Config.AutoInt
    let columnsOnScreen: Config.AutoInt
    let minimumHighlightWidth: Int

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
        self.rowsOnScreen = config?.motion.rowsOnScreen ?? Config.Motion.defaultRowsOnScreen
        self.columnsOnScreen =
            config?.motion.columnsOnScreen ?? Config.Motion.defaultColumnsOnScreen
        self.minimumHighlightWidth =
            config?.visual.minimumHighlightWidth ?? Config.Visual.defaultMinimumHighlightWidth
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
                return .normal(currentPendingOperation: .none, operationCountAsString: nil)
            case .find:
                //TODO add in IsQuickFind option in config and use it here
                return .find(currentPendingOperation: nil, findState: NeomouseType.FindState(), isQuickFind: false)
            case .command:
                return .command(command: "", suggestionIndex: nil)
            case .disabled:
                return .disabled
            //TODO not sure if this option should be needed. Defaults to the
            //marks window — the registers menu has no "open at launch"
            //semantics yet.
            case .menu:
                return .menu(window: .marks)
            }
        }()
    }

    /// Baseline cell size in points used when both axes are `.automatic`
    /// (or when rows auto + we need a starting cell height to square cols
    /// against). 20pt matches the old fixed `range_x`/`range_y` defaults
    /// — same "feel" as pre-refactor for users on the auto path.
    static let autoBaselineCellSize: CGFloat = 20

    /// Resolve `(rowsOnScreen, columnsOnScreen)` into concrete counts for
    /// a given usable rect. Rules:
    ///   - Rows `.explicit(n)` → n.
    ///   - Rows `.automatic`   → usable.height / 20pt (floored).
    ///   - Cols `.explicit(n)` → n.
    ///   - Cols `.automatic`   → usable.width / (resolved row height) →
    ///                           keeps cells square.
    func resolvedGrid(usable: CGRect) -> (rows: Int, cols: Int) {
        let baseline = NeoMouseState.autoBaselineCellSize

        let rows: Int = {
            switch rowsOnScreen {
            case .explicit(let n): return max(1, n)
            case .automatic:
                //NOTE: baseline should never be 0, maybe set a mininum number of rows, like 10?
                guard baseline > 0 else { return 1 }
                return max(1, Int((usable.height / baseline).rounded(.down)))
            }
        }()

        let cols: Int = {
            switch columnsOnScreen {
            case .explicit(let n): return max(1, n)
            case .automatic:
                // Square cells: col width = current row height.
                let rowHeight = usable.height / CGFloat(rows)
                guard rowHeight > 0 else { return 1 }
                return max(1, Int((usable.width / rowHeight).rounded(.down)))
            }
        }()

        return (rows, cols)
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
    static var isVisualObserver: AnyCancellable?
    static let sharedState: NeoMouseState = {
        // Deploy the bundled default `settings.toml` to ~/.config/neomouse/
        // on first launch so brew/nix/manual installs all get a usable
        // template at the standard resolved path — no extra step required.
        // No-op when the user already has a settings.toml there.
        deployBundledDefaultsIfMissing()

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

    /// Copy the bundled default `settings.toml` (shipped in the .app at
    /// `Contents/Resources/settings.toml`) to `~/.config/neomouse/settings.toml`
    /// if no file is already there. Respects user customizations — never
    /// overwrites. No source = no-op (this is normal under bare `swift run`
    /// where Bundle.main has no Resources; devs deploy via `just init`).
    private static func deployBundledDefaultsIfMissing() {
        let fm = FileManager.default
        let target = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neomouse/settings.toml")
        if fm.fileExists(atPath: target.path) { return }
        guard let source = Bundle.main.url(forResource: "settings", withExtension: "toml") else {
            debug(
                "No bundled settings.toml in Bundle.main; skipping default deploy (use `just init` for dev)"
            )
            return
        }
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: source, to: target)
            debug("Deployed default settings.toml from bundle to \(target.path)")
        } catch {
            debug("Failed to deploy bundled settings.toml: \(error)")
        }
    }
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

        //TODO Reenable once able to have register when proper content copying
        // Seed register "0" with whatever's on the clipboard at launch.
        if let currentPasteboardItem = Pasteboard.getFirst() {
            Register.set(
                register: "0",
                item: currentPasteboardItem,
                sessionId: currentSession.id!)
            // debug("Pasteboard: \(Pasteboard.preview(currentPasteboardItem))")
        }
        debug("currentSession: \(String(describing: currentSession))")
        let _allScreensBoundingRect = Screen.allBoundingRect()
        debug("allScreensRect: \(String(describing: _allScreensBoundingRect))")
        let appState = NeoMouse.sharedState
        // KeyCast.shared.passAppState(state: appState)
        // Wire appState into MarksMenu / RegisterMenu once at launch so their
        // refresh() calls work from .setMark / Register.set sites before the
        // menus have ever been shown.
        MarksMenu.shared.passAppState(state: appState)
        RegisterMenu.shared.passAppState(state: appState)
        CursorSurroundedGridOverlay.shared.passAppState(state: appState)

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
                switch appState.mode {
                case .disabled:
                    return
                case .normal(let currentPendingNormalOperation, let operationCountAsString):
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
                                let screenshotTaken = try await screenshot(
                                    rect: currentDisplayBounds, excluding: CoreOperations.excludedWindowIDsForScreenshot
                                )
                                guard let screenshot = screenshotTaken else {
                                    debug("ggyG screenshot failed: \(String(describing: screenshot))")
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
                            sessionId: currentSession.id!  // It should be autogenerated by sqlite
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
                        guard let mark = Mark.get(mark: event.characters!, sessionId: currentSession.id!) else {
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
                case .find:
                    switch event.keyCode {
                    case charToKeyCodeMap["Esc"]:
                        guard event.modifierFlags.rawValue == 256 else {
                            break
                        }
                        appState.gridDivisions = Config.Grid.defaultDivisions
                        NeoMouse.enterNormalMode(appState: appState)
                        break
                    default: break
                    }
                    switch asciiKey {
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
                        break
                    default:
                        NeoMouse.executeFindModeOperation(
                            event: event, appState: appState, currentScreenSize: currentScreenSize)
                        break
                    }
                case .command(let currentCommand, let suggestionIndex):
                    // Append a typed character to the command buffer. Hoisted out of
                    // the n/N case so p/P and the default branch can call it too.
                    // Writes back to appState.mode so @Published fires and the
                    // SwiftUI CommandLineView redraws; typing resets the suggestion
                    // cycle.
                    //TODO move to neomouseUtils
                    func appendCharacterToCommand() {
                        // ASCII-canonical so :commands resolve on Cyrillic /
                        // Greek / IME layouts. Users who actually want to type
                        // non-ASCII content into the command line aren't a
                        // case we support today (commands are English-only).
                        guard let character = asciiKey else { return }
                        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        guard !mods.contains(.command),
                            !mods.contains(.control),
                            !mods.contains(.option)
                        else { return }
                        appState.mode = .command(command: currentCommand + character, suggestionIndex: nil)
                    }
                    switch event.keyCode {
                    case charToKeyCodeMap["Esc"]:
                        guard event.modifierFlags.rawValue == 256 else {
                            break
                        }
                        HelpDialog.shared.hide()
                        CommandLine.shared.hide()
                        appState.mode = .normal(
                            currentPendingOperation: .none,
                            operationCountAsString: nil
                        )
                        return
                    case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
                        if let suggestionIndex {
                            CommandLine.shared.executeSuggestionCommand(at: suggestionIndex)
                            CommandLine.shared.hide()
                        } else {
                            debug("execute command: \(currentCommand)")

                            CommandLine.shared.executeCommand(at: currentCommand)
                            CommandLine.shared.hide()
                            appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
                        }
                        return
                    case charToKeyCodeMap["Backspace"], charToKeyCodeMap["Delete"]:
                        appState.mode = .command(
                            command: String(currentCommand.dropLast()),
                            suggestionIndex: nil
                        )
                        return
                    case charToKeyCodeMap["Tab"]:
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
                    default:
                        break
                    }
                    switch asciiKeyBase {
                    //Same fn as Tab
                    case "n", "N":
                        guard
                            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
                                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                                    .control, .shift, .capsLock,
                                ])
                        else {
                            return appendCharacterToCommand()
                        }
                        let matches = CommandLine.shared.filtered
                        guard !matches.isEmpty else { return }
                        let next: Int
                        if let currentSuggestionIndex = suggestionIndex {
                            next = (currentSuggestionIndex + 1) % matches.count
                        } else {
                            next = 0
                        }
                        appState.mode = .command(command: currentCommand, suggestionIndex: next)
                        return
                    //Same fn as Shift + Tab
                    case "p", "P":
                        guard
                            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
                                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [
                                    .control, .shift, .capsLock,
                                ])
                        else {
                            return appendCharacterToCommand()
                        }
                        let matches = CommandLine.shared.filtered
                        guard !matches.isEmpty else { return }
                        let next: Int
                        if let currentSuggestionIndex = suggestionIndex {
                            next = (currentSuggestionIndex - 1 + matches.count) % matches.count
                        } else {
                            next = matches.count - 1
                        }
                        appState.mode = .command(command: currentCommand, suggestionIndex: next)
                        return
                    // For all other Plain key: append. Allow Shift for capitals, reject
                    // Cmd / Ctrl / Opt chords (let those flow to the OS).
                    default:
                        return appendCharacterToCommand()
                    }
                case .menu(let window):
                    // Esc closes whichever menu is on-screen and returns to
                    // normal mode. Hide is idempotent on the inactive one.
                    if event.keyCode == charToKeyCodeMap["Esc"] {
                        guard event.modifierFlags.rawValue == 256 else { break }
                        MarksMenu.shared.hide()
                        RegisterMenu.shared.hide()
                        appState.mode = .normal(
                            currentPendingOperation: .none,
                            operationCountAsString: nil
                        )
                        return
                    }
                    switch window {
                    case .marks:
                        switch event.keyCode {
                        case charToKeyCodeMap["UpArrow"]:
                            MarksMenu.shared.selectPrev()
                            return
                        case charToKeyCodeMap["DownArrow"]:
                            MarksMenu.shared.selectNext()
                            return
                        case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
                            MarksMenu.shared.activateSelected()
                            return
                        default:
                            break
                        }
                    case .register:
                        // Pasty-style horizontal layout: ← / → navigate, the
                        // search bar accumulates printable chars + backspace.
                        switch event.keyCode {
                        case charToKeyCodeMap["LeftArrow"]:
                            RegisterMenu.shared.selectPrev()
                            return
                        case charToKeyCodeMap["RightArrow"]:
                            RegisterMenu.shared.selectNext()
                            return
                        case charToKeyCodeMap["Return"], charToKeyCodeMap["Enter"]:
                            RegisterMenu.shared.activateSelected()
                            return
                        case charToKeyCodeMap["Backspace"], charToKeyCodeMap["Delete"]:
                            RegisterMenu.shared.deleteLastSearchChar()
                            return
                        default:
                            // Reject Cmd/Ctrl/Opt chords; allow Shift + Caps
                            // for capitalisation. Same gate as command mode.
                            guard
                                event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                    .isSubset(of: [.shift, .capsLock])
                            else { break }
                            guard let chars = event.characters, !chars.isEmpty else { break }
                            // Skip C0 controls and DEL — arrow / function keys
                            // emit non-printable scalars that would otherwise
                            // sneak into the search string.
                            guard
                                chars.unicodeScalars.allSatisfy({
                                    $0.value >= 0x20 && $0.value != 0x7F
                                })
                            else { break }
                            RegisterMenu.shared.appendSearchChar(chars)
                            return
                        }
                    }
                case .specialFind:
                    // One-shot: Esc cancels; any keystroke that maps to a cell
                    // in the dense 6×6 inner-character grid lands the mouse on
                    // that cell's CG-global center via Mouse.moveToGlobal,
                    // then exits to normal. Modifier chords are rejected so
                    // Cmd-* / Ctrl-* keep flowing to the OS untouched.
                    if event.keyCode == charToKeyCodeMap["Esc"] {
                        guard event.modifierFlags.rawValue == 256 else { break }
                        CursorSurroundedGridOverlay.shared.hide()
                        Zoom.zoomOut()
                        NeoMouse.enterNormalMode(appState: appState)
                        return
                    }
                    guard
                        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                            .isSubset(of: [.shift, .capsLock])
                    else { break }
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
                    let divisions = CursorSurroundedGridOverlay.divisions
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
                    // Widen the zoom viewport back to the full display once
                    // the cursor has landed. No-op when zoom isn't active.
                    if let displayID = Screen.activeDisplays().first(where: {
                        CGDisplayBounds($0).contains(target)
                    }) {
                        Zoom.focus(on: CGDisplayBounds(displayID))
                    }
                    NeoMouse.enterNormalMode(appState: appState)
                    return
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

        // Global mouse monitor: installed only while visual mode is active.
        //
        // Why conditional: keeping `NSEvent.addGlobalMonitorForEvents` for
        // `.mouseMoved` / `.leftMouseDragged` registered at app launch
        // interferes with `MenuBarExtra` status-item click handling — the
        // dropdown never opens. Reproducible with a minimal SwiftUI sample
        // (see ~/Documents/swiftUITest): adding a global mouse monitor to
        // an LSUIElement app kills menu-bar interaction even though the
        // monitor is a passive observer that can't modify or block events.
        //
        // We only need the monitor during visual mode (it drags the
        // selection rectangle's end-point), so install on visual-enter,
        // remove on visual-exit. Outside of visual mode, the menu bar
        // dropdown stays clickable.
        NeoMouse.isVisualObserver = appState.$isVisual
            .removeDuplicates()
            .sink { isVisual in
                MainActor.assumeIsolated {
                    if isVisual {
                        NeoMouse.installVisualMouseMonitor(appState: appState)
                    } else {
                        NeoMouse.removeVisualMouseMonitor()
                    }
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
                            if let sessionId = NeoMouse.sharedState.currentSession?.id {
                                // Vim-style numbered-register cycle: shifts
                                // "1"–"9" up by one slot, drops "9", writes
                                // the new item to both "1" and "0" in a
                                // single transaction. See Register
                                // .cycleNumbered for the full contract.
                                Register.cycleNumbered(item: item, sessionId: sessionId)
                                RegisterMenu.shared.refresh()
                            } else {
                                debug("No current session id; skipping numbered-register cycle")
                            }
                        }
                    }
                }
            }
        }
    }

    var body: some Scene {
        MenuBar()
    }

    /// Install the global mouse monitor used by visual-mode selection
    /// tracking. Idempotent — no-op if already installed. See the comment
    /// at the install site for why this is conditional rather than always-on.
    @MainActor
    static func installVisualMouseMonitor(appState: NeoMouseState) {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { _ in
            MainActor.assumeIsolated {
                guard appState.isVisual, let loc = Mouse.location() else { return }
                appState.endCGXPoint = loc.x
                appState.endCGYPoint = loc.y
                if let (currentApp, currentAppCGRect) = Mouse.appUnderRect() {
                    debug("App: \(currentApp.localizedName ?? "unknown")")
                    debug("currentAppCGRect: \(currentAppCGRect)")
                }
            }
        }
    }

    /// Remove the visual-mode global mouse monitor if installed. Idempotent.
    @MainActor
    static func removeVisualMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    static func enterNormalMode(appState: NeoMouseState) {
        //TODO: NICE TO HAVE use previous session's
        appState.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
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
            // Normal find mode flow
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
                isQuickFind: false
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
            Mouse.moveToGlobal(x: targetX, y: targetY)
            // Mouse.moveToScreenLocal(x: targetX, y: targetY)
            enterNormalMode(appState: appState)
        }
    }
}
