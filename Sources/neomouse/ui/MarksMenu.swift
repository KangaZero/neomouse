import AppKit
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

@MainActor
final class MarksMenu: ObservableObject {

    static let shared = MarksMenu()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    @Published private(set) var marks: [Mark] = []
    @Published var selectedIndex: Int = 0
    /// Live search query. Mutated through `appendSearchChar` /
    /// `deleteLastSearchChar` from the global event-tap (`.menu(.marks)`
    /// branch). Drives `filteredMarks` and the in-panel search bar.
    /// Same pattern as RegisterMenu — the nonactivating panel + the global
    /// CGEventTap means SwiftUI's TextField can't see the keystrokes, so
    /// we mirror the search field via an @Published String and a plain
    /// Text view.
    @Published var searchText: String = ""

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    /// Whether the panel is currently on-screen. Used by NeoMouseApp's
    /// `case .menu:` dispatch to know which menu (this one vs RegisterMenu)
    /// owns the current keystrokes.
    var isVisible: Bool { window?.isVisible ?? false }

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
        // Reset search + selection so the next open starts clean.
        searchText = ""
        selectedIndex = 0
    }

    /// Re-fetch marks from the DB into `marks`. Call from any code path that
    /// mutates marks (Mark.set / Mark.delete) so the menu reflects the change
    /// — live if it's already showing (via @Published), or on the next show()
    /// if hidden. No-op when no appState/session is wired up yet.
    func refresh() {
        guard let sessionId = appState?.currentSession?.id else { return }
        marks = Mark.getAll(sessionId: sessionId) ?? []
        // Re-clamp selection against the (possibly newly-filtered) list.
        let bound = max(0, filteredMarks.count - 1)
        if selectedIndex > bound { selectedIndex = bound }
    }

    /// Case-insensitive contains match on the mark name (typically a single
    /// char) and the screen's localized name. Returns the full list when the
    /// query is empty. Cheap — marks per session are O(letters of the
    /// alphabet) so a per-keystroke recompute is fine.
    var filteredMarks: [Mark] {
        guard !searchText.isEmpty else { return marks }
        let q = searchText.lowercased()
        return marks.filter { mark in
            if mark.mark.lowercased().contains(q) { return true }
            // Match on display name of the screen the mark lives on, so the
            // user can narrow with e.g. "built" / "studio".
            let pt = CGPoint(x: mark.endCGXPoint, y: mark.endCGYPoint)
            if let screen = NSScreen.screens.first(where: { s in
                guard
                    let num = s.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                    ] as? NSNumber
                else { return false }
                return CGDisplayBounds(num.uint32Value).contains(pt)
            }), screen.localizedName.lowercased().contains(q) {
                return true
            }
            return false
        }
    }

    // MARK: - Public keyboard API
    // The global CGEventTap routes keys through NeoMouseApp.keyHandler (the
    // panel never becomes key window), so KeyHandlers' `case .menu:` calls
    // these on ↑/↓/Return/printables/Backspace rather than SwiftUI .onKeyPress.

    func selectNext() {
        let arr = filteredMarks
        guard !arr.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % arr.count
    }

    func selectPrev() {
        let arr = filteredMarks
        guard !arr.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + arr.count) % arr.count
    }

    func appendSearchChar(_ s: String) {
        searchText.append(s)
        selectedIndex = 0
    }

    func deleteLastSearchChar() {
        guard !searchText.isEmpty else { return }
        searchText.removeLast()
        selectedIndex = 0
    }

    /// Activate the selected mark — mirrors the existing
    /// `case .goToMarkExactState:` branch in KeyHandlers.handleNormalMode:
    /// warp the cursor to the mark's end CG point, restore the visual
    /// selection if the mark was set in visual mode, hide the menu, and
    /// return to normal mode.
    func activateSelected() {
        let arr = filteredMarks
        guard arr.indices.contains(selectedIndex), let appState else { return }
        let mark = arr[selectedIndex]

        // Restore visual state when the mark was set in visual mode — same
        // semantics as backtick (`` ` ``) / `.goToMarkExactState` from
        // normal mode. Plain Enter from this menu always restores exactly
        // (no separate "approximate vs exact" affordance like vim's ' vs `).
        appState.isVisual = mark.isVisual
        if mark.isVisual,
            let startX = mark.startCGXPoint, let startY = mark.startCGYPoint
        {
            appState.visual = NeomouseType.VisualState(
                startPos: CGPoint(x: startX, y: startY),
                endPos: CGPoint(x: mark.endCGXPoint, y: mark.endCGYPoint)
            )
            VisualHighlightOverlay.shared.passAppState(state: appState)
        }
        Mouse.moveToGlobal(x: mark.endCGXPoint, y: mark.endCGYPoint)
        hide()
        appState.mode = .normal(
            currentPendingOperation: .none, operationCountAsString: nil
        )
    }

    // MARK: - Show

    private func show() {
        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState,
            case .menu(window: .marks) = appState.mode
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

        let theme = appState.theme.marksMenu
        let panelSize0 = CGSize(width: theme.width, height: theme.height)
        let panel = MarksPanel(
            contentRect: CGRect(origin: .zero, size: panelSize0),
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

        let panelSize = panel.frame.size
        let origin = theme.anchor.origin(
            in: currentScreen.visibleFrame,
            panelSize: panelSize,
            offsetX: 0,
            offsetY: 0
        )
        panel.setFrameOrigin(origin)

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
        let theme = state.theme.marksMenu
        let items = menu.filteredMarks
        VStack(spacing: 0) {
            searchBar(theme: theme)
                .padding(.horizontal, theme.rowPaddingX)
                .padding(.vertical, 6)
            Divider().opacity(0.4)
            header(theme: theme)
            Divider().opacity(0.4)
            if items.isEmpty {
                Text(
                    menu.searchText.isEmpty
                        ? "No marks in current session"
                        : "No matches for \"\(menu.searchText)\""
                )
                .font(theme.emptyMessageFont.swiftUI)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, mark in
                                MarkRow(
                                    mark: mark,
                                    isSelected: idx == menu.selectedIndex,
                                    state: state
                                )
                                .id(mark.id)
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
                    .frame(maxHeight: CGFloat(theme.height))
                    // Keep the selected row visible as ↑/↓ moves selection
                    // past the viewport edge.
                    .onChange(of: menu.selectedIndex) { _, new in
                        guard items.indices.contains(new) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(items[new].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(theme.material.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .frame(width: CGFloat(theme.width))
    }

    /// Static-display search bar — same pattern as RegisterMenu. The global
    /// event tap consumes keys before SwiftUI sees them, so the field is
    /// driven from KeyHandlers' `case .menu(.marks):` keystroke branch via
    /// `menu.appendSearchChar` / `deleteLastSearchChar`.
    private func searchBar(theme: MarksMenuTheme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            if menu.searchText.isEmpty {
                Text("Search marks by name or screen")
                    .foregroundColor(.secondary)
            } else {
                Text(menu.searchText)
                    .foregroundColor(.primary)
            }
            Spacer()
            Text("\(menu.filteredMarks.count)")
                .foregroundColor(.secondary)
        }
        .font(theme.cellFont.swiftUI)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(theme: MarksMenuTheme) -> some View {
        HStack(spacing: 8) {
            Text("Mark").frame(width: Self.markColW, alignment: .leading)
            Text("Line").frame(width: Self.lineColW, alignment: .trailing)
            Text("Col").frame(width: Self.colColW, alignment: .trailing)
            Text("Start").frame(maxWidth: .infinity, alignment: .leading)
            Text("End").frame(maxWidth: .infinity, alignment: .leading)
            Text("isVisual").frame(maxWidth: .infinity, alignment: .leading)
            Text("Screen").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(theme.headerFont.swiftUI)
        .foregroundColor(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, theme.rowPaddingX)
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
        let theme = state.theme.marksMenu
        let cell = MarkRow.gridCell(for: mark, state: state)
        HStack(spacing: 8) {
            Text(mark.mark)
                .font(theme.markLabelFont.swiftUI)
                .frame(width: MarksMenuView.markColW, alignment: .leading)
            Text(cell.map { "\($0.line + 1)" } ?? "—")
                .font(theme.cellFont.swiftUI)
                .frame(width: MarksMenuView.lineColW, alignment: .trailing)
            Text(cell.map { "\($0.col + 1)" } ?? "—")
                .font(theme.cellFont.swiftUI)
                .frame(width: MarksMenuView.colColW, alignment: .trailing)
            Text(
                "(\(mark.startCGXPoint.map { "\(Int($0))" } ?? "-"), \(mark.startCGYPoint.map { "\(Int($0))" } ?? "-"))"
            )
            .font(theme.cellFont.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("(\(Int(mark.endCGXPoint)), \(Int(mark.endCGYPoint)))")
                .font(theme.cellFont.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("(\(mark.isVisual ? "Yes" : "No"))")
                .font(theme.cellFont.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("(\(screen.map { $0.localizedName } ?? "No Screen"))")
                .font(theme.cellFont.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, theme.rowPaddingY)
        .padding(.horizontal, theme.rowPaddingX)
        .background(isSelected ? theme.selectedRowBackground.swiftUI : Color.clear)
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
