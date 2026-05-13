import AppKit  // NSWorkspace / NSRunningApplication have no CG equivalent

// Single factory for every CGEvent we post. Default localEventsSuppressionInterval is
// 0.25s — after any synthesized post, the system filters real HID events from this
// source for that window. Designed for pure automation tools that don't want the user's
// hand fighting a scripted gesture. NeoMouse is a *hybrid* input tool — users mix
// keyboard-driven moves/gestures with physical mouse fine-tuning — so we zero it and
// let both input paths interleave at HID-event speed.
public func makeHIDEventSource() -> CGEventSource? {
    let src = CGEventSource(stateID: .hidSystemState)
    src?.localEventsSuppressionInterval = 0
    return src
}

// Posts a .mouseMoved (or .leftMouseDragged / .rightMouseDragged when a button is held)
// event whose mouseCursorPosition relocates the cursor as part of dispatch — replaces
// CGWarpMouseCursorPosition so observers of the event stream (overlay listeners,
// accessibility tools, target apps) see the move.
public func moveMouseByExactGlobalCGPoint(x: CGFloat, y: CGFloat, mouseFunction: (() -> Void)? = nil) {
    let point = CGPoint(x: x, y: y)
    let src = makeHIDEventSource()
    let leftDown = CGEventSource.buttonState(.hidSystemState, button: .left)
    let rightDown = CGEventSource.buttonState(.hidSystemState, button: .right)
    let type: CGEventType =
        leftDown
        ? .leftMouseDragged
        : rightDown ? .rightMouseDragged : .mouseMoved
    let button: CGMouseButton = leftDown ? .left : rightDown ? .right : .left
    debug("moveMouseByExactGlobalCGPoint to x:\(x), y: \(y), type: \(type), button: \(button)")
    CGEvent(
        mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: button
    )?.post(tap: .cghidEventTap)
}

public func moveMouseByExactCoordinatesOnCurrentScreen(x: CGFloat, y: CGFloat) {
    guard let current = CGEvent(source: nil)?.location else {
        debug("Could not retrieve mouse location in moveMouseByExactCoordinates")
        return
    }
    guard let display = getActiveDisplays().first(where: { CGDisplayBounds($0).contains(current) })
    else {
        debug("Could not retrieve current screen in moveMouseByExactCoordinates")
        return
    }
    let bounds = CGDisplayBounds(display)
    moveMouseByExactGlobalCGPoint(x: bounds.origin.x + x, y: bounds.origin.y + y)
    debug(
        "moveMouseByExactCoordinatesOnCurrentScreen to x:\(bounds.origin.x + x), y: \(bounds.origin.y + y)"
    )
}

public func getCurrentMouseLocation() -> CGPoint? {
    return CGEvent(source: nil)?.location
}

public func moveMouseRelatively(x: CGFloat, y: CGFloat, enableClampToCurrentScreen: Bool) {
    guard let current = CGEvent(source: nil)?.location else {
        debug("Could not retrieve mouse location in moveMouseRelatively")
        return
    }
    guard
        let currentDisplay = getActiveDisplays().first(where: {
            CGDisplayBounds($0).contains(current)
        })
    else {
        debug("Could not retrieve current screen in moveMouseRelatively")
        return
    }
    let currentBounds = CGDisplayBounds(currentDisplay)
    let allScreensRect = getAllScreensBoundingRect()

    // CG coords: y increases downward, so positive y = move down
    let newX = current.x + x
    let newY = current.y + y

    let clampedX =
        enableClampToCurrentScreen
        ? max(currentBounds.minX, min(newX, currentBounds.maxX))
        : max(allScreensRect.minX, min(newX, allScreensRect.maxX))
    let clampedY =
        enableClampToCurrentScreen
        ? max(currentBounds.minY, min(newY, currentBounds.maxY))
        : max(allScreensRect.minY, min(newY, allScreensRect.maxY))

    moveMouseByExactGlobalCGPoint(x: clampedX, y: clampedY)
    debug("moveMouseRelatively to x:\(clampedX), y: \(clampedY)")
}

public func getAppUnderMouse() -> NSRunningApplication? {
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

//TODO see if these work, gotta minimize vibe coding but idk this api, nor am i a good dev anyways
public enum MouseButton { case left, right }
// MARK: - Mouse

public func mouseClick(_ button: MouseButton, at point: CGPoint) {
    let src = makeHIDEventSource()
    let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    let btn: CGMouseButton = button == .left ? .left : .right

    let downEvent = CGEvent(
        mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: btn)
    let upEvent = CGEvent(
        mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: btn)

    downEvent?.post(tap: .cghidEventTap)
    usleep(8000)
    upEvent?.post(tap: .cghidEventTap)
}

public func doubleClick(at point: CGPoint) {
    let src = makeHIDEventSource()
    let down = CGEvent(
        mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point,
        mouseButton: .left)
    let up = CGEvent(
        mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point,
        mouseButton: .left)

    down?.setIntegerValueField(.mouseEventClickState, value: 2)
    up?.setIntegerValueField(.mouseEventClickState, value: 2)

    down?.post(tap: .cghidEventTap)
    usleep(8000)
    up?.post(tap: .cghidEventTap)
}

// MARK: - Mouse Hold / Drag

/// Press and hold the mouse button down (without releasing)
public func mouseDown(_ button: MouseButton, at point: CGPoint) {
    let src = makeHIDEventSource()
    let type: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let btn: CGMouseButton = button == .left ? .left : .right
    let event = CGEvent(
        mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)
    event?.post(tap: .cghidEventTap)
}

/// Release the mouse button
public func mouseUp(_ button: MouseButton, at point: CGPoint) {
    let src = makeHIDEventSource()
    let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    let btn: CGMouseButton = button == .left ? .left : .right
    let event = CGEvent(
        mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)
    event?.post(tap: .cghidEventTap)
}

/// Drag from one point to another (hold down → move → release)
public func mouseDrag(from start: CGPoint, to end: CGPoint, button: MouseButton = .left, steps: Int = 20) {
    let src = makeHIDEventSource()
    let dragType: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged
    let btn: CGMouseButton = button == .left ? .left : .right

    // press down at start
    mouseDown(button, at: start)
    usleep(8000)

    // move in steps for smooth drag
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = start.x + (end.x - start.x) * t
        let y = start.y + (end.y - start.y) * t
        let point = CGPoint(x: x, y: y)
        let dragEvent = CGEvent(
            mouseEventSource: src, mouseType: dragType, mouseCursorPosition: point, mouseButton: btn
        )
        dragEvent?.post(tap: .cghidEventTap)
        usleep(8000)
    }

    // release at end
    mouseUp(button, at: end)
}

// MARK: - Scroll

public func scroll(dx: Int32 = 0, dy: Int32 = 0, at point: CGPoint) {
    let src = makeHIDEventSource()
    guard
        let event = CGEvent(
            scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx,
            wheel3: 0)
    else { return }
    event.location = point
    event.post(tap: .cghidEventTap)
}
// MARK: - Shared Gesture Helper
