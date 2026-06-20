import CoreGraphics

import neomouseTypes

/// Namespace for display/screen geometry helpers.
public enum Screen {
    public static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays
    }

    // public static func mainRect() -> CGRect {
    //     activeDisplays().first.map { CGDisplayBounds($0) } ?? .zero
    // }

    /// Size of the screen currently under the cursor.
    public static func currentSize() -> CGSize? {
        guard let mouseLoc = CGEvent(source: nil)?.location else { return nil }
        let currentSize = activeDisplays().first(where: { CGDisplayBounds($0).contains(mouseLoc) }).map {
            CGDisplayBounds($0).size
        }
        if let currentSize {
            return currentSize
        } else {
            debug("Screen.currentSize: could not find display under cursor; defaulting to main display size")
            return CGDisplayBounds(CGMainDisplayID()).size
        }
    }

    /// Find the display rect adjacent to `current` in `direction`. Pure —
    /// caller supplies the display list + current rect, so this is testable
    /// without real CGDisplay state. `adjacentDisplayRectByDirection(at:)`
    /// is the impure wrapper that queries `activeDisplays()` + cursor.
    ///
    /// Predicate: a candidate display matches when it (a) edge-touches
    /// `current` along the chosen axis and (b) overlaps `current` on the
    /// *orthogonal* axis. The orthogonal-overlap check is what makes this
    /// correct on grid layouts — without it, `.right` from a 5x5 grid's
    /// (2, 2) would match any display in column 3 and `first(where:)` would
    /// return whichever happened to come first in the display list, not
    /// necessarily the one in row 2.
    ///
    /// CG coord conventions: y increases downward. `.down` means the
    /// candidate sits *below* current visually, i.e. its `minY` equals
    /// current's `maxY`. `.up` is the inverse.
    public static func adjacentDisplayRect(
        displays: [CGRect],
        current: CGRect,
        direction: NeomouseType.Direction
    ) -> CGRect? {
        displays.first(where: { display in
            guard display != current else { return false }
            switch direction {
            case .right:
                return current.maxX == display.minX && haveYOverlap(current, display)
            case .left:
                return current.minX == display.maxX && haveYOverlap(current, display)
            case .down:
                return current.maxY == display.minY && haveXOverlap(current, display)
            case .up:
                return current.minY == display.maxY && haveXOverlap(current, display)
            }
        })
    }

    private static func haveYOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        !(a.maxY <= b.minY || b.maxY <= a.minY)
    }

    private static func haveXOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        !(a.maxX <= b.minX || b.maxX <= a.minX)
    }

    public static func adjacentDisplayRectByDirection(at: NeomouseType.Direction) -> CGRect? {
        let displayIDs = activeDisplays()
        guard displayIDs.count > 1 else {
            debug(
                "Screen.adjacentDisplayRectByDirection: display count is \(displayIDs.count); need at least 2 for adjacentRect to be meaningful"
            )
            return nil
        }
        guard let mouseLocation = Mouse.location() else {
            debug("Screen.adjacentDisplayRectByDirection: could not get mouse location")
            return nil
        }
        let displays = displayIDs.map { CGDisplayBounds($0) }
        guard let current = displays.first(where: { $0.contains(mouseLocation) }) else {
            debug(
                "Screen.adjacentDisplayRectByDirection: no display under cursor at \(mouseLocation)"
            )
            return nil
        }
        return adjacentDisplayRect(displays: displays, current: current, direction: at)
    }

    /// Rect of the next display in `activeDisplays` order, wrapping around.
    public static func adjacentRect() -> CGRect? {
        let displays = activeDisplays()
        guard !displays.isEmpty && displays.count > 1 else {
            debug(
                "Screen.adjacentRect: display count is \(displays.count); need at least 2 for adjacentRect to be meaningful"
            )
            return nil
        }
        guard let mouseLocation = Mouse.location() else { return nil }

        let currentIndex =
            displays.firstIndex { CGDisplayBounds($0).contains(mouseLocation) } ?? 0
        let nextIndex = (currentIndex + 1) % displays.count
        return CGDisplayBounds(displays[nextIndex])
    }

    /// Union rect of every active display, in CG space.
    public static func allBoundingRect() -> CGRect {
        activeDisplays().reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// Flip a CG-space rect (y down, origin = top-left of primary) into AppKit
    /// space (y up, origin = bottom-left of primary). `NSWindow.setFrame` wants
    /// AppKit.
    public static func cgToAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func printLayouts() {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        for id in activeDisplays() {
            let frame = CGDisplayBounds(id)
            let position: String
            // CG coords: y=0 at top of primary, y increases downward
            if frame.minX >= mainBounds.maxX {
                position = "right"
            } else if frame.maxX <= mainBounds.minX {
                position = "left"
            } else if frame.maxY <= mainBounds.minY {
                position = "above"
            } else if frame.minY >= mainBounds.maxY {
                position = "below"
            } else {
                position = "main"
            }
            print("Display \(id): \(position) — \(frame)")
        }
    }
}
