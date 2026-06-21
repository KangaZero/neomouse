import Foundation

import neomouseUtils

extension Config {
    /// User-remappable Vim keybindings, keyed by the **canonical** US-ASCII Vim
    /// character (e.g. `"h"`, `"$"`, `" "`). A value is the *physical* key the
    /// user must press to trigger that canonical action. The dispatch layer
    /// resolves the pressed physical key back to its canonical char exactly
    /// once (`canonical(forPhysical:)`), so every hardcoded `case "h":` in the
    /// handlers keeps working — `h` is still "motion-left", just possibly on a
    /// different physical key.
    ///
    /// The map is keyed by canonical char (not by action) on purpose:
    /// canonicalization is char-level, so a char with several context-dependent
    /// meanings (e.g. `d` = delete *and* scroll-down) moves together when
    /// rebound — matching Vim's "rebind the key, all its meanings follow".
    ///
    /// Default == identity: an empty `overrides` map (and `toggleActivation`
    /// "e") reproduces today's behavior byte-for-byte. Optional in `Config`, so
    /// a settings.toml without `[keymaps]` decodes unchanged.
    public struct VimAsciiKeymap: Decodable, Sendable, Equatable {
        /// canonical char -> physical char. Only non-identity entries stored.
        public var overrides: [String: String]
        /// Activation/deactivation chord key (pressed with ⌘). Default "e" (⌘E).
        public var toggleActivation: String

        public static let defaultToggleActivation = "e"

        public init(
            overrides: [String: String] = [:],
            toggleActivation: String = VimAsciiKeymap.defaultToggleActivation
        ) {
            self.overrides = overrides
            self.toggleActivation = toggleActivation
        }

        // MARK: - Catalog (the remappable canonical keys)

        public enum Group: String, Sendable, CaseIterable {
            case motion = "Motion"
            case modes = "Modes"
            case marksRegisters = "Marks & Registers"
            case scroll = "Scroll"
            case gestures = "Gestures"
        }

        public struct Entry: Sendable {
            public let key: String
            public let label: String
            public let group: Group
        }

        /// Source of truth for which canonical keys are remappable (letters +
        /// symbols; digits 0-9 and the keyCode-based special keys are fixed),
        /// plus display labels/grouping for the Settings editor. Order = UI order.
        public static let catalog: [Entry] = [
            // Motion
            .init(key: "h", label: "Move left", group: .motion),
            .init(key: "j", label: "Move down", group: .motion),
            .init(key: "k", label: "Move up", group: .motion),
            .init(key: "l", label: "Move right", group: .motion),
            .init(key: "0", label: "Move to line start", group: .motion),
            .init(key: "$", label: "Move to line end", group: .motion),
            .init(key: "|", label: "Move to column (N|)", group: .motion),
            .init(key: "M", label: "Move to vertical middle", group: .motion),
            .init(key: "G", label: "Bottom of screen / Nth row", group: .motion),
            .init(key: "g", label: "g-prefix (gg / gm / gv)", group: .motion),
            .init(key: "m", label: "Set mark / gm middle", group: .motion),
            // Modes
            .init(key: "f", label: "Find mode", group: .modes),
            .init(key: "F", label: "Quick find (N-grid)", group: .modes),
            .init(key: "v", label: "Visual mode", group: .modes),
            .init(key: "V", label: "Visual line mode", group: .modes),
            .init(key: ":", label: "Command line", group: .modes),
            .init(key: "?", label: "Toggle help", group: .modes),
            .init(key: " ", label: "Special prefix (scroll/window/find)", group: .modes),
            .init(key: "w", label: "Window (after special)", group: .modes),
            .init(key: "s", label: "Snap to grid", group: .modes),
            // Marks & Registers
            .init(key: "'", label: "Go to mark", group: .marksRegisters),
            .init(key: "`", label: "Go to mark (restore visual)", group: .marksRegisters),
            .init(key: "\"", label: "Register prefix", group: .marksRegisters),
            .init(key: "y", label: "Yank", group: .marksRegisters),
            .init(key: "Y", label: "Yank (upper)", group: .marksRegisters),
            .init(key: "p", label: "Paste from register", group: .marksRegisters),
            .init(key: "P", label: "Paste (upper)", group: .marksRegisters),
            .init(key: "d", label: "Delete / scroll down", group: .marksRegisters),
            .init(key: "D", label: "Delete (upper)", group: .marksRegisters),
            // Scroll
            .init(key: "u", label: "Scroll up (special-u)", group: .scroll),
            .init(key: "U", label: "Scroll up (upper)", group: .scroll),
            .init(key: "H", label: "Scroll right", group: .scroll),
            .init(key: "J", label: "Scroll down", group: .scroll),
            .init(key: "K", label: "Scroll up", group: .scroll),
            .init(key: "L", label: "Scroll left", group: .scroll),
            .init(key: "W", label: "Window/scroll (upper)", group: .scroll),
            // Gestures
            .init(key: "r", label: "Rotate clockwise", group: .gestures),
            .init(key: "R", label: "Rotate counter-clockwise", group: .gestures),
            .init(key: "+", label: "Zoom in", group: .gestures),
            .init(key: "-", label: "Zoom out", group: .gestures),
            .init(key: "S", label: "Smart magnify", group: .gestures),
            .init(key: "o", label: "Swap visual corner", group: .gestures),
            .init(key: "O", label: "Swap visual corner (diagonal)", group: .gestures),
        ]

        public static let remappableKeys: Set<String> = Set(catalog.map(\.key))

        // MARK: - Resolution

        /// Physical key the user presses for a canonical action (identity when
        /// unmapped). Mirrors the user's `vimAsciiKeyMap["h"]` mental model.
        public subscript(canonical: String) -> String { overrides[canonical] ?? canonical }

        /// Reverse: the canonical Vim char for a pressed physical key.
        ///
        /// - An action explicitly bound to this key → that action.
        /// - A key whose action was remapped *away* → `nil` (the default no
        ///   longer fires — remapping moves the action, it doesn't duplicate it).
        ///   Exception: digit keys are never freed, since physical `0`–`9` feed
        ///   the normal-mode count buffer (`10j`).
        /// - Otherwise identity — so the DEFAULT (empty) map returns the input
        ///   unchanged (== today's behavior), and a non-printable key stays `nil`.
        public func canonical(forPhysical physical: String?) -> String? {
            guard let physical else { return nil }
            // overrides is tiny (usually empty); a scan is cheaper than caching.
            for (canon, phys) in overrides where phys == physical { return canon }
            // This key is a canonical action that's been moved elsewhere → freed.
            if overrides[physical] != nil, !Self.isForbiddenPhysical(physical) { return nil }
            return physical
        }

        /// Canonical keys whose chosen physical key collides with another
        /// canonical's (ambiguous remap). `m`/`d` etc. that legitimately share a
        /// char by *default* are NOT reported (identity entries aren't stored).
        public func conflictingCanonicalKeys() -> Set<String> {
            var seen: [String: String] = [:]  // physical -> first canonical
            var conflicts: Set<String> = []
            for (canon, phys) in overrides {
                if let first = seen[phys] {
                    conflicts.insert(canon)
                    conflicts.insert(first)
                } else {
                    seen[phys] = canon
                }
            }
            return conflicts
        }

        /// UI helper: set (or clear, when identity) the physical key for a
        /// canonical action. Digit targets are ignored (they collide with the
        /// count buffer), leaving the prior binding untouched.
        public mutating func setBinding(canonical: String, physical: String) {
            guard !Self.isForbiddenPhysical(physical) else {
                debug("VimAsciiKeymap.setBinding: ignored digit target \"\(physical)\" for \"\(canonical)\"")
                return
            }
            if physical == canonical || physical.isEmpty {
                overrides[canonical] = nil
                debug("VimAsciiKeymap.setBinding: reset \"\(canonical)\" to its default key")
            } else {
                overrides[canonical] = physical
                debug("VimAsciiKeymap.setBinding: bound \"\(canonical)\" → physical \"\(physical)\"")
            }
        }

        /// A physical key an action must not bind to. Bare digits drive the
        /// normal-mode count buffer, so rebinding a motion onto one would
        /// corrupt counts like `5j` / `3gg`.
        public static func isForbiddenPhysical(_ key: String) -> Bool {
            key.count == 1 && (key.first?.isNumber ?? false)
        }

        // MARK: - Decoding (strict)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            var overrides: [String: String] = [:]
            var toggle = Self.defaultToggleActivation
            for codingKey in c.allKeys {
                let name = codingKey.stringValue  // already camelCased by the decoder
                let value = try c.decode(String.self, forKey: codingKey)
                if name == "toggleActivation" {
                    guard value.count == 1 else {
                        throw DecodingError.dataCorruptedError(
                            forKey: codingKey, in: c,
                            debugDescription:
                                "keymaps.toggle_activation must be a single character, got \"\(value)\"")
                    }
                    toggle = value
                    continue
                }
                guard Self.remappableKeys.contains(name) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: codingKey, in: c,
                        debugDescription:
                            "unknown keymaps entry \"\(toSnakeCase(name))\"; remappable keys are the single Vim characters in the catalog (digits and special keys are fixed)"
                    )
                }
                guard value.count == 1 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: codingKey, in: c,
                        debugDescription:
                            "keymaps.\(toSnakeCase(name)) must be a single character, got \"\(value)\"")
                }
                if value == name { continue }  // identity → no override
                guard !Self.isForbiddenPhysical(value) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: codingKey, in: c,
                        debugDescription:
                            "keymaps.\(toSnakeCase(name)) cannot be bound to a digit key — digits drive the normal-mode count buffer (5j, 3gg)"
                    )
                }
                overrides[name] = value
            }
            self.overrides = overrides
            self.toggleActivation = toggle
        }
    }
}
