import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

// MARK: - Binding helpers
//
// Each form control needs a `Binding<T>` into `state.theme.<section>.<field>`.
// SwiftUI doesn't let you write `$state.theme.toast.width` directly because
// `theme` is a value-typed struct nested several levels deep — the `$`
// projection only works on direct `@State`/`@Published` storage. The
// `binding(for:)` helper below wraps a `WritableKeyPath<Config.Theme, T>`
// into a `Binding<T>` that reads/writes through `state.theme`. Mutating
// the value writes back into `state.theme = …`, which `@Published`
// republishes → every overlay observing `state` re-renders.

extension NeoMouseState {
    /// Two-way binding into a writable key path on `theme`.
    func binding<Value>(_ keyPath: WritableKeyPath<Config.Theme, Value>) -> Binding<Value> {
        Binding(
            get: { self.theme[keyPath: keyPath] },
            set: { self.theme[keyPath: keyPath] = $0 }
        )
    }
}

extension Binding where Value == ThemeColor {
    /// Bridge a `Binding<ThemeColor>` to SwiftUI's `Binding<Color>` so we
    /// can hand it straight to `ColorPicker(selection:)`. Reads come from
    /// our sRGB doubles; writes pull `red/green/blue/alpha` back out of
    /// the picker's NSColor (converted to sRGB to drop the colorspace
    /// roundtrip surprise).
    func asSwiftUIColor() -> Binding<Color> {
        Binding<Color>(
            get: { wrappedValue.swiftUI },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                wrappedValue = ThemeColor(
                    red: Double(ns.redComponent),
                    green: Double(ns.greenComponent),
                    blue: Double(ns.blueComponent),
                    alpha: Double(ns.alphaComponent)
                )
            }
        )
    }
}

// MARK: - ThemeColor / ThemeFont → TOML serialization

extension ThemeColor {
    /// Round-trip-friendly hex string. Skips the alpha pair when fully opaque
    /// so settings.toml stays terse for the common case.
    fileprivate var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        let a = Int((alpha * 255).rounded())
        if a == 255 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return String(format: "#%02x%02x%02x%02x", r, g, b, a)
    }
}

extension ThemeFont {
    /// Inline-table TOML representation (`{ family = "", size = 13, … }`).
    /// Always emits every field so the serialized output matches what
    /// `just init` ships — easy to diff, easy to hand-edit.
    fileprivate var tomlInline: String {
        "{ family = \"\(family)\", size = \(formatDouble(size))"
            + ", weight = \"\(weight.rawValue)\", design = \"\(design.rawValue)\" }"
    }
}

private func formatDouble(_ d: Double) -> String {
    // Drop trailing zeros for whole numbers so `100.0` → `100`. The decoder
    // accepts both via `tomlDouble`.
    if d.rounded() == d && abs(d) < 1e9 {
        return String(Int(d))
    }
    return String(d)
}

// MARK: - TOML writer for the [theme.*] block

/// Rewrites `~/.config/neomouse/settings.toml` so that the `[theme.*]`
/// sections match the live `Config.Theme`. Everything else in the file is
/// preserved byte-for-byte — we just truncate at the first `[theme.` header
/// line and re-emit the theme blocks from scratch.
@MainActor
enum ThemeWriter {
    /// Returns nil on success, or a short error message for surfacing in a
    /// toast. Writes are atomic (write to temp, rename over).
    static func persist(_ theme: Config.Theme) -> String? {
        guard let url = Config.resolvedURL else {
            return "no settings.toml found at any resolved path"
        }
        let existing: String
        do {
            existing = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "read failed: \(error.localizedDescription)"
        }
        let preserved = stripExistingThemeBlock(existing)
        let serialized = serializeTheme(theme)
        let combined = preserved + (preserved.hasSuffix("\n\n") ? "" : "\n") + serialized
        do {
            try combined.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "write failed: \(error.localizedDescription)"
        }
        return nil
    }

    /// Truncate at the first `[theme.` header line, preserving everything
    /// above it (including the file's leading comments and the
    /// non-theme `[grid]` / `[motion]` / `[visual]` / etc. sections).
    private static func stripExistingThemeBlock(_ text: String) -> String {
        guard let range = text.range(of: #"\n\[theme(\.|\])"#, options: .regularExpression) else {
            // No existing [theme.*] block → append after a blank line.
            return text.hasSuffix("\n") ? text : (text + "\n")
        }
        // Keep up to (but not including) the leading newline of the match.
        // The match starts with "\n", so we slice from `range.lowerBound`.
        return String(text[..<range.lowerBound]) + "\n"
    }

    private static func serializeTheme(_ t: Config.Theme) -> String {
        var lines: [String] = []
        lines.append("# ---------------------------------------------------------------------------")
        lines.append("# [theme.*] — per-element visual overrides (regenerated by SettingsWindow).")
        lines.append("# Edit by hand or via Settings… on the menu bar; both round-trip cleanly.")
        lines.append("# ---------------------------------------------------------------------------")
        lines.append("")
        lines.append(contentsOf: serializeGrid(t.grid))
        lines.append("")
        lines.append(contentsOf: serializeNumbersOverlay(t.numbersOverlay))
        lines.append("")
        lines.append(contentsOf: serializeCommandLine(t.commandLine))
        lines.append("")
        lines.append(contentsOf: serializeMarksMenu(t.marksMenu))
        lines.append("")
        lines.append(contentsOf: serializeRegisterMenu(t.registerMenu))
        lines.append("")
        lines.append(contentsOf: serializeHelpDialog(t.helpDialog))
        lines.append("")
        lines.append(contentsOf: serializeVisualHighlight(t.visualHighlight))
        lines.append("")
        lines.append(contentsOf: serializeToast(t.toast))
        lines.append("")
        lines.append(contentsOf: serializeKeyCast(t.keyCast))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func serializeGrid(_ g: GridTheme) -> [String] {
        [
            "[theme.grid]",
            "background              = \"\(g.background.hex)\"",
            "outer_line_color        = \"\(g.outerLineColor.hex)\"",
            "outer_label_color       = \"\(g.outerLabelColor.hex)\"",
            "outer_label_font        = \(g.outerLabelFont.tomlInline)",
            "inner_line_color        = \"\(g.innerLineColor.hex)\"",
            "inner_faint_line_color  = \"\(g.innerFaintLineColor.hex)\"",
            "inner_label_color       = \"\(g.innerLabelColor.hex)\"",
            "inner_label_font        = \(g.innerLabelFont.tomlInline)",
            "cursor_surrounded_box_size    = \(formatDouble(g.cursorSurroundedBoxSize))",
            "cursor_surrounded_divisions   = \(g.cursorSurroundedDivisions)",
            "cursor_surrounded_label_font  = \(g.cursorSurroundedLabelFont.tomlInline)",
        ]
    }

    private static func serializeNumbersOverlay(_ n: NumbersOverlayTheme) -> [String] {
        [
            "[theme.numbers_overlay]",
            "direction               = \"\(n.direction.rawValue)\"",
            "gutter_background       = \"\(n.gutterBackground.hex)\"",
            "cursor_line_highlight   = \"\(n.cursorLineHighlight.hex)\"",
            "cursor_column_highlight = \"\(n.cursorColumnHighlight.hex)\"",
            "cursor_text_color       = \"\(n.cursorTextColor.hex)\"",
            "text_color              = \"\(n.textColor.hex)\"",
            "font                    = \(n.font.tomlInline)",
            "gutter_width            = \(formatDouble(n.gutterWidth))",
            "column_strip_height     = \(formatDouble(n.columnStripHeight))",
        ]
    }

    private static func serializeCommandLine(_ c: CommandLineTheme) -> [String] {
        [
            "[theme.command_line]",
            "anchor                 = \"\(c.anchor.rawValue)\"",
            "x_offset               = \(formatDouble(c.xOffset))",
            "y_offset               = \(formatDouble(c.yOffset))",
            "width                  = \(formatDouble(c.width))",
            "height                 = \(formatDouble(c.height))",
            "corner_radius          = \(formatDouble(c.cornerRadius))",
            "text_font              = \(c.textFont.tomlInline)",
            "text_color             = \"\(c.textColor.hex)\"",
            "prefix_color           = \"\(c.prefixColor.hex)\"",
            "suggestion_font        = \(c.suggestionFont.tomlInline)",
            "suggestion_text_color  = \"\(c.suggestionTextColor.hex)\"",
            "suggestion_highlight   = \"\(c.suggestionHighlight.hex)\"",
            "material               = \"\(c.material.rawValue)\"",
        ]
    }

    private static func serializeMarksMenu(_ m: MarksMenuTheme) -> [String] {
        [
            "[theme.marks_menu]",
            "anchor                   = \"\(m.anchor.rawValue)\"",
            "width                    = \(formatDouble(m.width))",
            "height                   = \(formatDouble(m.height))",
            "corner_radius            = \(formatDouble(m.cornerRadius))",
            "material                 = \"\(m.material.rawValue)\"",
            "header_font              = \(m.headerFont.tomlInline)",
            "mark_label_font          = \(m.markLabelFont.tomlInline)",
            "cell_font                = \(m.cellFont.tomlInline)",
            "empty_message_font       = \(m.emptyMessageFont.tomlInline)",
            "selected_row_background  = \"\(m.selectedRowBackground.hex)\"",
            "row_padding_x            = \(formatDouble(m.rowPaddingX))",
            "row_padding_y            = \(formatDouble(m.rowPaddingY))",
        ]
    }

    private static func serializeRegisterMenu(_ r: RegisterMenuTheme) -> [String] {
        [
            "[theme.register_menu]",
            "anchor                     = \"\(r.anchor.rawValue)\"",
            "width                      = \(formatDouble(r.width))",
            "height                     = \(formatDouble(r.height))",
            "corner_radius              = \(formatDouble(r.cornerRadius))",
            "material                   = \"\(r.material.rawValue)\"",
            "card_width                 = \(formatDouble(r.cardWidth))",
            "card_height                = \(formatDouble(r.cardHeight))",
            "card_padding_x             = \(formatDouble(r.cardPaddingX))",
            "card_padding_y             = \(formatDouble(r.cardPaddingY))",
            "view_padding               = \(formatDouble(r.viewPadding))",
            "search_font                = \(r.searchFont.tomlInline)",
            "app_name_font              = \(r.appNameFont.tomlInline)",
            "register_label_font        = \(r.registerLabelFont.tomlInline)",
            "card_text_font             = \(r.cardTextFont.tomlInline)",
            "badge_font                 = \(r.badgeFont.tomlInline)",
            "register_badge_background  = \"\(r.registerBadgeBackground.hex)\"",
            "selected_card_border       = \"\(r.selectedCardBorder.hex)\"",
            "unselected_card_border     = \"\(r.unselectedCardBorder.hex)\"",
            "card_shadow_selected       = \"\(r.cardShadowSelected.hex)\"",
            "card_shadow_unselected     = \"\(r.cardShadowUnselected.hex)\"",
            "content_background         = \"\(r.contentBackground.hex)\"",
        ]
    }

    private static func serializeHelpDialog(_ h: HelpDialogTheme) -> [String] {
        [
            "[theme.help_dialog]",
            "anchor             = \"\(h.anchor.rawValue)\"",
            "width              = \(formatDouble(h.width))",
            "height             = \(formatDouble(h.height))",
            "padding            = \(formatDouble(h.padding))",
            "header_color       = \"\(h.headerColor.hex)\"",
            "header_font        = \(h.headerFont.tomlInline)",
            "keybind_font       = \(h.keybindFont.tomlInline)",
            "description_color  = \"\(h.descriptionColor.hex)\"",
        ]
    }

    private static func serializeVisualHighlight(_ v: VisualHighlightTheme) -> [String] {
        [
            "[theme.visual_highlight]",
            "fill = \"\(v.fill.hex)\"",
        ]
    }

    private static func serializeToast(_ t: ToastTheme) -> [String] {
        [
            "[theme.toast]",
            "anchor          = \"\(t.anchor.rawValue)\"",
            "x_offset        = \(formatDouble(t.xOffset))",
            "y_offset        = \(formatDouble(t.yOffset))",
            "width           = \(formatDouble(t.width))",
            "height          = \(formatDouble(t.height))",
            "corner_radius   = \(formatDouble(t.cornerRadius))",
            "padding_x       = \(formatDouble(t.paddingX))",
            "padding_y       = \(formatDouble(t.paddingY))",
            "outer_padding   = \(formatDouble(t.outerPadding))",
            "background      = \"\(t.background.hex)\"",
            "text_color      = \"\(t.textColor.hex)\"",
            "text_font       = \(t.textFont.tomlInline)",
        ]
    }

    private static func serializeKeyCast(_ k: KeyCastTheme) -> [String] {
        [
            "[theme.key_cast]",
            "anchor         = \"\(k.anchor.rawValue)\"",
            "x_offset       = \(formatDouble(k.xOffset))",
            "y_offset       = \(formatDouble(k.yOffset))",
            "width          = \(formatDouble(k.width))",
            "height         = \(formatDouble(k.height))",
            "corner_radius  = \(formatDouble(k.cornerRadius))",
            "padding_x      = \(formatDouble(k.paddingX))",
            "padding_y      = \(formatDouble(k.paddingY))",
            "background     = \"\(k.background.hex)\"",
            "text_color     = \"\(k.textColor.hex)\"",
            "border_color   = \"\(k.borderColor.hex)\"",
            "shadow_color   = \"\(k.shadowColor.hex)\"",
            "text_font      = \(k.textFont.tomlInline)",
        ]
    }
}

// MARK: - SettingsView

/// Sections shown in the sidebar — order matches what's most-asked.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case toast = "Toast"
    case keyCast = "Key Cast"
    case visualHighlight = "Visual Highlight"
    case numbersOverlay = "Numbers Overlay"
    case grid = "Grid"
    case commandLine = "Command Line"
    case helpDialog = "Help Dialog"
    case marksMenu = "Marks Menu"
    case registerMenu = "Register Menu"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .toast: return "bell.fill"
        case .keyCast: return "keyboard"
        case .visualHighlight: return "rectangle.dashed"
        case .numbersOverlay: return "list.number"
        case .grid: return "square.grid.3x3"
        case .commandLine: return "terminal.fill"
        case .helpDialog: return "questionmark.circle"
        case .marksMenu: return "bookmark.fill"
        case .registerMenu: return "tray.full.fill"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: NeoMouseState
    @State private var selection: SettingsSection = .toast
    @State private var saveResult: String?

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                Form {
                    switch selection {
                    case .toast: ToastForm(state: state)
                    case .keyCast: KeyCastForm(state: state)
                    case .visualHighlight: VisualHighlightForm(state: state)
                    case .numbersOverlay: NumbersOverlayForm(state: state)
                    case .grid: GridForm(state: state)
                    case .commandLine: CommandLineForm(state: state)
                    case .helpDialog: HelpDialogForm(state: state)
                    case .marksMenu: MarksMenuForm(state: state)
                    case .registerMenu: RegisterMenuForm(state: state)
                    }
                }
                .formStyle(.grouped)
                actionBar
            }
        }
        .navigationTitle("NeoMouse Settings")
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let saveResult {
                Text(saveResult)
                    .font(.caption)
                    .foregroundStyle(saveResult.hasPrefix("Saved") ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            Spacer()
            Button("Reset to Defaults") {
                state.theme = Config.Theme()
                saveResult = nil
            }
            Button("Save to settings.toml") {
                if let error = ThemeWriter.persist(state.theme) {
                    saveResult = "Save failed: \(error)"
                } else {
                    saveResult = "Saved to ~/.config/neomouse/settings.toml"
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.bar)
    }
}

// MARK: - Reusable controls

/// SwiftUI fix-up: SwiftUI `Picker` requires `Hashable` selection values. Our
/// theme enums conform to `Hashable` automatically via their `String` raw
/// type. This is just a thin wrapper that wires a `ForEach(allCases)` into
/// a labeled `Picker`.
private struct EnumPicker<E: CaseIterable & Hashable & RawRepresentable>: View
where E.RawValue == String, E.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: E

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(E.allCases), id: \.self) { value in
                Text(value.rawValue).tag(value)
            }
        }
    }
}

/// Font editor — family / size / weight / design on one row. Family is a
/// free-text field (empty = system font); size uses a stepper; weight and
/// design are pickers backed by `ThemeFont.Weight.allCases` etc.
private struct FontEditor: View {
    let title: String
    @Binding var font: ThemeFont

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                TextField(
                    "family (empty = system)",
                    text: Binding(get: { font.family }, set: { font.family = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                Stepper(
                    value: Binding(get: { font.size }, set: { font.size = $0 }),
                    in: 6...96, step: 1
                ) {
                    Text("\(Int(font.size)) pt")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .leading)
                }
                Picker(
                    "weight",
                    selection: Binding(
                        get: { font.weight }, set: { font.weight = $0 })
                ) {
                    ForEach(Array(ThemeFont.Weight.allCases), id: \.self) { w in
                        Text(w.rawValue).tag(w)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)
                Picker(
                    "design",
                    selection: Binding(
                        get: { font.design }, set: { font.design = $0 })
                ) {
                    ForEach(Array(ThemeFont.Design.allCases), id: \.self) { d in
                        Text(d.rawValue).tag(d)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
            }
        }
    }
}

// MARK: - Per-section forms
//
// One Form per theme sub-section. Layout-wise: anchor / offset / size on
// top, colors next, fonts at the bottom. Color pickers use SwiftUI's
// `ColorPicker(supportsOpacity: true)` so users can drag the alpha slider
// in the system color panel — which is what makes the muted overlays work.

private struct ToastForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Position & size") {
            EnumPicker(title: "Anchor", selection: state.binding(\.toast.anchor))
            HStack {
                LabeledStepper("X offset", value: state.binding(\.toast.xOffset))
                LabeledStepper("Y offset", value: state.binding(\.toast.yOffset))
            }
            HStack {
                LabeledStepper("Width", value: state.binding(\.toast.width), range: 100...1200)
                LabeledStepper("Height", value: state.binding(\.toast.height), range: 24...400)
            }
            HStack {
                LabeledStepper("Corner radius", value: state.binding(\.toast.cornerRadius), range: 0...64)
                LabeledStepper("Outer padding", value: state.binding(\.toast.outerPadding), range: 0...64)
            }
            HStack {
                LabeledStepper("Padding X", value: state.binding(\.toast.paddingX), range: 0...64)
                LabeledStepper("Padding Y", value: state.binding(\.toast.paddingY), range: 0...64)
            }
        }
        Section("Colors") {
            ColorPicker(
                "Background", selection: state.binding(\.toast.background).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker("Text", selection: state.binding(\.toast.textColor).asSwiftUIColor(), supportsOpacity: true)
        }
        Section("Font") {
            FontEditor(title: "Text font", font: state.binding(\.toast.textFont))
        }
    }
}

private struct KeyCastForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Position & size") {
            EnumPicker(title: "Anchor", selection: state.binding(\.keyCast.anchor))
            HStack {
                LabeledStepper("X offset", value: state.binding(\.keyCast.xOffset))
                LabeledStepper("Y offset", value: state.binding(\.keyCast.yOffset))
            }
            HStack {
                LabeledStepper("Width", value: state.binding(\.keyCast.width), range: 80...600)
                LabeledStepper("Height", value: state.binding(\.keyCast.height), range: 24...200)
            }
            HStack {
                LabeledStepper("Corner radius", value: state.binding(\.keyCast.cornerRadius), range: 0...64)
            }
            HStack {
                LabeledStepper("Padding X", value: state.binding(\.keyCast.paddingX), range: 0...64)
                LabeledStepper("Padding Y", value: state.binding(\.keyCast.paddingY), range: 0...64)
            }
        }
        Section("Colors") {
            ColorPicker(
                "Background", selection: state.binding(\.keyCast.background).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker("Text", selection: state.binding(\.keyCast.textColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Border", selection: state.binding(\.keyCast.borderColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Shadow", selection: state.binding(\.keyCast.shadowColor).asSwiftUIColor(), supportsOpacity: true)
        }
        Section("Font") {
            FontEditor(title: "Text font", font: state.binding(\.keyCast.textFont))
        }
    }
}

private struct VisualHighlightForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Selection rectangle") {
            ColorPicker(
                "Fill", selection: state.binding(\.visualHighlight.fill).asSwiftUIColor(), supportsOpacity: true)
        }
    }
}

private struct NumbersOverlayForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Gutter") {
            EnumPicker(title: "Direction", selection: state.binding(\.numbersOverlay.direction))
            HStack {
                LabeledStepper("Gutter width", value: state.binding(\.numbersOverlay.gutterWidth), range: 10...80)
                LabeledStepper(
                    "Column strip height", value: state.binding(\.numbersOverlay.columnStripHeight), range: 10...80)
            }
        }
        Section("Colors") {
            ColorPicker(
                "Gutter background", selection: state.binding(\.numbersOverlay.gutterBackground).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Cursor line tint", selection: state.binding(\.numbersOverlay.cursorLineHighlight).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Cursor column tint", selection: state.binding(\.numbersOverlay.cursorColumnHighlight).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Cursor text", selection: state.binding(\.numbersOverlay.cursorTextColor).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Other text", selection: state.binding(\.numbersOverlay.textColor).asSwiftUIColor(),
                supportsOpacity: true)
        }
        Section("Font") {
            FontEditor(title: "Number font", font: state.binding(\.numbersOverlay.font))
        }
    }
}

private struct GridForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Colors") {
            ColorPicker(
                "Background", selection: state.binding(\.grid.background).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Outer line", selection: state.binding(\.grid.outerLineColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Outer label", selection: state.binding(\.grid.outerLabelColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Inner line", selection: state.binding(\.grid.innerLineColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Inner faint line", selection: state.binding(\.grid.innerFaintLineColor).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Inner label", selection: state.binding(\.grid.innerLabelColor).asSwiftUIColor(), supportsOpacity: true)
        }
        Section("Fonts") {
            FontEditor(title: "Outer label font", font: state.binding(\.grid.outerLabelFont))
            FontEditor(title: "Inner label font", font: state.binding(\.grid.innerLabelFont))
            FontEditor(title: "Cursor-surrounded label font", font: state.binding(\.grid.cursorSurroundedLabelFont))
        }
        Section("Cursor-surrounded grid (special-find)") {
            HStack {
                LabeledStepper("Box size", value: state.binding(\.grid.cursorSurroundedBoxSize), range: 100...600)
                LabeledIntStepper("Divisions", value: state.binding(\.grid.cursorSurroundedDivisions), range: 2...12)
            }
        }
    }
}

private struct CommandLineForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Position & size") {
            EnumPicker(title: "Anchor", selection: state.binding(\.commandLine.anchor))
            HStack {
                LabeledStepper("X offset", value: state.binding(\.commandLine.xOffset))
                LabeledStepper("Y offset", value: state.binding(\.commandLine.yOffset))
            }
            HStack {
                LabeledStepper("Width", value: state.binding(\.commandLine.width), range: 200...1400)
                LabeledStepper("Height", value: state.binding(\.commandLine.height), range: 24...200)
            }
            LabeledStepper("Corner radius", value: state.binding(\.commandLine.cornerRadius), range: 0...64)
            EnumPicker(title: "Material", selection: state.binding(\.commandLine.material))
        }
        Section("Colors") {
            ColorPicker(
                "Text", selection: state.binding(\.commandLine.textColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Prefix (\":\")", selection: state.binding(\.commandLine.prefixColor).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Suggestion text", selection: state.binding(\.commandLine.suggestionTextColor).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Suggestion highlight", selection: state.binding(\.commandLine.suggestionHighlight).asSwiftUIColor(),
                supportsOpacity: true)
        }
        Section("Fonts") {
            FontEditor(title: "Text font", font: state.binding(\.commandLine.textFont))
            FontEditor(title: "Suggestion font", font: state.binding(\.commandLine.suggestionFont))
        }
    }
}

private struct HelpDialogForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Window") {
            EnumPicker(title: "Anchor", selection: state.binding(\.helpDialog.anchor))
            HStack {
                LabeledStepper("Width", value: state.binding(\.helpDialog.width), range: 400...1600)
                LabeledStepper("Height", value: state.binding(\.helpDialog.height), range: 400...1600)
            }
            LabeledStepper("Padding", value: state.binding(\.helpDialog.padding), range: 0...64)
        }
        Section("Colors") {
            ColorPicker(
                "Header", selection: state.binding(\.helpDialog.headerColor).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Description", selection: state.binding(\.helpDialog.descriptionColor).asSwiftUIColor(),
                supportsOpacity: true)
        }
        Section("Fonts") {
            FontEditor(title: "Header font", font: state.binding(\.helpDialog.headerFont))
            FontEditor(title: "Keybind font", font: state.binding(\.helpDialog.keybindFont))
        }
    }
}

private struct MarksMenuForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Panel") {
            EnumPicker(title: "Anchor", selection: state.binding(\.marksMenu.anchor))
            HStack {
                LabeledStepper("Width", value: state.binding(\.marksMenu.width), range: 200...1200)
                LabeledStepper("Height", value: state.binding(\.marksMenu.height), range: 200...1200)
            }
            HStack {
                LabeledStepper("Corner radius", value: state.binding(\.marksMenu.cornerRadius), range: 0...64)
                EnumPicker(title: "Material", selection: state.binding(\.marksMenu.material))
            }
            HStack {
                LabeledStepper("Row padding X", value: state.binding(\.marksMenu.rowPaddingX), range: 0...64)
                LabeledStepper("Row padding Y", value: state.binding(\.marksMenu.rowPaddingY), range: 0...64)
            }
        }
        Section("Colors") {
            ColorPicker(
                "Selected row", selection: state.binding(\.marksMenu.selectedRowBackground).asSwiftUIColor(),
                supportsOpacity: true)
        }
        Section("Fonts") {
            FontEditor(title: "Header", font: state.binding(\.marksMenu.headerFont))
            FontEditor(title: "Mark label", font: state.binding(\.marksMenu.markLabelFont))
            FontEditor(title: "Cell", font: state.binding(\.marksMenu.cellFont))
            FontEditor(title: "Empty message", font: state.binding(\.marksMenu.emptyMessageFont))
        }
    }
}

private struct RegisterMenuForm: View {
    @ObservedObject var state: NeoMouseState
    var body: some View {
        Section("Panel") {
            EnumPicker(title: "Anchor", selection: state.binding(\.registerMenu.anchor))
            HStack {
                LabeledStepper("Width", value: state.binding(\.registerMenu.width), range: 400...2000)
                LabeledStepper("Height", value: state.binding(\.registerMenu.height), range: 200...1400)
            }
            HStack {
                LabeledStepper("Corner radius", value: state.binding(\.registerMenu.cornerRadius), range: 0...64)
                EnumPicker(title: "Material", selection: state.binding(\.registerMenu.material))
            }
            LabeledStepper("View padding", value: state.binding(\.registerMenu.viewPadding), range: 0...64)
        }
        Section("Cards") {
            HStack {
                LabeledStepper("Card width", value: state.binding(\.registerMenu.cardWidth), range: 100...500)
                LabeledStepper("Card height", value: state.binding(\.registerMenu.cardHeight), range: 100...600)
            }
            HStack {
                LabeledStepper("Card padding X", value: state.binding(\.registerMenu.cardPaddingX), range: 0...64)
                LabeledStepper("Card padding Y", value: state.binding(\.registerMenu.cardPaddingY), range: 0...64)
            }
        }
        Section("Colors") {
            ColorPicker(
                "Register badge", selection: state.binding(\.registerMenu.registerBadgeBackground).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Selected card border", selection: state.binding(\.registerMenu.selectedCardBorder).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Unselected card border",
                selection: state.binding(\.registerMenu.unselectedCardBorder).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Selected card shadow", selection: state.binding(\.registerMenu.cardShadowSelected).asSwiftUIColor(),
                supportsOpacity: true)
            ColorPicker(
                "Unselected card shadow",
                selection: state.binding(\.registerMenu.cardShadowUnselected).asSwiftUIColor(), supportsOpacity: true)
            ColorPicker(
                "Content background", selection: state.binding(\.registerMenu.contentBackground).asSwiftUIColor(),
                supportsOpacity: true)
        }
        Section("Fonts") {
            FontEditor(title: "Search", font: state.binding(\.registerMenu.searchFont))
            FontEditor(title: "App name", font: state.binding(\.registerMenu.appNameFont))
            FontEditor(title: "Register label", font: state.binding(\.registerMenu.registerLabelFont))
            FontEditor(title: "Card text", font: state.binding(\.registerMenu.cardTextFont))
            FontEditor(title: "Badge", font: state.binding(\.registerMenu.badgeFont))
        }
    }
}

// MARK: - Stepper helpers

/// Two-column stepper-with-label for `Double` fields. Range defaults to a
/// reasonable upper bound for most position/size fields; pass an explicit
/// `range:` for fields with different domains.
private struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...2000
    var step: Double = 1

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...2000, step: Double = 1) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        Stepper(
            value: $value,
            in: range,
            step: step
        ) {
            HStack(spacing: 4) {
                Text(title)
                Spacer()
                Text("\(Int(value))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Same as LabeledStepper, but for `Int` fields (grid divisions etc).
private struct LabeledIntStepper: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...100

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int> = 1...100) {
        self.title = title
        self._value = value
        self.range = range
    }

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack(spacing: 4) {
                Text(title)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
