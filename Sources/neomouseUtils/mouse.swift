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

    /// Move the cursor to (`x`, `y`) in CG global coords. Two-step pattern,
    /// proven zoom-immune in `moveRelative`:
    ///   1. `CGWarpMouseCursorPosition` writes the cursor below the zoom
    ///      transform — authoritative position write.
    ///   2. A `.mouseMoved` (or dragged) event is posted to
    ///      `.cgSessionEventTap` (downstream of HID-level zoom processing)
    ///      with the motion expressed via `kCGMouseEventDeltaX/Y` plus the
    ///      absolute `location`. Observers (the global NSEvent monitor that
    ///      drives visual-mode end-points, target apps' hover state) fire
    ///      off the deltas; absolute consumers read `location`.
    public static func moveToGlobal(x: CGFloat, y: CGFloat, isMoveToScreenLocal: Bool = false) {
        // Clamp to the union of all active displays so a caller passing a
        // stale/out-of-bounds point (e.g. a mark recorded on a now-disconnected
        // monitor) doesn't strand the cursor in dead space.
        let bounds = Screen.allBoundingRect()
        let clampedX: CGFloat
        let clampedY: CGFloat
        debug("bounds in moveToGlobal: \(bounds), x: \(x), y: \(y)")

        if bounds.isNull {
            // No active displays (CGRect.null.minX == .infinity — clamping
            // would yield NaN). Degrade to a pass-through.
            clampedX = x
            clampedY = y
        } else {
            clampedX = max(bounds.minX, min(x, bounds.maxX))
            clampedY = max(bounds.minY, min(y, bounds.maxY))
            if clampedX != x || clampedY != y {
                debug(
                    "Mouse.moveToGlobal clamped (\(x), \(y)) → (\(clampedX), \(clampedY)) to fit allBoundingRect \(bounds)"
                )
            }
        }
        let point = CGPoint(x: clampedX, y: clampedY)
        let currentLoc = CGEvent(source: nil)?.location ?? point

        // 1. Authoritative position write.
        CGWarpMouseCursorPosition(point)

        // 2. Observer notification via session tap with delta fields.
        let src = eventSource()
        let leftDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let rightDown = CGEventSource.buttonState(.hidSystemState, button: .right)
        let type: CGEventType =
            leftDown
            ? .leftMouseDragged
            : rightDown
                ? .rightMouseDragged
                : .mouseMoved
        if !isMoveToScreenLocal {
            debug("Mouse.moveToGlobal x:\(clampedX), y:\(clampedY), type:\(type)")
        }
        let event = CGEvent(source: src)
        event?.type = type
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - currentLoc.x))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - currentLoc.y))
        event?.location = point
        event?.post(tap: .cgSessionEventTap)
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

    // public static func moveRelative(x: CGFloat, y: CGFloat) {
    //     guard var currentMouseLocation = CGEvent(source: nil)?.location else {
    //         debug("Mouse.moveRelativeV2: could not retrieve cursor location")
    //         return
    //     }
    //     currentMouseLocation.x += x
    //     currentMouseLocation.y += y
    //     CGWarpMouseCursorPosition(currentMouseLocation)
    //     debug("Mouse.moveRelativeV2 to x:\(currentMouseLocation.x), y:\(currentMouseLocation.y)")
    //
    //     // Observer notification post. Two zoom-safety choices baked in:
    //     //   * Delta fields (kCGMouseEventDeltaX/Y) instead of the convenience
    //     //     init's absolute mouseCursorPosition. Absolute positions on
    //     //     posted events get remapped by the Zoom transform; raw deltas
    //     //     are treated as motion data and skip that path.
    //     //   * `.cgSessionEventTap` rather than `.cghidEventTap`. Session tap
    //     //     is downstream of HID-level zoom processing, so the position +
    //     //     deltas we set are honoured as-is. cghidEventTap re-enters the
    //     //     zoom remap and undoes the warp above.
    //     // mouseDragged when a button is held so drag pipelines (incl. visual-
    //     // mode selection via the global NSEvent monitor) still get the right
    //     // event type.
    //     let src = eventSource()
    //     let leftDown = CGEventSource.buttonState(.hidSystemState, button: .left)
    //     let rightDown = CGEventSource.buttonState(.hidSystemState, button: .right)
    //     let type: CGEventType =
    //         leftDown
    //         ? .leftMouseDragged
    //         : rightDown
    //             ? .rightMouseDragged
    //             : .mouseMoved
    //     let event = CGEvent(source: src)
    //     event?.type = type
    //     event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(x))
    //     event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(y))
    //     event?.location = currentMouseLocation
    //     event?.post(tap: .cgSessionEventTap)
    // }
    //
    public static func moveRelative(x: CGFloat, y: CGFloat, clampToScreen: Bool) {
        guard let current = CGEvent(source: nil)?.location else {
            debug("Mouse.moveRelative: could not retrieve cursor location")
            return
        }

        //IMPORTANT: Will default to main display if it can't find the display under the cursor, to avoid the mouse getting "lost" and unresponsive. This can happen when the cursor is on a secondary display that gets disconnected, or if there's some weirdness with the CG API. It's better to have a fallback than to just not move at all.
        let currentDisplayId =
            Screen.activeDisplays().first(where: { CGDisplayBounds($0).contains(current) }) ?? CGMainDisplayID()

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
    public static func appUnderRect() -> (app: NSRunningApplication, rect: CGRect)? {
        guard let mouseLocation = CGEvent(source: nil)?.location else { return nil }

        for app in NSWorkspace.shared.runningApplications {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                let windows = windowsRef as? [AXUIElement]
            else { continue }

            for window in windows {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
                    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
                    let pv = posRef, let sv = sizeRef
                else { continue }

                var pos = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sv as! AXValue, .cgSize, &size)

                let rect = CGRect(x: pos.x, y: pos.y, width: size.width, height: size.height)
                if rect.contains(mouseLocation) {
                    return (app, rect)
                }
            }
        }
        return nil
    }  // MARK: - Click

    public static func click(_ button: Button, at point: CGPoint) {
        // Warp first so the cursor is at `point` regardless of Zoom remap on
        // the posted events, then post mouseDown/Up at the session tap
        // (downstream of zoom). Without the warp + session combo, clicks
        // under Accessibility Zoom land at the zoom-transformed coord.
        CGWarpMouseCursorPosition(point)
        let src = eventSource()
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let btn: CGMouseButton = button == .left ? .left : .right

        CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cgSessionEventTap)
        usleep(8000)
        CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cgSessionEventTap)
    }

    public static func doubleClick(at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let src = eventSource()
        let down = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left)

        down?.setIntegerValueField(.mouseEventClickState, value: 2)
        up?.setIntegerValueField(.mouseEventClickState, value: 2)

        down?.post(tap: .cgSessionEventTap)
        usleep(8000)
        up?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Hold / drag

    /// Press and hold the button without releasing.
    public static func down(_ button: Button, at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let src = eventSource()
        let type: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let btn: CGMouseButton = button == .left ? .left : .right
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cgSessionEventTap)
    }

    /// Release the button.
    public static func up(_ button: Button, at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let src = eventSource()
        let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let btn: CGMouseButton = button == .left ? .left : .right
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)?
            .post(tap: .cgSessionEventTap)
    }

    /// Drag from one point to another (hold → move in `steps` increments → release).
    public static func drag(from start: CGPoint, to end: CGPoint, button: Button = .left, steps: Int = 20) {
        let src = eventSource()
        let dragType: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged
        let btn: CGMouseButton = button == .left ? .left : .right

        down(button, at: start)
        usleep(8000)

        var prev = start
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            let point = CGPoint(x: x, y: y)
            // Warp each step so the cursor visually tracks the drag under
            // zoom; session-tap post carries the dragged event with deltas
            // for any consumer that listens.
            CGWarpMouseCursorPosition(point)
            let event = CGEvent(source: src)
            event?.type = dragType
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - prev.x))
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - prev.y))
            event?.location = point
            event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(btn.rawValue))
            event?.post(tap: .cgSessionEventTap)
            usleep(8000)
            prev = point
        }

        up(button, at: end)
    }

    // MARK: - Scroll

    public static func scroll(dx: Int32 = 0, dy: Int32 = 0, at point: CGPoint) {
        // Scroll events route to whatever view contains the cursor's screen
        // position. Warp the cursor so under Zoom the scroll lands on the
        // intended view rather than the zoom-remapped one.
        CGWarpMouseCursorPosition(point)
        let src = eventSource()
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.location = point
        event.post(tap: .cgSessionEventTap)
    }
}
