import AppKit
import SwiftUI

/// Factory + common config for the *fullscreen click-through overlay*
/// pattern — used by GridOverlay, VisualHighlightOverlay, NumbersOverlay,
/// and CursorSurroundedGridOverlay. All four wanted the same NSWindow
/// settings (borderless, .screenSaver level, transparent background,
/// click-through, joins all Spaces + full-screen aux), differing only in
/// content rect and SwiftUI root view.
///
/// **Why this isn't generalized to every overlay:** the floating-pill
/// overlays (ToastManager, KeyCast, CommandLine, MarksMenu, RegisterMenu,
/// HelpDialog) each have meaningful per-overlay variation
/// (`acceptsMouseMovedEvents`, hosting `sizingOptions`,
/// `isReleasedWhenClosed`, titlebar style masks, etc.). A single factory
/// across both patterns would devolve into a wide options bag that hides
/// per-overlay intent. Keeping the floating-pill setup inline per file
/// keeps each `show()` self-documenting.
@MainActor
enum OverlayWindow {
    /// Build a borderless, click-through, transparent NSWindow at
    /// `.screenSaver` level, suitable for non-interactive visual overlays
    /// (grids, highlights, number gutters). The caller owns the returned
    /// window — call `orderFront(nil)` / `orderOut(nil)` as needed.
    ///
    /// - Parameters:
    ///   - contentRect: The window's initial frame in screen coordinates.
    ///   - rootView: SwiftUI root view to host. Captured via NSHostingView.
    ///   - hasShadow: Defaults to NSWindow's default. NumbersOverlay
    ///     explicitly disables this; the rest leave it at the default.
    static func makeFullscreenClickThrough<Content: View>(
        contentRect: CGRect,
        rootView: Content,
        hasShadow: Bool = true
    ) -> NSWindow {
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = hasShadow
        // .screenSaver (101) sits above .floating (3) and .modalPanel (8),
        // ensuring the overlay isn't occluded by Spotlight, command-line
        // pills, etc. Don't lower this — overlays must paint on top.
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        // Visible on every Space (incl. fullscreen apps); doesn't itself
        // claim a Space. Required for the overlay to track the user across
        // workspace switches without being rebuilt.
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: rootView)
        return win
    }
}
