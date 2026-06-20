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
//
// Module-internal (not file-private) because both the primitives below and
// the per-element themes in ElementThemes.swift decode Double fields with it.
func tomlDouble<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>, forKey key: K, default d: Double
) throws -> Double {
    guard c.contains(key) else { return d }
    if let i = try? c.decode(Int.self, forKey: key) { return Double(i) }
    return try c.decode(Double.self, forKey: key)
}

// MARK: - Shared primitives

/// 0..1 RGBA. Decoded from a hex string in TOML: `"#rrggbb"`, `"#rrggbbaa"`,
/// `"#rgb"`, or `"#rgba"` — the `#` is optional. Out-of-format values throw
/// a TOML decoding error at load time.
public struct ThemeColor: Decodable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

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
    public var family: String
    public var size: Double
    public var weight: Weight
    public var design: Design

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

/// Side of the screen for the NumbersOverlay gutter.
public enum ThemeDirection: String, Decodable, Sendable, CaseIterable {
    case left
    case right
}

/// Side of the screen for the NumbersOverlay column strip.
public enum ThemeVerticalDirection: String, Decodable, Sendable, CaseIterable {
    case top
    case bottom
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

extension ThemeVerticalDirection {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(
            Self.self, fieldName: "column_strip_direction", decoder: decoder)
    }
}

extension ThemeMaterial {
    public init(from decoder: any Decoder) throws {
        self = try decodeFriendlyEnum(Self.self, fieldName: "material", decoder: decoder)
    }
}
