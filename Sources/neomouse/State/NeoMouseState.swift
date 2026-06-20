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
