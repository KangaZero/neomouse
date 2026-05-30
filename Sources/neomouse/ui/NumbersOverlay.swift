import AppKit
import Combine
import SwiftUI

import neomouseConfig
import neomouseUtils

/// Vim-style ruler overlay. Pinned to the display under the cursor at
/// show-time; in relative mode it follows the cursor across displays. Two
/// modes:
///
/// * `.absolute` — left gutter shows row numbers `1..rowsOnScreen`, top
///   strip shows column numbers `1..columnsOnScreen` (`:numbers`/`:nu`).
/// * `.relative` — cursor row + column show their absolute numbers; every
///   other row/column shows the distance from the cursor
///   (`:relativenumbers`/`:rnu`), like nvim's `set number relativenumber`
///   but for both axes.
///
/// Cursor tracking uses `NSEvent.addGlobalMonitorForEvents(.mouseMoved...)`,
/// installed only while `.relative` is active and removed on hide so we don't
/// pay for a global monitor when the overlay isn't showing. The window is
/// borderless, click-through, screen-saver level — it sits on top of
/// everything without stealing input.
///
/// Row + column counts come from `appState.resolvedGrid(usable:)` — see
/// `NeoMouseState`. Auto rows = screen height / 20pt baseline; auto cols
/// square the cells against the resolved row height. Anchor recomputes
/// both when the cursor moves to a different display.
@MainActor
final class NumbersOverlay {
    static let shared = NumbersOverlay()

    /// `.off` = no row/col labels (but the overlay window may still be
    /// shown if any band option is active). `.absolute` / `.relative` =
    /// the two nvim-style number-label modes.
    enum Mode: Equatable { case off, absolute, relative }
    enum Option { case cursorline, cursorcolumn }

    /// Observable state the SwiftUI view binds to. Lives on the singleton so
    /// the global mouse monitor can mutate `currentLineIndex` /
    /// `currentColumnIndex` without having to thread a reference back into
    /// the view.
    final class Model: ObservableObject {
        @Published var mode: Mode = .off
        @Published var options: [Option] = []
        @Published var rowsOnScreen: Int = 1
        @Published var columnsOnScreen: Int = 1
        /// Cell size in points. Derived from `usable / count` here — counts
        /// are the user-facing config, step is the implementation detail.
        /// Same formula `hjkl` uses to compute its step → cells align 1:1.
        @Published var stepX: CGFloat = 1
        @Published var stepY: CGFloat = 1
        @Published var currentLineIndex: Int = 0  // 0-based row under cursor
        @Published var currentColumnIndex: Int = 0  // 0-based col under cursor
        /// Full screen frame (not visibleFrame) — matches GridOverlay, which
        /// also draws over menu bar / Dock since the window sits at
        /// `screenSaver` level. Captured at show + each re-anchor.
        @Published var screenFrame: CGRect = .zero
        /// Padding from each edge of `screenFrame`, mirrors GridOverlay's
        /// `state.gridInset`. Keeps the ruler from butting up against the
        /// physical bezel / notch / corners.
        @Published var inset: CGFloat = 0
        /// Live theme handle so hot-reload of `[theme.numbers_overlay]`
        /// republishes into the SwiftUI view (the host view was created with
        /// a captured-by-value theme that wouldn't otherwise see the update).
        @Published var theme: NumbersOverlayTheme = NumbersOverlayTheme()
    }

    let model = Model()
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }
    private weak var appState: NeoMouseState?
    private var mouseMonitor: Any?
    /// The display the overlay is currently pinned to. When the cursor
    /// crosses into another screen (relative mode only), `reanchorIfNeeded`
    /// moves the window over and refreshes the captured frame.
    private var anchoredScreen: NSScreen?

    /// Theme-driven gutter dimensions. Read from `appState.theme.numbersOverlay`
    /// at present-time; fall back to defaults when state isn't available yet.
    var gutterWidth: CGFloat {
        CGFloat(appState?.theme.numbersOverlay.gutterWidth ?? 20)
    }
    var columnStripHeight: CGFloat {
        CGFloat(appState?.theme.numbersOverlay.columnStripHeight ?? 20)
    }

    func passAppState(state: NeoMouseState) {
        appState = state
        model.theme = state.theme.numbersOverlay
        // Pipe future theme republishes (from SettingsWatcher hot reload) into
        // the model so the SwiftUI view picks them up. Also re-anchor the
        // window if gutter_width / column_strip_height changed.
        themeCancellable = state.$theme
            .map(\.numbersOverlay)
            .removeDuplicates { lhs, rhs in
                // Compare on a stable derived hash — NumbersOverlayTheme is
                // not Equatable on the whole struct (font/color sub-types
                // are), so the conservative path is "always re-publish."
                return false
            }
            .sink { [weak self] newTheme in
                MainActor.assumeIsolated {
                    self?.model.theme = newTheme
                    if let appState = self?.appState, let screen = self?.anchoredScreen {
                        self?.anchorWindow(to: screen)
                        self?.recomputeIndices(mouseLocation: NSEvent.mouseLocation)
                        _ = appState  // appease unused-binding
                    }
                }
            }
    }

    /// Toggle a label mode. Same-mode → labels off (window may stay if a
    /// band option is still active). Different-mode → switch labels.
    func toggle(mode: Mode) {
        guard mode != .off else { return }  // .off is internal
        setMode(model.mode == mode ? .off : mode)
    }

    /// Toggle a band option (`:cursorline` / `:cursorcolumn`). Independent
    /// of `mode` — bands can be active without any label mode, and vice
    /// versa. Visibility resolves to "show window iff anything is visible."
    func toggleOption(_ option: Option) {
        if let idx = model.options.firstIndex(of: option) {
            model.options.remove(at: idx)
        } else {
            model.options.append(option)
        }
        updateVisibility()
        if isWindowVisible {
            // Bring indices in sync immediately so the band lands on the
            // correct row/col without waiting for the first mouse move.
            recomputeIndices(mouseLocation: NSEvent.mouseLocation)
        }
    }

    func hide() {
        window?.orderOut(nil)
        removeMouseMonitor()
    }

    // MARK: - Visibility / mode-setting internals

    private var isWindowVisible: Bool { window?.isVisible ?? false }

    private func setMode(_ mode: Mode) {
        model.mode = mode
        updateVisibility()
        if isWindowVisible {
            recomputeIndices(mouseLocation: NSEvent.mouseLocation)
        }
    }

    /// Resolve "should the overlay window be visible?" from current state.
    /// Window stays up while *anything* it draws is active — label mode or
    /// any band option. Hides once everything's off.
    private func updateVisibility() {
        if model.mode == .off && model.options.isEmpty {
            hide()
        } else {
            present()
        }
    }

    /// Create (if needed) + order-front the overlay window. Pure plumbing —
    /// callers mutate `mode` / `options` first, then call this via
    /// `updateVisibility`.
    private func present() {
        guard appState !== nil else {
            debug("NumbersOverlay.present: no appState")
            return
        }
        guard
            let currentScreen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            }) ?? NSScreen.main
        else {
            debug("NumbersOverlay.present: no screen")
            return
        }
        anchorWindow(to: currentScreen)
        recomputeIndices(mouseLocation: NSEvent.mouseLocation)
        reanchorIfNeeded(mouseLocation: NSEvent.mouseLocation)

        if window == nil {
            window = OverlayWindow.makeFullscreenClickThrough(
                contentRect: Self.rectForScreen(currentScreen),
                rootView: NumbersOverlayView(model: model),
                hasShadow: false
            )
        }
        window?.setFrame(Self.rectForScreen(currentScreen), display: true)
        window?.orderFrontRegardless()

        installMouseMonitorIfNeeded()
    }

    /// Warp the cursor to the centre of the cell currently highlighted by
    /// the overlay (`currentLineIndex`, `currentColumnIndex`). Used as the
    /// "snap to ruler cell" action — e.g. after the user picks a target with
    /// the relative-number ruler on screen.
    ///
    /// Coordinate-system notes: `visibleFrame` is in AppKit space
    /// (origin bottom-left, y increases upward). `Mouse.moveToGlobal` expects
    /// CG global coords (origin top-left of the primary display, y increases
    /// downward). We compute the cell centre in AppKit space first, then
    /// flip once at the end against the primary screen's height.
    func snapCursor() {
        guard let screen = anchoredScreen else {
            debug("NumbersOverlay.snap: no anchored screen")
            return
        }
        // Always refresh indices from the live cursor position. In .relative
        // mode the mouse monitor keeps them current already, but in
        // .absolute mode they're frozen at show-time — so without this call,
        // snap would warp back to wherever the cursor was when the user
        // opened the ruler instead of where it is now.
        recomputeIndices(mouseLocation: NSEvent.mouseLocation)

        // Same usable rect + step values used by recomputeIndices + the
        // view's layout, so snap lands exactly where the highlight is and
        // exactly one hjkl step away from each neighbour.
        let usable = Self.usableRect(screen.frame, inset: model.inset)
        let stepX = model.stepX
        let stepY = model.stepY

        // Cell centre in AppKit coords. Row index counts down from the top
        // of the usable rect (i.e. starts at usable.maxY).
        let row = CGFloat(model.currentLineIndex)
        let col = CGFloat(model.currentColumnIndex)
        let appKitX = usable.minX + (col + 0.5) * stepX
        let appKitY = usable.maxY - (row + 0.5) * stepY

        // AppKit → CG conversion uses the primary screen's height. AppKit's
        // global origin is the bottom-left of the screen whose `frame.origin`
        // is (0, 0), which is always `NSScreen.screens[0]` on macOS.
        guard let primary = NSScreen.screens.first else {
            debug("NumbersOverlay.snap: no primary screen")
            return
        }
        let cgY = primary.frame.height - appKitY

        Mouse.moveToGlobal(x: appKitX, y: cgY)
    }

    // MARK: - Internals

    /// Full screen rect (incl. menu bar / Dock area). Window at
    /// `screenSaver` level draws over them anyway; matches GridOverlay so
    /// inset math is consistent across overlays.
    private static func rectForScreen(_ screen: NSScreen) -> CGRect {
        screen.frame
    }

    /// Usable drawing area = screen frame inset by `inset` on every side.
    /// All row/col cell math runs against this rect, not the full frame.
    private static func usableRect(_ frame: CGRect, inset: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX + inset,
            y: frame.minY + inset,
            width: max(0, frame.width - 2 * inset),
            height: max(0, frame.height - 2 * inset)
        )
    }

    /// Pin the window + cached frame to a specific screen. Used both at
    /// show-time and whenever the cursor crosses onto a different display.
    /// Counts come from the `.automatic`-aware `resolvedGrid(usable:)` so
    /// behavior is identical to `hjkl` / `gg` / `V` step computation →
    /// motion ↔ overlay align 1:1.
    private func anchorWindow(to screen: NSScreen) {
        anchoredScreen = screen
        let frame = screen.frame
        let inset = appState?.gridInset ?? 0
        let usable = Self.usableRect(frame, inset: inset)
        let grid = appState?.resolvedGrid(usable: usable) ?? (rows: 1, cols: 1)
        model.screenFrame = frame
        model.inset = inset
        model.rowsOnScreen = grid.rows
        model.columnsOnScreen = grid.cols
        model.stepX = usable.width / CGFloat(grid.cols)
        model.stepY = usable.height / CGFloat(grid.rows)
        window?.setFrame(Self.rectForScreen(screen), display: true)
    }

    private func installMouseMonitorIfNeeded() {
        //IMPORTANT: This is needed as to not stack additional events to monitors/displays that already have one
        guard mouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard let self else { return }
            // Global monitor delivers off the main run loop in some cases;
            // hop back so we touch @Published state on the main actor.
            Task { @MainActor in
                let location = NSEvent.mouseLocation
                self.reanchorIfNeeded(mouseLocation: location)
                // Recompute when anything cursor-following is active:
                // relative labels, or either band option.
                if model.mode == .relative || !model.options.isEmpty {
                    self.recomputeIndices(mouseLocation: location)
                }
            }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    /// If the cursor has crossed onto a different display, move the overlay
    /// + refresh cached state so subsequent index math is correct. No-op
    /// while the cursor remains on the anchored screen, or briefly leaves
    /// all screens (rare; we keep the last anchor in that case).
    private func reanchorIfNeeded(mouseLocation: CGPoint) {
        guard
            let screen = NSScreen.screens.first(where: {
                $0.frame.contains(mouseLocation)
            })
        else { return }
        if screen !== anchoredScreen {
            anchorWindow(to: screen)
            //NOTE: this is still needed after re-anchoring because the mouse monitor delivers
            //so recomputeIndices is still needed even for absolute mode, but only called on screen change
            if model.mode == .absolute {
                recomputeIndices(mouseLocation: mouseLocation)
            }
        }
    }

    /// Translate a screen-coords mouse point into 0-based (row, column)
    /// indices on the anchored screen. AppKit's coord system has origin
    /// at bottom-left, so y is flipped into "distance from the top of the
    /// visible frame" before dividing by row height. X is straightforward
    /// (left → right).
    private func recomputeIndices(mouseLocation: CGPoint) {
        let usable = Self.usableRect(model.screenFrame, inset: model.inset)
        guard usable.height > 0, usable.width > 0 else { return }
        let lineCount = max(1, model.rowsOnScreen)
        let colCount = max(1, model.columnsOnScreen)
        // Use step (= rangeY / rangeX) directly, not usable/count. Keeps
        // cell index exactly aligned with how hjkl moves the cursor.
        let stepX = model.stepX
        let stepY = model.stepY

        let topDown = usable.maxY - mouseLocation.y
        let rawRow = Int((topDown / stepY).rounded(.down))
        let clampedRow = min(max(rawRow, 0), lineCount - 1)

        let leftRight = mouseLocation.x - usable.minX
        let rawCol = Int((leftRight / stepX).rounded(.down))
        let clampedCol = min(max(rawCol, 0), colCount - 1)

        // Guard against redundant @Published fires — SwiftUI re-renders
        // anyway, but skipping no-op writes avoids needless body() calls.
        if clampedRow != model.currentLineIndex {
            model.currentLineIndex = clampedRow
        }
        if clampedCol != model.currentColumnIndex {
            model.currentColumnIndex = clampedCol
        }
    }
}

struct NumbersOverlayView: View {
    @ObservedObject var model: NumbersOverlay.Model
    /// Theme read off the @Published `model.theme` so SettingsWatcher
    /// hot-reload republishes propagate without re-creating the host view.
    var theme: NumbersOverlayTheme { model.theme }

    var body: some View {
        // Drive layout from `screenFrame` directly instead of a
        // GeometryReader. GeometryReader has no preferred size, so when this
        // view is hosted in a borderless / transparent / screen-saver-level
        // NSHostingView, the very first render can collapse to zero size and
        // paint nothing until some later @Published mutation forces a
        // relayout — which is why `.relative` (mouse monitor → constant
        // mutations) appeared to work while `.absolute` (no mutations after
        // show) did not. Explicit width/height fixes both modes on the
        // initial render.
        //
        // `.ignoresSafeArea(.all)` is mandatory: without it NSHostingView
        // applies menu-bar / notch insets to the SwiftUI tree, so the ruler
        // renders shifted down from the window's actual frame. Matches
        // GridOverlay, which has the same issue + the same fix.
        let outer = model.screenFrame.size
        let inset = model.inset
        let inner = CGSize(
            width: max(0, outer.width - 2 * inset),
            height: max(0, outer.height - 2 * inset)
        )
        // Gutter sits flush against the left or right edge of the inset rect
        // based on `theme.direction`. .left → x: inset (original behavior).
        // .right → x: inset + inner.width - gutterWidth.
        let gutterWidth = CGFloat(theme.gutterWidth)
        let gutterX: CGFloat = {
            switch theme.direction {
            case .left: return inset
            case .right: return inset + inner.width - gutterWidth
            }
        }()
        // Column strip lives on top or bottom of the inset rect based on
        // `theme.columnStripDirection`. .top → y: inset (original behavior).
        // .bottom → y: inset + inner.height - columnStripHeight.
        let columnStripHeight = CGFloat(theme.columnStripHeight)
        let columnStripY: CGFloat = {
            switch theme.columnStripDirection {
            case .top: return inset
            case .bottom: return inset + inner.height - columnStripHeight
            }
        }()
        ZStack(alignment: .topLeading) {
            // Highlight bands first → row gutter + column strip draw on top
            // so labels stay legible over the tint. Bands span the full
            // inner rect (inset-adjusted screen), not just the gutter/strip
            // — that's the difference between "highlight the label" and
            // "highlight the line" (nvim's `:set cursorline`).
            cursorlineBand(inner: inner)
                .offset(x: inset, y: inset)
            cursorcolumnBand(inner: inner)
                .offset(x: inset, y: inset)
            // Labels render only when a number mode is active. `.off`
            // keeps the window up for standalone band display
            // (`:cursorline` / `:cursorcolumn` without numbers).
            if model.mode != .off {
                rowGutter(totalHeight: inner.height)
                    .offset(x: gutterX, y: inset)
                columnStrip(totalWidth: inner.width)
                    .offset(x: inset, y: columnStripY)
            }
        }
        .frame(width: outer.width, height: outer.height, alignment: .topLeading)
        .ignoresSafeArea(.all)
    }

    @ViewBuilder
    private func cursorlineBand(inner: CGSize) -> some View {
        if model.options.contains(.cursorline) {
            Rectangle()
                .fill(theme.cursorLineHighlight.swiftUI)
                .frame(width: inner.width, height: model.stepY)
                .offset(y: CGFloat(model.currentLineIndex) * model.stepY)
        }
    }

    @ViewBuilder
    private func cursorcolumnBand(inner: CGSize) -> some View {
        if model.options.contains(.cursorcolumn) {
            Rectangle()
                .fill(theme.cursorColumnHighlight.swiftUI)
                .frame(width: model.stepX, height: inner.height)
                .offset(x: CGFloat(model.currentColumnIndex) * model.stepX)
        }
    }

    @ViewBuilder
    private func rowGutter(totalHeight: CGFloat) -> some View {
        let count = max(1, model.rowsOnScreen)
        // Cell height = exact hjkl step (model.stepY = rangeY), not
        // totalHeight/count — divides drift when usable height isn't an
        // exact multiple of the step.
        let rowHeight = model.stepY
        // Auto-scale to row height, capped at the theme's configured size.
        let fontSize = max(9, min(theme.font.size, rowHeight * 0.6))
        // Right-direction gutters look better with text aligned to the
        // leading edge (text grows away from the screen edge); left
        // direction keeps the original trailing alignment.
        let textAlignment: Alignment = theme.direction == .right ? .leading : .trailing
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Text(rowLabel(i))
                    .font(
                        scaledFont(base: theme.font, size: fontSize)
                    )
                    .foregroundColor(rowColor(i))
                    .frame(
                        width: CGFloat(theme.gutterWidth),
                        height: rowHeight,
                        alignment: textAlignment
                    )
                    .padding(theme.direction == .right ? .leading : .trailing, 6)
            }
        }
        .frame(width: CGFloat(theme.gutterWidth), height: totalHeight, alignment: .topLeading)
        .background(theme.gutterBackground.swiftUI)
    }

    @ViewBuilder
    private func columnStrip(totalWidth: CGFloat) -> some View {
        let count = max(1, model.columnsOnScreen)
        // Cell width = exact hjkl step (model.stepX = rangeX).
        let colWidth = model.stepX
        // Tighter font bound for the column strip — many narrow cells means
        // labels need to fit in <colWidth, with minimumScaleFactor taking
        // over when even the floor is too big.
        let fontSize = max(8, min(theme.font.size, colWidth * 0.45))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Text(columnLabel(i))
                    .font(scaledFont(base: theme.font, size: fontSize))
                    .foregroundColor(columnColor(i))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: colWidth, height: CGFloat(theme.columnStripHeight))
            }
        }
        .frame(
            width: totalWidth, height: CGFloat(theme.columnStripHeight), alignment: .topLeading
        )
        .background(theme.gutterBackground.swiftUI)
    }

    /// Build a SwiftUI Font with the same family/weight/design as `base`
    /// but at `size`. Used to honor the auto-scale row-height math while
    /// keeping the user's font knobs intact.
    private func scaledFont(base: ThemeFont, size: CGFloat) -> Font {
        ThemeFont(size: Double(size), weight: base.weight, design: base.design, family: base.family)
            .swiftUI
    }

    private func rowLabel(_ i: Int) -> String {
        switch model.mode {
        case .absolute: return "\(i + 1)"
        case .relative:
            return i == model.currentLineIndex
                ? "\(i + 1)"
                : "\(abs(i - model.currentLineIndex))"
        case .off: return ""
        }
    }

    private func columnLabel(_ i: Int) -> String {
        switch model.mode {
        case .absolute: return "\(i + 1)"
        case .relative:
            return i == model.currentColumnIndex
                ? "\(i + 1)"
                : "\(abs(i - model.currentColumnIndex))"
        case .off: return ""
        }
    }

    private func rowColor(_ i: Int) -> Color {
        (model.mode == .relative && i == model.currentLineIndex)
            ? theme.cursorTextColor.swiftUI : theme.textColor.swiftUI
    }

    private func columnColor(_ i: Int) -> Color {
        (model.mode == .relative && i == model.currentColumnIndex)
            ? theme.cursorTextColor.swiftUI : theme.textColor.swiftUI
    }
}
