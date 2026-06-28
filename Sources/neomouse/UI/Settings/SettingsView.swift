import AppKit
import SwiftUI

import neomouseConfig
import neomouseUtils

// MARK: - Binding helpers

/// Local `@unchecked Sendable` wrapper around a `WritableKeyPath`. Used by
/// the `binding(_:)` extension below; see comment there for why.
private struct SendableKeyPath<Root, Value>: @unchecked Sendable {
    let keyPath: WritableKeyPath<Root, Value>
}

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
    ///
    /// `Value: Sendable` is required because `Binding.init(get:set:)` takes
    /// `@Sendable` closures under Swift 6 strict concurrency, and a
    /// `WritableKeyPath<Root, Value>` is only `Sendable` when both `Root`
    /// (already-Sendable `Config.Theme`) AND `Value` are. All theme leaf
    /// types — Double / Int / String / Bool / ThemeColor / ThemeFont / the
    /// theme enums — already conform, so call sites compile unchanged.
    func binding<Value: Sendable>(
        _ keyPath: WritableKeyPath<Config.Theme, Value>
    ) -> Binding<Value> {
        // `WritableKeyPath` is a class and isn't `Sendable` (even when both
        // `Root` and `Value` are), so capturing it in `Binding`'s `@Sendable`
        // closures triggers a strict-concurrency warning. Wrapping in a
        // local `@unchecked Sendable` struct silences the warning without
        // any runtime cost — the key path is immutable, the only mutation
        // goes through `self.theme`, and `theme` access is main-actor in
        // practice (SwiftUI updates) or main-actor-isolated (CGEventTap
        // callback path).
        let wrapped = SendableKeyPath(keyPath: keyPath)
        return Binding(
            get: { self.theme[keyPath: wrapped.keyPath] },
            set: { self.theme[keyPath: wrapped.keyPath] = $0 }
        )
    }

    /// Two-way binding for the physical key bound to a canonical Vim char.
    /// Get returns the resolved physical key (identity when unmapped); set
    /// keeps only the last typed character and clears back to identity when it
    /// equals the canonical char (so an unedited row stores no override).
    func keymapBinding(forCanonical canonical: String) -> Binding<String> {
        Binding(
            get: { self.keymaps[canonical] },
            set: { self.keymaps.setBinding(canonical: canonical, physical: String($0.suffix(1))) }
        )
    }

    /// Two-way binding for the ⌘-activation chord key (kept to a single char).
    func toggleActivationBinding() -> Binding<String> {
        Binding(
            get: { self.keymaps.toggleActivation },
            set: { new in
                let last = String(new.suffix(1))
                if !last.isEmpty { self.keymaps.toggleActivation = last }
            }
        )
    }

    /// Broadcast a single `family / weight / design` triple to every
    /// `ThemeFont`-typed leaf on `theme`, preserving each leaf's own
    /// `size`. Used by the Settings window's "Shared Font" section so a
    /// single picker controls the typeface across every overlay without
    /// trampling per-element font sizes (grid labels are 60pt, toast text
    /// is 13pt — they need different sizes even when they share a family).
    @MainActor
    func setSharedFontFace(family: String, weight: ThemeFont.Weight, design: ThemeFont.Design) {
        // Tiny helper to rewrite a font field while keeping its size.
        func reface(_ font: ThemeFont) -> ThemeFont {
            ThemeFont(size: font.size, weight: weight, design: design, family: family)
        }
        theme.grid.outerLabelFont = reface(theme.grid.outerLabelFont)
        theme.grid.innerLabelFont = reface(theme.grid.innerLabelFont)
        theme.grid.cursorSurroundedLabelFont = reface(theme.grid.cursorSurroundedLabelFont)
        theme.numbersOverlay.font = reface(theme.numbersOverlay.font)
        theme.commandLine.textFont = reface(theme.commandLine.textFont)
        theme.commandLine.suggestionFont = reface(theme.commandLine.suggestionFont)
        theme.marksMenu.headerFont = reface(theme.marksMenu.headerFont)
        theme.marksMenu.markLabelFont = reface(theme.marksMenu.markLabelFont)
        theme.marksMenu.cellFont = reface(theme.marksMenu.cellFont)
        theme.marksMenu.emptyMessageFont = reface(theme.marksMenu.emptyMessageFont)
        theme.registerMenu.searchFont = reface(theme.registerMenu.searchFont)
        theme.registerMenu.appNameFont = reface(theme.registerMenu.appNameFont)
        theme.registerMenu.registerLabelFont = reface(theme.registerMenu.registerLabelFont)
        theme.registerMenu.cardTextFont = reface(theme.registerMenu.cardTextFont)
        theme.registerMenu.badgeFont = reface(theme.registerMenu.badgeFont)
        theme.helpDialog.headerFont = reface(theme.helpDialog.headerFont)
        theme.helpDialog.keybindFont = reface(theme.helpDialog.keybindFont)
        theme.toast.textFont = reface(theme.toast.textFont)
        theme.keyCast.textFont = reface(theme.keyCast.textFont)
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
        let combined = replacingThemeBlock(in: existing, with: serializeTheme(theme))
        do {
            try combined.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "write failed: \(error.localizedDescription)"
        }
        return nil
    }

    /// Replace the contiguous run of `[theme.*]` sections **in place** with the
    /// regenerated block, preserving everything before AND after it. The theme
    /// run spans from the first `[theme.*]` header to the next non-theme `[`
    /// header (or EOF). Because content after the theme block survives, users
    /// can place other sections (`[keymaps]`, etc.) after `[theme.*]` and order
    /// the file's sections however they like. Appends after a blank line when
    /// there's no theme block yet. (Theme sub-sections are assumed contiguous,
    /// as shipped and as `serializeTheme` emits them.)
    private static func replacingThemeBlock(in text: String, with block: String) -> String {
        guard
            let firstTheme = text.range(
                of: #"(?m)^\[theme(\.|\])"#, options: .regularExpression)
        else {
            let prefix = text.hasSuffix("\n") ? text : (text + "\n")
            return prefix + "\n" + block
        }
        // Walk forward from the first theme header to the first header line that
        // isn't a `[theme…]` — that's where the theme run ends.
        var spanEnd = text.endIndex
        var cursor = firstTheme.upperBound
        while let header = text.range(
            of: #"(?m)^\["#, options: .regularExpression, range: cursor..<text.endIndex)
        {
            let headerLine = text[header.lowerBound...].prefix { $0 != "\n" }
            if !headerLine.hasPrefix("[theme") {
                spanEnd = header.lowerBound
                break
            }
            cursor = header.upperBound
        }
        let before = droppingGeneratedHeader(String(text[..<firstTheme.lowerBound]))
        let after = String(text[spanEnd...])
        let body = block.hasSuffix("\n") ? String(block.dropLast()) : block
        let head = before.hasSuffix("\n") ? before : (before + "\n")
        return after.isEmpty ? (head + body + "\n") : (head + body + "\n\n" + after)
    }

    /// Drop any previously-generated `# [theme.*] … (regenerated by
    /// SettingsWindow)` header block(s) from the tail of the preserved prefix.
    /// `serializeTheme` re-emits this header every save; without this strip it
    /// would pile up one copy per save (the prefix preserves everything above
    /// `[theme.grid]`, including the last save's header). Matching on the unique
    /// "(regenerated by SettingsWindow)" marker line, everything from the first
    /// such block down to the theme data is generated, so truncating there
    /// removes all accumulated copies at once. The shipped hand-written legend
    /// ("# [theme.*] — per-element visual overrides" with no "(regenerated…)")
    /// doesn't match and is preserved.
    private static func droppingGeneratedHeader(_ before: String) -> String {
        guard
            let marker = before.range(
                of:
                    #"(?m)^# -{3,}\n# \[theme\.\*\] — per-element visual overrides \(regenerated by SettingsWindow\)\."#,
                options: .regularExpression)
        else { return before }
        return String(before[..<marker.lowerBound])
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
            "column_strip_direction  = \"\(n.columnStripDirection.rawValue)\"",
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

// MARK: - TOML writer for [configuration] knobs

/// Persists non-theme `[configuration]` toggles back into settings.toml.
/// `ThemeWriter` only rewrites the `[theme.*]` block (everything above the
/// first `[theme.` header is preserved byte-for-byte), so a behavior knob like
/// `is_auto_snap` — which lives in `[configuration]`, *above* the theme block
/// — needs its own line-level rewrite. Runs *before* `ThemeWriter.persist`
/// at the Save call site so the theme writer re-reads the already-updated file
/// and preserves the change.
@MainActor
enum ConfigWriter {
    /// Persist `[configuration].is_auto_snap`. Returns nil on success or a
    /// short error string for surfacing in a toast / the Settings action bar.
    static func persistConfiguration(_ value: Bool, _ keyInSnakeCase: String) -> String? {
        guard let url = Config.resolvedURL else {
            return "no settings.toml found at any resolved path"
        }
        let existing: String
        do {
            existing = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "read failed: \(error.localizedDescription)"
        }
        let updated = setBool(keyInSnakeCase, value: value, section: "configuration", in: existing)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "write failed for \(keyInSnakeCase): \(error.localizedDescription)"
        }
        return nil
    }

    /// Rewrite (or insert) a `key = true/false` line. Three cases, in order:
    ///   1. Key already present → replace just its value, in place.
    ///   2. `[section]` header present but key absent → insert the line right
    ///      after the header.
    ///   3. Neither → splice a fresh `[section]` block in before the first
    ///      `[theme.*]` header (or append at EOF if there's no theme block).
    private static func setBool(
        _ key: String, value: Bool, section: String, in text: String
    ) -> String {
        let literal = value ? "true" : "false"

        // 1. Replace an existing `key = true|false` value in place.
        let keyPattern = "(?m)^(\\s*\(key)\\s*=\\s*)(?:true|false)\\b"
        if let range = text.range(of: keyPattern, options: .regularExpression) {
            return text.replacingOccurrences(
                of: keyPattern, with: "$1\(literal)",
                options: .regularExpression, range: range
            )
        }

        // 2. Insert under an existing section header.
        let sectionPattern = "(?m)^\\[\(section)\\][ \\t]*$"
        if let range = text.range(of: sectionPattern, options: .regularExpression) {
            var result = text
            result.insert(contentsOf: "\n\(key) = \(literal)", at: range.upperBound)
            return result
        }

        // 3. No section at all — splice one in before the theme block.
        let block = "[\(section)]\n\(key) = \(literal)\n\n"
        if let themeRange = text.range(
            of: "(?m)^\\[theme(\\.|\\])", options: .regularExpression
        ) {
            var result = text
            result.insert(contentsOf: block, at: themeRange.lowerBound)
            return result
        }
        let prefix = text.hasSuffix("\n") ? text : text + "\n"
        return prefix + "\n" + block
    }
}

// MARK: - TOML writer for the [keymaps] block

/// Rewrites the `[keymaps]` section of the resolved settings.toml to match the
/// live `VimAsciiKeymap`. Strips any existing `[keymaps]` block and re-emits it
/// spliced in **before** the first `[theme.*]` header (so `ThemeWriter`, which
/// preserves everything above the theme block, keeps it). Atomic write. Only
/// non-identity overrides + `toggle_activation` are written (identity entries
/// are the default and need no line).
@MainActor
enum KeymapWriter {
    static func persist(_ keymaps: Config.VimAsciiKeymap) -> String? {
        guard let url = Config.resolvedURL else {
            return "no settings.toml found at any resolved path"
        }
        let existing: String
        do {
            existing = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "read failed: \(error.localizedDescription)"
        }
        let block = serialize(keymaps)
        let combined: String
        if let section = keymapsSectionRange(in: existing) {
            // Replace the existing `[keymaps]` IN PLACE so the user's section
            // ordering is preserved wherever they put it — before or after the
            // theme block (ThemeWriter now rewrites theme in place too, so a
            // post-theme section survives). We never move it.
            var text = existing
            text.replaceSubrange(section, with: block)
            combined = text
        } else {
            // No `[keymaps]` yet → introduce it before the theme block (so the
            // config sections group together), else at EOF.
            combined = spliceBeforeTheme(block, into: existing)
        }

        do {
            try combined.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "write failed: \(error.localizedDescription)"
        }
        return nil
    }

    /// Range of an existing `[keymaps]` section: its header line through the
    /// first blank line / next `^[` header / EOF after it (whichever comes
    /// first), so following sections' leading comments are left intact.
    private static func keymapsSectionRange(in text: String) -> Range<String.Index>? {
        guard
            let header = text.range(
                of: #"(?m)^\[keymaps\][ \t]*$"#, options: .regularExpression)
        else { return nil }
        let after = text[header.upperBound...]
        let blank = after.range(of: #"(?m)^[ \t]*$"#, options: .regularExpression)?.lowerBound
        let nextHeader = after.range(of: #"(?m)^\["#, options: .regularExpression)?.lowerBound
        let end = [blank, nextHeader].compactMap { $0 }.min() ?? text.endIndex
        return header.lowerBound..<end
    }

    /// Insert `block` immediately before the first `[theme.*]` header, else
    /// append at EOF.
    private static func spliceBeforeTheme(_ block: String, into text: String) -> String {
        if let themeStart = text.range(
            of: #"(?m)^\[theme(\.|\])"#, options: .regularExpression
        )?.lowerBound {
            var result = text
            result.insert(contentsOf: block + "\n", at: themeStart)
            return result
        }
        let prefix = text.hasSuffix("\n") ? text : text + "\n"
        return prefix + "\n" + block
    }

    private static func serialize(_ keymaps: Config.VimAsciiKeymap) -> String {
        var lines = ["[keymaps]"]
        lines.append("toggle_activation = \"\(escape(keymaps.toggleActivation))\"  # ⌘ + this key")
        // Emit every catalog binding (resolved value = override or its default)
        // in catalog order, grouped, so the file documents all keys and
        // round-trips like the [theme.*] block.
        var lastGroup: Config.VimAsciiKeymap.Group?
        for entry in Config.VimAsciiKeymap.catalog {
            if entry.group != lastGroup {
                lines.append("# \(entry.group.rawValue)")
                lastGroup = entry.group
            }
            lines.append("\(tomlKey(entry.key)) = \"\(escape(keymaps[entry.key]))\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Bare key for `[A-Za-z0-9_]`, quoted otherwise (symbols / space).
    private static func tomlKey(_ key: String) -> String {
        let bareOK = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return bareOK ? key : "\"\(escape(key))\""
    }

    private static func escape(_ s: String) -> String {
        if s == "\"" { return "\\\"" }
        if s == "\\" { return "\\\\" }
        return s
    }
}

// MARK: - Settings file bootstrap

/// Creates a settings.toml when none exists yet, so a Save from the Settings
/// window has a file to write into instead of failing with "no settings.toml
/// found at any resolved path". Used as a fallback by the Save button.
@MainActor
enum SettingsBootstrap {
    /// The standard path we create when nothing is resolved (matches the
    /// resolution order's `~/.config/neomouse/` candidate).
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neomouse/settings.toml")
    }

    /// Create `~/.config/neomouse/settings.toml`, seeded from the bundled
    /// default template when available (a complete, valid config the writers
    /// then overlay the live state onto), else an empty file the writers fill
    /// with their managed sections. Returns nil on success or a short error.
    static func createDefaultSettingsFile() -> String? {
        let fm = FileManager.default
        let target = defaultURL
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return "could not create config directory: \(error.localizedDescription)"
        }
        let seed: String
        if let bundled = Bundle.main.url(forResource: "settings", withExtension: "toml"),
            let contents = try? String(contentsOf: bundled, encoding: .utf8)
        {
            seed = contents
        } else {
            seed = ""
        }
        do {
            try seed.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            return "could not create settings.toml: \(error.localizedDescription)"
        }
        debug("Created settings.toml at \(target.path) (seed: \(seed.isEmpty ? "empty" : "bundled default"))")
        return nil
    }
}

// MARK: - SettingsView

/// Sections shown in the sidebar — order matches what's most-asked. "Shared
/// Font" sits at the top because changing the typeface is the single most
/// impactful theme tweak (it propagates to every overlay).
private enum SettingsSection: String, CaseIterable, Identifiable {
    case behavior = "Behavior"
    case keybindings = "Keybindings"
    case sharedFont = "Shared Font"
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
        case .behavior: return "slider.horizontal.3"
        case .keybindings: return "command"
        case .sharedFont: return "textformat"
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
    @State private var selection: SettingsSection = .sharedFont
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
                    case .behavior: BehaviorForm(state: state)
                    case .keybindings: KeybindingsForm(state: state)
                    case .sharedFont: SharedFontForm(state: state)
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
                state.isAutoSnap = Config.Configuration.defaultIsAutoSnap
                state.frontAppFollowsMouse = Config.Configuration.defaultFrontAppFollowsMouse
                state.keymaps = Config.VimAsciiKeymap()
                saveResult = nil
            }
            Button("Save to settings.toml") {
                // Order matters: ConfigWriter / KeymapWriter run first because
                // ThemeWriter re-reads the file, and all three preserve the rest
                // of the file in place. (Section order is up to the user.)
                @MainActor func runWriters() -> [String] {
                    var errors: [String] = []
                    if let error = ConfigWriter.persistConfiguration(state.isAutoSnap, "is_auto_snap") {
                        errors.append(error)
                    }
                    if let error = ConfigWriter.persistConfiguration(
                        state.frontAppFollowsMouse, "front_app_follows_mouse")
                    {
                        errors.append(error)
                    }
                    if let error = KeymapWriter.persist(state.keymaps) {
                        errors.append(error)
                    }
                    if let error = ThemeWriter.persist(state.theme) {
                        errors.append(error)
                    }
                    return errors
                }
                var errors = runWriters()
                // If the save failed because there's no settings.toml yet,
                // create one at ~/.config/neomouse/settings.toml and retry once.
                if !errors.isEmpty, Config.resolvedURL == nil {
                    if let createError = SettingsBootstrap.createDefaultSettingsFile() {
                        errors.append(createError)
                    } else {
                        errors = runWriters()
                    }
                }
                saveResult =
                    errors.isEmpty
                    ? "Saved to ~/.config/neomouse/settings.toml"
                    : "Save failed: \(errors.joined(separator: "; "))"
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

/// Non-theme behavior knobs from `[configuration]`. Persisted via
/// `ConfigWriter` (not `ThemeWriter`) on Save. Unlike the theme forms, these
/// take effect the next time NeoMouse is active — the Settings window
/// force-pauses NeoMouse while open, so there's nothing live to preview here.
/// One editable binding row: action label + a single-key field. Type the
/// literal key (e.g. "h", "H", "$"); only the last character is kept. Red
/// outline when the key collides with another action's binding.
private struct KeyRow: View {
    let title: String
    @Binding var key: String
    var conflict: Bool = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: $key)
                .frame(width: 46)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(conflict ? Color.red : Color.clear, lineWidth: 1.5))
        }
    }
}

/// Editor for the remappable Vim keybindings. Each row rebinds a canonical Vim
/// char to a different physical key; edits are live (overlays/handlers read
/// `state.keymaps` immediately) and persist via `KeymapWriter` on Save.
private struct KeybindingsForm: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        let conflicts = state.keymaps.conflictingCanonicalKeys()

        Section("Activation") {
            KeyRow(title: "Toggle NeoMouse (with ⌘)", key: state.toggleActivationBinding())
        }
        Text(
            "Rebind a Vim key to a different physical key. Digits and special keys (Esc / Tab / arrows / F-keys) are fixed."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        ForEach(Config.VimAsciiKeymap.Group.allCases, id: \.self) { group in
            Section(group.rawValue) {
                ForEach(
                    Config.VimAsciiKeymap.catalog.filter { $0.group == group }, id: \.key
                ) { entry in
                    KeyRow(
                        title: entry.label,
                        key: state.keymapBinding(forCanonical: entry.key),
                        conflict: conflicts.contains(entry.key))
                }
            }
        }

        if !conflicts.isEmpty {
            Text(
                "Some keys are bound to more than one action (highlighted). Allowed — modes disambiguate many — but may be ambiguous."
            )
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}

private struct BehaviorForm: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        Section("Cursor") {
            Toggle("Auto-snap to cursor band", isOn: $state.isAutoSnap)
            Text(
                """
                When :cursorline / :cursorcolumn is active, hjkl motions snap \
                the cursor to the centre of its grid cell so it always lines up \
                with the highlighted band. No effect when no band is showing.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Most front app on cursor set as current active app", isOn: $state.frontAppFollowsMouse)
            Text(
                """
                When active, the most front app (e.g. highest z-index) the cursor is on \
                becomes the current active application.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        }
    }
}

/// Single point of control for the typeface used everywhere in neomouse.
/// Changing family / weight / design here broadcasts to every `ThemeFont`
/// leaf on `state.theme` via `setSharedFontFace`, but preserves each
/// element's per-element font *size* (a grid label at 60pt and a toast
/// label at 13pt are still 60 and 13 respectively after the broadcast —
/// only the typeface changes). For per-element size adjustments, see the
/// individual element's "Font" section.
///
/// We use `theme.toast.textFont` as the canonical source of truth for the
/// currently-displayed family / weight / design so the form's three
/// controls always reflect the most-recently-broadcast values. Hand-editing
/// settings.toml to give different elements different families is still
/// allowed; the next change here will overwrite that divergence.
private struct SharedFontForm: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        Section("Typeface (applies to every overlay)") {
            TextField(
                "Family (empty = system font)",
                text: Binding(
                    get: { state.theme.toast.textFont.family },
                    set: { newFamily in
                        let cur = state.theme.toast.textFont
                        state.setSharedFontFace(
                            family: newFamily, weight: cur.weight, design: cur.design)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Picker(
                "Weight",
                selection: Binding(
                    get: { state.theme.toast.textFont.weight },
                    set: { newWeight in
                        let cur = state.theme.toast.textFont
                        state.setSharedFontFace(
                            family: cur.family, weight: newWeight, design: cur.design)
                    })
            ) {
                ForEach(Array(ThemeFont.Weight.allCases), id: \.self) { w in
                    Text(w.rawValue).tag(w)
                }
            }

            Picker(
                "Design",
                selection: Binding(
                    get: { state.theme.toast.textFont.design },
                    set: { newDesign in
                        let cur = state.theme.toast.textFont
                        state.setSharedFontFace(
                            family: cur.family, weight: cur.weight, design: newDesign)
                    })
            ) {
                ForEach(Array(ThemeFont.Design.allCases), id: \.self) { d in
                    Text(d.rawValue).tag(d)
                }
            }
        }
        Section("How sizes work") {
            Text(
                """
                Each overlay keeps its own font *size* (set on the element's \
                section in the sidebar) — only the typeface above is shared. \
                Default sizes match nvim-style layouts: grid labels are 60pt, \
                toast text is 13pt, register cards are 11pt, etc.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

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
            LabeledStepper(
                "Text font size", value: state.binding(\.toast.textFont.size), range: 6...96)
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
            LabeledStepper(
                "Text font size", value: state.binding(\.keyCast.textFont.size), range: 6...96)
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
            LabeledStepper(
                "Gutter width", value: state.binding(\.numbersOverlay.gutterWidth), range: 10...80)
        }
        Section("Column strip") {
            EnumPicker(
                title: "Direction",
                selection: state.binding(\.numbersOverlay.columnStripDirection))
            LabeledStepper(
                "Column strip height", value: state.binding(\.numbersOverlay.columnStripHeight),
                range: 10...80)
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
            LabeledStepper(
                "Number font size", value: state.binding(\.numbersOverlay.font.size), range: 6...96)
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
            LabeledStepper(
                "Outer label font size", value: state.binding(\.grid.outerLabelFont.size), range: 6...96)
            LabeledStepper(
                "Inner label font size", value: state.binding(\.grid.innerLabelFont.size), range: 6...96)
            LabeledStepper(
                "Cursor-surrounded label font size",
                value: state.binding(\.grid.cursorSurroundedLabelFont.size),
                range: 6...96)
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
            LabeledStepper(
                "Text font size", value: state.binding(\.commandLine.textFont.size), range: 6...96)
            LabeledStepper(
                "Suggestion font size", value: state.binding(\.commandLine.suggestionFont.size), range: 6...96)
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
            LabeledStepper(
                "Header font size", value: state.binding(\.helpDialog.headerFont.size), range: 6...96)
            LabeledStepper(
                "Keybind font size", value: state.binding(\.helpDialog.keybindFont.size), range: 6...96)
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
            LabeledStepper(
                "Header size", value: state.binding(\.marksMenu.headerFont.size), range: 6...96)
            LabeledStepper(
                "Mark label size", value: state.binding(\.marksMenu.markLabelFont.size), range: 6...96)
            LabeledStepper(
                "Cell size", value: state.binding(\.marksMenu.cellFont.size), range: 6...96)
            LabeledStepper(
                "Empty message size", value: state.binding(\.marksMenu.emptyMessageFont.size), range: 6...96)
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
            LabeledStepper(
                "Search size", value: state.binding(\.registerMenu.searchFont.size), range: 6...96)
            LabeledStepper(
                "App name size", value: state.binding(\.registerMenu.appNameFont.size), range: 6...96)
            LabeledStepper(
                "Register label size", value: state.binding(\.registerMenu.registerLabelFont.size), range: 6...96)
            LabeledStepper(
                "Card text size", value: state.binding(\.registerMenu.cardTextFont.size), range: 6...96)
            LabeledStepper(
                "Badge size", value: state.binding(\.registerMenu.badgeFont.size), range: 6...96)
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
