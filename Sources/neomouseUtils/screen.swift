import CoreGraphics

/// Namespace for display/screen geometry helpers.
public enum Screen {
    public static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays
    }

    public static func mainRect() -> CGRect {
        activeDisplays().first.map { CGDisplayBounds($0) } ?? .zero
    }

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
            return mainRect().size
        }
    }

    /// Rect of the next display in `activeDisplays` order, wrapping around.
    public static func adjacentRect() -> CGRect? {
        let displays = activeDisplays()
        guard !displays.isEmpty else { return nil }
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
