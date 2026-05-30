import CoreGraphics
import Foundation

// TOMLDecoder doesn't auto-coerce between TOML's `Integer` and `Float`
// scalars. A field declared `Double` in Swift errors out when the TOML
// value is written as `width = 420` (integer) rather than `width = 420.0`
// (float) — and the error it surfaces is the cryptic
//   "Expected value of type OffsetDateTime but found null"
// because the decoder's `decode(Double.self)` falls through to a datetime
// branch when the float parse fails.
//
// `tomlDouble` accepts either form transparently. Use it instead of
// `c.decodeIfPresent(Double.self, forKey: …) ?? default` for every Double
// theme field so users can write whatever numeric literal feels natural.
private func tomlDouble<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>, forKey key: K, default d: Double
) throws -> Double {
    guard c.contains(key) else { return d }
    if let i = try? c.decode(Int.self, forKey: key) { return Double(i) }
    return try c.decode(Double.self, forKey: key)
}

// User-overridable theme model for every neomouse UI element (except the
// menu-bar status icon, which is intentionally tied to the mode/state
// color scheme). Each subsection of `Config.Theme` maps to one TOML table
// — e.g. `[theme.toast]` decodes into `Config.Theme.Toast`.
//
// All sub-fields are optional in the TOML; missing keys fall back to
// the hardcoded values that ship in this file. So a brand-new settings.toml
// with no `[theme.*]` blocks renders neomouse exactly as it always has.
//
// SwiftUI / NSColor / Font conversion lives in the executable target
// (`Sources/neomouse/ui/Theme+SwiftUI.swift`) because neomouseConfig is kept
// SwiftUI/AppKit-free so it can be reused from non-UI targets / tests.

extension Config {
    /// Top-level theme container. Each property is a sub-theme for one UI
    /// element (or one shared element family — GridTheme covers both the
    /// find-mode grid and the cursor-surrounded special-find grid).
    public struct Theme: Decodable, Sendable {
        public let grid: GridTheme
        public let numbersOverlay: NumbersOverlayTheme
        public let commandLine: CommandLineTheme
        public let marksMenu: MarksMenuTheme
        public let registerMenu: RegisterMenuTheme
        public let helpDialog: HelpDialogTheme
        public let visualHighlight: VisualHighlightTheme
        public let toast: ToastTheme
        public let keyCast: KeyCastTheme

        public init(
            grid: GridTheme = GridTheme(),
            numbersOverlay: NumbersOverlayTheme = NumbersOverlayTheme(),
            commandLine: CommandLineTheme = CommandLineTheme(),
            marksMenu: MarksMenuTheme = MarksMenuTheme(),
            registerMenu: RegisterMenuTheme = RegisterMenuTheme(),
            helpDialog: HelpDialogTheme = HelpDialogTheme(),
            visualHighlight: VisualHighlightTheme = VisualHighlightTheme(),
            toast: ToastTheme = ToastTheme(),
            keyCast: KeyCastTheme = KeyCastTheme()
        ) {
            self.grid = grid
            self.numbersOverlay = numbersOverlay
            self.commandLine = commandLine
            self.marksMenu = marksMenu
            self.registerMenu = registerMenu
            self.helpDialog = helpDialog
            self.visualHighlight = visualHighlight
            self.toast = toast
            self.keyCast = keyCast
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case grid, numbersOverlay, commandLine, marksMenu, registerMenu
            case helpDialog, visualHighlight, toast, keyCast
        }

        public init(from decoder: any Decoder) throws {
            try validateKnownKeys(
                decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme")
            let c = try decoder.container(keyedBy: CodingKeys.self)
            grid = try c.decodeIfPresent(GridTheme.self, forKey: .grid) ?? GridTheme()
            numbersOverlay =
                try c.decodeIfPresent(NumbersOverlayTheme.self, forKey: .numbersOverlay)
                ?? NumbersOverlayTheme()
            commandLine =
                try c.decodeIfPresent(CommandLineTheme.self, forKey: .commandLine) ?? CommandLineTheme()
            marksMenu =
                try c.decodeIfPresent(MarksMenuTheme.self, forKey: .marksMenu) ?? MarksMenuTheme()
            registerMenu =
                try c.decodeIfPresent(RegisterMenuTheme.self, forKey: .registerMenu) ?? RegisterMenuTheme()
            helpDialog =
                try c.decodeIfPresent(HelpDialogTheme.self, forKey: .helpDialog) ?? HelpDialogTheme()
            visualHighlight =
                try c.decodeIfPresent(VisualHighlightTheme.self, forKey: .visualHighlight)
                ?? VisualHighlightTheme()
            toast = try c.decodeIfPresent(ToastTheme.self, forKey: .toast) ?? ToastTheme()
            keyCast = try c.decodeIfPresent(KeyCastTheme.self, forKey: .keyCast) ?? KeyCastTheme()
        }
    }
}

// MARK: - Shared primitives

/// 0..1 RGBA. Decoded from a hex string in TOML: `"#rrggbb"`, `"#rrggbbaa"`,
/// `"#rgb"`, or `"#rgba"` — the `#` is optional. Out-of-format values throw
/// a TOML decoding error at load time.
public struct ThemeColor: Decodable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Black, fully opaque — handy default sentinel.
    public static let black = ThemeColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let clear = ThemeColor(red: 0, green: 0, blue: 0, alpha: 0)

    public static func hex(_ hex: String) -> ThemeColor {
        parse(hex: hex) ?? .black
    }

    /// Parse `#rrggbb` / `#rrggbbaa` / `#rgb` / `#rgba` (case-insensitive,
    /// `#` optional). Returns nil for any other shape.
    public static func parse(hex: String) -> ThemeColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let length = s.count
        if length == 3 || length == 4 {
            // expand each nibble to a byte: "abc" → "aabbcc"
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
            return nil
        }
        if s.count == 6 {
            return ThemeColor(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1.0
            )
        }
        return ThemeColor(
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            alpha: Double(value & 0xFF) / 255
        )
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let hex = try c.decode(String.self)
        guard let parsed = ThemeColor.parse(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription:
                    "invalid color hex \"\(hex)\" — expected #rgb / #rgba / #rrggbb / #rrggbbaa"
            )
        }
        self = parsed
    }
}

/// Font specification. `family` blank → SwiftUI's system font (preferred —
/// stays consistent with macOS UI conventions). `design` only applies to
/// the system font; it's ignored when `family` is set.
public struct ThemeFont: Decodable, Sendable, Equatable {
    public let family: String
    public let size: Double
    public let weight: Weight
    public let design: Design

    public enum Weight: String, Decodable, Sendable, CaseIterable {
        case ultraLight = "ultra_light"
        case thin
        case light
        case regular
        case medium
        case semibold
        case bold
        case heavy
        case black
    }

    public enum Design: String, Decodable, Sendable, CaseIterable {
        case `default`
        case monospaced
        case serif
        case rounded
    }

    public init(
        size: Double,
        weight: Weight = .regular,
        design: Design = .default,
        family: String = ""
    ) {
        self.family = family
        self.size = size
        self.weight = weight
        self.design = design
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case family, size, weight, design
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "font")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decodeIfPresent(String.self, forKey: .family) ?? ""
        size = try tomlDouble(c, forKey: .size, default: 13)
        weight = try c.decodeIfPresent(Weight.self, forKey: .weight) ?? .regular
        design = try c.decodeIfPresent(Design.self, forKey: .design) ?? .default
    }
}

/// Where a transient overlay (toast, command line, key cast, etc.) anchors
/// itself on the active screen's visible frame. Combine with `offsetX` /
/// `offsetY` (in points) for fine tuning.
public enum ThemeAnchor: String, Decodable, Sendable, CaseIterable {
    case top
    case topLeft = "top_left"
    case topRight = "top_right"
    case center
    case centerLeft = "center_left"
    case centerRight = "center_right"
    case bottom
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
}

/// Side of the screen for the NumbersOverlay gutter (and a future toggle
/// for the column strip).
public enum ThemeDirection: String, Decodable, Sendable, CaseIterable {
    case left
    case right
}

/// SwiftUI Material flavor — picks the level of background blur on a panel.
public enum ThemeMaterial: String, Decodable, Sendable, CaseIterable {
    case ultraThin = "ultra_thin"
    case thin
    case regular
    case thick
    case ultraThick = "ultra_thick"
    case bar
    case hud
}

// MARK: - Per-element themes
//
// Every field is non-optional with a hardcoded default chosen to match the
// app's current visual appearance. Each struct's `init(from:)` uses
// decodeIfPresent so the TOML can override only the keys it cares about.

/// Shared by GridOverlay (find-mode big-grid) AND
/// CursorSurroundedGridOverlay (specialFind dense grid). Names use
/// "outer" / "inner" for GridOverlay's two layers; the surrounded grid
/// uses `outerLineColor` for its strokes and `innerLabelColor` /
/// `innerLabelFont` for its single labels-per-cell.
public struct GridTheme: Decodable, Sendable {
    public let background: ThemeColor
    public let outerLineColor: ThemeColor
    public let outerLabelColor: ThemeColor
    public let outerLabelFont: ThemeFont
    public let innerLineColor: ThemeColor
    public let innerFaintLineColor: ThemeColor
    public let innerLabelColor: ThemeColor
    public let innerLabelFont: ThemeFont
    /// CursorSurroundedGridOverlay-specific: box edge length in points.
    public let cursorSurroundedBoxSize: Double
    /// CursorSurroundedGridOverlay-specific: cells per axis.
    public let cursorSurroundedDivisions: Int
    /// CursorSurroundedGridOverlay-specific: label font (denser cells need
    /// smaller text than GridOverlay's outer labels).
    public let cursorSurroundedLabelFont: ThemeFont

    public init(
        background: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.15),
        outerLineColor: ThemeColor = .init(red: 1, green: 1, blue: 1, alpha: 0.6),
        outerLabelColor: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 1),  // SwiftUI .blue
        outerLabelFont: ThemeFont = .init(size: 60, weight: .bold),
        innerLineColor: ThemeColor = .init(red: 1, green: 1, blue: 1, alpha: 0.6),
        innerFaintLineColor: ThemeColor = .init(red: 1, green: 1, blue: 1, alpha: 0.3),
        innerLabelColor: ThemeColor = .white,
        innerLabelFont: ThemeFont = .init(size: 12),
        cursorSurroundedBoxSize: Double = 200,
        cursorSurroundedDivisions: Int = 6,
        cursorSurroundedLabelFont: ThemeFont = .init(size: 14, weight: .semibold, design: .monospaced)
    ) {
        self.background = background
        self.outerLineColor = outerLineColor
        self.outerLabelColor = outerLabelColor
        self.outerLabelFont = outerLabelFont
        self.innerLineColor = innerLineColor
        self.innerFaintLineColor = innerFaintLineColor
        self.innerLabelColor = innerLabelColor
        self.innerLabelFont = innerLabelFont
        self.cursorSurroundedBoxSize = cursorSurroundedBoxSize
        self.cursorSurroundedDivisions = cursorSurroundedDivisions
        self.cursorSurroundedLabelFont = cursorSurroundedLabelFont
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case background, outerLineColor, outerLabelColor, outerLabelFont
        case innerLineColor, innerFaintLineColor, innerLabelColor, innerLabelFont
        case cursorSurroundedBoxSize, cursorSurroundedDivisions, cursorSurroundedLabelFont
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.grid")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GridTheme()
        background = try c.decodeIfPresent(ThemeColor.self, forKey: .background) ?? d.background
        outerLineColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .outerLineColor) ?? d.outerLineColor
        outerLabelColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .outerLabelColor) ?? d.outerLabelColor
        outerLabelFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .outerLabelFont) ?? d.outerLabelFont
        innerLineColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .innerLineColor) ?? d.innerLineColor
        innerFaintLineColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .innerFaintLineColor)
            ?? d.innerFaintLineColor
        innerLabelColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .innerLabelColor) ?? d.innerLabelColor
        innerLabelFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .innerLabelFont) ?? d.innerLabelFont
        cursorSurroundedBoxSize =
            try tomlDouble(c, forKey: .cursorSurroundedBoxSize, default: d.cursorSurroundedBoxSize)
        cursorSurroundedDivisions =
            try c.decodeIfPresent(Int.self, forKey: .cursorSurroundedDivisions)
            ?? d.cursorSurroundedDivisions
        cursorSurroundedLabelFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .cursorSurroundedLabelFont)
            ?? d.cursorSurroundedLabelFont
    }
}

public struct NumbersOverlayTheme: Decodable, Sendable {
    /// Which side of the screen the line-number gutter sits on. The column
    /// strip stays at the top for now (parallel toggle is a future TODO).
    public let direction: ThemeDirection
    public let gutterBackground: ThemeColor
    public let cursorLineHighlight: ThemeColor
    public let cursorColumnHighlight: ThemeColor
    public let cursorTextColor: ThemeColor
    public let textColor: ThemeColor
    /// Font size is auto-scaled to row height; this defines weight + design + family only.
    public let font: ThemeFont
    public let gutterWidth: Double
    public let columnStripHeight: Double

    public init(
        direction: ThemeDirection = .left,
        gutterBackground: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.55),
        cursorLineHighlight: ThemeColor = .init(red: 1, green: 1, blue: 0, alpha: 0.18),
        cursorColumnHighlight: ThemeColor = .init(red: 1, green: 1, blue: 0, alpha: 0.18),
        cursorTextColor: ThemeColor = .init(red: 1, green: 1, blue: 0, alpha: 1),
        textColor: ThemeColor = .init(red: 1, green: 1, blue: 1, alpha: 0.75),
        font: ThemeFont = .init(size: 12, design: .monospaced),
        gutterWidth: Double = 20,
        columnStripHeight: Double = 20
    ) {
        self.direction = direction
        self.gutterBackground = gutterBackground
        self.cursorLineHighlight = cursorLineHighlight
        self.cursorColumnHighlight = cursorColumnHighlight
        self.cursorTextColor = cursorTextColor
        self.textColor = textColor
        self.font = font
        self.gutterWidth = gutterWidth
        self.columnStripHeight = columnStripHeight
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case direction, gutterBackground, cursorLineHighlight, cursorColumnHighlight
        case cursorTextColor, textColor, font, gutterWidth, columnStripHeight
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.numbers_overlay")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NumbersOverlayTheme()
        direction = try c.decodeIfPresent(ThemeDirection.self, forKey: .direction) ?? d.direction
        gutterBackground =
            try c.decodeIfPresent(ThemeColor.self, forKey: .gutterBackground) ?? d.gutterBackground
        cursorLineHighlight =
            try c.decodeIfPresent(ThemeColor.self, forKey: .cursorLineHighlight)
            ?? d.cursorLineHighlight
        cursorColumnHighlight =
            try c.decodeIfPresent(ThemeColor.self, forKey: .cursorColumnHighlight)
            ?? d.cursorColumnHighlight
        cursorTextColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .cursorTextColor) ?? d.cursorTextColor
        textColor = try c.decodeIfPresent(ThemeColor.self, forKey: .textColor) ?? d.textColor
        font = try c.decodeIfPresent(ThemeFont.self, forKey: .font) ?? d.font
        gutterWidth = try tomlDouble(c, forKey: .gutterWidth, default: d.gutterWidth)
        columnStripHeight =
            try tomlDouble(c, forKey: .columnStripHeight, default: d.columnStripHeight)
    }
}

public struct CommandLineTheme: Decodable, Sendable {
    public let anchor: ThemeAnchor
    public let xOffset: Double
    public let yOffset: Double
    public let width: Double
    public let height: Double
    public let cornerRadius: Double
    public let textFont: ThemeFont
    public let textColor: ThemeColor
    public let prefixColor: ThemeColor
    public let suggestionFont: ThemeFont
    public let suggestionTextColor: ThemeColor
    public let suggestionHighlight: ThemeColor
    public let material: ThemeMaterial

    public init(
        anchor: ThemeAnchor = .bottom,
        xOffset: Double = 0,
        yOffset: Double = 100,
        width: Double = 420,
        height: Double = 60,
        cornerRadius: Double = 8,
        textFont: ThemeFont = .init(size: 13, design: .monospaced),
        textColor: ThemeColor = .init(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        prefixColor: ThemeColor = .init(red: 0.6, green: 0.6, blue: 0.6, alpha: 1),
        suggestionFont: ThemeFont = .init(size: 13, design: .monospaced),
        suggestionTextColor: ThemeColor = .init(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        suggestionHighlight: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 0.35),
        material: ThemeMaterial = .regular
    ) {
        self.anchor = anchor
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.textFont = textFont
        self.textColor = textColor
        self.prefixColor = prefixColor
        self.suggestionFont = suggestionFont
        self.suggestionTextColor = suggestionTextColor
        self.suggestionHighlight = suggestionHighlight
        self.material = material
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchor, xOffset, yOffset, width, height, cornerRadius
        case textFont, textColor, prefixColor
        case suggestionFont, suggestionTextColor, suggestionHighlight, material
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.command_line")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CommandLineTheme()
        anchor = try c.decodeIfPresent(ThemeAnchor.self, forKey: .anchor) ?? d.anchor
        xOffset = try tomlDouble(c, forKey: .xOffset, default: d.xOffset)
        yOffset = try tomlDouble(c, forKey: .yOffset, default: d.yOffset)
        width = try tomlDouble(c, forKey: .width, default: d.width)
        height = try tomlDouble(c, forKey: .height, default: d.height)
        cornerRadius = try tomlDouble(c, forKey: .cornerRadius, default: d.cornerRadius)
        textFont = try c.decodeIfPresent(ThemeFont.self, forKey: .textFont) ?? d.textFont
        textColor = try c.decodeIfPresent(ThemeColor.self, forKey: .textColor) ?? d.textColor
        prefixColor = try c.decodeIfPresent(ThemeColor.self, forKey: .prefixColor) ?? d.prefixColor
        suggestionFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .suggestionFont) ?? d.suggestionFont
        suggestionTextColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .suggestionTextColor)
            ?? d.suggestionTextColor
        suggestionHighlight =
            try c.decodeIfPresent(ThemeColor.self, forKey: .suggestionHighlight)
            ?? d.suggestionHighlight
        material = try c.decodeIfPresent(ThemeMaterial.self, forKey: .material) ?? d.material
    }
}

public struct MarksMenuTheme: Decodable, Sendable {
    public let anchor: ThemeAnchor
    public let width: Double
    public let height: Double
    public let cornerRadius: Double
    public let material: ThemeMaterial
    public let headerFont: ThemeFont
    public let markLabelFont: ThemeFont
    public let cellFont: ThemeFont
    public let emptyMessageFont: ThemeFont
    public let selectedRowBackground: ThemeColor
    public let rowPaddingX: Double
    public let rowPaddingY: Double

    public init(
        anchor: ThemeAnchor = .center,
        width: Double = 500,
        height: Double = 500,
        cornerRadius: Double = 8,
        material: ThemeMaterial = .ultraThin,
        headerFont: ThemeFont = .init(size: 11, weight: .semibold),
        markLabelFont: ThemeFont = .init(size: 12, weight: .medium, design: .monospaced),
        cellFont: ThemeFont = .init(size: 12, design: .monospaced),
        emptyMessageFont: ThemeFont = .init(size: 12),
        selectedRowBackground: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 0.35),
        rowPaddingX: Double = 12,
        rowPaddingY: Double = 4
    ) {
        self.anchor = anchor
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.material = material
        self.headerFont = headerFont
        self.markLabelFont = markLabelFont
        self.cellFont = cellFont
        self.emptyMessageFont = emptyMessageFont
        self.selectedRowBackground = selectedRowBackground
        self.rowPaddingX = rowPaddingX
        self.rowPaddingY = rowPaddingY
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchor, width, height, cornerRadius, material
        case headerFont, markLabelFont, cellFont, emptyMessageFont
        case selectedRowBackground, rowPaddingX, rowPaddingY
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.marks_menu")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MarksMenuTheme()
        anchor = try c.decodeIfPresent(ThemeAnchor.self, forKey: .anchor) ?? d.anchor
        width = try tomlDouble(c, forKey: .width, default: d.width)
        height = try tomlDouble(c, forKey: .height, default: d.height)
        cornerRadius = try tomlDouble(c, forKey: .cornerRadius, default: d.cornerRadius)
        material = try c.decodeIfPresent(ThemeMaterial.self, forKey: .material) ?? d.material
        headerFont = try c.decodeIfPresent(ThemeFont.self, forKey: .headerFont) ?? d.headerFont
        markLabelFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .markLabelFont) ?? d.markLabelFont
        cellFont = try c.decodeIfPresent(ThemeFont.self, forKey: .cellFont) ?? d.cellFont
        emptyMessageFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .emptyMessageFont) ?? d.emptyMessageFont
        selectedRowBackground =
            try c.decodeIfPresent(ThemeColor.self, forKey: .selectedRowBackground)
            ?? d.selectedRowBackground
        rowPaddingX = try tomlDouble(c, forKey: .rowPaddingX, default: d.rowPaddingX)
        rowPaddingY = try tomlDouble(c, forKey: .rowPaddingY, default: d.rowPaddingY)
    }
}

public struct RegisterMenuTheme: Decodable, Sendable {
    public let anchor: ThemeAnchor
    public let width: Double
    public let height: Double
    public let cornerRadius: Double
    public let material: ThemeMaterial
    public let cardWidth: Double
    public let cardHeight: Double
    public let cardPaddingX: Double
    public let cardPaddingY: Double
    public let viewPadding: Double
    public let searchFont: ThemeFont
    public let appNameFont: ThemeFont
    public let registerLabelFont: ThemeFont
    public let cardTextFont: ThemeFont
    public let badgeFont: ThemeFont
    public let registerBadgeBackground: ThemeColor
    public let selectedCardBorder: ThemeColor
    public let unselectedCardBorder: ThemeColor
    public let cardShadowSelected: ThemeColor
    public let cardShadowUnselected: ThemeColor
    public let contentBackground: ThemeColor

    public init(
        anchor: ThemeAnchor = .center,
        width: Double = 920,
        height: Double = 380,
        cornerRadius: Double = 12,
        material: ThemeMaterial = .ultraThin,
        cardWidth: Double = 220,
        cardHeight: Double = 280,
        cardPaddingX: Double = 4,
        cardPaddingY: Double = 4,
        viewPadding: Double = 12,
        searchFont: ThemeFont = .init(size: 13),
        appNameFont: ThemeFont = .init(size: 11, weight: .medium),
        registerLabelFont: ThemeFont = .init(size: 12, weight: .bold, design: .monospaced),
        cardTextFont: ThemeFont = .init(size: 11, design: .monospaced),
        badgeFont: ThemeFont = .init(size: 11, design: .monospaced),
        registerBadgeBackground: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 0.35),
        selectedCardBorder: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 1),
        unselectedCardBorder: ThemeColor = .init(red: 1, green: 1, blue: 1, alpha: 0.08),
        cardShadowSelected: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.35),
        cardShadowUnselected: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.15),
        contentBackground: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.08)
    ) {
        self.anchor = anchor
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.material = material
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardPaddingX = cardPaddingX
        self.cardPaddingY = cardPaddingY
        self.viewPadding = viewPadding
        self.searchFont = searchFont
        self.appNameFont = appNameFont
        self.registerLabelFont = registerLabelFont
        self.cardTextFont = cardTextFont
        self.badgeFont = badgeFont
        self.registerBadgeBackground = registerBadgeBackground
        self.selectedCardBorder = selectedCardBorder
        self.unselectedCardBorder = unselectedCardBorder
        self.cardShadowSelected = cardShadowSelected
        self.cardShadowUnselected = cardShadowUnselected
        self.contentBackground = contentBackground
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchor, width, height, cornerRadius, material
        case cardWidth, cardHeight, cardPaddingX, cardPaddingY, viewPadding
        case searchFont, appNameFont, registerLabelFont, cardTextFont, badgeFont
        case registerBadgeBackground, selectedCardBorder, unselectedCardBorder
        case cardShadowSelected, cardShadowUnselected, contentBackground
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.register_menu")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RegisterMenuTheme()
        anchor = try c.decodeIfPresent(ThemeAnchor.self, forKey: .anchor) ?? d.anchor
        width = try tomlDouble(c, forKey: .width, default: d.width)
        height = try tomlDouble(c, forKey: .height, default: d.height)
        cornerRadius = try tomlDouble(c, forKey: .cornerRadius, default: d.cornerRadius)
        material = try c.decodeIfPresent(ThemeMaterial.self, forKey: .material) ?? d.material
        cardWidth = try tomlDouble(c, forKey: .cardWidth, default: d.cardWidth)
        cardHeight = try tomlDouble(c, forKey: .cardHeight, default: d.cardHeight)
        cardPaddingX = try tomlDouble(c, forKey: .cardPaddingX, default: d.cardPaddingX)
        cardPaddingY = try tomlDouble(c, forKey: .cardPaddingY, default: d.cardPaddingY)
        viewPadding = try tomlDouble(c, forKey: .viewPadding, default: d.viewPadding)
        searchFont = try c.decodeIfPresent(ThemeFont.self, forKey: .searchFont) ?? d.searchFont
        appNameFont = try c.decodeIfPresent(ThemeFont.self, forKey: .appNameFont) ?? d.appNameFont
        registerLabelFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .registerLabelFont) ?? d.registerLabelFont
        cardTextFont =
            try c.decodeIfPresent(ThemeFont.self, forKey: .cardTextFont) ?? d.cardTextFont
        badgeFont = try c.decodeIfPresent(ThemeFont.self, forKey: .badgeFont) ?? d.badgeFont
        registerBadgeBackground =
            try c.decodeIfPresent(ThemeColor.self, forKey: .registerBadgeBackground)
            ?? d.registerBadgeBackground
        selectedCardBorder =
            try c.decodeIfPresent(ThemeColor.self, forKey: .selectedCardBorder)
            ?? d.selectedCardBorder
        unselectedCardBorder =
            try c.decodeIfPresent(ThemeColor.self, forKey: .unselectedCardBorder)
            ?? d.unselectedCardBorder
        cardShadowSelected =
            try c.decodeIfPresent(ThemeColor.self, forKey: .cardShadowSelected)
            ?? d.cardShadowSelected
        cardShadowUnselected =
            try c.decodeIfPresent(ThemeColor.self, forKey: .cardShadowUnselected)
            ?? d.cardShadowUnselected
        contentBackground =
            try c.decodeIfPresent(ThemeColor.self, forKey: .contentBackground) ?? d.contentBackground
    }
}

public struct HelpDialogTheme: Decodable, Sendable {
    public let anchor: ThemeAnchor
    public let width: Double
    public let height: Double
    public let padding: Double
    public let headerColor: ThemeColor
    public let headerFont: ThemeFont
    public let keybindFont: ThemeFont
    public let descriptionColor: ThemeColor

    public init(
        anchor: ThemeAnchor = .center,
        width: Double = 700,
        height: Double = 850,
        padding: Double = 20,
        headerColor: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 1),
        headerFont: ThemeFont = .init(size: 17, weight: .semibold),
        keybindFont: ThemeFont = .init(size: 13, design: .monospaced),
        descriptionColor: ThemeColor = .init(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
    ) {
        self.anchor = anchor
        self.width = width
        self.height = height
        self.padding = padding
        self.headerColor = headerColor
        self.headerFont = headerFont
        self.keybindFont = keybindFont
        self.descriptionColor = descriptionColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchor, width, height, padding
        case headerColor, headerFont, keybindFont, descriptionColor
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.help_dialog")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HelpDialogTheme()
        anchor = try c.decodeIfPresent(ThemeAnchor.self, forKey: .anchor) ?? d.anchor
        width = try tomlDouble(c, forKey: .width, default: d.width)
        height = try tomlDouble(c, forKey: .height, default: d.height)
        padding = try tomlDouble(c, forKey: .padding, default: d.padding)
        headerColor = try c.decodeIfPresent(ThemeColor.self, forKey: .headerColor) ?? d.headerColor
        headerFont = try c.decodeIfPresent(ThemeFont.self, forKey: .headerFont) ?? d.headerFont
        keybindFont = try c.decodeIfPresent(ThemeFont.self, forKey: .keybindFont) ?? d.keybindFont
        descriptionColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .descriptionColor) ?? d.descriptionColor
    }
}

public struct VisualHighlightTheme: Decodable, Sendable {
    public let fill: ThemeColor

    public init(
        fill: ThemeColor = .init(red: 0, green: 0.478, blue: 1, alpha: 0.3)
    ) {
        self.fill = fill
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case fill }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.visual_highlight")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VisualHighlightTheme()
        fill = try c.decodeIfPresent(ThemeColor.self, forKey: .fill) ?? d.fill
    }
}

public struct ToastTheme: Decodable, Sendable {
    public let anchor: ThemeAnchor
    public let xOffset: Double
    public let yOffset: Double
    public let width: Double
    public let height: Double
    public let cornerRadius: Double
    public let paddingX: Double
    public let paddingY: Double
    public let outerPadding: Double
    public let background: ThemeColor
    public let textColor: ThemeColor
    public let textFont: ThemeFont

    public init(
        anchor: ThemeAnchor = .topRight,
        xOffset: Double = 20,
        yOffset: Double = 20,
        width: Double = 300,
        height: Double = 60,
        cornerRadius: Double = 12,
        paddingX: Double = 16,
        paddingY: Double = 12,
        outerPadding: Double = 10,
        background: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.85),
        textColor: ThemeColor = .white,
        textFont: ThemeFont = .init(size: 13, weight: .medium)
    ) {
        self.anchor = anchor
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.outerPadding = outerPadding
        self.background = background
        self.textColor = textColor
        self.textFont = textFont
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchor, xOffset, yOffset, width, height, cornerRadius
        case paddingX, paddingY, outerPadding
        case background, textColor, textFont
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.toast")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToastTheme()
        anchor = try c.decodeIfPresent(ThemeAnchor.self, forKey: .anchor) ?? d.anchor
        xOffset = try tomlDouble(c, forKey: .xOffset, default: d.xOffset)
        yOffset = try tomlDouble(c, forKey: .yOffset, default: d.yOffset)
        width = try tomlDouble(c, forKey: .width, default: d.width)
        height = try tomlDouble(c, forKey: .height, default: d.height)
        cornerRadius = try tomlDouble(c, forKey: .cornerRadius, default: d.cornerRadius)
        paddingX = try tomlDouble(c, forKey: .paddingX, default: d.paddingX)
        paddingY = try tomlDouble(c, forKey: .paddingY, default: d.paddingY)
        outerPadding =
            try tomlDouble(c, forKey: .outerPadding, default: d.outerPadding)
        background = try c.decodeIfPresent(ThemeColor.self, forKey: .background) ?? d.background
        textColor = try c.decodeIfPresent(ThemeColor.self, forKey: .textColor) ?? d.textColor
        textFont = try c.decodeIfPresent(ThemeFont.self, forKey: .textFont) ?? d.textFont
    }
}

public struct KeyCastTheme: Decodable, Sendable {
    public let anchor: ThemeAnchor
    public let xOffset: Double
    public let yOffset: Double
    public let width: Double
    public let height: Double
    public let cornerRadius: Double
    public let paddingX: Double
    public let paddingY: Double
    public let background: ThemeColor
    public let textColor: ThemeColor
    public let borderColor: ThemeColor
    public let shadowColor: ThemeColor
    public let textFont: ThemeFont

    public init(
        anchor: ThemeAnchor = .top,
        xOffset: Double = 0,
        yOffset: Double = 12,
        width: Double = 240,
        height: Double = 48,
        cornerRadius: Double = 10,
        paddingX: Double = 18,
        paddingY: Double = 10,
        background: ThemeColor = .black,
        textColor: ThemeColor = .white,
        borderColor: ThemeColor = .init(red: 1, green: 1, blue: 1, alpha: 0.18),
        shadowColor: ThemeColor = .init(red: 0, green: 0, blue: 0, alpha: 0.55),
        textFont: ThemeFont = .init(size: 24, weight: .bold, design: .monospaced)
    ) {
        self.anchor = anchor
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.background = background
        self.textColor = textColor
        self.borderColor = borderColor
        self.shadowColor = shadowColor
        self.textFont = textFont
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchor, xOffset, yOffset, width, height, cornerRadius, paddingX, paddingY
        case background, textColor, borderColor, shadowColor, textFont
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.key_cast")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyCastTheme()
        anchor = try c.decodeIfPresent(ThemeAnchor.self, forKey: .anchor) ?? d.anchor
        xOffset = try tomlDouble(c, forKey: .xOffset, default: d.xOffset)
        yOffset = try tomlDouble(c, forKey: .yOffset, default: d.yOffset)
        width = try tomlDouble(c, forKey: .width, default: d.width)
        height = try tomlDouble(c, forKey: .height, default: d.height)
        cornerRadius = try tomlDouble(c, forKey: .cornerRadius, default: d.cornerRadius)
        paddingX = try tomlDouble(c, forKey: .paddingX, default: d.paddingX)
        paddingY = try tomlDouble(c, forKey: .paddingY, default: d.paddingY)
        background = try c.decodeIfPresent(ThemeColor.self, forKey: .background) ?? d.background
        textColor = try c.decodeIfPresent(ThemeColor.self, forKey: .textColor) ?? d.textColor
        borderColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .borderColor) ?? d.borderColor
        shadowColor =
            try c.decodeIfPresent(ThemeColor.self, forKey: .shadowColor) ?? d.shadowColor
        textFont = try c.decodeIfPresent(ThemeFont.self, forKey: .textFont) ?? d.textFont
    }
}

// MARK: - Friendly decode for theme enums
//
// Each of the theme's enum types overrides the auto-synthesized
// `init(from:)` with one that throws a `DecodingError` whose
// `debugDescription` lists every valid raw value. That message bubbles all
// the way out to the user via `SettingsWatcher`'s "Reload failed: …"
// toast — so a typo like `direction = "leftt"` produces a usable hint
// ("unknown direction value \"leftt\"; expected one of: left, right")
// instead of TOMLDecoder's terse "Cannot initialize ThemeDirection from
// invalid String value".

extension ThemeFont.Weight {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(Self.self, fieldName: "weight", decoder: decoder)
    }
}

extension ThemeFont.Design {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(Self.self, fieldName: "design", decoder: decoder)
    }
}

extension ThemeAnchor {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(Self.self, fieldName: "anchor", decoder: decoder)
    }
}

extension ThemeDirection {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(Self.self, fieldName: "direction", decoder: decoder)
    }
}

extension ThemeMaterial {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(Self.self, fieldName: "material", decoder: decoder)
    }
}
