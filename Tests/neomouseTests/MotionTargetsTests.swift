import CoreGraphics
import Testing

import neomouseUtils

@Suite("Cardinal motion targets (normal mode)")
struct MotionTargetsTests {

    // MARK: - leftEdge (`0`)

    @Test("0 jumps to gridInset on x, preserves y")
    func leftEdgePreservesY() {
        let p = MotionTarget.leftEdge(localY: 250, gridInset: 10)
        #expect(p.x == 10)
        #expect(p.y == 250)
    }

    @Test("0 with zero gridInset lands on x=0")
    func leftEdgeZeroInset() {
        let p = MotionTarget.leftEdge(localY: 0, gridInset: 0)
        #expect(p.x == 0)
        #expect(p.y == 0)
    }

    // MARK: - rightEdge (`$`)

    @Test("$ jumps to screenWidth minus inset on x, preserves y")
    func rightEdgePreservesY() {
        let p = MotionTarget.rightEdge(localY: 250, screenWidth: 1920, gridInset: 10)
        #expect(p.x == 1910)
        #expect(p.y == 250)
    }

    @Test("$ collapses to right edge when inset is 0")
    func rightEdgeZeroInset() {
        let p = MotionTarget.rightEdge(localY: 100, screenWidth: 800, gridInset: 0)
        #expect(p.x == 800)
        #expect(p.y == 100)
    }

    // MARK: - top (`gg`)

    @Test("gg jumps to gridInset on y, preserves x")
    func topPreservesX() {
        let p = MotionTarget.top(localX: 640, gridInset: 10)
        #expect(p.x == 640)
        #expect(p.y == 10)
    }

    // MARK: - bottom (`G`)

    @Test("G jumps to screenHeight minus inset on y, preserves x")
    func bottomPreservesX() {
        let p = MotionTarget.bottom(localX: 640, screenHeight: 1080, gridInset: 10)
        #expect(p.x == 640)
        #expect(p.y == 1070)
    }

    @Test("G + gg are mirrors through the screen mid-y")
    func topBottomMirror() {
        let h: CGFloat = 1080
        let inset: CGFloat = 10
        let top = MotionTarget.top(localX: 0, gridInset: inset)
        let bot = MotionTarget.bottom(localX: 0, screenHeight: h, gridInset: inset)
        #expect(top.y + bot.y == h)
    }

    // MARK: - verticalMiddle (`M`)

    @Test("M jumps to mid-height regardless of inset")
    func verticalMiddleMidHeight() {
        let p = MotionTarget.verticalMiddle(localX: 640, screenHeight: 1080)
        #expect(p.x == 640)
        #expect(p.y == 540)
    }

    // MARK: - horizontalMiddle (`gm`)

    @Test("gm jumps to mid-width regardless of inset")
    func horizontalMiddleMidWidth() {
        let p = MotionTarget.horizontalMiddle(localY: 250, screenWidth: 1920)
        #expect(p.x == 960)
        #expect(p.y == 250)
    }

    @Test("verticalMiddle and horizontalMiddle preserve the orthogonal axis")
    func middlesPreserveOrthogonalAxis() {
        let v = MotionTarget.verticalMiddle(localX: 123, screenHeight: 1080)
        let h = MotionTarget.horizontalMiddle(localY: 456, screenWidth: 1920)
        #expect(v.x == 123)
        #expect(h.y == 456)
    }

    // MARK: - toLineCount (`Ng`)

    @Test("Ng at count=1 lands on the first cell's center")
    func lineCountFirstLine() {
        // stepY = (1080 - 2*10) / 50 = 21.2
        // y = inset + (1 - 0.5) * stepY = 10 + 0.5 * 21.2 = 20.6
        let p = MotionTarget.toLineCount(
            localX: 0, screenHeight: 1080, gridInset: 10, rowsOnScreen: 50, count: 1)
        #expect(abs(p.y - 20.6) < 0.0001)
    }

    @Test("Ng at count=rowsOnScreen lands half a cell above the bottom edge")
    func lineCountLastLine() {
        // Cell center of the last row:
        //   stepY = (1080 - 2*10) / 50 = 21.2
        //   y = 10 + (50 - 0.5) * 21.2 = 10 + 49.5 * 21.2 = 1059.4
        let p = MotionTarget.toLineCount(
            localX: 0, screenHeight: 1080, gridInset: 10, rowsOnScreen: 50, count: 50)
        #expect(abs(p.y - 1059.4) < 0.0001)
        // No longer coincides with MotionTarget.bottom (the bottom edge) —
        // they're separated by half a cell. This is the cell-center vs
        // cell-edge fix.
        let b = MotionTarget.bottom(localX: 0, screenHeight: 1080, gridInset: 10)
        let stepY = (1080.0 - 2 * 10.0) / 50.0  // 21.2
        #expect(abs((b.y - p.y) - stepY / 2) < 0.0001)
    }

    @Test("Ng spacing between consecutive counts equals stepY")
    func lineCountDeltaIsStepY() {
        // Linearity in the old (incorrect) formula held only because no
        // leading inset was added. The corrected formula is affine
        // (y = inset + (n - 0.5) * step), so doubling count no longer
        // doubles y — but the *delta* between consecutive counts is still
        // exactly stepY. That's the testable invariant.
        let stepY = (1080.0 - 2 * 10.0) / 50.0  // 21.2
        let p5 = MotionTarget.toLineCount(
            localX: 0, screenHeight: 1080, gridInset: 10, rowsOnScreen: 50, count: 5)
        let p6 = MotionTarget.toLineCount(
            localX: 0, screenHeight: 1080, gridInset: 10, rowsOnScreen: 50, count: 6)
        #expect(abs((p6.y - p5.y) - stepY) < 0.0001)
        let p10 = MotionTarget.toLineCount(
            localX: 0, screenHeight: 1080, gridInset: 10, rowsOnScreen: 50, count: 10)
        #expect(abs((p10.y - p5.y) - 5 * stepY) < 0.0001)
    }

    @Test("Ng preserves localX")
    func lineCountPreservesX() {
        let p = MotionTarget.toLineCount(
            localX: 999, screenHeight: 1080, gridInset: 10, rowsOnScreen: 50, count: 7)
        #expect(p.x == 999)
    }
}
