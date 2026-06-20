import Testing

import neomouseUtils

@Suite("Pending-operation reducer (normal mode state machine)")
struct PendingOpReducerTests {

    // MARK: - Single-key motions (no pending state)

    @Test("plain G emits goBottom, clears pending")
    func plainG() {
        let r = reducePendingOp(pending: .none, key: "G")
        #expect(r.newPending == .none)
        #expect(r.intent == .goBottom)
    }

    @Test("plain M emits goVerticalMiddle")
    func plainM() {
        let r = reducePendingOp(pending: .none, key: "M")
        #expect(r.newPending == .none)
        #expect(r.intent == .goVerticalMiddle)
    }

    @Test("plain 0 emits goLeftEdge (not a count digit)")
    func plainZero() {
        let r = reducePendingOp(pending: .none, key: "0")
        #expect(r.newPending == .none)
        #expect(r.intent == .goLeftEdge)
    }

    @Test("plain $ emits goRightEdge")
    func plainDollar() {
        let r = reducePendingOp(pending: .none, key: "$")
        #expect(r.newPending == .none)
        #expect(r.intent == .goRightEdge)
    }

    @Test("plain h/j/k/l emit moveRelative with count=1")
    func plainHJKL() {
        #expect(
            reducePendingOp(pending: .none, key: "h").intent
                == .moveRelative(direction: .left, count: 1))
        #expect(
            reducePendingOp(pending: .none, key: "j").intent
                == .moveRelative(direction: .down, count: 1))
        #expect(
            reducePendingOp(pending: .none, key: "k").intent
                == .moveRelative(direction: .up, count: 1))
        #expect(
            reducePendingOp(pending: .none, key: "l").intent
                == .moveRelative(direction: .right, count: 1))
    }

    // MARK: - `g` prefix and its completions

    @Test("g alone arms pending without emitting")
    func gArmsPending() {
        let r = reducePendingOp(pending: .none, key: "g")
        #expect(r.newPending == .g)
        #expect(r.intent == .none)
    }

    @Test("gg emits goTop, clears pending")
    func ggGoesTop() {
        let r = reducePendingOp(pending: .g, key: "g")
        #expect(r.newPending == .none)
        #expect(r.intent == .goTop)
    }

    @Test("gm emits goHorizontalMiddle, clears pending")
    func gmGoesHorizontalMiddle() {
        let r = reducePendingOp(pending: .g, key: "m")
        #expect(r.newPending == .none)
        #expect(r.intent == .goHorizontalMiddle)
    }

    @Test("g followed by unknown key resets pending with no intent")
    func gUnknownResets() {
        let r = reducePendingOp(pending: .g, key: "x")
        #expect(r.newPending == .none)
        #expect(r.intent == .none)
    }

    // MARK: - `m` (mark) prefix

    @Test("m alone arms pending without emitting")
    func mArmsPending() {
        let r = reducePendingOp(pending: .none, key: "m")
        #expect(r.newPending == .mark)
        #expect(r.intent == .none)
    }

    @Test("m followed by a letter emits setMark")
    func mPlusLetter() {
        let r = reducePendingOp(pending: .mark, key: "a")
        #expect(r.newPending == .none)
        #expect(r.intent == .setMark(name: "a"))
    }

    @Test("m followed by a digit emits setMark")
    func mPlusDigit() {
        let r = reducePendingOp(pending: .mark, key: "7")
        #expect(r.newPending == .none)
        #expect(r.intent == .setMark(name: "7"))
    }

    @Test("m followed by a symbol resets pending, no intent")
    func mPlusSymbolRejected() {
        let r = reducePendingOp(pending: .mark, key: "$")
        #expect(r.newPending == .none)
        #expect(r.intent == .none)
    }

    @Test("mm is a self-targeted mark, not a no-op")
    func mPlusMIsMarkM() {
        let r = reducePendingOp(pending: .mark, key: "m")
        #expect(r.newPending == .none)
        #expect(r.intent == .setMark(name: "m"))
    }

    // MARK: - Ctrl-w (window) prefix

    @Test("Ctrl-w arms pending without emitting")
    func ctrlWArmsPending() {
        let r = reducePendingOp(pending: .none, key: "w", isControlHeld: true)
        #expect(r.newPending == .ctrlW)
        #expect(r.intent == .none)
    }

    @Test("plain w with no pending does nothing (resets)")
    func plainWResets() {
        // "w" without ctrl and without a prior prefix isn't bound to anything yet.
        let r = reducePendingOp(pending: .none, key: "w")
        #expect(r.newPending == .none)
        #expect(r.intent == .none)
    }

    @Test("Ctrl-w then w emits jumpAdjacentScreen")
    func ctrlWThenW() {
        let r = reducePendingOp(pending: .ctrlW, key: "w")
        #expect(r.newPending == .none)
        #expect(r.intent == .jumpAdjacentScreen)
    }

    // MARK: - Count prefix (numeric buildup)

    @Test("first non-zero digit arms count")
    func firstDigit() {
        let r = reducePendingOp(pending: .none, key: "5")
        #expect(r.newPending == .count(5))
        #expect(r.intent == .none)
    }

    @Test("subsequent digits append (left shift × 10 + new)")
    func digitBuildup() {
        let r1 = reducePendingOp(pending: .count(1), key: "0")
        #expect(r1.newPending == .count(10))
        let r2 = reducePendingOp(pending: .count(10), key: "5")
        #expect(r2.newPending == .count(105))
    }

    @Test("0 with no pending stays as goLeftEdge, never starts a count")
    func zeroDoesNotStartCount() {
        let r = reducePendingOp(pending: .none, key: "0")
        #expect(r.newPending == .none)
        #expect(r.intent == .goLeftEdge)
    }

    @Test("0 inside a running count is a real digit")
    func zeroInsideCount() {
        let r = reducePendingOp(pending: .count(3), key: "0")
        #expect(r.newPending == .count(30))
        #expect(r.intent == .none)
    }

    @Test("Ng (count + g) emits goLineCount with the accumulated number")
    func countG() {
        let r = reducePendingOp(pending: .count(10), key: "g")
        #expect(r.newPending == .none)
        #expect(r.intent == .goLineCount(10))
    }

    @Test("Nj/Nk/Nh/Nl emit moveRelative with the accumulated count")
    func countHJKL() {
        #expect(
            reducePendingOp(pending: .count(5), key: "j").intent
                == .moveRelative(direction: .down, count: 5))
        #expect(
            reducePendingOp(pending: .count(5), key: "k").intent
                == .moveRelative(direction: .up, count: 5))
        #expect(
            reducePendingOp(pending: .count(5), key: "h").intent
                == .moveRelative(direction: .left, count: 5))
        #expect(
            reducePendingOp(pending: .count(5), key: "l").intent
                == .moveRelative(direction: .right, count: 5))
    }

    @Test("count + unknown key resets without emitting")
    func countUnknownResets() {
        let r = reducePendingOp(pending: .count(42), key: "x")
        #expect(r.newPending == .none)
        #expect(r.intent == .none)
    }

    // MARK: - Default / catch-all

    @Test("totally unknown key with no pending is a no-op")
    func unknownNoOp() {
        let r = reducePendingOp(pending: .none, key: "~")
        #expect(r.newPending == .none)
        #expect(r.intent == .none)
    }
}
