import AppKit
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseUtils

@MainActor
final class RegisterMenu: ObservableObject {

    static let shared = RegisterMenu()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    @Published private(set) var registers: [Register] = []
    @Published var selectedIndex: Int = 0
    /// Live search query. Mutated through `appendSearchChar` /
    /// `deleteSearchChar` from NeoMouseApp's event-tap handler — the panel is
    /// nonactivating + the global CGEventTap consumes keys before SwiftUI's
    /// TextField could ever see them, so we mirror the command-mode pattern
    /// and drive the field from the same place that drives every other
    /// keystroke in the app.
    @Published var searchText: String = ""

    /// Whether the panel is currently on-screen. Used by NeoMouseApp's
    /// `case .menu:` dispatch to know which menu (this one vs MarksMenu) owns
    /// the current keystrokes.
    var isVisible: Bool { window?.isVisible ?? false }

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
        // Reset search so the next open starts clean. Selection follows.
        searchText = ""
        selectedIndex = 0
    }

    /// Re-fetch registers from the DB into `registers`. Call from any code path
    /// that mutates registers (Register.set / Register.delete, plus the
    /// pasteboard watcher) so the menu reflects the change — live if it's
    /// already showing (via @Published), or on the next show() if hidden. No-op
    /// when no appState/session is wired up yet.
    func refresh() {
        guard let sessionId = appState?.currentSession?.id else { return }
        let next = Register.getAll(sessionId: sessionId) ?? []
        // Most-recent first matches Pasty's left-to-right MRU ordering.
        registers = next.sorted { $0.createdAt > $1.createdAt }
        // Re-clamp selection against the (possibly newly-filtered) list.
        let bound = max(0, filteredRegisters.count - 1)
        if selectedIndex > bound { selectedIndex = bound }
    }

    /// Subsequence-match on register name, origin URL, or `.string` content of
    /// the decoded pasteboard item. Case-insensitive contains — cheap, plenty
    /// expressive for ~50 entries. Returns the full list when the query is
    /// empty.
    var filteredRegisters: [Register] {
        guard !searchText.isEmpty else { return registers }
        let q = searchText.lowercased()
        return registers.filter { r in
            if r.register.lowercased().contains(q) { return true }
            if let url = r.originURL, url.lowercased().contains(q) { return true }
            if let item = r.pasteboardItem,
                let s = item.string(forType: .string),
                s.lowercased().contains(q)
            {
                return true
            }
            return false
        }
    }

    // MARK: - Public keyboard API
    // The global CGEventTap routes keys through NeoMouseApp.keyHandler. Search
    // text accumulates here; arrow keys move selection; Return activates.

    func appendSearchChar(_ s: String) {
        searchText.append(s)
        selectedIndex = 0
    }

    func deleteLastSearchChar() {
        guard !searchText.isEmpty else { return }
        searchText.removeLast()
        selectedIndex = 0
    }

    func selectNext() {
        let arr = filteredRegisters
        guard !arr.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % arr.count
    }

    func selectPrev() {
        let arr = filteredRegisters
        guard !arr.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + arr.count) % arr.count
    }

    /// Mirrors `CoreOperations.pasteFromRegister`: write the selected
    /// register's content to NSPasteboard, hide the menu, return to normal
    /// mode, then simulate ⌘V into whichever app was focused when the menu
    /// opened. The nonactivating panel never stole app focus, so the
    /// underlying app is still the one that receives the paste.
    func activateSelected() {
        let arr = filteredRegisters
        guard arr.indices.contains(selectedIndex), let appState else { return }
        let register = arr[selectedIndex]
        guard let item = register.pasteboardItem else {
            debug("RegisterMenu.activateSelected: register '\(register.register)' has no pasteboardItem")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        hide()
        appState.mode = .normal(
            currentPendingOperation: .none, operationCountAsString: nil
        )
        // Defer the synthesized ⌘V one runloop tick — gives the panel time
        // to orderOut and the focused-app chain to settle before the paste
        // lands, matching the existing pasteFromRegister cadence.
        DispatchQueue.main.async {
            System.simulate(.paste)
        }
    }

    // MARK: - Show

    private func show() {
        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState,
            case .menu(window: .register) = appState.mode
        else {
            return debug(
                "Could not retrieve current screen in RegisterMenu.show and/or appState is \(appState == nil ? "nil" : "not nil")"
            )
        }

        // Refresh data each time the menu opens. Subsequent in-app mutations
        // (Register.set in CoreOperations) call refresh() directly so the
        // panel stays live while visible.
        refresh()
        searchText = ""
        selectedIndex = 0

        let theme = appState.theme.registerMenu
        let panel = RegisterPanel(
            contentRect: CGRect(x: 0, y: 0, width: theme.width, height: theme.height),
            styleMask: [.closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: RegisterMenuView(menu: self, state: appState))
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

        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

/// NSPanel created with `.nonactivatingPanel` returns `false` from
/// `canBecomeKey` by default. Override so the panel itself can become key
/// (enables `onTapGesture` / `onHover` on first interaction) without
/// activating the owning app.
@MainActor
private final class RegisterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SwiftUI

private struct RegisterMenuView: View {
    @ObservedObject var menu: RegisterMenu
    @ObservedObject var state: NeoMouseState

    var body: some View {
        let theme = state.theme.registerMenu
        let items = menu.filteredRegisters
        VStack(spacing: 10) {
            searchBar(theme: theme)
            if items.isEmpty {
                Spacer()
                Text(
                    menu.searchText.isEmpty
                        ? "No registers in current session"
                        : "No matches for \"\(menu.searchText)\""
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, register in
                                RegisterCard(
                                    register: register,
                                    isSelected: idx == menu.selectedIndex,
                                    theme: theme
                                )
                                .id(register.id)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                                .onHover { hovering in
                                    if hovering { menu.selectedIndex = idx }
                                }
                                .onTapGesture {
                                    menu.selectedIndex = idx
                                    menu.activateSelected()
                                }
                            }
                        }
                        .padding(.horizontal, theme.cardPaddingX)
                        .padding(.vertical, theme.cardPaddingY)
                    }
                    // Keep the selected card visible as the user moves through
                    // with ←/→. Without this, arrow-driven selection silently
                    // walks off the right edge of the viewport.
                    .onChange(of: menu.selectedIndex) { _, new in
                        guard items.indices.contains(new) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(items[new].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(theme.viewPadding)
        .background(theme.material.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .frame(width: CGFloat(theme.width), height: CGFloat(theme.height))
    }

    private func searchBar(theme: RegisterMenuTheme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            // Static display, not a TextField — the global event tap consumes
            // keys before SwiftUI sees them, so the field is driven from
            // NeoMouseApp's `case .menu:` keystroke handler.
            if menu.searchText.isEmpty {
                Text("Search registers by name, text, or URL")
                    .foregroundColor(.secondary)
            } else {
                Text(menu.searchText)
                    .foregroundColor(.primary)
            }
            Spacer()
            Text("\(menu.filteredRegisters.count)")
                .font(theme.badgeFont.swiftUI)
                .foregroundColor(.secondary)
        }
        .font(theme.searchFont.swiftUI)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Card

private struct RegisterCard: View {
    let register: Register
    let isSelected: Bool
    let theme: RegisterMenuTheme

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        // Decode once per body run. Cheap for typical clipboard sizes; if we
        // ever notice frame drops with large image registers, hoist this into
        // a precomputed `displayPayload` on the model.
        let item = register.pasteboardItem
        let image = item.flatMap(Self.pasteboardImage(from:))
        let text = item?.string(forType: .string)
        let source = Self.resolveSourceApp(bundleId: register.sourceAppBundleId)

        VStack(alignment: .leading, spacing: 0) {
            header(source: source)
            Divider().opacity(0.4)
            contentView(image: image, text: text)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: CGFloat(theme.cardWidth), height: CGFloat(theme.cardHeight))
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    (isSelected ? theme.selectedCardBorder : theme.unselectedCardBorder).swiftUI,
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(
            color: (isSelected ? theme.cardShadowSelected : theme.cardShadowUnselected).swiftUI,
            radius: isSelected ? 8 : 3,
            y: 2
        )
    }

    private func header(source: (name: String, icon: NSImage)?) -> some View {
        HStack(spacing: 6) {
            if let icon = source?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            }
            Text(source?.name ?? "Unknown")
                .font(theme.appNameFont.swiftUI)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("\"\(register.register)")
                .font(theme.registerLabelFont.swiftUI)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.registerBadgeBackground.swiftUI)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func contentView(image: NSImage?, text: String?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else if let text, !text.isEmpty {
                Text(text)
                    .font(theme.cardTextFont.swiftUI)
                    .lineLimit(10)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    Text("Binary content")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.contentBackground.swiftUI)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let url = register.originURL, !url.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                    Text(url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(.secondary)
                .font(.system(size: 10))
            }
            Text(Self.relativeFormatter.localizedString(for: register.createdAt, relativeTo: Date()))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Decoding helpers

    /// Pull a renderable `NSImage` out of the pasteboard item. macOS normalizes
    /// most image pastes to `.tiff`; browsers may write `.png` directly; some
    /// apps push JPEG. We try each in order and return the first that decodes.
    private static func pasteboardImage(from item: NSPasteboardItem) -> NSImage? {
        let candidates: [NSPasteboard.PasteboardType] = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
        ]
        for type in candidates {
            if let data = item.data(forType: type), let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }

    /// Resolve a stored bundle ID to a display name + icon via NSWorkspace.
    /// `urlForApplication(withBundleIdentifier:)` is cheap and uses LSCache —
    /// fine to call per-card. Returns nil if the app is no longer installed.
    private static func resolveSourceApp(bundleId: String?) -> (name: String, icon: NSImage)? {
        guard let bundleId,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let bundle = Bundle(url: appURL)
        let name =
            (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return (name, icon)
    }
}
