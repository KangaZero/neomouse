import Foundation
import Testing

import neomouseConfig

/// End-to-end decode of `settings.toml` through `Config.loadConfig(from:)`:
/// the happy path, the `tomlDouble` int/float coercion, theme overrides vs
/// defaults, and the strict-validation failure modes (unknown keys, invalid
/// enum values). Each case writes a TOML string to a temp file and loads it,
/// exercising the real entry point rather than a decoder shim.
@Suite("Config TOML decoding + strict validation")
struct ConfigDecodingTests {
    /// A complete, valid config covering every required (non-defaulted)
    /// section. Theme blocks are appended per-test.
    static let base = """
        [grid]
        inset = 10
        divisions = 5
        inner_divisions = 3
        find_mode_characters = "abc"
        find_mode_inner_characters = "abc"
        is_always_show_inner_characters = true

        [motion]
        rows_on_screen = "automatic"
        columns_on_screen = 10
        is_clamp_cursor_to_current_screen = false

        [visual]
        minimum_highlight_width = 5

        [gesture]
        zoom_step_value = 0.1
        increments_per_gesture = 5
        degrees_to_rotate = 90

        [commands]
        available = ["numbers", "help"]

        [configuration]
        """

    private func tomlURL(_ toml: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neomouse-test-\(UUID().uuidString).toml")
        try! toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("happy path decodes required sections + Configuration defaults")
    func happyPath() throws {
        let c = try Config.loadConfig(from: tomlURL(Self.base))
        #expect(c.grid.divisions == 5)
        #expect(c.motion.rowsOnScreen == .automatic)
        #expect(c.motion.columnsOnScreen == .explicit(10))
        // [configuration] is present but empty → every field is its default.
        #expect(c.configuration.isAutoSnap == Config.Configuration.defaultIsAutoSnap)
        #expect(c.configuration.modeOnStart == .normal)
        // No [theme] section → theme is nil (consumer falls back to Theme()).
        #expect(c.theme == nil)
    }

    @Test("tomlDouble coerces an integer literal into a Double theme field")
    func tomlDoubleIntegerCoercion() throws {
        let c = try Config.loadConfig(from: tomlURL(Self.base + "\n[theme.toast]\nwidth = 300\n"))
        // `width = 300` is a TOML Integer, not 300.0 — tomlDouble must accept it.
        #expect(c.theme?.toast.width == 300)
        // Unspecified theme field keeps its default.
        #expect(c.theme?.toast.anchor == .topRight)
    }

    @Test("theme override applies; sibling fields keep defaults")
    func themeOverride() throws {
        let c = try Config.loadConfig(
            from: tomlURL(Self.base + "\n[theme.numbers_overlay]\ndirection = \"right\"\n"))
        #expect(c.theme?.numbersOverlay.direction == .right)
        #expect(c.theme?.numbersOverlay.columnStripDirection == .top)
    }

    @Test("a theme color field decodes from a hex string")
    func themeColorFromTOML() throws {
        let c = try Config.loadConfig(
            from: tomlURL(Self.base + "\n[theme.visual_highlight]\nfill = \"#ff0000\"\n"))
        #expect(c.theme?.visualHighlight.fill == ThemeColor(red: 1, green: 0, blue: 0, alpha: 1))
    }

    @Test("strict validation rejects an unknown key in [configuration]")
    func rejectsUnknownKey() {
        #expect(throws: Config.LoadError.self) {
            try Config.loadConfig(from: tomlURL(Self.base + "bogus_key = true\n"))
        }
    }

    @Test("an invalid enum value surfaces a decode error")
    func rejectsInvalidEnum() {
        #expect(throws: Config.LoadError.self) {
            try Config.loadConfig(
                from: tomlURL(Self.base + "\n[theme.numbers_overlay]\ndirection = \"leftt\"\n"))
        }
    }
}
