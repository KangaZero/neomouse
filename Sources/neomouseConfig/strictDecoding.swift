import Foundation

// Strict-decoding helpers for settings.toml. We reject:
//
//   1. **Unknown keys** inside a `[theme.*]` section (e.g. `gutter_widht`)
//      with a message listing every valid key for that section.
//
//   2. **Unknown enum values** (e.g. `direction = "leftt"`, `anchor =
//      "toplefr"`, `material = "frosted"`) with a message listing every
//      valid choice.
//
// Goal: turn silent-drop typos into actionable startup / reload errors.
// `SettingsWatcher` surfaces the message via a toast ("Reload failed: …")
// so the user sees exactly what to fix without scraping the log.

// MARK: - Unknown-key validation

/// A `CodingKey` that round-trips any string. Used to enumerate every
/// actually-present key in a TOML section — the section's typed
/// `CodingKeys` enum would silently skip keys it doesn't know about, so we
/// can't enumerate unknowns that way.
public struct AnyCodingKey: CodingKey, Hashable {
    public let stringValue: String
    public let intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Reject any TOML key in `decoder`'s section that isn't declared in `K`.
/// Throws a friendly `DecodingError` listing the unknown keys and every
/// valid key in alphabetical order. Call this once at the top of each
/// section's `init(from:)` — before decoding individual fields — so the
/// error fires before any partial decode happens.
public func validateKnownKeys<K: CodingKey & CaseIterable>(
    decoder: any Decoder,
    keyedBy: K.Type,
    sectionName: String
) throws {
    let permissive = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowed = Set(K.allCases.map(\.stringValue))
    let given = permissive.allKeys.map(\.stringValue)
    let unknown = given.filter { !allowed.contains($0) }
    guard unknown.isEmpty else {
        // TOMLDecoder's `.convertFromSnakeCase` strategy maps TOML `x_offset`
        // to the Swift property `xOffset` before populating `allKeys` — so
        // the strings here are camelCase. The user wrote snake_case in their
        // settings.toml, so we display snake_case in the message to match.
        let unknownList = unknown.sorted().map { "\"\(toSnakeCase($0))\"" }.joined(separator: ", ")
        let allowedList = allowed.sorted().map(toSnakeCase).joined(separator: ", ")
        // Surface the first unknown key in `forKey:` so the error path is
        // meaningful (e.g. `theme.numbersOverlay.gutter_widht`).
        let key =
            permissive.allKeys.first { unknown.contains($0.stringValue) }
            ?? AnyCodingKey(stringValue: unknown[0])
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: permissive,
            debugDescription:
                "unknown key(s) in [\(sectionName)]: \(unknownList). Valid keys: \(allowedList)."
        )
    }
}

// MARK: - Unknown-enum-value validation

/// Convert camelCase to snake_case for user-facing error messages. Matches
/// how the user authors keys in their TOML (`xOffset` → `x_offset`,
/// `cursorSurroundedBoxSize` → `cursor_surrounded_box_size`).
public func toSnakeCase(_ camel: String) -> String {
    var result = ""
    for char in camel {
        if char.isUppercase {
            if !result.isEmpty { result += "_" }
            result += char.lowercased()
        } else {
            result += String(char)
        }
    }
    return result
}

/// Decode a `String`-raw-value enum from a single-value container with a
/// friendly error message listing every valid case when the raw value
/// doesn't match. Use as the body of a custom `init(from:)` on the enum so
/// Swift's auto-synthesized init (which throws a generic
/// "Cannot initialize X from invalid String value …") is overridden.
public func decodeFriendlyEnum<E: RawRepresentable & CaseIterable>(
    _ type: E.Type, fieldName: String, decoder: any Decoder
) throws -> E where E.RawValue == String {
    let c = try decoder.singleValueContainer()
    let raw = try c.decode(String.self)
    if let value = E(rawValue: raw) {
        return value
    }
    let allowed = E.allCases.map { String(describing: $0.rawValue) }.sorted().joined(separator: ", ")
    throw DecodingError.dataCorruptedError(
        in: c,
        debugDescription:
            "unknown \(fieldName) value \"\(raw)\"; expected one of: \(allowed)"
    )
}
