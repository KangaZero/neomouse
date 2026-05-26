// MARK: - Gestures
import AppKit

import neomouseTypes

/// Namespace for synthetic trackpad gestures.
public enum Gesture {
    public enum ZoomDirection { case `in`, out }
    // public enum SwipeDirection { case left, right, up, down }

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

    /// Synthesizes a four-direction trackpad swipe at `point`.
    ///
    /// `incrementsPerGesture` exists for API parity with `pinchZoom` and
    /// `rotate`, which are continuous gestures whose deltas accumulate. Swipe
    /// is *discrete* — macOS dispatches it atomically once `.began` is posted,
    /// and the target app typically sees a single trigger regardless of how
    /// many `.changed` events follow. The parameter is plumbed through so
    /// callers can use the same wiring as the other gestures, but cranking
    /// it up won't repeat the swipe.
    public static func swipe(
        direction: NeomouseType.Direction,
        at point: CGPoint,
        incrementsPerGesture: UInt
    ) {
        debug(
            "swipe \(direction) at \(point) with incrementsPerGesture \(incrementsPerGesture)"
        )
        var safeIncrementsPerGesture = incrementsPerGesture
        if safeIncrementsPerGesture == 0 {
            print("Invalid incrementsPerGesture for swipe: 0. Defaulting to 1")
            safeIncrementsPerGesture = 1
        }
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
        for _ in 0..<safeIncrementsPerGesture {
            postGestureEvent(
                src: src, type: .swipe, value: 0, phase: .changed, at: point, dx: dx, dy: dy
            )
            usleep(8000)
        }
        postGestureEvent(src: src, type: .swipe, value: 0, phase: .ended, at: point, dx: dx, dy: dy)
    }

    /// Synthesizes a scroll-wheel gesture in one of four directions at `point`.
    /// Each tick scrolls by `stepValue` pixels and the whole thing repeats
    /// `incrementsPerGesture` times, so the *total* scroll = stepValue × N.
    ///
    /// Unlike `pinchZoom` / `rotate` / `swipe` (which post CGEvent *gesture*
    /// events via `postGestureEvent`), this wraps `Mouse.scroll` — real
    /// scroll-wheel events, which every app handles natively. That's what you
    /// want for cursor-driven page navigation (vim-style Ctrl-D / Ctrl-U).
    ///
    /// Sign convention: `.up` reveals content above the current view; `.down`
    /// reveals content below; `.left` / `.right` reveal content to the sides.
    /// macOS "natural scrolling" inverts the *physical-finger-vs-content*
    /// mapping at the OS layer but the underlying scroll-wheel event is the
    /// same — if your muscle memory points the other way, flip the signs in
    /// the switch below.
    public static func scroll(
        direction: NeomouseType.Direction,
        at point: CGPoint,
        stepValue: Int32,
        incrementsPerGesture: UInt = 1
    ) {
        debug(
            "scroll \(direction) at \(point) with stepValue \(stepValue) and incrementsPerGesture \(incrementsPerGesture)"
        )
        var safeStepValue = stepValue
        if safeStepValue <= 0 {
            print("Invalid stepValue for scroll: \(safeStepValue). Defaulting to 10")
            safeStepValue = 10
        }
        var safeIncrementsPerGesture = incrementsPerGesture
        if safeIncrementsPerGesture == 0 {
            print("Invalid incrementsPerGesture for scroll: 0. Defaulting to 1")
            safeIncrementsPerGesture = 1
        }
        let (dx, dy): (Int32, Int32) =
            switch direction {
            case .left: (-safeStepValue, 0)
            case .right: (safeStepValue, 0)
            case .up: (0, safeStepValue)
            case .down: (0, -safeStepValue)
            }
        for _ in 0..<safeIncrementsPerGesture {
            Mouse.scroll(dx: dx, dy: dy, at: point)
            usleep(8000)
        }
    }
}
