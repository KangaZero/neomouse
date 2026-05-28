import AppKit

import neomouseUtils

extension NeoMouse {
    /// Install the global key-event tap. Two flavours, chosen by
    /// `NeoMouseState.isDisableKeyInput`:
    ///
    /// * `true`  → `.defaultTap` — actively swallows plain-key presses while
    ///             neomouse is active. Cmd / Ctrl / Opt chords and
    ///             Esc / Tab / Backspace / arrow / F1–F20 still flow to the
    ///             OS (handler is also notified). Self-synthesized keys (sentinel
    ///             userData from `System.simulate`) always pass through.
    /// * `false` → `.listenOnly` — passive observer; every key reaches the
    ///             focused app, neomouse just gets notified for state updates.
    ///
    /// Requires *both* Accessibility AND Input Monitoring permissions in
    /// System Settings → Privacy. Without those, `tapCreate` returns nil.
    @MainActor
    /// TODO consider logic and add for non-English based keyboard layouts.
    static func installKeyEventTap() {
        let state = NeoMouse.sharedState
        let keyMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        if state.isDisableKeyInput {
            debug("isDisableKeyInput is true - applying CGEvent tap that swallows most regular key events (a-z0-9)")
            NeoMouse.keyEventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: keyMask,
                callback: { _, type, cgEvent, _ in
                    // System disables the tap if our callback ever exceeds the
                    // per-event budget — re-enable and pass the event through.
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = NeoMouse.keyEventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return Unmanaged.passUnretained(cgEvent)
                    }
                    // Recognise our own synthesized keys (e.g. Cmd+C/V via
                    // `System.simulate`) so they aren't swallowed by the tap that
                    // posted them. Without this check we'd silently no-op every
                    // clipboard shortcut neomouse fires while active.
                    if cgEvent.getIntegerValueField(.eventSourceUserData) == System.synthesizedEventUserData {
                        return Unmanaged.passUnretained(cgEvent)
                    }
                    guard let nsEvent = NSEvent(cgEvent: cgEvent) else {
                        return Unmanaged.passUnretained(cgEvent)
                    }
                    // Bool-only return from MainActor — CGEvent isn't Sendable,
                    // so we build Unmanaged.passUnretained outside the actor hop.
                    let shouldSwallow: Bool = MainActor.assumeIsolated {
                        let state = NeoMouse.sharedState
                        func isNeomouseActive() -> Bool {
                            if case .disabled = state.mode { return false }
                            return true
                        }
                        let isAllowTapThrough = isNeomouseActive()

                        // Pass-through filter (active mode only):
                        //   * Cmd / Ctrl / Opt held → system shortcuts (Cmd-S, Cmd-Tab,
                        //     Ctrl-Space, etc.) must still work.
                        //   * Esc / Tab / Backspace / arrow keys / F1–F12 → leave the
                        //     OS in charge; neomouse no longer uses these chords.
                        //   Shift alone is NOT treated as a modifier so capital-letter
                        //   motions ('V', 'G', 'M') still get handled.
                        if isAllowTapThrough {
                            let isCommandOrMenuMode =
                                switch state.mode {
                                case .command, .menu: true
                                default: false
                                }
                            let mods = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                            //IMPORTANT: Disable control when in command or menu mode as they are used (e.g. Ctrl-n / Ctrl-p)
                            let hasSystemMod =
                                mods.contains(.command)
                                || (!isCommandOrMenuMode && mods.contains(.control))
                                || mods.contains(.option)
                            let keyCode = nsEvent.keyCode
                            let isSpecialKey: Bool = {
                                switch keyCode {
                                case charToKeyCodeMap["Tab"], charToKeyCodeMap["Backspace"], charToKeyCodeMap["Return"],
                                    charToKeyCodeMap["Enter"],
                                    charToKeyCodeMap["Esc"], charToKeyCodeMap["LeftArrow"],
                                    charToKeyCodeMap["RightArrow"],
                                    charToKeyCodeMap["DownArrow"], charToKeyCodeMap["UpArrow"]:
                                    //IMPORTANT: Disable specialKeys when in command or menu mode as these keys will be used
                                    return isCommandOrMenuMode ? false : true
                                default:
                                    return false
                                }
                            }()
                            let isFKey: Bool = {
                                switch keyCode {
                                case charToKeyCodeMap["F1"], charToKeyCodeMap["F2"], charToKeyCodeMap["F3"],
                                    charToKeyCodeMap["F4"], charToKeyCodeMap["F5"], charToKeyCodeMap["F6"],
                                    charToKeyCodeMap["F7"], charToKeyCodeMap["F8"], charToKeyCodeMap["F9"],
                                    charToKeyCodeMap["F10"], charToKeyCodeMap["F11"], charToKeyCodeMap["F12"],
                                    charToKeyCodeMap["F13"], charToKeyCodeMap["F14"], charToKeyCodeMap["F15"],
                                    charToKeyCodeMap["F16"], charToKeyCodeMap["F17"], charToKeyCodeMap["F18"],
                                    charToKeyCodeMap["F19"], charToKeyCodeMap["F20"]:
                                    return true
                                default:
                                    return false
                                }
                            }()
                            // keycodes above 128 are non-standard so they are allowed to pass through
                            // INFO: The Fn keycode is 179 so no need to check for it to enable it
                            if hasSystemMod || isSpecialKey || isFKey || keyCode >= 128 {
                                // Notify neomouse AND let the OS see the key. Side-effect:
                                // app may also react (e.g. Esc closes its picker). Accepted
                                // tradeoff so Cmd-E / Esc / Ctrl-W keep working as neomouse
                                // chords without blocking system shortcuts.
                                NeoMouse.keyHandler?(nsEvent)
                                return false
                            }
                        }

                        NeoMouse.keyHandler?(nsEvent)
                        return isAllowTapThrough || isNeomouseActive()
                    }
                    return shouldSwallow ? nil : Unmanaged.passUnretained(cgEvent)
                },
                userInfo: nil
            )
            attachTapToRunLoop(
                failureMessage: "CGEvent.tapCreate failed — check Accessibility + Input Monitoring permissions")
        } else {
            debug("isDisableKeyInput is false - installing passive (listen-only) CGEventTap")
            // .listenOnly = passive observer; callback return value is ignored
            // by the system, so every key passes through to the focused app no
            // matter what. We still call the neomouse handler for state updates.
            NeoMouse.keyEventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: keyMask,
                callback: { _, type, cgEvent, _ in
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = NeoMouse.keyEventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return nil
                    }
                    guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
                    MainActor.assumeIsolated {
                        NeoMouse.keyHandler?(nsEvent)
                    }
                    return nil  // ignored under .listenOnly
                },
                userInfo: nil
            )
            attachTapToRunLoop(
                failureMessage:
                    "CGEvent.tapCreate (listen-only) failed — check Accessibility + Input Monitoring permissions")
        }
    }

    private static func attachTapToRunLoop(failureMessage: String) {
        guard let tap = NeoMouse.keyEventTap else {
            debug(failureMessage)
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NeoMouse.keyEventTapRunLoopSource = src
    }
}
