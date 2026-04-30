import AppKit  // NSWorkspace / NSRunningApplication have no CG equivalent

func moveMouseByExactGlobalCGPoint(x: CGFloat, y: CGFloat) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
}

func moveMouseByExactCoordinatesOnCurrentScreen(x: CGFloat, y: CGFloat) {
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
    CGWarpMouseCursorPosition(CGPoint(x: bounds.origin.x + x, y: bounds.origin.y + y))
}

func getCurrentMouseLocation() -> CGPoint? {
    return CGEvent(source: nil)?.location
}

func moveMouseRelatively(x: CGFloat, y: CGFloat, enableClampToCurrentScreen: Bool) {
    guard let current = CGEvent(source: nil)?.location else {
        debug("Could not retrieve mouse location in moveMouseRelatively")
        return
    }
    guard let currentDisplay = getActiveDisplays().first(where: { CGDisplayBounds($0).contains(current) })
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

    CGWarpMouseCursorPosition(CGPoint(x: clampedX, y: clampedY))
    debug("moveMouseRelatively to x:\(clampedX), y: \(clampedY)")
}

func getAppUnderMouse() -> NSRunningApplication? {
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
enum MouseButton { case left, right }
enum ZoomDirection { case `in`, out }
enum SwipeDirection { case left, right, up, down }

enum GestureType {
    case magnify, smartMagnify, rotate, swipe

    var subtype: Int64 {
        switch self {
        case .magnify: return 8
        case .smartMagnify: return 9
        case .rotate: return 5
        case .swipe: return 6
        }
    }
}

// MARK: - Mouse

func mouseClick(_ button: MouseButton, at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
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

func doubleClick(at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
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

func moveMouse(to point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(
        mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point,
        mouseButton: .left)
    event?.post(tap: .cghidEventTap)
}

// MARK: - Mouse Hold / Drag

/// Press and hold the mouse button down (without releasing)
func mouseDown(_ button: MouseButton, at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    let type: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let btn: CGMouseButton = button == .left ? .left : .right
    let event = CGEvent(
        mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)
    event?.post(tap: .cghidEventTap)
}

/// Release the mouse button
func mouseUp(_ button: MouseButton, at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    let btn: CGMouseButton = button == .left ? .left : .right
    let event = CGEvent(
        mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: btn)
    event?.post(tap: .cghidEventTap)
}

/// Drag from one point to another (hold down → move → release)
func mouseDrag(from start: CGPoint, to end: CGPoint, button: MouseButton = .left, steps: Int = 20) {
    let src = CGEventSource(stateID: .hidSystemState)
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

func scroll(dx: Int32 = 0, dy: Int32 = 0, at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard
        let event = CGEvent(
            scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx,
            wheel3: 0)
    else { return }
    event.location = point
    event.post(tap: .cghidEventTap)
}

// MARK: - Gestures

func pinchZoom(_ direction: ZoomDirection, at point: CGPoint, steps: Int = 8) {
    let step: Double = direction == .in ? 0.08 : -0.08
    let src = CGEventSource(stateID: .hidSystemState)

    postGestureEvent(src: src, type: .magnify, value: 0, phase: .began, at: point)
    usleep(8000)
    for _ in 0..<steps {
        postGestureEvent(src: src, type: .magnify, value: step, phase: .changed, at: point)
        usleep(8000)
    }
    postGestureEvent(src: src, type: .magnify, value: 0, phase: .ended, at: point)
}

func smartMagnify(at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    postGestureEvent(src: src, type: .smartMagnify, value: 0, phase: .began, at: point)
    usleep(8000)
    postGestureEvent(src: src, type: .smartMagnify, value: 0, phase: .ended, at: point)
}

func rotate(degrees: Double, at point: CGPoint, steps: Int = 8) {
    let step = degrees / Double(steps)
    let src = CGEventSource(stateID: .hidSystemState)

    postGestureEvent(src: src, type: .rotate, value: 0, phase: .began, at: point)
    usleep(8000)
    for _ in 0..<steps {
        postGestureEvent(src: src, type: .rotate, value: step, phase: .changed, at: point)
        usleep(8000)
    }
    postGestureEvent(src: src, type: .rotate, value: 0, phase: .ended, at: point)
}

func swipe(_ direction: SwipeDirection, at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)

    let (dx, dy): (Double, Double) =
        switch direction {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }

    postGestureEvent(src: src, type: .swipe, value: 0, phase: .began, at: point, dx: dx, dy: dy)
    usleep(8000)
    postGestureEvent(src: src, type: .swipe, value: 0, phase: .changed, at: point, dx: dx, dy: dy)
    usleep(8000)
    postGestureEvent(src: src, type: .swipe, value: 0, phase: .ended, at: point, dx: dx, dy: dy)
}

// MARK: - Shared Gesture Helper

private func postGestureEvent(
    src: CGEventSource?,
    type: GestureType,
    value: Double,
    phase: CGGesturePhase,
    at point: CGPoint,
    dx: Double = 0,
    dy: Double = 0
) {
    guard let event = CGEvent(source: src) else { return }
    event.type = CGEventType(rawValue: 29)!  // kCGEventGesture
    event.location = point
    event.setIntegerValueField(CGEventField(rawValue: 110)!, value: type.subtype)
    event.setDoubleValueField(CGEventField(rawValue: 113)!, value: value)
    event.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase.rawValue))

    if type == .swipe {
        event.setDoubleValueField(CGEventField(rawValue: 116)!, value: dx)
        event.setDoubleValueField(CGEventField(rawValue: 119)!, value: dy)
    }

    event.post(tap: .cghidEventTap)
}
