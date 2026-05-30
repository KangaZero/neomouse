import AppKit
import SwiftUI

import neomouseUtils

/// One-shot dense grid that pops up in a fixed-size box around the cursor.
/// A single keypress lands the mouse on the picked cell. Sibling to
/// `GridOverlay` (full-screen find) but kept in its own file because the
/// geometry, lifecycle (one-shot), and keyboard contract are all different
/// enough that a shared abstraction would just be `if dense` everywhere.
@MainActor
final class CursorSurroundedGridOverlay {

    static let shared = CursorSurroundedGridOverlay()
    private var window: NSWindow?
    private weak var appState: NeoMouseState?

    /// CG-global top-left of the box, captured at show() time so the
    /// keyHandler can resolve a picked (col, row) back to a screen position
    /// without re-querying the cursor (which may have moved). Cleared on
    /// hide().
    private(set) var boxTopLeftCG: CGPoint?

    /// Theme-driven runtime values. The keyHandler reads `divisions` (via
    /// `currentDivisions`) to size the cell math, so we keep a property
    /// instead of inlining theme access in the keyHandler call sites.
    var currentDivisions: Int {
        appState?.theme.grid.cursorSurroundedDivisions ?? 6
    }
    var currentBoxSize: CGFloat {
        CGFloat(appState?.theme.grid.cursorSurroundedBoxSize ?? 200)
    }

    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func passAppState(state: NeoMouseState) {
        appState = state
    }

    func toggle() {
        if let window, window.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        window?.orderOut(nil)
        boxTopLeftCG = nil
    }

    /// Resolve a (col, row) cell to its CG-global center, suitable for
    /// `Mouse.moveToGlobal`. Returns nil if the overlay isn't currently shown.
    func cellCenterCG(col: Int, row: Int) -> CGPoint? {
        guard let topLeft = boxTopLeftCG else { return nil }
        let cellSize = currentBoxSize / CGFloat(currentDivisions)
        return CGPoint(
            x: topLeft.x + CGFloat(col) * cellSize + cellSize / 2,
            y: topLeft.y + CGFloat(row) * cellSize + cellSize / 2
        )
    }

    // MARK: - Show

    private func show() {
        guard let appState, case .specialFind = appState.mode else {
            return debug(
                "CursorSurroundedGridOverlay.show: appState/mode mismatch (mode is \(String(describing: appState?.mode)))"
            )
        }
        // We need both: NSEvent.mouseLocation (NS screen coords, y-up) for
        // NSWindow positioning, and Mouse.location() (CG global, y-down) for
        // the box top-left we hand to the keyHandler. Computing each in its
        // native coord space avoids any flipped-y conversion.
        let nsCursor = NSEvent.mouseLocation
        guard
            let nsScreen = NSScreen.screens.first(where: { $0.frame.contains(nsCursor) })
        else {
            return debug("CursorSurroundedGridOverlay.show: no NSScreen under cursor")
        }
        guard let cgCursor = Mouse.location() else {
            return debug("CursorSurroundedGridOverlay.show: Mouse.location() returned nil")
        }
        guard
            let displayID = Screen.activeDisplays().first(where: {
                CGDisplayBounds($0).contains(cgCursor)
            })
        else {
            return debug("CursorSurroundedGridOverlay.show: no CG display under cursor")
        }

        let size = currentBoxSize

        // NS-side: window frame in screen coords. visibleFrame excludes menu
        // bar + Dock, so we can't tuck under either.
        var nsOrigin = CGPoint(x: nsCursor.x - size / 2, y: nsCursor.y - size / 2)
        let nsBounds = nsScreen.visibleFrame
        nsOrigin.x = max(nsBounds.minX, min(nsOrigin.x, nsBounds.maxX - size))
        nsOrigin.y = max(nsBounds.minY, min(nsOrigin.y, nsBounds.maxY - size))
        let frame = CGRect(origin: nsOrigin, size: CGSize(width: size, height: size))

        // CG-side: top-left of the box in global CG coords. Clamped against
        // CGDisplayBounds (NOT visibleFrame — the CG bounds include menu bar
        // because CG has no concept of the macOS chrome; the NS clamp above
        // already keeps the window away from it). We mirror the NS clamp so
        // the stored CG corner stays in sync with the actual rendered window.
        var cgTopLeft = CGPoint(x: cgCursor.x - size / 2, y: cgCursor.y - size / 2)
        let cgBounds = CGDisplayBounds(displayID)
        cgTopLeft.x = max(cgBounds.minX, min(cgTopLeft.x, cgBounds.maxX - size))
        cgTopLeft.y = max(cgBounds.minY, min(cgTopLeft.y, cgBounds.maxY - size))
        boxTopLeftCG = cgTopLeft

        if window == nil {
            window = OverlayWindow.makeFullscreenClickThrough(
                contentRect: frame,
                rootView: CursorSurroundedGridOverlayView(state: appState)
            )
        }
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
    }
}

// MARK: - SwiftUI

private struct CursorSurroundedGridOverlayView: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        let theme = state.theme.grid
        GeometryReader { geo in
            ZStack {
                theme.background.swiftUI
                Canvas { ctx, _ in
                    let divisions = theme.cursorSurroundedDivisions
                    let cellW = geo.size.width / CGFloat(divisions)
                    let cellH = geo.size.height / CGFloat(divisions)

                    // Grid lines.
                    var path = Path()
                    for i in 0...divisions {
                        let x = CGFloat(i) * cellW
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        let y = CGFloat(i) * cellH
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    ctx.stroke(path, with: .color(theme.outerLineColor.swiftUI), lineWidth: 0.5)

                    // Character labels — reuse the inner-grid alphabet so
                    // the user doesn't have to learn a third character set.
                    let chars = state.findModeInnerGridDivisionCharacters
                    for col in 0..<divisions {
                        for row in 0..<divisions {
                            let index = row * divisions + col
                            guard index < chars.count else { continue }
                            let label = Text(chars[index])
                                .font(theme.cursorSurroundedLabelFont.swiftUI)
                                .foregroundColor(theme.innerLabelColor.swiftUI)
                            ctx.draw(
                                label,
                                at: CGPoint(
                                    x: CGFloat(col) * cellW + cellW / 2,
                                    y: CGFloat(row) * cellH + cellH / 2
                                ),
                                anchor: .center
                            )
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.all)
    }
}
