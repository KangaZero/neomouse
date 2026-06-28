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

    @Test("[keymaps] decodes overrides + toggle_activation")
    func keymapsDecode() throws {
        let c = try Config.loadConfig(
            from: tomlURL(Self.base + "\n[keymaps]\ntoggle_activation = \"q\"\nj = \"n\"\n"))
        #expect(c.keymaps?.toggleActivation == "q")
        #expect(c.keymaps?.overrides["j"] == "n")
        #expect(c.keymaps?.canonical(forPhysical: "n") == "j")
    }

    @Test("absent [keymaps] decodes as nil")
    func keymapsAbsent() throws {
        #expect(try Config.loadConfig(from: tomlURL(Self.base)).keymaps == nil)
    }

    @Test("unknown keymaps entry is rejected")
    func keymapsUnknownKey() {
        #expect(throws: Config.LoadError.self) {
            try Config.loadConfig(from: tomlURL(Self.base + "\n[keymaps]\nnope = \"x\"\n"))
        }
    }

    @Test("multi-char keymaps value is rejected")
    func keymapsMultiChar() {
        #expect(throws: Config.LoadError.self) {
            try Config.loadConfig(from: tomlURL(Self.base + "\n[keymaps]\nj = \"nn\"\n"))
        }
    }

    @Test("binding an action onto a digit key is rejected")
    func keymapsDigitTarget() {
        #expect(throws: Config.LoadError.self) {
            try Config.loadConfig(from: tomlURL(Self.base + "\n[keymaps]\nh = \"5\"\n"))
        }
    }

    @Test("a malformed-TOML load error reads cleanly (no raw DecodingError dump)")
    func malformedTomlErrorIsReadable() {
        do {
            _ = try Config.loadConfig(from: tomlURL(Self.base + "\nthis is not valid toml\n"))
            Issue.record("expected a decode failure")
        } catch let error as Config.LoadError {
            let message = "\(error)"
            #expect(message.hasPrefix("Invalid TOML in"))
            // None of the noisy raw-DecodingError wrapping should leak through.
            #expect(!message.contains("DecodingError"))
            #expect(!message.contains("Debug description"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("the shipped settings.toml decodes; its [keymaps] is the identity default")
    func shippedSettingsTomlDecodes() throws {
        // Path relative to this source file → cwd-independent.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Config
            .deletingLastPathComponent()  // neomouseTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let c = try Config.loadConfig(from: root.appendingPathComponent("settings.toml"))
        #expect(c.keymaps?.toggleActivation == "e")
        // Every shipped binding is at its default → no overrides stored.
        #expect(c.keymaps?.overrides.isEmpty == true)
    }
}
