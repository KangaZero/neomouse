import AppKit
import ApplicationServices

// The Accessibility API lets this app observe other apps' windows.
// Requires Accessibility permission in System Settings — without it, all AX calls fail.

// Gets the pixel size of the frontmost app's focused window.
func getFrontmostAppWinSize() -> CGSize? {
    // Ask NSWorkspace which app is currently in front. Returns nil if none.
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

    // Create an AX handle into that app using its process ID.
    // Think of this as a master key the OS grants us to observe that app's UI tree.
    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    // Declare an empty "envelope" (CFTypeRef = type-erased C pointer — could hold anything).
    // Pass it by reference with & so the AX API can write the focused window into it.
    var windowRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
            == .success,
        let window = windowRef  // unwrap — if the envelope is empty, bail
    else { return nil }

    // Same pattern: declare an empty envelope for the size value.
    var sizeRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
        let sizeValue = sizeRef  // unwrap — bail if AX couldn't read the size
    else { return nil }

    // "Open the envelope": tell the system we expect a CGSize inside, extract it into `size`.
    // AXValue is Apple's wrapper for geometric types (CGSize, CGPoint, CGRect) over the AX API.
    var size = CGSize.zero
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return size
}

// Gets the full rect (origin + size) of the frontmost app's focused window.
// Same pattern as getFrontmostAppWinSize but fetches both position and size in one go.
func getFrontmostAppWinRect() -> CGRect? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return getAppWinRectByApp(app: app)
}

func getAppWinRectByApp(app: NSRunningApplication) -> CGRect? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    var windowRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
            == .success,
        let window = windowRef
    else { return nil }

    // Two envelopes this time — one for position (CGPoint), one for size (CGSize).
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?

    guard
        AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
        AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
        let posValue = positionRef,
        let sizeValue = sizeRef
    else { return nil }

    // Open both envelopes into their respective types.
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

    // Combine into a CGRect (origin + size) and return.
    return CGRect(origin: position, size: size)

}
