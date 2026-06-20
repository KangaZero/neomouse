import Testing

import neomouseConfig

/// `ThemeColor.parse` is the pure hex → 0..1 RGBA decoder behind every
/// `[theme.*]` color field. Accepts `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`
/// with an optional leading `#`; returns nil for anything else.
@Suite("ThemeColor hex parsing")
struct ThemeColorTests {
    @Test("#rrggbb → channels in 0..1, alpha defaults to 1")
    func sixDigit() {
        let c = ThemeColor.parse(hex: "#ff0000")
        #expect(c?.red == 1)
        #expect(c?.green == 0)
        #expect(c?.blue == 0)
        #expect(c?.alpha == 1)
    }

    @Test("leading # is optional")
    func noHash() {
        #expect(ThemeColor.parse(hex: "00ff00")?.green == 1)
    }

    @Test("#rrggbbaa decodes the alpha byte")
    func eightDigit() {
        let c = ThemeColor.parse(hex: "#00000080")
        #expect(c?.alpha == Double(0x80) / 255)
    }

    @Test("#rgb shorthand expands each nibble to a byte")
    func threeDigit() {
        let c = ThemeColor.parse(hex: "#f00")
        #expect(c?.red == 1)
        #expect(c?.green == 0)
        #expect(c?.blue == 0)
    }

    @Test("#rgba shorthand expands alpha too")
    func fourDigit() {
        let c = ThemeColor.parse(hex: "#f00f")
        #expect(c?.red == 1)
        #expect(c?.alpha == 1)
    }

    @Test("malformed hex returns nil", arguments: ["zzzzzz", "#12", "#12345", "", "#"])
    func invalid(_ bad: String) {
        #expect(ThemeColor.parse(hex: bad) == nil)
    }

    @Test(".hex falls back to black on invalid input")
    func hexFallbackToBlack() {
        #expect(ThemeColor.hex("nonsense") == .black)
        #expect(ThemeColor.hex("#ffffff") == .white)
    }
}
