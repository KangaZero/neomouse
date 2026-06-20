import CoreGraphics
import Foundation

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
    public var background: ThemeColor
    public var outerLineColor: ThemeColor
    public var outerLabelColor: ThemeColor
    public var outerLabelFont: ThemeFont
    public var innerLineColor: ThemeColor
    public var innerFaintLineColor: ThemeColor
    public var innerLabelColor: ThemeColor
    public var innerLabelFont: ThemeFont
    /// CursorSurroundedGridOverlay-specific: box edge length in points.
    public var cursorSurroundedBoxSize: Double
    /// CursorSurroundedGridOverlay-specific: cells per axis.
    public var cursorSurroundedDivisions: Int
    /// CursorSurroundedGridOverlay-specific: label font (denser cells need
    /// smaller text than GridOverlay's outer labels).
    public var cursorSurroundedLabelFont: ThemeFont

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
    /// Side the line-number gutter sits on.
    public var direction: ThemeDirection
    /// Side the column-number strip sits on. `.top` = original behavior.
    public var columnStripDirection: ThemeVerticalDirection
    public var gutterBackground: ThemeColor
    public var cursorLineHighlight: ThemeColor
    public var cursorColumnHighlight: ThemeColor
    public var cursorTextColor: ThemeColor
    public var textColor: ThemeColor
    /// Font size is auto-scaled to row height; this defines weight + design + family only.
    public var font: ThemeFont
    public var gutterWidth: Double
    public var columnStripHeight: Double

    public init(
        direction: ThemeDirection = .left,
        columnStripDirection: ThemeVerticalDirection = .top,
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
        self.columnStripDirection = columnStripDirection
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
        case direction, columnStripDirection, gutterBackground, cursorLineHighlight
        case cursorColumnHighlight, cursorTextColor, textColor, font, gutterWidth, columnStripHeight
    }

    public init(from decoder: any Decoder) throws {
        try validateKnownKeys(
            decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme.numbers_overlay")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NumbersOverlayTheme()
        direction = try c.decodeIfPresent(ThemeDirection.self, forKey: .direction) ?? d.direction
        columnStripDirection =
            try c.decodeIfPresent(ThemeVerticalDirection.self, forKey: .columnStripDirection)
            ?? d.columnStripDirection
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
    public var anchor: ThemeAnchor
    public var xOffset: Double
    public var yOffset: Double
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var textFont: ThemeFont
    public var textColor: ThemeColor
    public var prefixColor: ThemeColor
    public var suggestionFont: ThemeFont
    public var suggestionTextColor: ThemeColor
    public var suggestionHighlight: ThemeColor
    public var material: ThemeMaterial

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
    public var anchor: ThemeAnchor
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var material: ThemeMaterial
    public var headerFont: ThemeFont
    public var markLabelFont: ThemeFont
    public var cellFont: ThemeFont
    public var emptyMessageFont: ThemeFont
    public var selectedRowBackground: ThemeColor
    public var rowPaddingX: Double
    public var rowPaddingY: Double

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
    public var anchor: ThemeAnchor
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var material: ThemeMaterial
    public var cardWidth: Double
    public var cardHeight: Double
    public var cardPaddingX: Double
    public var cardPaddingY: Double
    public var viewPadding: Double
    public var searchFont: ThemeFont
    public var appNameFont: ThemeFont
    public var registerLabelFont: ThemeFont
    public var cardTextFont: ThemeFont
    public var badgeFont: ThemeFont
    public var registerBadgeBackground: ThemeColor
    public var selectedCardBorder: ThemeColor
    public var unselectedCardBorder: ThemeColor
    public var cardShadowSelected: ThemeColor
    public var cardShadowUnselected: ThemeColor
    public var contentBackground: ThemeColor

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
    public var anchor: ThemeAnchor
    public var width: Double
    public var height: Double
    public var padding: Double
    public var headerColor: ThemeColor
    public var headerFont: ThemeFont
    public var keybindFont: ThemeFont
    public var descriptionColor: ThemeColor

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
    public var fill: ThemeColor

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
    public var anchor: ThemeAnchor
    public var xOffset: Double
    public var yOffset: Double
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var paddingX: Double
    public var paddingY: Double
    public var outerPadding: Double
    public var background: ThemeColor
    public var textColor: ThemeColor
    public var textFont: ThemeFont

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
    public var anchor: ThemeAnchor
    public var xOffset: Double
    public var yOffset: Double
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var paddingX: Double
    public var paddingY: Double
    public var background: ThemeColor
    public var textColor: ThemeColor
    public var borderColor: ThemeColor
    public var shadowColor: ThemeColor
    public var textFont: ThemeFont

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
