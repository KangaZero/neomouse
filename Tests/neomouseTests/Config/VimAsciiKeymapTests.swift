import Testing

import neomouseConfig

/// The remappable-keybindings model. The first test is the **no-regression
/// proof**: the default keymap is the identity map, so every handler `case`
/// still matches its original char.
@Suite("VimAsciiKeymap")
struct VimAsciiKeymapTests {
    typealias Keymap = Config.VimAsciiKeymap

    @Test("default map is identity for every catalog key, nil stays nil")
    func defaultIsIdentity() {
        let km = Keymap()
        for entry in Keymap.catalog {
            #expect(km.canonical(forPhysical: entry.key) == entry.key)
            #expect(km[entry.key] == entry.key)
        }
        #expect(km.canonical(forPhysical: nil) == nil)
        #expect(km.toggleActivation == "e")
        #expect(km.overrides.isEmpty)
    }

    @Test("an override resolves the physical key to its canonical char")
    func overrideResolves() {
        let km = Keymap(overrides: ["j": "n"])
        #expect(km.canonical(forPhysical: "n") == "j")  // pressing "n" now does "down"
        #expect(km["j"] == "n")  // action "j" lives on physical "n"
        #expect(km.canonical(forPhysical: "x") == "x")  // unmapped → identity
    }

    @Test("remapping an action frees its default key (digits excepted for counts)")
    func remapFreesDefault() {
        let km = Keymap(overrides: ["j": "n"])
        #expect(km.canonical(forPhysical: "n") == "j")  // moved here
        #expect(km.canonical(forPhysical: "j") == nil)  // default freed — no longer "down"
        #expect(km.canonical(forPhysical: "k") == "k")  // untouched

        // Remapping line-start ("0") must NOT free physical 0 — it still feeds
        // the count buffer.
        let zero = Keymap(overrides: ["0": "z"])
        #expect(zero.canonical(forPhysical: "z") == "0")
        #expect(zero.canonical(forPhysical: "0") == "0")
    }

    @Test("swapping two canonical keys resolves both directions")
    func swapTwoActions() {
        let km = Keymap(overrides: ["j": "k", "k": "j"])
        #expect(km.canonical(forPhysical: "k") == "j")
        #expect(km.canonical(forPhysical: "j") == "k")
    }

    @Test("two actions bound to one physical key are reported as conflicts")
    func conflictsDetected() {
        let km = Keymap(overrides: ["h": "x", "j": "x"])
        #expect(km.conflictingCanonicalKeys() == ["h", "j"])
        #expect(Keymap().conflictingCanonicalKeys().isEmpty)
    }

    @Test("setBinding stores an override and clears back to identity")
    func setBindingRoundTrip() {
        var km = Keymap()
        km.setBinding(canonical: "h", physical: "x")
        #expect(km["h"] == "x")
        #expect(km.overrides["h"] == "x")
        km.setBinding(canonical: "h", physical: "h")  // identity clears the entry
        #expect(km.overrides["h"] == nil)
        #expect(km["h"] == "h")
    }

    @Test("digit targets are ignored (count-buffer protection); 0 is remappable")
    func digitTargetGuard() {
        #expect(Keymap.remappableKeys.contains("0"))  // line-start is rebindable
        #expect(Keymap.isForbiddenPhysical("5"))
        #expect(!Keymap.isForbiddenPhysical("x"))

        var km = Keymap()
        km.setBinding(canonical: "h", physical: "x")
        km.setBinding(canonical: "h", physical: "5")  // digit ignored
        #expect(km["h"] == "x")  // prior binding kept
    }
}
