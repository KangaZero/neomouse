import AppKit
import Combine
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseUtils
import neomouseTypes

// `@unchecked Sendable` is safe here because every mutation either:
//   * comes from SwiftUI (always main-actor isolated),
//   * comes from the CGEventTap callback in KeyEventTap.swift (wrapped in
//     `MainActor.assumeIsolated` before touching state), or
//   * comes from a Combine sink that does the same.
// Without the conformance, the SwiftUI `Binding(get:set:)` helpers added in
// `ui/SettingsView.swift` produce strict-concurrency warnings on every
// closure that captures `self` — Binding's `get:` / `set:` are `@Sendable`
// in the Swift 6 SDK.
class NeoMouseState: ObservableObject, @unchecked Sendable {
    @Published var mode: NeomouseType.Mode = .disabled
    @Published var gridInset: CGFloat
    //TODO Eventually use Session.Operations Table for the below Published var
    @Published var isVisual: Bool = false

    /// Current visual-mode selection (start + end CG points). Single source
    /// of truth — the eight pre-existing per-coord properties
    /// (startCGXPoint, startCGYPoint, …, previousVisualEndCGYPoint) are now
    /// computed-property shims that read/write through this struct. New code
    /// should prefer `visual`, `previousVisual`, `currentVisualRect`, and
    /// the `setVisualStart/setVisualEnd/clearVisual` helpers below.
    @Published var visual: NeomouseType.VisualState = .init()
    /// Snapshot of `visual` at the moment `exitVisualState()` last ran.
    /// `goToPreviousVisualState` (and the gv keybind) restores from this.
    @Published var previousVisual: NeomouseType.VisualState = .init()

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
    /// Gates the vim-showcmd KeyCast overlay. When false, the panel is never
    /// shown regardless of what's pending; when true, KeyCast.update() decides
    /// per-state whether to surface it.
    let isShowKeyCast: Bool
    /// When true, hjkl motions snap the cursor to its grid-cell centre while
    /// `:cursorline` / `:cursorcolumn` is active so it aligns with the
    /// highlighted band. See `NeoMouse.autoSnapToCursorBandIfNeeded`.
    ///
    /// `@Published var` (not `let`) because the Settings window toggles it
    /// live and `SettingsWatcher` hot-reloads it from settings.toml — see
    /// `reload(from:)` and `SettingsView`'s Behavior section.
    @Published var isAutoSnap: Bool

    @Published var frontAppFollowsMouse: Bool
    //TODO add the rest

    // User-overridable visual theme for every overlay / menu / toast.
    // `@Published` so `SettingsWatcher` can republish a new value on every
    // settings.toml save and SwiftUI views observing `state` (via
    // `@ObservedObject`) automatically re-render. Defaults match the
    // original hardcoded values so a settings.toml with no `[theme.*]`
    // blocks renders identically to the pre-theme app.
    @Published var theme: Config.Theme

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
        self.frontAppFollowsMouse =
            config?.configuration.frontAppFollowsMouse ?? Config.Configuration.defaultFrontAppFollowsMouse
        self.modeOnStart =
            config?.configuration.modeOnStart ?? Config.Configuration.defaultModeOnStart
        self.isShowKeyCast =
            config?.configuration.isShowKeyCast ?? Config.Configuration.defaultIsShowKeyCast
        self.isAutoSnap =
            config?.configuration.isAutoSnap ?? Config.Configuration.defaultIsAutoSnap
        self.theme = config?.theme ?? Config.Theme()

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

    /// Live-reload the subset of settings that can change at runtime without
    /// re-installing event taps / re-loading the DB / etc. Called by
    /// `SettingsWatcher` on every successful re-decode of settings.toml.
    ///
    /// Currently reloadable: `[theme.*]` — colors, fonts, sizes, anchors. All
    /// SwiftUI views that read `state.theme.X` inside `body` redraw
    /// automatically because `theme` is `@Published`. Panels that captured
    /// theme at panel-creation time (CommandLine, MarksMenu, RegisterMenu,
    /// HelpDialog) pick up changes on next show — close-and-reopen. Also
    /// `[configuration].is_auto_snap` — a cheap behavior toggle read fresh on
    /// every hjkl motion, so a re-decode picks it up with no further wiring.
    ///
    /// Not reloadable (require restart, with no toast nag because users
    /// rarely change them): `is_disable_key_input` (CGEventTap mode swap is
    /// risky), `mode_on_start` (only meaningful at launch), `max_session_count`
    /// (retroactive DB truncation is awkward), `[commands] available`
    /// (wildmenu cache would need a rebuild).
    func reload(from config: Config) {
        theme = config.theme ?? Config.Theme()
        isAutoSnap = config.configuration.isAutoSnap
        frontAppFollowsMouse = config.configuration.frontAppFollowsMouse
    }

    // MARK: - Visual selection helpers

    /// Returns the active visual selection as a normalized CGRect, or nil
    /// when either endpoint is missing. Callers no longer have to unpack
    /// four separate optional point fields and compute min/abs/width/height
    /// themselves — they get a single guarded value.
    var currentVisualRect: CGRect? { Self.rect(from: visual) }
    /// Same idea for the previous selection — what `goToPreviousVisualState`
    /// restores from.
    var previousVisualRect: CGRect? { Self.rect(from: previousVisual) }

    private static func rect(from selection: NeomouseType.VisualState) -> CGRect? {
        guard let s = selection.startPos, let e = selection.endPos else { return nil }
        return CGRect(
            x: min(s.x, e.x),
            y: min(s.y, e.y),
            width: abs(e.x - s.x),
            height: abs(e.y - s.y)
        )
    }

    /// Set the start point of the current selection — both x and y in one
    /// atomic publish, instead of two separate `startCGXPoint = …` /
    /// `startCGYPoint = …` writes.
    func setVisualStart(_ point: CGPoint) {
        visual.startPos = point
    }

    func setVisualEnd(_ point: CGPoint) {
        visual.endPos = point
    }

    /// Snapshot the current selection into `previousVisual` and clear the
    /// current selection. Mirrors the legacy "exit visual" pattern
    /// (`previousVisualX = startX; startX = nil`) but in a single publish.
    func savePreviousAndClearVisual() {
        previousVisual = visual
        visual = .init()
    }

    func clearVisualSelection() {
        visual = .init()
    }

    // MARK: - Backwards-compatibility shims
    //
    // Pre-VisualState the class had eight `@Published` per-coord fields
    // (startCGXPoint, startCGYPoint, …, previousVisualEndCGYPoint). These
    // shims let the 70+ existing call sites in NeoMouseApp.swift,
    // CoreOperations.swift, AppDelegate.swift, MarksMenu.swift, and the
    // overlays keep compiling unchanged while the storage migrates to two
    // `VisualState` structs. New code should prefer `visual` / `previousVisual`
    // / `currentVisualRect` directly.
    //
    // Setting any one coordinate writes through to the underlying VisualState
    // (using 0 for the missing coord if the matching point was nil). Setting
    // any one coordinate to nil clears the whole point — matches the legacy
    // usage pattern, which always paired `startCGXPoint = nil; startCGYPoint = nil`.

    var startCGXPoint: CGFloat? {
        get { visual.startPos?.x }
        set { visual.startPos = Self.mergeX(newValue, into: visual.startPos) }
    }
    var startCGYPoint: CGFloat? {
        get { visual.startPos?.y }
        set { visual.startPos = Self.mergeY(newValue, into: visual.startPos) }
    }
    var endCGXPoint: CGFloat? {
        get { visual.endPos?.x }
        set { visual.endPos = Self.mergeX(newValue, into: visual.endPos) }
    }
    var endCGYPoint: CGFloat? {
        get { visual.endPos?.y }
        set { visual.endPos = Self.mergeY(newValue, into: visual.endPos) }
    }
    var previousVisualStartCGXPoint: CGFloat? {
        get { previousVisual.startPos?.x }
        set { previousVisual.startPos = Self.mergeX(newValue, into: previousVisual.startPos) }
    }
    var previousVisualStartCGYPoint: CGFloat? {
        get { previousVisual.startPos?.y }
        set { previousVisual.startPos = Self.mergeY(newValue, into: previousVisual.startPos) }
    }
    var previousVisualEndCGXPoint: CGFloat? {
        get { previousVisual.endPos?.x }
        set { previousVisual.endPos = Self.mergeX(newValue, into: previousVisual.endPos) }
    }
    var previousVisualEndCGYPoint: CGFloat? {
        get { previousVisual.endPos?.y }
        set { previousVisual.endPos = Self.mergeY(newValue, into: previousVisual.endPos) }
    }

    private static func mergeX(_ x: CGFloat?, into existing: CGPoint?) -> CGPoint? {
        guard let x else { return nil }
        return CGPoint(x: x, y: existing?.y ?? 0)
    }

    private static func mergeY(_ y: CGFloat?, into existing: CGPoint?) -> CGPoint? {
        guard let y else { return nil }
        return CGPoint(x: existing?.x ?? 0, y: y)
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
    static var settingsWatcher: SettingsWatcher?
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
        // `Session.id` is `Int64?` (GRDB autoincrement). It's populated by the
        // insert that ran during `initializeDB` above, so it's never nil here
        // in practice — but rather than `currentSession.id!` repeatedly, bind
        // once and surface a clear error if the invariant is ever broken.
        guard let sessionId = currentSession.id else {
            debug("Session loaded but had no id; was it persisted?")
            showFatalAlertAndQuit(
                title: "NeoMouse failed to start",
                message: """
                    The session loaded from the database is missing its row id. \
                    This indicates a DB corruption issue — please report it.
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
                sessionId: sessionId)
            // debug("Pasteboard: \(Pasteboard.preview(currentPasteboardItem))")
        }
        debug("currentSession: \(String(describing: currentSession))")
        let _allScreensBoundingRect = Screen.allBoundingRect()
        debug("allScreensRect: \(String(describing: _allScreensBoundingRect))")
        let appState = NeoMouse.sharedState
        // KeyCast subscribes to $mode here so the vim-showcmd pill can
        // appear/disappear reactively as soon as a pending op is set/cleared.
        KeyCast.shared.passAppState(state: appState)
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
                case .find:
                    NeoMouse.handleFindMode(ctx: ctx)
                case .command(let command, let suggestionIndex):
                    NeoMouse.handleCommandMode(
                        ctx: ctx, currentCommand: command, suggestionIndex: suggestionIndex
                    )
                case .menu(let window):
                    NeoMouse.handleMenuMode(ctx: ctx, window: window)
                case .specialFind:
                    NeoMouse.handleSpecialFindMode(ctx: ctx)
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

        // Hot reload: watch the resolved settings.toml for writes; on every
        // successful re-decode, push the new theme into appState (which is
        // @Published → SwiftUI views observing `state` re-render). Decode
        // failures keep the old config in place and surface the error via
        // toast so the user knows what to fix without scraping the log file.
        NeoMouse.settingsWatcher = SettingsWatcher { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let config):
                    appState.reload(from: config)
                    debug("SettingsWatcher: reloaded \(Config.resolvedURL?.path ?? "<unknown>")")
                    ToastManager.shared.show("Reloaded settings.toml")
                case .failure(let error):
                    debug("SettingsWatcher: reload failed — \(error)")
                    ToastManager.shared.show("Reload failed: \(error)")
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

    /// Auto-snap: when `is_auto_snap` is enabled and a cursor band
    /// (`:cursorline` / `:cursorcolumn`) is currently showing, warp the cursor
    /// to the centre of the grid cell it sits in so it lines up exactly with
    /// the highlighted band. Reuses `NumbersOverlay.snapCursor()` — the same
    /// path the manual `s` keybind uses — which recomputes the cell index from
    /// the live cursor position first, so it's safe to call right after a
    /// motion has warped the cursor. No-op when auto-snap is off or no band is
    /// active.
    @MainActor
    static func autoSnapToCursorBandIfNeeded(appState: NeoMouseState) {
        guard appState.isAutoSnap, NumbersOverlay.shared.hasActiveCursorBand else { return }
        NumbersOverlay.shared.snapCursor()
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
