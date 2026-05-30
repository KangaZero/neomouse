import AppKit
import Carbon
import Foundation

/// Resolve the Unicode key-layout data we should translate keycodes against.
///
/// - Prefers the user's current input source.
/// - Falls back to `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` when
///   the current source has no UnicodeKeyLayoutData. That happens for input
///   methods (Pinyin / Hangul / Kotoeri / Vietnamese …) and for layouts that
///   only ship the legacy KCHR resource. The ASCII-capable source is always a
///   Latin layout (typically US or ABC) so Latin keybinds keep resolving.
///
/// This DOES NOT translate non-Latin layouts (Cyrillic, Greek, Hebrew, Arabic,
/// Thai) into Latin. On those layouts the source itself returns valid
/// UnicodeKeyLayoutData — UCKeyTranslate will hand back the native-script
/// character. If we want neomouse keybinds to keep working on those layouts,
/// callers that build a Latin-keyed map should pass `forceLatin: true`.
private func currentKeyLayoutData(forceLatin: Bool = false) -> CFData? {
    if !forceLatin {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let p = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            return unsafeBitCast(p, to: CFData.self)
        }
    }
    let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
    guard let p = TISGetInputSourceProperty(ascii, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    return unsafeBitCast(p, to: CFData.self)
}

/// Translate a keycode + modifier bitmap against the chosen layout. `modifiers`
/// follows the Carbon convention (bits 8..15 of NSEvent.ModifierFlags.rawValue);
/// pass 0 for "unmodified character produced by this physical key."
private func translate(
    keyCode: UInt16,
    modifiers: UInt32 = 0,
    forceLatin: Bool = false
) -> String? {
    guard let layoutData = currentKeyLayoutData(forceLatin: forceLatin) else { return nil }
    let layoutPtr = unsafeBitCast(
        CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var charCount = 0

    UCKeyTranslate(
        layoutPtr,
        keyCode,
        UInt16(kUCKeyActionDown),
        modifiers,
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

/// Layout-aware translation of `keyCode` to its unmodified character against
/// the user's current keyboard layout (or the ASCII-capable fallback when
/// the current source is an IME).
public func keyCodeToChar(_ keyCode: UInt16) -> String? {
    translate(keyCode: keyCode)
}

/// Translate `keyCode` against an ASCII-capable Latin layout regardless of
/// what the user is currently typing in. Use this when matching Vim keybinds
/// so `h`/`j`/`k`/`l` still resolve while the user is on Cyrillic, Greek,
/// Pinyin, Hangul, etc.
///
/// `modifiers` accepts the raw `NSEvent.ModifierFlags.rawValue` — only Shift
/// and Option are forwarded to `UCKeyTranslate` (Cmd / Ctrl / CapsLock don't
/// change the character produced by a physical key in standard layouts, and
/// including them only confuses the translator).
public func asciiChar(forKeyCode keyCode: UInt16, modifiers: UInt = 0) -> String? {
    // UCKeyTranslate's modifier byte is Carbon EventModifiers >> 8:
    //   shiftKey  (0x0200) >> 8 = 0x02
    //   optionKey (0x0800) >> 8 = 0x08
    var carbon: UInt32 = 0
    if modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 { carbon |= 0x02 }
    if modifiers & NSEvent.ModifierFlags.option.rawValue != 0 { carbon |= 0x08 }
    return translate(keyCode: keyCode, modifiers: carbon, forceLatin: true)
}

/// Convenience: ASCII-canonical character for `event`, equivalent in semantics
/// to `event.characters` (shift/option applied) but layout-independent.
public func asciiChar(forEvent event: NSEvent) -> String? {
    asciiChar(forKeyCode: event.keyCode, modifiers: event.modifierFlags.rawValue)
}

/// Convenience: ASCII-canonical character for `event`, equivalent in semantics
/// to `event.charactersIgnoringModifiers` (only shift respected, Cmd/Ctrl/Opt
/// stripped) but layout-independent.
public func asciiCharIgnoringModifiers(forEvent event: NSEvent) -> String? {
    asciiChar(
        forKeyCode: event.keyCode,
        modifiers: event.modifierFlags.rawValue & NSEvent.ModifierFlags.shift.rawValue
    )
}

// Build a Latin-keyed char→keycode map. Always resolves against the
// ASCII-capable layout so Cyrillic/IME users still get a usable map.
private func buildKeyCodeMap() -> [String: UInt16] {
    var map: [String: UInt16] = [:]
    // macOS hardware keycodes are UInt7 (0..127). 128 covers the full range.
    for keyCode in 0..<128 {
        if let char = translate(keyCode: UInt16(keyCode), forceLatin: true), !char.isEmpty {
            map[char] = UInt16(keyCode)
        }
    }
    // Positional overlay: digits, punctuation, and non-printable special keys
    // that we want addressable by stable name regardless of layout. Digits are
    // intentionally positional (e.g. on French AZERTY '1' needs Shift, but
    // `charToKeyCodeMap["1"]` should still hand back the physical 1-key code).
    let remainingKeys: [String: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "-": 27, ".": 47, "/": 44, "=": 24,
        "Tab": 48, "Backspace": 51, "Return": 36, "Space": 49, "Esc": 53,
        "Enter": 76,
        "LeftArrow": 123, "RightArrow": 124, "DownArrow": 125, "UpArrow": 126,
        "Fn": 179,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96,
        "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109,
        "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113,
        "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,
    ]
    for (k, v) in remainingKeys { map[k] = v }
    return map
}

/// Thread-safe, layout-aware char→keycode lookup.
///
/// - Rebuilt automatically when the user switches input source (Cmd-Space).
///   Listens on `kTISNotifySelectedKeyboardInputSourceChanged` via the CF
///   distributed notification center.
/// - Subscript and `keyChar(forKeyCode:)` are safe to call from any thread.
/// - Latin guarantee: the map is built against the ASCII-capable layout, so
///   keys like `"h"`, `"j"`, `"k"`, `"l"` always resolve even when the user
///   is typing in Cyrillic / Greek / Hangul / etc.
public final class KeyCodeMap: @unchecked Sendable {
    private var map: [String: UInt16] = [:]
    private let lock = NSLock()

    fileprivate init() {
        rebuild()
        observeLayoutChanges()
    }

    public subscript(key: String) -> UInt16? {
        lock.withLock { map[key] }
    }

    /// Reverse lookup: name of the first key in the map bound to `keyCode`.
    /// Returns nil if no entry matches (e.g. for an obscure media key).
    public func keyChar(forKeyCode keyCode: UInt16) -> String? {
        lock.withLock { map.first(where: { $0.value == keyCode })?.key }
    }

    /// Snapshot for callers that need iteration (e.g. `first(where:)` with a
    /// complex predicate). Returns a copy so subsequent rebuilds don't race.
    public func snapshot() -> [String: UInt16] {
        lock.withLock { map }
    }

    private func rebuild() {
        let new = buildKeyCodeMap()
        lock.withLock { map = new }
    }

    private func observeLayoutChanges() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let me = Unmanaged<KeyCodeMap>.fromOpaque(observer).takeUnretainedValue()
                me.rebuild()
            },
            // == kTISNotifySelectedKeyboardInputSourceChanged. Hard-coded to
            // dodge the Swift 6 strict-concurrency check on the imported
            // CFStringRef global.
            "com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }
}

public let charToKeyCodeMap = KeyCodeMap()
