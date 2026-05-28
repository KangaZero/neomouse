import Carbon  // brings in HIToolbox.UAZoomFocus
import CoreGraphics

/// Programmatic interface to macOS Accessibility Zoom. Wraps the Carbon
/// `UAZoom*` functions from HIToolbox — deprecated as of 10.10 but still the
/// only public API for this, and the canonical choice in every accessibility
/// tool that drives Zoom (Hammerspoon, BetterTouchTool, Karabiner extensions).
///
/// What you can drive programmatically:
///   * Check whether the user has Zoom enabled in System Settings →
///     Accessibility → Zoom (`isUserEnabled`).
///   * Pan the zoom viewport to a given rect while zoom is active
///     (`focus(on:)`). This is a *focus change*, not an enable.
///
/// What you cannot drive:
///   * Programmatically enable the user's Zoom feature (privacy/UX).
///   * Change zoom magnification level.
///
/// Toggling zoom on/off is done by synthesizing the user's configured
/// keyboard shortcut (`toggle()` — defaults to Cmd+Option+8). Requires the
/// user to have ticked "Use keyboard shortcuts to zoom" in the Zoom prefs;
/// otherwise the synthesized chord is a no-op.
public enum Zoom {

    /// `true` if the user has Zoom turned on in System Settings →
    /// Accessibility → Zoom. Independent of whether zoom is *currently
    /// active* — the user can have it enabled but not toggled on.
    public static var isUserEnabled: Bool { UAZoomEnabled() }

    /// Current magnification, `1.0` meaning unzoomed. Reads
    /// `closeViewZoomFactor` from `com.apple.universalaccess` preferences —
    /// not an Apple-documented API contract but the canonical channel every
    /// accessibility tool uses for this question (Hammerspoon, BetterTouchTool,
    /// etc.). Defaults-based, so there may be sub-second lag between the user
    /// pressing Cmd+Option+8 and this updating; fine for one-shot decisions,
    /// don't poll in a tight loop.
    public static var currentZoomFactor: Double {
        readUAPreference("closeViewZoomFactor") ?? 1.0
    }

    /// `true` while the user is actively zoomed in (factor > 1.0). Falls back
    /// to the `closeViewZoomedIn` boolean when no factor is persisted (some
    /// macOS versions only write one or the other).
    public static var isCurrentlyZoomed: Bool {
        if let f: Double = readUAPreference("closeViewZoomFactor"), f > 1.0 { return true }
        if let on: Bool = readUAPreference("closeViewZoomedIn") { return on }
        return false
    }

    private static func readUAPreference<T>(_ key: String) -> T? {
        CFPreferencesCopyAppValue(key as CFString, "com.apple.universalaccess" as CFString) as? T
    }

    /// Pan the zoom viewport so `rect` is the focused region. CG-global
    /// coords, points. No-op when Zoom isn't currently active (i.e. user
    /// hasn't toggled it on yet) — the call returns an error code but we
    /// swallow it; nothing useful for callers to do.
    public static func focus(on rect: CGRect) {
        // guard isUserEnabled else {
        //     return
        //         debug("Zoom.focus: user doesn't have Zoom enabled; call is a no-op")
        // }
        var viewport = rect
        UAZoomChangeFocus(&viewport, nil, UAZoomChangeFocusType(kUAZoomFocusTypeOther))
    }

    /// Synthesize Cmd+Option+8 — the user's default Zoom toggle shortcut.
    /// Requires "Use keyboard shortcuts to zoom" enabled in System Settings.
    ///
    /// Posted at `.cgSessionEventTap` like every other synthesis in NeoMouse.
    /// The Zoom *mouse-position remap* lives at HID level (which is why
    /// mouse moves had to bypass it via warp + session-tap), but Zoom's
    /// global hotkey listener is registered through the higher-level hotkey
    /// infrastructure (`RegisterEventHotKey`-style) and catches Cmd+Option+8
    /// regardless of which tap injected it. Verified empirically.
    fileprivate static func toggle() {
        let before = currentZoomFactor
        guard let src = CGEventSource(stateID: .hidSystemState),
            let keyCode = charToKeyCodeMap["8"]
        else {
            return debug(
                "Zoom.toggle: no event source / keyCode for '8' (zoomFactor=\(before))")
        }

        debug("Zoom.toggle: before (user-enabled: \(isUserEnabled))")
        let flags: CGEventFlags = [.maskCommand, .maskAlternate]
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        // Defaults-backed reads lag the actual zoom state by a few hundred ms
        // (the system updates the preference on the next runloop tick after
        // the toggle settles), so `after` will frequently still equal
        // `before` immediately. Useful regardless: when they differ, the
        // toggle definitely landed; when they don't, you'd need to poll
        // briefly to confirm. Kept synchronous to avoid adding a Task hop
        // just for diagnostics.
        let after = currentZoomFactor
        debug("isCurrentlyZoomed : \(isCurrentlyZoomed)")
        debug("Zoom.toggle: after (user-enabled: \(isUserEnabled))")
    }

    public static func zoomIn() {
        // !isUserEnabled means that the user has not zoomed in
        if !isUserEnabled {
            toggle()
        }
    }

    public static func zoomOut() {
        if isUserEnabled {
            toggle()
        }
    }
}
