import AppKit  // NSWorkspace / NSRunningApplication have no CG equivalent

/// Namespace for cursor + mouse-event synthesis. All entry points are static —
/// `Mouse` is caseless so it can't be instantiated.
public enum Mouse {
    public enum Button { case left, right }

    // MARK: - Event source

    /// Single factory for every CGEvent we post. Default
    /// `localEventsSuppressionInterval` is 0.25s — after any synthesized post,
    /// the system filters real HID events from this source for that window.
    /// Designed for pure automation tools that don't want the user's hand
    /// fighting a scripted gesture. NeoMouse is a *hybrid* input tool — users
    /// mix keyboard-driven moves/gestures with physical mouse fine-tuning — so
    /// we zero it and let both input paths interleave at HID-event speed.
    public static func eventSource() -> CGEventSource? {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0
        return src
    }

    // MARK: - Location + movement

    public static func location() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Posts a `.mouseMoved` (or `.leftMouseDragged` / `.rightMouseDragged`
    /// when a button is held) event whose `mouseCursorPosition` relocates the
    /// cursor as part of dispatch — replaces `CGWarpMouseCursorPosition` so
    /// observers of the event stream (overlay listeners, accessibility tools,
    /// target apps) see the move.
    public static func moveToGlobal(x: CGFloat, y: CGFloat, isMoveToScreenLocal: Bool = false) {
        let point = CGPoint(x: x, y: y)
        let src = eventSource()
        let leftDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let rightDown = CGEventSource.buttonState(.hidSystemState, button: .right)
        let type: CGEventType =
            leftDown
            ? .leftMouseDragged
            : rightDown
                ? .rightMouseDragged
                : .mouseMoved
        let button: CGMouseButton = leftDown ? .left : rightDown ? .right : .left
        if !isMoveToScreenLocal {
            debug("Mouse.moveToGlobal x:\(x), y:\(y), type:\(type), button:\(button)")
        }
        CGEvent(
            mouseEventSource: src, mouseType: type,
            mouseCursorPosition: point, mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    /// Move to (x, y) interpreted as coords on the screen currently containing
    /// the cursor. Adds that display's origin so the global post lands on the
    /// right monitor.
    public static func moveToScreenLocal(x: CGFloat, y: CGFloat) {
        guard let current = CGEvent(source: nil)?.location else {
            debug("Mouse.moveToScreenLocal: could not retrieve cursor location")
            return
        }
        guard let display = Screen.activeDisplays().first(where: { CGDisplayBounds($0).contains(current) })
        else {
            debug("Mouse.moveToScreenLocal: could not find display under cursor")
            return
        }
        let bounds = CGDisplayBounds(display)
        moveToGlobal(x: bounds.origin.x + x, y: bounds.origin.y + y, isMoveToScreenLocal: true)
        debug("Mouse.moveToScreenLocal global x:\(bounds.origin.x + x), y:\(bounds.origin.y + y)")
    }

    public static func moveRelative(x: CGFloat, y: CGFloat, clampToScreen: Bool) {
        guard let current = CGEvent(source: nil)?.location else {
            debug("Mouse.moveRelative: could not retrieve cursor location")
            return
        }

        //IMPORTANT: Will default to main display if it can't find the display under the cursor, to avoid the mouse getting "lost" and unresponsive. This can happen when the cursor is on a secondary display that gets disconnected, or if there's some weirdness with the CG API. It's better to have a fallback than to just not move at all.
        let currentDisplayId =
            Screen.activeDisplays().first(where: { CGDisplayBounds($0).contains(current) }) ?? CGMainDisplayID()

        // guard
        //     let currentDisplayId = Screen.activeDisplays().first(where: {
        //         CGDisplayBounds($0).contains(current)
        //     })
        // else {
        //     debug("Mouse.moveRelative: could not find display under cursor, defaulting to main screen")
        //     return
        // }
        let currentBounds = CGDisplayBounds(currentDisplayId)
        let allScreensRect = Screen.allBoundingRect()

        // CG coords: y increases downward, so positive y = move down
        let newX = current.x + x
        let newY = current.y + y

        let clampedX =
            clampToScreen
            ? max(currentBounds.minX, min(newX, currentBounds.maxX))
            : max(allScreensRect.minX, min(newX, allScreensRect.maxX))
        let clampedY =
            clampToScreen
            ? max(currentBounds.minY, min(newY, currentBounds.maxY))
            : max(allScreensRect.minY, min(newY, allScreensRect.maxY))

        moveToGlobal(x: clampedX, y: clampedY)
        debug("Mouse.moveRelative to x:\(clampedX), y:\(clampedY)")
    }

    // MARK: - Hit-testing

    public static func appUnder() -> NSRunningApplication? {
        guard let mouseLocation = CGEvent(source: nil)?.location else { return nil }

        return NSWorkspace.shared.runningApplications.first { app in
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
                    == .success,
                let windows = windowsRef as? [AXUIElement]
            else { return false }

            return windows.contains { window in
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
                        == .success,
                    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                        == .success,
                    let pv = posRef, let sv = sizeRef
                else { return false }

                var pos = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sv as! AXValue, .cgSize, &size)

                // AX API returns CG coords (top-left origin), same as CGEvent.location — no flip needed
                return CGRect(x: pos.x, y: pos.y, width: size.width, height: size.height)
                    .contains(mouseLocation)
            }
        }
    }

    // MARK: - Click

    public static func click(_ button: Button, at point: CGPoint) {
        let src = eventSource()
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let btn: CGMouseButton = button == .left ? .left : .right

        CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cghidEventTap)
        usleep(8000)
        CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cghidEventTap)
    }

    public static func doubleClick(at point: CGPoint) {
        let src = eventSource()
        let down = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left)

        down?.setIntegerValueField(.mouseEventClickState, value: 2)
        up?.setIntegerValueField(.mouseEventClickState, value: 2)

        down?.post(tap: .cghidEventTap)
        usleep(8000)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Hold / drag

    /// Press and hold the button without releasing.
    public static func down(_ button: Button, at point: CGPoint) {
        let src = eventSource()
        let type: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let btn: CGMouseButton = button == .left ? .left : .right
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cghidEventTap)
    }

    /// Release the button.
    public static func up(_ button: Button, at point: CGPoint) {
        let src = eventSource()
        let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let btn: CGMouseButton = button == .left ? .left : .right
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cghidEventTap)
    }

    /// Drag from one point to another (hold → move in `steps` increments → release).
    public static func drag(from start: CGPoint, to end: CGPoint, button: Button = .left, steps: Int = 20) {
        let src = eventSource()
        let dragType: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged
        let btn: CGMouseButton = button == .left ? .left : .right

        down(button, at: start)
        usleep(8000)

        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            let point = CGPoint(x: x, y: y)
            CGEvent(
                mouseEventSource: src, mouseType: dragType,
                mouseCursorPosition: point, mouseButton: btn
            )?.post(tap: .cghidEventTap)
            usleep(8000)
        }

        up(button, at: end)
    }

    // MARK: - Scroll

    public static func scroll(dx: Int32 = 0, dy: Int32 = 0, at point: CGPoint) {
        let src = eventSource()
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}
