import CoreGraphics
import Testing

@testable import neomouse

@Suite("HJKL direction mapping (normal mode)")
struct HJKLTests {

    @Test("h maps to .left")
    func hMapsToLeft() {
        #expect(HJKLDirection("h") == .left)
    }

    @Test("j maps to .down")
    func jMapsToDown() {
        #expect(HJKLDirection("j") == .down)
    }

    @Test("k maps to .up")
    func kMapsToUp() {
        #expect(HJKLDirection("k") == .up)
    }

    @Test("l maps to .right")
    func lMapsToRight() {
        #expect(HJKLDirection("l") == .right)
    }

    @Test("non-hjkl keys return nil")
    func nonHJKLReturnsNil() {
        #expect(HJKLDirection("a") == nil)
        #expect(HJKLDirection("") == nil)
        #expect(HJKLDirection("H") == nil)  // capital is a different operation
        #expect(HJKLDirection("hj") == nil)
    }

    @Test("h moves cursor left by stepX")
    func hMovesLeftByStepX() {
        let d = HJKLDirection.left.delta(stepX: 20, stepY: 20)
        #expect(d.dx == -20)
        #expect(d.dy == 0)
    }

    @Test("j moves cursor down by stepY (positive y in CG coords)")
    func jMovesDownByStepY() {
        let d = HJKLDirection.down.delta(stepX: 20, stepY: 20)
        #expect(d.dx == 0)
        #expect(d.dy == 20)
    }

    @Test("k moves cursor up by stepY (negative y in CG coords)")
    func kMovesUpByStepY() {
        let d = HJKLDirection.up.delta(stepX: 20, stepY: 20)
        #expect(d.dx == 0)
        #expect(d.dy == -20)
    }

    @Test("l moves cursor right by stepX")
    func lMovesRightByStepX() {
        let d = HJKLDirection.right.delta(stepX: 20, stepY: 20)
        #expect(d.dx == 20)
        #expect(d.dy == 0)
    }

    @Test("count multiplier scales delta (5j moves 5x stepY)")
    func countScalesDelta() {
        let d = HJKLDirection.down.delta(stepX: 20, stepY: 20, count: 5)
        #expect(d.dx == 0)
        #expect(d.dy == 100)
    }

    @Test("count=0 produces no movement")
    func zeroCountIsZero() {
        for dir in [HJKLDirection.left, .down, .up, .right] {
            let d = dir.delta(stepX: 20, stepY: 20, count: 0)
            #expect(d.dx == 0)
            #expect(d.dy == 0)
        }
    }

    @Test("h and l are mirrors; j and k are mirrors")
    func oppositesCancel() {
        let h = HJKLDirection.left.delta(stepX: 20, stepY: 20)
        let l = HJKLDirection.right.delta(stepX: 20, stepY: 20)
        #expect(h.dx == -l.dx)
        #expect(h.dy == l.dy)

        let j = HJKLDirection.down.delta(stepX: 20, stepY: 20)
        let k = HJKLDirection.up.delta(stepX: 20, stepY: 20)
        #expect(j.dy == -k.dy)
        #expect(j.dx == k.dx)
    }
}
