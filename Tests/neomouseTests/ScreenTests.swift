import CoreGraphics
import Testing

import neomouseTypes
import neomouseUtils

/// 5x5 grid of identical 1920x1080 displays. Indices are (col, row) with
/// row 0 at top (CG coords — y increases downward). Origin of display (c, r):
/// (c * displayW, r * displayH).
///
/// Visual layout (col, row):
///
///   (0,0) (1,0) (2,0) (3,0) (4,0)
///   (0,1) (1,1) (2,1) (3,1) (4,1)
///   (0,2) (1,2) (2,2) (3,2) (4,2)   ← row 2 is the middle
///   (0,3) (1,3) (2,3) (3,3) (4,3)
///   (0,4) (1,4) (2,4) (3,4) (4,4)
///
/// All tests run against `Screen.adjacentDisplayRect(displays:current:direction:)` —
/// the pure version that doesn't touch real CGDisplay state. The impure
/// wrapper `adjacentDisplayRectByDirection(at:)` delegates to it.
@Suite("Screen.adjacentDisplayRect (5x5 grid of 25 displays)")
struct ScreenAdjacentDisplayTests {

    static let displayW: CGFloat = 1920
    static let displayH: CGFloat = 1080
    static let cols = 5
    static let rows = 5

    /// Build the 25-display fixture. Row-major order so display at (c, r) is
    /// at array index `r * cols + c`.
    static func makeDisplays() -> [CGRect] {
        var d: [CGRect] = []
        d.reserveCapacity(rows * cols)
        for row in 0..<rows {
            for col in 0..<cols {
                d.append(at(col, row))
            }
        }
        return d
    }

    /// Rect of the display at grid position (col, row). Same construction
    /// as in `makeDisplays` so `==` against a fixture element holds.
    static func at(_ col: Int, _ row: Int) -> CGRect {
        CGRect(
            x: CGFloat(col) * displayW,
            y: CGFloat(row) * displayH,
            width: displayW,
            height: displayH
        )
    }

    // MARK: - From the center display (2, 2)

    @Test("center (2,2) → left → (1,2)")
    func centerLeft() {
        let r = Screen.adjacentDisplayRect(
            displays: Self.makeDisplays(), current: Self.at(2, 2), direction: .left)
        #expect(r == Self.at(1, 2))
    }

    @Test("center (2,2) → right → (3,2)")
    func centerRight() {
        let r = Screen.adjacentDisplayRect(
            displays: Self.makeDisplays(), current: Self.at(2, 2), direction: .right)
        #expect(r == Self.at(3, 2))
    }

    @Test("center (2,2) → up → (2,1)")
    func centerUp() {
        let r = Screen.adjacentDisplayRect(
            displays: Self.makeDisplays(), current: Self.at(2, 2), direction: .up)
        #expect(r == Self.at(2, 1))
    }

    @Test("center (2,2) → down → (2,3)")
    func centerDown() {
        let r = Screen.adjacentDisplayRect(
            displays: Self.makeDisplays(), current: Self.at(2, 2), direction: .down)
        #expect(r == Self.at(2, 3))
    }

    // MARK: - Sequential traversals out from the center

    @Test("center → right → right → right → off-right edge returns nil")
    func centerWalkRightToEdge() {
        let grid = Self.makeDisplays()
        var current = Self.at(2, 2)
        for expectedCol in 3...4 {
            let next = Screen.adjacentDisplayRect(
                displays: grid, current: current, direction: .right)
            #expect(next == Self.at(expectedCol, 2))
            current = next!
        }
        // We're now at (4, 2); one more `.right` should fall off the edge.
        let offEdge = Screen.adjacentDisplayRect(
            displays: grid, current: current, direction: .right)
        #expect(offEdge == nil)
    }

    @Test("center → left → left → left → off-left edge returns nil")
    func centerWalkLeftToEdge() {
        let grid = Self.makeDisplays()
        var current = Self.at(2, 2)
        for expectedCol in stride(from: 1, through: 0, by: -1) {
            let next = Screen.adjacentDisplayRect(
                displays: grid, current: current, direction: .left)
            #expect(next == Self.at(expectedCol, 2))
            current = next!
        }
        let offEdge = Screen.adjacentDisplayRect(
            displays: grid, current: current, direction: .left)
        #expect(offEdge == nil)
    }

    @Test("center → up → up → up → off-top edge returns nil")
    func centerWalkUpToEdge() {
        let grid = Self.makeDisplays()
        var current = Self.at(2, 2)
        for expectedRow in stride(from: 1, through: 0, by: -1) {
            let next = Screen.adjacentDisplayRect(
                displays: grid, current: current, direction: .up)
            #expect(next == Self.at(2, expectedRow))
            current = next!
        }
        let offEdge = Screen.adjacentDisplayRect(
            displays: grid, current: current, direction: .up)
        #expect(offEdge == nil)
    }

    @Test("center → down → down → down → off-bottom edge returns nil")
    func centerWalkDownToEdge() {
        let grid = Self.makeDisplays()
        var current = Self.at(2, 2)
        for expectedRow in 3...4 {
            let next = Screen.adjacentDisplayRect(
                displays: grid, current: current, direction: .down)
            #expect(next == Self.at(2, expectedRow))
            current = next!
        }
        let offEdge = Screen.adjacentDisplayRect(
            displays: grid, current: current, direction: .down)
        #expect(offEdge == nil)
    }

    @Test("center → right → right → up → up reaches top-right corner (4, 0)")
    func centerToTopRightCorner() {
        let grid = Self.makeDisplays()
        var current = Self.at(2, 2)
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .right)!
        #expect(current == Self.at(3, 2))
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .right)!
        #expect(current == Self.at(4, 2))
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .up)!
        #expect(current == Self.at(4, 1))
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .up)!
        #expect(current == Self.at(4, 0))
        // At the corner; right + up both off-edge.
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .right) == nil)
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .up) == nil)
    }

    @Test("center → left → left → down → down reaches bottom-left corner (0, 4)")
    func centerToBottomLeftCorner() {
        let grid = Self.makeDisplays()
        var current = Self.at(2, 2)
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .left)!
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .left)!
        #expect(current == Self.at(0, 2))
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .down)!
        current =
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .down)!
        #expect(current == Self.at(0, 4))
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .left) == nil)
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: current, direction: .down) == nil)
    }

    // MARK: - Edge / corner displays

    @Test("top-left corner (0,0) — left and up both nil; right and down land")
    func topLeftCornerNeighbors() {
        let grid = Self.makeDisplays()
        let c = Self.at(0, 0)
        #expect(Screen.adjacentDisplayRect(displays: grid, current: c, direction: .left) == nil)
        #expect(Screen.adjacentDisplayRect(displays: grid, current: c, direction: .up) == nil)
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: c, direction: .right) == Self.at(1, 0))
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: c, direction: .down) == Self.at(0, 1))
    }

    @Test("bottom-right corner (4,4) — right and down both nil; left and up land")
    func bottomRightCornerNeighbors() {
        let grid = Self.makeDisplays()
        let c = Self.at(4, 4)
        #expect(Screen.adjacentDisplayRect(displays: grid, current: c, direction: .right) == nil)
        #expect(Screen.adjacentDisplayRect(displays: grid, current: c, direction: .down) == nil)
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: c, direction: .left) == Self.at(3, 4))
        #expect(
            Screen.adjacentDisplayRect(displays: grid, current: c, direction: .up) == Self.at(4, 3))
    }

    // MARK: - Exhaustive interior sweep

    @Test("every interior display (1..3, 1..3) has exactly the 4 expected neighbors")
    func interiorDisplaysAllFourNeighbors() {
        let grid = Self.makeDisplays()
        for row in 1...3 {
            for col in 1...3 {
                let c = Self.at(col, row)
                #expect(
                    Screen.adjacentDisplayRect(displays: grid, current: c, direction: .left)
                        == Self.at(col - 1, row),
                    "left from (\(col),\(row))"
                )
                #expect(
                    Screen.adjacentDisplayRect(displays: grid, current: c, direction: .right)
                        == Self.at(col + 1, row),
                    "right from (\(col),\(row))"
                )
                #expect(
                    Screen.adjacentDisplayRect(displays: grid, current: c, direction: .up)
                        == Self.at(col, row - 1),
                    "up from (\(col),\(row))"
                )
                #expect(
                    Screen.adjacentDisplayRect(displays: grid, current: c, direction: .down)
                        == Self.at(col, row + 1),
                    "down from (\(col),\(row))"
                )
            }
        }
    }

    // MARK: - Regression: orthogonal-axis isolation
    //
    // The old predicate didn't require Y-overlap on `.right` / `.left` (or
    // X-overlap on `.up` / `.down`), so from (2, 2) going right would match
    // ANY display in column 3 — the first one in display-list order would
    // win, not necessarily the same-row neighbor. These tests pin that
    // behavior down: the result must be in the same row as the source.

    @Test("right from any row picks the same-row neighbor, not row 0")
    func rightStaysInRow() {
        let grid = Self.makeDisplays()
        for row in 0..<5 {
            let c = Self.at(2, row)
            let r = Screen.adjacentDisplayRect(displays: grid, current: c, direction: .right)
            #expect(r == Self.at(3, row), "right from (2,\(row)) should be (3,\(row))")
        }
    }

    @Test("down from any column picks the same-column neighbor, not column 0")
    func downStaysInColumn() {
        let grid = Self.makeDisplays()
        for col in 0..<5 {
            let c = Self.at(col, 2)
            let r = Screen.adjacentDisplayRect(displays: grid, current: c, direction: .down)
            #expect(r == Self.at(col, 3), "down from (\(col),2) should be (\(col),3)")
        }
    }
}
