// MARK: - Gestures
import AppKit

/// Namespace for synthetic trackpad gestures.
public enum Gesture {
    public enum ZoomDirection { case `in`, out }
    public enum SwipeDirection { case left, right, up, down }

    public static func pinchZoom(
        _ direction: ZoomDirection,
        at point: CGPoint,
        stepValue: Double,
        incrementsPerGesture: UInt
    ) {
        debug(
            "pinchZoom \(direction) at \(point) with stepValue \(stepValue) and incrementsPerGesture \(incrementsPerGesture)"
        )
        var safeStepValue = stepValue
        var safeIncrementsPerGesture = incrementsPerGesture
        //IMPORTANT: Needs at least 0.2 for zoom-in
        let minStepValue = direction == .in ? 0.2 : 0.1
        if safeStepValue <= minStepValue {
            let stepValueToUse = direction == .in ? 0.2 : 0.1
            print("Invalid step value for pinchZoom: \(safeStepValue). Defaulting to \(stepValueToUse)")
            safeStepValue = stepValueToUse
        }
        if safeIncrementsPerGesture == 0 {
            print("Invalid incrementsPerGesture for pinchZoom: 0. Defaulting to 1")
            safeIncrementsPerGesture = 1
        }
        let step: Double = direction == .in ? min(safeStepValue, 1) : max(-1, -safeStepValue)
        let src = Mouse.eventSource()

        postGestureEvent(src: src, type: .magnify, value: 0, phase: .began, at: point)
        usleep(8000)
        //INFO: To simulate a zoom gesture, we need to send multiple .changed events with incremental values.
        for _ in 0..<safeIncrementsPerGesture {
            postGestureEvent(src: src, type: .magnify, value: step, phase: .changed, at: point)
            usleep(8000)
        }
        postGestureEvent(src: src, type: .magnify, value: 0, phase: .ended, at: point)
    }

    public static func smartMagnify(at point: CGPoint) {
        debug("smartMagnify at \(point)")
        let src = Mouse.eventSource()
        // smartMagnify is a one-shot toggle, not a phased gesture — a single
        // event with value=1 mirrors what a real two-finger double-tap emits.
        postGestureEvent(src: src, type: .smartMagnify, value: 1, phase: .began, at: point)
    }

    public static func rotate(degrees: Double, at point: CGPoint, incrementsPerGesture: UInt) {
        debug("rotate \(degrees) degrees at \(point) with incrementsPerGesture \(incrementsPerGesture)")
        var safeIncrementsPerGesture = incrementsPerGesture
        if safeIncrementsPerGesture == 0 {
            print("Invalid incrementsPerGesture for rotate: 0. Defaulting to 1")
            safeIncrementsPerGesture = 1
        }
        let step = degrees
        let src = Mouse.eventSource()

        postGestureEvent(src: src, type: .rotate, value: 0, phase: .began, at: point)
        usleep(8000)
        for _ in 0..<safeIncrementsPerGesture {
            postGestureEvent(src: src, type: .rotate, value: step, phase: .changed, at: point)
            usleep(8000)
        }
        postGestureEvent(src: src, type: .rotate, value: 0, phase: .ended, at: point)
    }

    public static func swipe(_ direction: SwipeDirection, at point: CGPoint) {
        let src = Mouse.eventSource()

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
}
