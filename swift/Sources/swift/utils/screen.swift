import CoreGraphics

func getActiveDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return displays
}

func getCurrentScreenSize() -> CGSize? {
    guard let mouseLoc = CGEvent(source: nil)?.location else { return nil }
    return getActiveDisplays().first(where: { CGDisplayBounds($0).contains(mouseLoc) }).map {
        CGDisplayBounds($0).size
    }
}

func getAllScreensBoundingRect() -> CGRect {
    return getActiveDisplays().reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
}

// Flip a CG-space rect (y down, origin = top-left of primary) into AppKit space
// (y up, origin = bottom-left of primary). NSWindow.setFrame wants AppKit.
func cgRectToAppKitRect(_ rect: CGRect) -> CGRect {
    let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
    return CGRect(
        x: rect.origin.x,
        y: primaryHeight - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

func screenLayouts() {
    let mainBounds = CGDisplayBounds(CGMainDisplayID())
    for id in getActiveDisplays() {
        let frame = CGDisplayBounds(id)
        let position: String
        // CG coords: y=0 at top of primary, y increases downward
        if frame.minX >= mainBounds.maxX { position = "right" }
        else if frame.maxX <= mainBounds.minX { position = "left" }
        else if frame.maxY <= mainBounds.minY { position = "above" }
        else if frame.minY >= mainBounds.maxY { position = "below" }
        else { position = "main" }
        print("Display \(id): \(position) — \(frame)")
    }
}
