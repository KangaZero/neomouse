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

    //TODO add in test for this
    public static func adjacentDisplayRectByDirection(at: NeomouseType.Direction) -> CGRect? {
        let displayIDs = activeDisplays()
        guard !displayIDs.isEmpty && displayIDs.count > 1 else {
            debug(
                "Screen.getAdjacentDisplayRectByDirection: display count is \(displayIDs.count); need at least 2 for adjacentRect to be meaningful"
            )
            return nil
        }
        //TODO check whether or not mouse location is always valid
        guard let mouseLocation = Mouse.location() else {
            debug("Screen.getAdjacentDisplayRectByDirection: could not get mouse location")
            return nil
        }

        guard
            let currentDisplayRect =
                displayIDs
                .first(where: { CGDisplayBounds($0).contains(mouseLocation) })
                .map({ CGDisplayBounds($0) })
        else {
            debug(
                "Screen.getAdjacentDisplayRectByDirection: could not find display under cursor; cannot determine adjacent display by direction"
            )
            return nil
        }
        guard
            let nextDisplayIndex = displayIDs.first(where: { display in
                guard
                    display
                        != displayIDs
                        .first(where: { CGDisplayBounds($0).contains(mouseLocation) })
                else { return false }

                let displayRect = CGDisplayBounds(display)
                debug(
                    "current display x: [min \(currentDisplayRect.minX), max \(currentDisplayRect.maxX)], y: [min \(currentDisplayRect.minY), max \(currentDisplayRect.maxY)]"
                )
                debug(
                    "candidate display x: [min \(displayRect.minX), max \(displayRect.maxX)], y: [min \(displayRect.minY), max \(displayRect.maxY)]"
                )
                //TODO: Not sure how to test this properly. So far will work if there are only 2 displays, but not sure if more are added.
                switch at {
                case .right:
                    return currentDisplayRect.maxX == displayRect.minX && currentDisplayRect.minX < displayRect.minX
                        && currentDisplayRect.maxX < displayRect.maxX
                // return displayRect.minX >= currentDisplayRect.maxX && displayRect.maxX > currentDisplayRect.maxX
                case .left:
                    return currentDisplayRect.minX == displayRect.maxX && currentDisplayRect.minX > displayRect.minX
                        && currentDisplayRect.maxX > displayRect.maxX
                // return displayRect.maxX <= currentDisplayRect.minX && displayRect.minX < currentDisplayRect.minX
                case .down:
                    return currentDisplayRect.maxY == displayRect.minY && currentDisplayRect.minY < displayRect.minY
                        && currentDisplayRect.maxY < displayRect.maxY
                // return displayRect.minY >= currentDisplayRect.maxY && displayRect.maxY > currentDisplayRect.maxY
                case .up:
                    return currentDisplayRect.minY == displayRect.maxY && currentDisplayRect.minY > displayRect.minY
                        && currentDisplayRect.maxY > displayRect.maxY
                // return displayRect.maxY >= currentDisplayRect.minY && displayRect.minY < currentDisplayRect.minY
                }
            })
        else {
            debug(
                "Screen.getAdjacentDisplayRectByDirection: could not find adjacent display in direction \(at) from current display; maybe no displays are arranged in that direction?"
            )
            return nil
        }
        debug("nextDisplayIndex: \(nextDisplayIndex)")
        debug("displays: \(displayIDs)")
        //IMPORTANT: Need to substract 1 as displayIDs start from 1, and indexing beyond will cause out of bounds error
        return CGDisplayBounds(displayIDs[(Int(nextDisplayIndex) - 1)])
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
