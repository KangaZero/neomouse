import AppKit
import Combine
import SwiftUI

import neomouseUtils

/// Vim-style ruler overlay. Pinned to the display under the cursor at
/// show-time; in relative mode it follows the cursor across displays. Two
/// modes:
///
/// * `.absolute` — left gutter shows row numbers `1..linesOnScreen`, top
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
/// Column count is derived from `linesOnScreen × aspect ratio` so cells stay
/// roughly square on any display. Computed at anchor-time and re-derived on
/// every re-anchor (different screen → different aspect → different count).
@MainActor
final class NumbersOverlay {
    static let shared = NumbersOverlay()

    enum Mode { case absolute, relative }

    /// Observable state the SwiftUI view binds to. Lives on the singleton so
    /// the global mouse monitor can mutate `currentLineIndex` /
    /// `currentColumnIndex` without having to thread a reference back into
    /// the view.
    final class Model: ObservableObject {
        @Published var mode: Mode = .absolute
        @Published var linesOnScreen: Int = 1
        @Published var columnsOnScreen: Int = 1
        @Published var currentLineIndex: Int = 0  // 0-based row under cursor
        @Published var currentColumnIndex: Int = 0  // 0-based col under cursor
        /// Captured at show-time + each re-anchor so the mouse-move handler
        /// can recompute indices without re-querying NSScreen, and so the
        /// view can size itself directly from the model. Must be @Published
        /// — the view reads `.size` from this when laying out, so a screen
        /// change has to trigger a re-render.
        @Published var screenVisibleFrame: CGRect = .zero
    }

    let model = Model()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?
    private var mouseMonitor: Any?
    /// The display the overlay is currently pinned to. When the cursor
    /// crosses into another screen (relative mode only), `reanchorIfNeeded`
    /// moves the window over and refreshes the captured frame.
    private var anchoredScreen: NSScreen?

    /// Width of the row gutter, in points.
    static let gutterWidth: CGFloat = 56
    /// Height of the top column strip, in points.
    static let columnStripHeight: CGFloat = 24

    func passAppState(state: NeoMouseState) {
        appState = state
    }

    /// Toggle the overlay. If it's already visible in the same mode, hide.
    /// If visible in a different mode, swap to the new mode without flicker.
    func toggle(mode: Mode) {
        if let window, window.isVisible {
            if model.mode == mode {
                hide()
            } else {
                switchMode(to: mode)
            }
        } else {
            show(mode: mode)
        }
    }

    func show(mode: Mode) {
        guard let appState else {
            debug("NumbersOverlay.show: no appState")
            return
        }
        guard
            let currentScreen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            }) ?? NSScreen.main
        else {
            debug("NumbersOverlay.show: no screen")
            return
        }

        model.mode = mode
        model.linesOnScreen = max(1, appState.linesOnScreen)
        anchorWindow(to: currentScreen)
        recomputeIndices(mouseLocation: NSEvent.mouseLocation)

        if window == nil {
            let win = NSWindow(
                contentRect: rectForScreen(currentScreen),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = .screenSaver
            win.ignoresMouseEvents = true
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: NumbersOverlayView(model: model))
            window = win
        }
        window?.setFrame(rectForScreen(currentScreen), display: true)
        window?.orderFrontRegardless()

        installMouseMonitorIfNeeded()
    }

    func hide() {
        window?.orderOut(nil)
        removeMouseMonitor()
    }

    // MARK: - Internals

    /// Window now spans the full `visibleFrame` of the anchored display so
    /// it can host both the left row gutter and the top column strip in one
    /// SwiftUI tree. The window itself is `ignoresMouseEvents = true`, so
    /// the L-shaped non-transparent area + transparent middle still passes
    /// every click through to whatever app is underneath.
    private func rectForScreen(_ screen: NSScreen) -> CGRect {
        screen.visibleFrame
    }

    /// Pin the window + cached frame to a specific screen. Used both at
    /// show-time and whenever the cursor crosses onto a different display.
    /// Column count is re-derived here because aspect ratio is per-display.
    private func anchorWindow(to screen: NSScreen) {
        anchoredScreen = screen
        let frame = screen.visibleFrame
        model.screenVisibleFrame = frame
        model.columnsOnScreen = Self.deriveColumnCount(
            lines: model.linesOnScreen,
            frame: frame
        )
        window?.setFrame(rectForScreen(screen), display: true)
    }

    /// Pick a column count that makes cells roughly square at the chosen
    /// row count. Floor of `lines × aspect` so we don't push beyond what
    /// fits — and a hard floor of 1 so divide-by-zero is impossible.
    private static func deriveColumnCount(lines: Int, frame: CGRect) -> Int {
        guard frame.height > 0 else { return 1 }
        let aspect = frame.width / frame.height
        return max(1, Int((Double(lines) * aspect).rounded()))
    }

    private func switchMode(to mode: Mode) {
        model.mode = mode
        if mode == .relative {
            installMouseMonitorIfNeeded()
            recomputeIndices(mouseLocation: NSEvent.mouseLocation)
        } else {
            // Absolute mode doesn't care about cursor position; drop the
            // global monitor to keep the overhead at zero.
            removeMouseMonitor()
        }
    }

    private func installMouseMonitorIfNeeded() {
        guard model.mode == .relative, mouseMonitor == nil else { return }
        // `.mouseMoved` only fires while no button is pressed; add the drag
        // masks too so the highlight still tracks during click-and-drag.
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
                self.recomputeIndices(mouseLocation: location)
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
        }
    }

    /// Translate a screen-coords mouse point into 0-based (row, column)
    /// indices on the anchored screen. AppKit's coord system has origin
    /// at bottom-left, so y is flipped into "distance from the top of the
    /// visible frame" before dividing by row height. X is straightforward
    /// (left → right).
    private func recomputeIndices(mouseLocation: CGPoint) {
        let frame = model.screenVisibleFrame
        guard frame.height > 0, frame.width > 0 else { return }
        let lineCount = max(1, model.linesOnScreen)
        let colCount = max(1, model.columnsOnScreen)
        let rowHeight = frame.height / CGFloat(lineCount)
        let colWidth = frame.width / CGFloat(colCount)

        let topDown = frame.maxY - mouseLocation.y
        let rawRow = Int((topDown / rowHeight).rounded(.down))
        let clampedRow = min(max(rawRow, 0), lineCount - 1)

        let leftRight = mouseLocation.x - frame.minX
        let rawCol = Int((leftRight / colWidth).rounded(.down))
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

    var body: some View {
        // Drive layout from `screenVisibleFrame` directly instead of a
        // GeometryReader. GeometryReader has no preferred size, so when this
        // view is hosted in a borderless / transparent / screen-saver-level
        // NSHostingView, the very first render can collapse to zero size and
        // paint nothing until some later @Published mutation forces a
        // relayout — which is why `.relative` (mouse monitor → constant
        // mutations) appeared to work while `.absolute` (no mutations after
        // show) did not. Explicit width/height fixes both modes on the
        // initial render.
        let size = model.screenVisibleFrame.size
        ZStack(alignment: .topLeading) {
            rowGutter(totalHeight: size.height)
            columnStrip(totalWidth: size.width)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func rowGutter(totalHeight: CGFloat) -> some View {
        let count = max(1, model.linesOnScreen)
        let rowHeight = totalHeight / CGFloat(count)
        let fontSize = max(9, min(14, rowHeight * 0.6))
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Text(rowLabel(i))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(rowColor(i))
                    .frame(
                        width: NumbersOverlay.gutterWidth,
                        height: rowHeight,
                        alignment: .trailing
                    )
                    .padding(.trailing, 6)
            }
        }
        .frame(width: NumbersOverlay.gutterWidth, height: totalHeight, alignment: .topLeading)
        .background(Color.black.opacity(0.55))
    }

    @ViewBuilder
    private func columnStrip(totalWidth: CGFloat) -> some View {
        let count = max(1, model.columnsOnScreen)
        let colWidth = totalWidth / CGFloat(count)
        // Tighter font bound for the column strip — many narrow cells means
        // labels need to fit in <colWidth, with minimumScaleFactor taking
        // over when even the floor is too big.
        let fontSize = max(8, min(12, colWidth * 0.45))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Text(columnLabel(i))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(columnColor(i))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: colWidth, height: NumbersOverlay.columnStripHeight)
            }
        }
        .frame(width: totalWidth, height: NumbersOverlay.columnStripHeight, alignment: .topLeading)
        .background(Color.black.opacity(0.55))
    }

    private func rowLabel(_ i: Int) -> String {
        switch model.mode {
        case .absolute: return "\(i + 1)"
        case .relative:
            return i == model.currentLineIndex
                ? "\(i + 1)"
                : "\(abs(i - model.currentLineIndex))"
        }
    }

    private func columnLabel(_ i: Int) -> String {
        switch model.mode {
        case .absolute: return "\(i + 1)"
        case .relative:
            return i == model.currentColumnIndex
                ? "\(i + 1)"
                : "\(abs(i - model.currentColumnIndex))"
        }
    }

    private func rowColor(_ i: Int) -> Color {
        (model.mode == .relative && i == model.currentLineIndex)
            ? .yellow : .white.opacity(0.75)
    }

    private func columnColor(_ i: Int) -> Color {
        (model.mode == .relative && i == model.currentColumnIndex)
            ? .yellow : .white.opacity(0.75)
    }
}
