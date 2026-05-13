import CoreGraphics

// MARK: - Cardinal motion targets
//
// Pure target-point computations for the cardinal normal-mode motions. Mirrors
// the inline arithmetic that used to live in the keyMonitor closure in
// NeoMouseApp.swift, lifted out so the math is testable without NSEvent /
// NSWindow / AppKit. The caller still does the cursor warp.
//
// All inputs and outputs are in **screen-local** CG coordinates (top-left
// origin), matching `moveMouseByExactCoordinatesOnCurrentScreen`.

public enum MotionTarget {
    /// `0` — left edge, offset by `gridInset`.
    public static func leftEdge(localY: CGFloat, gridInset: CGFloat) -> CGPoint {
        CGPoint(x: gridInset, y: localY)
    }

    /// `$` — right edge, inset from the right.
    public static func rightEdge(localY: CGFloat, screenWidth: CGFloat, gridInset: CGFloat)
        -> CGPoint
    {
        CGPoint(x: screenWidth - gridInset, y: localY)
    }

    /// `gg` — top edge, offset by `gridInset`.
    public static func top(localX: CGFloat, gridInset: CGFloat) -> CGPoint {
        CGPoint(x: localX, y: gridInset)
    }

    /// `G` — bottom edge, inset from the bottom.
    public static func bottom(localX: CGFloat, screenHeight: CGFloat, gridInset: CGFloat)
        -> CGPoint
    {
        CGPoint(x: localX, y: screenHeight - gridInset)
    }

    /// `M` — vertical centre (mid-height) of the current screen.
    public static func verticalMiddle(localX: CGFloat, screenHeight: CGFloat) -> CGPoint {
        CGPoint(x: localX, y: screenHeight / 2)
    }

    /// `gm` — horizontal centre (mid-width) of the current screen.
    public static func horizontalMiddle(localY: CGFloat, screenWidth: CGFloat) -> CGPoint {
        CGPoint(x: screenWidth / 2, y: localY)
    }

    /// `Ng` — jump to "line N" of `linesOnScreen` evenly-divided rows.
    /// Y = (screenHeight - gridInset) / linesOnScreen * count.
    public static func toLineCount(
        localX: CGFloat,
        screenHeight: CGFloat,
        gridInset: CGFloat,
        linesOnScreen: Int,
        count: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: localX,
            y: (screenHeight - gridInset) / CGFloat(linesOnScreen) * count
        )
    }
}

// MARK: - Pending-operation state machine (spec, not yet wired)
//
// Models the multi-keystroke normal-mode sequences (gg, gm, Ng, m+name,
// Ctrl-w w, count+hjkl) as a pure reducer: (state, keystroke) → (state',
// intent). NOT yet integrated into the keyMonitor closure — kept here as an
// executable specification so future refactors have a target to drop in.
//
// `key` is the *logical* key the user pressed (post charactersIgnoringModifiers
// normalisation). Caller passes `isControlHeld: true` to disambiguate Ctrl-w
// (logical key "w") from plain "w".

public enum PendingOp: Equatable {
    case none
    case g  // `g` pressed once, awaiting completion
    case ctrlW  // Ctrl-w pressed, awaiting window command
    case mark  // `m` pressed, awaiting mark name
    case count(Int)  // numeric prefix being assembled (e.g. "10" → 10)
}

public enum MotionIntent: Equatable {
    case none
    case goTop  // gg
    case goBottom  // G
    case goLeftEdge  // 0
    case goRightEdge  // $
    case goVerticalMiddle  // M
    case goHorizontalMiddle  // gm
    case goLineCount(Int)  // Ng
    case jumpAdjacentScreen  // Ctrl-w w
    case setMark(name: String)  // m + letter/digit
    case moveRelative(direction: HJKLDirection, count: Int)
}

/// Pure transition function for the pending-operation state machine.
/// Returns the new pending state and any intent to execute. Unknown sequences
/// reset pending to `.none` and emit `.none`.
public func reducePendingOp(
    pending: PendingOp,
    key: String,
    isControlHeld: Bool = false
) -> (newPending: PendingOp, intent: MotionIntent) {
    // Mark name after `m`: any single letter or digit completes the sequence.
    if case .mark = pending,
        key.count == 1,
        let first = key.first,
        first.isLetter || first.isNumber
    {
        return (.none, .setMark(name: key))
    }

    switch (pending, key, isControlHeld) {
    // Two-keystroke completions
    case (.g, "g", _): return (.none, .goTop)
    case (.g, "m", _): return (.none, .goHorizontalMiddle)
    case (.ctrlW, "w", _): return (.none, .jumpAdjacentScreen)
    case (.count(let n), "g", _): return (.none, .goLineCount(n))
    case (.count(let n), "j", _): return (.none, .moveRelative(direction: .down, count: n))
    case (.count(let n), "k", _): return (.none, .moveRelative(direction: .up, count: n))
    case (.count(let n), "h", _): return (.none, .moveRelative(direction: .left, count: n))
    case (.count(let n), "l", _): return (.none, .moveRelative(direction: .right, count: n))

    // Count digit buildup. "0" with no pending is the leftEdge motion (handled
    // below), so exclude it here; "0" while already counting is a real digit.
    case (.none, let d, _)
    where d.count == 1 && (d.first?.isNumber ?? false) && d != "0":
        return (.count(Int(d) ?? 0), .none)
    case (.count(let n), let d, _) where d.count == 1 && (d.first?.isNumber ?? false):
        return (.count(n * 10 + (Int(d) ?? 0)), .none)

    // Pending-prefix arming (single keystroke that opens a multi-key sequence)
    case (.none, "g", _): return (.g, .none)
    case (.none, "m", _): return (.mark, .none)
    case (.none, "w", true): return (.ctrlW, .none)

    // Single-key motions with no pending
    case (.none, "G", _): return (.none, .goBottom)
    case (.none, "M", _): return (.none, .goVerticalMiddle)
    case (.none, "0", _): return (.none, .goLeftEdge)
    case (.none, "$", _): return (.none, .goRightEdge)
    case (.none, "h", _): return (.none, .moveRelative(direction: .left, count: 1))
    case (.none, "j", _): return (.none, .moveRelative(direction: .down, count: 1))
    case (.none, "k", _): return (.none, .moveRelative(direction: .up, count: 1))
    case (.none, "l", _): return (.none, .moveRelative(direction: .right, count: 1))

    // Anything else: drop pending state, emit no intent.
    default: return (.none, .none)
    }
}
