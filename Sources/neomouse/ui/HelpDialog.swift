import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

/// Floating help window listing every neomouse keybind. Press `?` in normal
/// mode to toggle. Standard NSWindow (not NSPanel) so the title-bar close
/// button renders + the user can scroll + select text inside. `level =
/// .floating` keeps it above the focused app; `orderFront(nil)` (vs
/// makeKeyAndOrderFront) means showing it doesn't steal focus — focus only
/// switches when the user actually clicks inside.
@MainActor
final class HelpDialog {
    static let shared = HelpDialog()
    private var window: NSWindow?

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

    func show() {
        // Gate: only available in normal mode. Stops `?` from opening the
        // help panel while typing in command mode, picking a target in
        // find mode, etc.
        guard case .normal = NeoMouse.sharedState.mode else {
            debug(
                "HelpDialog.show: refused — (automatically hiding if shown) only available in normal mode (current: \(NeoMouse.sharedState.mode))"
            )
            hide()
            return
        }
        guard
            let currentScreen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            }) ?? NSScreen.main
        else {
            debug("HelpDialog.show: no screen available")
            return
        }
        let theme = NeoMouse.sharedState.theme.helpDialog
        let size = CGSize(width: theme.width, height: theme.height)
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            win = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "NeoMouse Help"
            win.level = .floating
            // Clicking the title-bar close button should just hide, not
            // deallocate the window — toggle() can show it again later.
            win.isReleasedWhenClosed = false
            win.hidesOnDeactivate = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: HelpDialogView(theme: theme))
            window = win
        }
        let origin = theme.anchor.origin(
            in: currentScreen.visibleFrame,
            panelSize: size,
            offsetX: 0,
            offsetY: 0
        )
        win.setFrameOrigin(origin)
        // orderFront, not makeKeyAndOrderFront — show without stealing focus.
        win.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

/// One sidebar entry per topic. Same shape as `SettingsSection` in
/// `SettingsView.swift` — sidebar `Label(rawValue, systemImage:)` + detail
/// view per case. **Quickstart** sits first so a brand-new user sees the
/// 30-second cheatsheet before any of the deeper documentation; subsequent
/// sections go in learning order.
private enum HelpSection: String, CaseIterable, Identifiable {
    case quickstart = "Quickstart"
    case activation = "Activation"
    case motion = "Motion"
    case find = "Find"
    case visual = "Visual"
    case marks = "Marks"
    case registers = "Registers"
    case commands = "Commands"
    case gestures = "Gestures"
    case config = "Config"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .quickstart: return "bolt.fill"
        case .activation: return "power"
        case .motion: return "arrow.up.and.down.and.arrow.left.and.right"
        case .find: return "magnifyingglass"
        case .visual: return "selection.pin.in.out"
        case .marks: return "bookmark.fill"
        case .registers: return "tray.full.fill"
        case .commands: return "terminal.fill"
        case .gestures: return "hand.draw"
        case .config: return "gearshape.fill"
        }
    }
}

struct HelpDialogView: View {
    let theme: HelpDialogTheme
    @State private var selection: HelpSection = .quickstart

    var body: some View {
        // Same NavigationSplitView layout as the Settings window — sidebar
        // list of sections + detail pane per selection. Keeps the two
        // first-party panels visually consistent.
        NavigationSplitView {
            List(HelpSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                content(for: selection)
                    .padding(theme.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("NeoMouse Help")
        .textSelection(.enabled)
    }

    // MARK: - Per-section content

    @ViewBuilder
    private func content(for section: HelpSection) -> some View {
        switch section {
        case .quickstart: quickstart
        case .activation: activation
        case .motion: motion
        case .find: find
        case .visual: visual
        case .marks: marks
        case .registers: registers
        case .commands: commands
        case .gestures: gestures
        case .config: config
        }
    }

    // MARK: Quickstart — 30-second cheatsheet

    private var quickstart: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Quickstart")
            intro(
                "NeoMouse turns a vim-style modal interface into a system-wide cursor controller. Activate with Cmd-E, drive the cursor with hjkl + grid jumps, snapshot regions to your clipboard, and stash positions/clipboard slots as marks/registers."
            )

            subheading("The essentials")
            row("Cmd-E", "Activate / deactivate neomouse")
            row("?", "Toggle this help")
            row("Esc", "Cancel pending op, exit visual mode")

            subheading("Move")
            row("h j k l", "Left / down / up / right (one grid cell)")
            row("<N><motion>", "Repeat motion N times — e.g. `10j`, `5l`")
            row("0  $", "Left edge / right edge of current line")
            row("gg  G  M  gm", "Top / bottom / vertical-mid / horizontal-mid")

            subheading("Jump anywhere (2 keys)")
            row("f", "Open the labeled grid")
            row("<char><char>", "Pick outer cell, then inner cell — cursor warps there")

            subheading("Capture")
            row("v + motion + y", "Visual-select a rect, yank as screenshot to clipboard")
            row("\"{r}y  \"{r}p", "Yank into register r / paste from register r")

            subheading("Remember positions")
            row("m{x}  `{x}", "Set mark x at cursor / jump back to mark x")

            subheading("Commands")
            row(":help  :marks  :registers", "Open help / marks menu / registers menu")
            row(":nu  :rnu", "Toggle absolute / relative line+column numbers")
            row(":q  :r", "Quit / restart the daemon")

            subheading("Next steps")
            tip(
                "Each tab above goes deep on its topic — read **Motion** to understand the grid, **Visual** for the yank-screenshot flow, **Commands** for the full :ex command list, and **Config** for the settings.toml knobs you'll want to tune."
            )
        }
    }

    // MARK: Activation

    private var activation: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Activation")
            intro(
                "NeoMouse runs as a menu-bar daemon, always on but only intercepting keys while *active*. When deactivated every keystroke flows to the focused app untouched. When active, vim-style motions move the system cursor; chords with Cmd/Ctrl/Opt and the F1-F20 keys still pass through to the OS so system shortcuts keep working."
            )

            subheading("Toggle")
            row("Cmd-E", "Activate / deactivate")
            row("?", "Toggle this help dialog (only in normal mode)")
            row("Esc", "Exit visual mode or clear any pending operation")

            subheading("Modes")
            tip(
                "**disabled** — neomouse is observing, not intercepting. Everything goes to the focused app.\n**normal** — motion keys, register/mark prefixes, command line (`:`), visual toggle (`v`), find (`f`).\n**find** — labeled grid is up; next 1-2 keys pick the target cell.\n**visual** — anchor is held; motion extends the selection; `y` yanks the rectangle.\n**command** — `:` is showing the wildmenu; type + Tab to filter, Enter to execute.\n**menu** — marks or registers menu is open; ↑/↓ or ←/→ navigates, Enter activates.\n**specialFind** — one-shot dense grid around the cursor (Space+f)."
            )

            subheading("Status indicator")
            tip(
                "The menu-bar icon's color reflects the current mode at a glance. Click the icon to open the dropdown menu (Settings…, Help, Diagnostics, Restart, Quit)."
            )
        }
    }

    // MARK: Motion

    private var motion: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Motion")
            intro(
                "Each display is divided into a grid of cells (default ~20pt squares). Motion keys move the cursor an integer number of cells. Prefix any motion with a count to repeat it N times."
            )

            subheading("Basic motions")
            row("h  j  k  l", "Move 1 cell left / down / up / right")
            row("<N><motion>", "Repeat motion N times — e.g. `10j` = 10 cells down")
            row("0", "Snap to left edge of current row (vim `^`)")
            row("$", "Snap to right edge of current row")
            row("gg", "Top-left corner of screen")
            row("G", "Bottom of screen")
            row("M", "Vertical middle (mid-row)")
            row("gm", "Horizontal middle (mid-column)")

            subheading("Multi-display")
            row("Ctrl-W w", "Jump to next display (round-robin across all connected screens)")
            tip(
                "Coordinates use macOS CG-global space (origin = top-left of the primary display). When the cursor warps to another display the grid recomputes for that display's resolved row/column count."
            )

            subheading("Grid sizing")
            tip(
                "The grid count comes from `[motion]` in settings.toml — `rows_on_screen` and `columns_on_screen` accept either an integer or the literal `\"automatic\"`. Automatic rows derive from screen height / 20pt; automatic columns then square the cells against the resolved row height. Cells stay roughly square on every display."
            )
        }
    }

    // MARK: Find

    private var find: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Find")
            intro(
                "Two-keystroke jump anywhere on the screen. `f` overlays a labeled grid: the first keystroke picks the outer cell (typically 5×5), the second picks the inner cell (typically 3×3). Total addressable points = `(outer × inner)²` — at defaults that's 225 jump targets per display, each reachable in two keys."
            )

            subheading("Entering find")
            row("f", "Enter find mode at default `grid.divisions`")
            row("<N>f", "Enter find with N×N outer grid (capped at `maxGridDivisions`, default 6)")
            row("Esc", "Cancel find, return to normal")

            subheading("Selecting a cell")
            row("<char>", "First press picks the outer cell (label printed in the cell)")
            row("<char>", "Second press picks the inner cell within → cursor warps to that cell's centre")
            tip(
                "Cell labels come from `[grid].find_mode_characters` and `find_mode_inner_characters`. Defaults are `\"abcdefghijklmnopqrstuvwxyz\"` for both. Override either to put your fastest-to-type keys on the homerow."
            )

            subheading("Special find (dense local grid)")
            row("Space f", "Open a small dense grid centred on the cursor")
            row("<char>", "Single press lands on the picked cell (one-shot — no inner step)")
            tip(
                "Special find is meant for sub-pixel-precision dabbing — clicking a small button or anchor near the cursor without typing a full two-key find. Box size + divisions are themed via `[theme.grid].cursor_surrounded_box_size` / `cursor_surrounded_divisions`."
            )
        }
    }

    // MARK: Visual

    private var visual: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Visual")
            intro(
                "Visual mode anchors a start point at the cursor's current position; subsequent motions extend the end point. `y` captures the resulting rectangle as a screenshot to the clipboard (uses ScreenCaptureKit — needs the Screen Recording TCC grant)."
            )

            subheading("Toggle")
            row("v", "Toggle visual mode (anchors at current cursor)")
            row("o / O", "Swap visual anchor and cursor")
            row("Esc", "Exit visual mode (snapshots selection into `previousVisual`)")

            subheading("Capture")
            row("y", "Yank visual rect — screenshot to clipboard, hear the Screen Capture sound")
            row("gv", "Reselect previous visual region (vim's `gv`)")

            subheading("With marks")
            tip(
                "Setting a mark (`m{x}`) while in visual mode stores **both** the start and end CG points. Jumping back with backtick (`` `{x} ``) restores the full visual selection, not just the cursor endpoint. Apostrophe (`'{x}`) only restores the cursor."
            )

            subheading("Permission")
            tip(
                "Yank requires Screen Recording in System Settings → Privacy & Security. NeoMouse prompts for this at launch alongside Accessibility + Input Monitoring; if denied, yanking surfaces a toast pointing back to the right Settings pane. New grants only take effect on next launch."
            )
        }
    }

    // MARK: Marks

    private var marks: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Marks")
            intro(
                "Marks remember cursor positions (and visual selections) per session. They're persisted to SQLite so they survive restarts, scoped to the currently-active session — switching sessions gives you a fresh set."
            )

            subheading("Keybinds")
            row("m{a-z0-9}", "Set mark at current cursor (or visual rect)")
            row("'{a-z0-9}", "Jump to mark — cursor endpoint only")
            row("`{a-z0-9}", "Jump to mark — restore visual selection if one was set")

            subheading("Menu")
            row(":marks (or :m)", "Open the marks menu")
            row("type", "Filter by mark name or screen — incremental search")
            row("↑ / ↓", "Move selection")
            row("Enter", "Jump to selected mark (restores visual state, mirrors backtick)")
            row("Esc", "Close menu")

            subheading("Behaviour notes")
            tip(
                "Marks can be set in any mode that exposes a stable cursor position. Setting a mark in visual mode stores both endpoints; setting in normal mode stores only the cursor. The menu shows screen name, line/column on the current grid, and the raw CG coordinates."
            )
        }
    }

    // MARK: Registers

    private var registers: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Registers")
            intro(
                "Registers are named clipboard slots — yank into one with `\"{r}y`, paste back with `\"{r}p`. NeoMouse also auto-captures fresh pasteboard content into the numeral registers `1`-`9` so you have a recent-clipboard ring without doing anything special."
            )

            subheading("Keybinds")
            row("\"{a-z0-9}", "Select register for the next action (yank / delete / paste)")
            row("\"{r}y", "Yank current clipboard into register r")
            row("\"{r}d", "Cut: delete + capture into register r")
            row("\"{r}p", "Paste from register r")

            subheading("Menu (Pasty-style)")
            row(":registers (or :reg)", "Open the registers menu")
            row("type", "Filter by register name, source app, or content text")
            row("← / →", "Move horizontal selection")
            row("Enter", "Paste selected register into the previously-focused app")
            row("Esc", "Close menu without pasting")

            subheading("Auto-numbered registers")
            tip(
                "Every clipboard change (Cmd-C in any app) is automatically stored in the lowest-numbered empty register `1`-`9`. Once they're full, new content has to be captured manually via `\"{r}y`. This mirrors vim's numbered yank registers — you can always grab the last few clipboard items even if you didn't explicitly stash them."
            )
        }
    }

    // MARK: Commands

    private var commands: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Commands")
            intro(
                "Ex-style commands. Press `:` in normal mode to open the command line, type the command (Tab / Shift-Tab or Ctrl-n / Ctrl-p cycle suggestions in the wildmenu), Enter to execute. Aliases are first-class — typing `:nu` runs the same code as `:numbers`. Available commands are whitelisted via `[commands].available` in settings.toml."
            )

            subheading("Overlay toggles")
            commandRow(":help", ":h", "Toggle this help dialog")
            commandRow(":numbers", ":nu", "Toggle absolute line/column numbers overlay")
            commandRow(":relativenumbers", ":rnu", "Toggle relative numbers (distance from cursor)")
            commandRow(":cursorline", ":cul", "Toggle highlight on the cursor's row")
            commandRow(":cursorcolumn", ":cuc", "Toggle highlight on the cursor's column")

            subheading("Navigation")
            commandRow(":cursor X Y", ":c X Y", "Jump cursor to grid cell (X, Y) — also accepts `:c(X, Y)`")
            commandRow(":marks", ":m", "Open the marks menu")
            commandRow(":registers", ":reg", "Open the registers menu")
            commandRow(":jumps", ":ju", "Open jump history menu — **planned, not yet implemented**")

            subheading("Maintenance")
            commandRow(":delmarks", ":delm", "Delete every mark in the current session — **planned**")
            commandRow(":restart", ":r", "Cleanly relaunch the daemon — TCC grants carry across")
            commandRow(":quit", ":q", "Quit neomouse")

            subheading("Wildmenu (suggestion popup)")
            tip(
                "Typing in command mode fuzzy-matches against `[commands].available`. Tab / Shift-Tab cycle the highlighted suggestion forward / backward; Enter on a highlight executes that command (even if it doesn't exactly match what you typed). Short aliases (`nu`, `h`, `q`, etc.) are hidden from the suggestion list to keep it uncluttered but still work when typed."
            )
        }
    }

    // MARK: Gestures

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Gestures")
            intro(
                "Synthesized trackpad gestures targeted at the current cursor position. Useful for apps that respond to pinch / rotate / scroll but where typing a keystroke wouldn't do the right thing (e.g. zooming a map, rotating an image)."
            )

            subheading("Keybinds")
            row("r / R", "Rotate clockwise / counter-clockwise (`gesture.degrees_to_rotate`)")
            row("+ / -", "Pinch zoom in / out (`gesture.zoom_step_value` per gesture)")
            row("Space d / Space u", "Scroll down / up — count-aware, e.g. `5 Space d`")

            subheading("Tuning")
            tip(
                "`[gesture]` in settings.toml controls all three: `zoom_step_value` (0.01-10, default 0.1), `increments_per_gesture` (default 5 — higher = smoother but slower), `degrees_to_rotate` (default 90). Live-reload picks up changes within ~250ms."
            )
        }
    }

    // MARK: Config

    private var config: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Config")
            intro(
                "NeoMouse is configured via `~/.config/neomouse/settings.toml` (with `~/Library/Application Support/neomouse/settings.toml` as a fallback). The file is validated against `schema/settings.schema.json`; typos in keys or enum values fail loudly with friendly error messages."
            )

            subheading("Hot reload")
            tip(
                "Edits to settings.toml apply within ~250ms — no restart needed. The file watcher debounces rapid saves and is atomic-save aware (re-opens its file descriptor on rename events). Reloads surface a toast (`Reloaded settings.toml` or `Reload failed: <error>`)."
            )

            subheading("Top-level sections")
            commandRow("[grid]", "", "Cell inset, divisions, find-mode character sets")
            commandRow(
                "[motion]", "",
                "rows_on_screen, columns_on_screen (Int or \"automatic\"), is_clamp_cursor_to_current_screen"
            )
            commandRow(
                "[visual]", "",
                "minimum_highlight_width — smallest pixel rect that yank will capture"
            )
            commandRow(
                "[gesture]", "",
                "zoom_step_value, increments_per_gesture, degrees_to_rotate"
            )
            commandRow(
                "[commands]", "",
                "available — whitelist of :commands exposed in command mode"
            )
            commandRow(
                "[configuration]", "",
                "is_disable_key_input, max_session_count, new_session_on_open, mode_on_start, is_show_key_cast"
            )
            commandRow(
                "[theme.*]", "",
                "Per-element colors, fonts, sizes, anchors — see Settings UI for a visual editor"
            )

            subheading("In-app Settings UI")
            tip(
                "Open via the menu-bar icon → Settings… (or `⌘,`). Apple-style preferences window with native controls (ColorPicker, Stepper, Picker, Font picker) for every `[theme.*]` field. Live preview, plus `Save to settings.toml` (`⌘S`) to persist. Reset to Defaults reverts the whole theme."
            )

            subheading("Permissions")
            tip(
                "Three TCC grants required, all prompted at launch:\n**Accessibility** — for AXIsProcessTrustedWithOptions / event tap creation.\n**Input Monitoring** — to receive keyDown events through the CGEventTap.\n**Screen Recording** — for the yank screenshot pipeline (ScreenCaptureKit).\nGrants take effect on next launch. Deny → re-enable from System Settings → Privacy & Security, then relaunch."
            )
        }
    }

    // MARK: - Row helpers

    /// Tab-level header — large title at the very top of each section.
    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(theme.headerColor.swiftUI)
            .padding(.bottom, 2)
    }

    /// Subdivision header within a tab — used to group related rows under
    /// a labelled hunk ("Move", "Capture", "Permission", etc.).
    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(theme.headerFont.swiftUI)
            .foregroundColor(theme.headerColor.swiftUI)
            .padding(.top, 6)
    }

    /// Section preamble paragraph. Wraps the explainer in the description
    /// color + a slightly tighter line spacing so the keybind rows below
    /// pop visually.
    private func intro(_ text: String) -> some View {
        Text(text)
            .foregroundColor(theme.descriptionColor.swiftUI)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    /// Multi-line tip / explainer block. Uses Markdown's bold (`**…**`) so
    /// scenario labels read cleanly without a separate row. Same colour as
    /// `intro` but tighter top spacing — meant to live under a `subheading`.
    private func tip(_ markdown: String) -> some View {
        Text(.init(markdown))
            .foregroundColor(theme.descriptionColor.swiftUI)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Simple "<keybind>  <description>" row — used by every tab except
    /// Commands + Config, which have a canonical + alias column.
    private func row(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(theme.keybindFont.swiftUI)
                .frame(width: 180, alignment: .leading)
                .foregroundColor(.primary)
            Text(description)
                .foregroundColor(theme.descriptionColor.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Commands / Config row with three columns: canonical name, alias,
    /// description. Alias column is narrower so descriptions line up across
    /// the full list. Pass `""` for `alias` when there isn't one (e.g.
    /// section names in the Config tab).
    private func commandRow(_ canonical: String, _ alias: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(canonical)
                .font(theme.keybindFont.swiftUI)
                .frame(width: 170, alignment: .leading)
                .foregroundColor(.primary)
            Text(alias)
                .font(theme.keybindFont.swiftUI)
                .frame(width: 70, alignment: .leading)
                .foregroundColor(theme.descriptionColor.swiftUI)
            Text(description)
                .foregroundColor(theme.descriptionColor.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
