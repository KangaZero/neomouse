import AppKit
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseUtils

@MainActor
final class MarksMenu: ObservableObject {

    static let shared = MarksMenu()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    @Published private(set) var marks: [Mark] = []
    @Published var selectedIndex: Int = 0

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    func toggle() {
        if let window, window.isVisible {
            hide()
        } else {
            show()
        }
    }

    func passAppState(state: NeoMouseState) {
        appState = state
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Re-fetch marks from the DB into `marks`. Call from any code path that
    /// mutates marks (Mark.set / Mark.delete) so the menu reflects the change
    /// — live if it's already showing (via @Published), or on the next show()
    /// if hidden. No-op when no appState/session is wired up yet.
    func refresh() {
        guard let sessionId = appState?.currentSession?.id else { return }
        marks = Mark.getAll(sessionId: sessionId) ?? []
        if selectedIndex >= marks.count {
            selectedIndex = max(0, marks.count - 1)
        }
    }

    // MARK: - Public keyboard API
    // The global CGEventTap routes keys through NeoMouseApp.keyHandler (the
    // panel never becomes key window), so NeoMouseApp's `case .menu:` calls
    // these on Up/Down/Enter rather than SwiftUI `.onKeyPress`.

    func selectNext() {
        guard !marks.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % marks.count
    }

    func selectPrev() {
        guard !marks.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + marks.count) % marks.count
    }

    func activateSelected() {
        guard marks.indices.contains(selectedIndex) else { return }
        let mark = marks[selectedIndex]
        //TODO navigate the cursor to the selected mark — mirror the goToMark
        //flow in NeoMouseApp (Mouse.moveToGlobal to mark.endCG{X,Y}Point, and
        //if mark.isVisual restore start/end onto appState +
        //VisualHighlightOverlay.shared.passAppState), then hide() and return
        //to .normal mode.
        _ = mark
    }

    // MARK: - Show

    private func show() {
        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState,
            case .menu = appState.mode
        else {
            return debug(
                "Could not retrieve current screen in MarksMenu.show and/or appState is \(appState == nil ? "nil" : "not nil")"
            )
        }

        // Refresh data each time the menu opens. Subsequent in-app mutations
        // (Mark.set / Mark.delete in NeoMouseApp) call refresh() directly so
        // the panel stays live while visible.
        refresh()
        selectedIndex = marks.isEmpty ? 0 : min(selectedIndex, marks.count - 1)

        let panel = MarksPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // panel.title = "Marks"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        // Hover requires per-frame mouse-moved events. Belt-and-suspenders —
        // SwiftUI .onHover usually works without this, but the panel being a
        // utility/nonactivating panel makes it inconsistent across macOS
        // versions.
        panel.acceptsMouseMovedEvents = true
        // Without .clear, AppKit fills the panel backing under the SwiftUI
        // material → invisible (or grey) window.
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: MarksMenuView(menu: self, state: appState))
        // Auto-resize to whatever SwiftUI prefers — list height grows with
        // the row count up to the ScrollView's cap.
        hosting.sizingOptions = .preferredContentSize
        panel.contentView = hosting

        // Centered on the screen under the cursor.
        let frame = currentScreen.visibleFrame
        let panelSize = panel.frame.size
        panel.setFrameOrigin(
            CGPoint(
                x: frame.midX - panelSize.width / 2,
                y: frame.midY - panelSize.height / 2
            )
        )

        // makeKeyAndOrderFront (not orderFront) so the first click on a row
        // fires the SwiftUI tap gesture immediately. Without making the panel
        // key, macOS consumes the first click as an app-activation handshake
        // and the row's .onTapGesture only fires on the *second* click —
        // the classic "first-mouse" gotcha for floating utility windows.
        // `.nonactivatingPanel` ensures becoming key does NOT activate the
        // owning app, so whatever Safari/etc. the user was on stays focused.
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

/// NSPanel created with `.nonactivatingPanel` returns `false` from
/// `canBecomeKey` by default — that's how macOS prevents nonactivating
/// utility windows from stealing focus. We override it so this specific
/// panel CAN become key, which is what makes `onTapGesture` /
/// `onHover` route correctly on the first interaction. Because the
/// `.nonactivatingPanel` style mask is still set, the *app* doesn't
/// activate — only the panel becomes the focus target.
@MainActor
private final class MarksPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SwiftUI

private struct MarksMenuView: View {
    @ObservedObject var menu: MarksMenu
    @ObservedObject var state: NeoMouseState

    fileprivate static let markColW: CGFloat = 50
    fileprivate static let lineColW: CGFloat = 50
    fileprivate static let colColW: CGFloat = 50

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if menu.marks.isEmpty {
                Text("No marks in current session")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(menu.marks.enumerated()), id: \.element.id) { idx, mark in
                            MarkRow(
                                mark: mark,
                                isSelected: idx == menu.selectedIndex,
                                state: state
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { menu.selectedIndex = idx }
                            }
                            .onTapGesture {
                                menu.selectedIndex = idx
                                menu.activateSelected()
                            }
                        }
                    }
                }
                .frame(maxHeight: 500)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 500)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Mark").frame(width: Self.markColW, alignment: .leading)
            Text("Line").frame(width: Self.lineColW, alignment: .trailing)
            Text("Col").frame(width: Self.colColW, alignment: .trailing)
            Text("Start").frame(maxWidth: .infinity, alignment: .leading)
            Text("End").frame(maxWidth: .infinity, alignment: .leading)
            Text("isVisual").frame(maxWidth: .infinity, alignment: .leading)
            Text("Screen").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }
}

private struct MarkRow: View {
    let mark: Mark
    let isSelected: Bool
    @ObservedObject var state: NeoMouseState

    // Computed (not stored) because it depends on `mark`, and stored-property
    // initializers can't read other stored properties — they run before `self`
    // is available. Also uses CGDisplayBounds (top-left origin, same space as
    // the mark's stored point) for the contains-check; NSScreen.frame is
    // bottom-left and would be wrong on a multi-display setup.
    private var screen: NSScreen? {
        let pt = CGPoint(x: mark.endCGXPoint, y: mark.endCGYPoint)
        return NSScreen.screens.first { s in
            guard
                let num = s.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else { return false }
            return CGDisplayBounds(num.uint32Value).contains(pt)
        }
    }

    var body: some View {
        let cell = MarkRow.gridCell(for: mark, state: state)
        HStack(spacing: 8) {
            Text(mark.mark)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: MarksMenuView.markColW, alignment: .leading)
            Text(cell.map { "\($0.line + 1)" } ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: MarksMenuView.lineColW, alignment: .trailing)
            Text(cell.map { "\($0.col + 1)" } ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: MarksMenuView.colColW, alignment: .trailing)
            Text(
                "(\(mark.startCGXPoint.map { "\(Int($0))" } ?? "-"), \(mark.startCGYPoint.map { "\(Int($0))" } ?? "-"))"
            )
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("(\(Int(mark.endCGXPoint)), \(Int(mark.endCGYPoint)))")
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("(\(mark.isVisual ? "Yes" : "No"))")
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("(\(screen.map { $0.localizedName } ?? "No Screen"))")
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
    }

    /// Map a mark's stored (global CG-space) position to a (line, col) cell on
    /// the dynamic grid. The display that *contains* the mark's point is the
    /// reference frame — multi-display correct. `state.resolvedGrid` is the
    /// single source of truth for the rows×cols count (same call used by hjkl,
    /// gg, and NumbersOverlay in NeoMouseApp).
    fileprivate static func gridCell(
        for mark: Mark, state: NeoMouseState
    ) -> (line: Int, col: Int)? {
        let pt = CGPoint(x: mark.endCGXPoint, y: mark.endCGYPoint)
        // CGDisplayBounds uses CG's top-left origin, same as the mark's stored
        // point — search there rather than NSScreen.frame (bottom-left).
        guard
            let displayID = Screen.activeDisplays().first(where: {
                CGDisplayBounds($0).contains(pt)
            })
        else { return nil }
        let bounds = CGDisplayBounds(displayID)
        let usable = CGRect(
            x: state.gridInset,
            y: state.gridInset,
            width: max(1, bounds.width - 2 * state.gridInset),
            height: max(1, bounds.height - 2 * state.gridInset)
        )
        let grid = state.resolvedGrid(usable: usable)
        let localX = pt.x - bounds.origin.x
        let localY = pt.y - bounds.origin.y
        let cellWidth = usable.width / CGFloat(grid.cols)
        let cellHeight = usable.height / CGFloat(grid.rows)
        let col = Int(((localX - state.gridInset) / cellWidth).rounded(.down))
        let line = Int(((localY - state.gridInset) / cellHeight).rounded(.down))
        return (
            line: max(0, min(grid.rows - 1, line)),
            col: max(0, min(grid.cols - 1, col))
        )
    }
}
