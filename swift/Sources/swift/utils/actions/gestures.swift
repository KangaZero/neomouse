// MARK: - Gestures
import AppKit

enum ZoomDirection { case `in`, out }
enum SwipeDirection { case left, right, up, down }

func pinchZoom(
    _ direction: ZoomDirection, at point: CGPoint, stepValue: Double,
    incrementsPerGesture: UInt
) {
    var safeStepValue = stepValue
    var safeIncrementsPerGesture = incrementsPerGesture
    if safeStepValue <= 0 {
        print(
            "Invalid step value for pinchZoom: \(safeStepValue). Must be greater than 0. Defaulting to 0.1"
        )
        safeStepValue = 0.1
    }
    if safeIncrementsPerGesture == 0 {
        print(
            "Invalid incrementsPerGesture for pinchZoom: \(safeIncrementsPerGesture). Must be greater than 0. Defaulting to 1"
        )
        safeIncrementsPerGesture = 1
    }
    let step: Double = direction == .in ? min(safeStepValue, 1) : max(-1, -safeStepValue)
    let src = CGEventSource(stateID: .hidSystemState)

    postGestureEvent(src: src, type: .magnify, value: 0, phase: .began, at: point)
    usleep(8000)
    //INFO: To simulate a zoom gesture, we need to send multiple .changed events with incremental values.
    for _ in 0..<safeIncrementsPerGesture {
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

func rotate(degrees: Double, at point: CGPoint, incrementsPerGesture: UInt) {
    var safeIncrementsPerGesture = incrementsPerGesture
    if safeIncrementsPerGesture == 0 {
        print(
            "Invalid incrementsPerGesture for rotate: \(safeIncrementsPerGesture). Must be greater than 0. Defaulting to 1"
        )
        safeIncrementsPerGesture = 1
    }
    let step = degrees
    let src = CGEventSource(stateID: .hidSystemState)

    postGestureEvent(src: src, type: .rotate, value: 0, phase: .began, at: point)
    usleep(8000)
    for _ in 0..<safeIncrementsPerGesture {
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
