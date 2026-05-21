import ScreenCaptureKit
import CoreGraphics

public func screenshot(rect: CGRect, excluding ids: [CGWindowID] = []) async throws
    -> CGImage?
{
    let content = try await SCShareableContent.current

    // Find the display that contains this rect
    guard
        let display = content.displays.first(where: { display in
            display.frame.intersects(rect)
        })
    else {
        return nil
    }

    let excluded = ids.isEmpty ? [] : content.windows.filter { ids.contains($0.windowID) }
    let filter = SCContentFilter(display: display, excludingWindows: excluded)

    let config = SCStreamConfiguration()

    // Convert rect to display-local coordinates
    let localRect = CGRect(
        x: rect.origin.x - display.frame.origin.x,
        y: rect.origin.y - display.frame.origin.y,
        width: rect.width,
        height: rect.height
    )

    config.sourceRect = localRect
    config.width = Int(localRect.width)
    config.height = Int(localRect.height)
    config.showsCursor = false

    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: config
    )
    return image
}

public func screenshotMultiDisplay(rect: CGRect, excluding ids: [CGWindowID] = [])
    async throws -> CGImage?
{
    let content = try await SCShareableContent.current

    // Find all displays that intersect the rect
    debug("relevantDisplays: displays \(content.displays)")
    let relevantDisplays = content.displays.filter { $0.frame.intersects(rect) }
    debug("screenshotMultiDisplay: found \(relevantDisplays.count) relevant displays for rect \(rect)")
    guard !relevantDisplays.isEmpty else { return nil }

    // If only one display, use the simpler path
    if relevantDisplays.count == 1 {
        return try await screenshot(rect: rect, excluding: ids)
    }

    // Capture each display's portion
    var captures: [(image: CGImage, frame: CGRect)] = []

    for display in relevantDisplays {
        let intersection = rect.intersection(display.frame)
        let localRect = CGRect(
            x: intersection.origin.x - display.frame.origin.x,
            y: intersection.origin.y - display.frame.origin.y,
            width: intersection.width,
            height: intersection.height
        )

        let excluded = ids.isEmpty ? [] : content.windows.filter { ids.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        config.width = Int(localRect.width)
        config.height = Int(localRect.height)
        config.showsCursor = false
        do {
            let image: CGImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            captures.append((image, intersection))
        } catch {
            debug("Error capturing image for display \(display.displayID): ", error)
        }
    }

    // Stitch them into one image
    return stitchImages(captures, targetRect: rect)
}

private func stitchImages(_ captures: [(image: CGImage, frame: CGRect)], targetRect: CGRect) -> CGImage? {
    let width = Int(targetRect.width)
    let height = Int(targetRect.height)

    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        return nil
    }

    // SCDisplay.frame uses CG-global coords (top-left origin, y-down).
    // CGContext default = bottom-left origin, y-up. Flip Y so top display
    // lands at top of buffer; else stacked displays end up vertically swapped.
    for (image, frame) in captures {
        let localX = frame.origin.x - targetRect.origin.x
        let localY = targetRect.height - (frame.origin.y - targetRect.origin.y) - frame.height
        let localFrame = CGRect(x: localX, y: localY, width: frame.width, height: frame.height)
        context.draw(image, in: localFrame)
    }

    return context.makeImage()
}
