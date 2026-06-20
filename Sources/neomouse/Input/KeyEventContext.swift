import AppKit
import CoreGraphics
import Foundation

import neomouseConfig
import neomouseDB
import neomouseTypes
import neomouseUtils

/// Bundles every derived value the per-mode key handlers need. The main
/// `keyHandler` closure computes this once per keystroke (mouse position,
/// active display, ASCII-normalized characters, operation count parsed out
/// of the pending normal-mode count string, etc.), then dispatches into the
/// matching `handle…Mode` static below.
///
/// All handlers run on the main actor — the keyHandler is invoked from the
/// CGEventTap callback wrapped in `MainActor.assumeIsolated`.
@MainActor
struct KeyEventContext {
    let event: NSEvent
    let appState: NeoMouseState
    let currentSession: Session
    let sessionId: Int64
    let currentCGPoint: CGPoint
    let localCGPoint: CGPoint
    let currentDisplayBounds: CGRect
    let currentScreenSize: CGSize
    /// Numeric prefix parsed from the pending normal-mode operation count
    /// string (e.g. "5gg" → 5). Defaults to 1 when no count is buffered.
    /// CGFloat (not Int/UInt) so it composes with CGWarpMouseCursorPosition
    /// math without conversion churn at every callsite.
    let operationCount: CGFloat
    /// ASCII-normalized character with shift+option applied. Mirrors
    /// `NSEvent.characters` but layout-independent — Vim motions still resolve
    /// when the user is typing Cyrillic / Greek / Hangul / IME.
    let asciiKey: String?
    /// ASCII-normalized character with only shift respected. Mirrors
    /// `NSEvent.charactersIgnoringModifiers`.
    let asciiKeyBase: String?
}
