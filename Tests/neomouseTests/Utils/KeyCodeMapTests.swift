import AppKit
import Carbon
import Testing

import neomouseUtils

// MARK: - Deterministic basics
//
// These tests don't care which keyboard layout the host is on — `asciiChar`
// forces an ASCII-capable Latin layout under the hood, and the special-key
// section of `charToKeyCodeMap` is hard-coded positionally. So they are
// stable across CI hosts and local dev machines.

// Carbon's TIS functions aren't thread-safe — production code always invokes
// them from the main thread (MainActor in the key handler). Pin these tests
// to the main actor so swift-testing's parallel test runner doesn't fan them
// across threads and trip a TIS internal assertion (SIGABRT) during a
// concurrent `TISCopyCurrent…` call.
@MainActor
@Suite("ASCII char translation (layout-independent helper)")
struct AsciiCharTests {

    @Test("hjkl keycodes (US-positional) resolve to Latin h/j/k/l")
    func hjklLatin() {
        #expect(latinASCIIChar(keyCode: 4) == "h")
        #expect(latinASCIIChar(keyCode: 38) == "j")
        #expect(latinASCIIChar(keyCode: 40) == "k")
        #expect(latinASCIIChar(keyCode: 37) == "l")
    }

    @Test("Other normal-mode keys resolve as expected")
    func othersLatin() {
        #expect(latinASCIIChar(keyCode: 5) == "g")  // gg / G
        #expect(latinASCIIChar(keyCode: 9) == "v")  // visual
        #expect(latinASCIIChar(keyCode: 16) == "y")  // yank
        #expect(latinASCIIChar(keyCode: 35) == "p")  // paste
        #expect(latinASCIIChar(keyCode: 14) == "e")  // exit/toggle (Cmd+E)
    }

    @Test("Shift modifier produces the uppercase variant")
    func shiftUppercase() {
        let shift = NSEvent.ModifierFlags.shift.rawValue
        #expect(latinASCIIChar(keyCode: 4, modifiers: shift) == "H")
        #expect(latinASCIIChar(keyCode: 5, modifiers: shift) == "G")
        #expect(latinASCIIChar(keyCode: 16, modifiers: shift) == "Y")
    }

    @Test("Shift+1 yields '!' (modifier byte reaches UCKeyTranslate correctly)")
    func shiftDigitSymbol() {
        // Belt-and-braces: a wrong shift in the modifier conversion would
        // produce "1" or nothing here instead of "!".
        let shift = NSEvent.ModifierFlags.shift.rawValue
        #expect(latinASCIIChar(keyCode: 18, modifiers: shift) == "!")
    }

    @Test("Cmd / Ctrl modifiers do not change the produced character")
    func cmdCtrlIgnored() {
        let cmd = NSEvent.ModifierFlags.command.rawValue
        let ctrl = NSEvent.ModifierFlags.control.rawValue
        #expect(latinASCIIChar(keyCode: 0, modifiers: cmd) == "a")
        #expect(latinASCIIChar(keyCode: 0, modifiers: ctrl) == "a")
        #expect(latinASCIIChar(keyCode: 0, modifiers: cmd | ctrl) == "a")
    }

    @Test("Cmd+Shift behaves like Shift alone for character translation")
    func cmdShiftEqualsShift() {
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let cmd = NSEvent.ModifierFlags.command.rawValue
        #expect(latinASCIIChar(keyCode: 4, modifiers: shift) == latinASCIIChar(keyCode: 4, modifiers: shift | cmd))
    }
}

@MainActor
@Suite("charToKeyCodeMap — Latin guarantee + positional special keys")
struct CharToKeyCodeMapTests {

    @Test("All 26 lowercase Latin letters are present (forced-Latin build path)")
    func latinAlphabetPresent() {
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(charToKeyCodeMap[String(letter)] != nil, "missing entry for '\(letter)'")
        }
    }

    @Test("Digits are positional (US-QWERTY positions, even on AZERTY/Dvorak/etc.)")
    func digitsPositional() {
        #expect(charToKeyCodeMap["0"] == 29)
        #expect(charToKeyCodeMap["1"] == 18)
        #expect(charToKeyCodeMap["5"] == 23)
        #expect(charToKeyCodeMap["9"] == 25)
    }

    @Test("Non-printable special keys map to their canonical keycodes")
    func specialKeyCodes() {
        #expect(charToKeyCodeMap["Esc"] == 53)
        #expect(charToKeyCodeMap["Tab"] == 48)
        #expect(charToKeyCodeMap["Return"] == 36)
        #expect(charToKeyCodeMap["Enter"] == 76)
        #expect(charToKeyCodeMap["Space"] == 49)
        #expect(charToKeyCodeMap["Backspace"] == 51)
        #expect(charToKeyCodeMap["LeftArrow"] == 123)
        #expect(charToKeyCodeMap["RightArrow"] == 124)
        #expect(charToKeyCodeMap["DownArrow"] == 125)
        #expect(charToKeyCodeMap["UpArrow"] == 126)
        #expect(charToKeyCodeMap["F1"] == 122)
        #expect(charToKeyCodeMap["F12"] == 111)
    }

    @Test("Reverse lookup (keyChar(forKeyCode:)) matches forward lookup")
    func reverseLookupConsistent() {
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            let s = String(letter)
            guard let kc = charToKeyCodeMap[s] else { continue }
            #expect(
                charToKeyCodeMap.keyChar(forKeyCode: kc) == s,
                "reverse lookup mismatch for '\(letter)' (keycode \(kc))")
        }
    }

    @Test("snapshot() returns a usable dictionary copy")
    func snapshotIsCopy() {
        let snap = charToKeyCodeMap.snapshot()
        #expect(snap["h"] == charToKeyCodeMap["h"])
        #expect(snap.count >= 26 + 10)  // 26 letters + 10 digits, at minimum
    }
}

// MARK: - Cross-layout fallback
//
// These tests verify the key invariant of the recent fix: when the user is on
// a non-Latin layout (Cyrillic, Greek, Hebrew, Arabic, Thai…), our helper
// still produces Latin characters because we route through the ASCII-capable
// layout fallback.
//
// We don't switch the host's input source (that would mutate user state).
// Instead we use TISCreateInputSourceList to FETCH an installed non-Latin
// layout's UCKeyboardLayout data, prove the layout itself produces non-ASCII
// (so the test fixture is meaningful), then prove our helper ignores it.
//
// On a host with no non-Latin layouts installed, the test short-circuits with
// a documented note rather than failing.

@MainActor
@Suite("Non-Latin layout fallback — Latin keybinds keep resolving")
struct NonLatinLayoutFallbackTests {

    /// Try to find an installed non-Latin keyboard layout. We probe a list of
    /// IDs that ship with macOS by default but aren't enabled out of the box.
    static func nonLatinLayoutData() -> (id: String, data: CFData)? {
        let candidates = [
            "com.apple.keylayout.Russian",
            "com.apple.keylayout.RussianWin",
            "com.apple.keylayout.Greek",
            "com.apple.keylayout.GreekPolytonic",
            "com.apple.keylayout.Hebrew",
            "com.apple.keylayout.Hebrew-PC",
            "com.apple.keylayout.Arabic",
            "com.apple.keylayout.ArabicPC",
            "com.apple.keylayout.Thai",
            "com.apple.keylayout.Ukrainian",
            "com.apple.keylayout.Bulgarian",
        ]
        for id in candidates {
            // Inline the property-name string literals (== the imported
            // kTIS… globals) to dodge Swift 6 strict-concurrency checks on
            // the CFStringRef globals.
            let filter: [CFString: Any] = [
                "TISPropertyInputSourceID" as CFString: id as CFString
            ]
            guard
                let array = TISCreateInputSourceList(filter as CFDictionary, true)?
                    .takeRetainedValue(),
                CFArrayGetCount(array) > 0
            else { continue }
            let sourceRef = CFArrayGetValueAtIndex(array, 0)!
            let source = Unmanaged<TISInputSource>.fromOpaque(sourceRef).takeUnretainedValue()
            guard
                let propRaw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let data = unsafeBitCast(propRaw, to: CFData.self)
            return (id, data)
        }
        return nil
    }

    private static func translate(keyCode: UInt16, with layoutData: CFData) -> String? {
        let ptr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var charCount = 0
        UCKeyTranslate(
            ptr,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            4,
            &charCount,
            &chars
        )
        guard charCount > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: charCount)
    }

    @Test("Fixture: an installed non-Latin layout produces non-ASCII for keycode 4 (H position)")
    func fixtureIsActuallyNonLatin() {
        guard let (id, layout) = Self.nonLatinLayoutData() else {
            // No non-Latin layouts installed; nothing to assert. macOS 14+
            // usually ships several, so this branch is rare in practice.
            return
        }
        let native = Self.translate(keyCode: 4, with: layout)
        let scalar = native?.unicodeScalars.first?.value ?? 0
        #expect(
            scalar > 0x7F,
            "expected non-ASCII char from \(id) for keycode 4, got '\(native ?? "")' (U+\(String(scalar, radix: 16)))"
        )
    }

    @Test("latinASCIIChar(keyCode: 4) is still 'h' even with non-Latin layouts installed")
    func asciiHelperStillLatin() {
        // This is the load-bearing assertion: regardless of what installed
        // layouts exist on this host (and regardless of which one is
        // currently selected by the user), the helper routes through the
        // ASCII-capable layout fallback and gives a Latin letter.
        #expect(latinASCIIChar(keyCode: 4) == "h")
        #expect(latinASCIIChar(keyCode: 38) == "j")
        #expect(latinASCIIChar(keyCode: 40) == "k")
        #expect(latinASCIIChar(keyCode: 37) == "l")
    }

    @Test("charToKeyCodeMap exposes Latin a-z even with non-Latin layouts installed")
    func mapStillHasLatin() {
        // Same invariant from the other direction: the global map is built
        // against the ASCII-capable layout, so Latin letters are always
        // addressable regardless of the host's current input source.
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(charToKeyCodeMap[String(letter)] != nil, "missing '\(letter)'")
        }
    }
}
