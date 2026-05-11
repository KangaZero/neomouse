import AppKit

@MainActor
func exitVisualMode(appState: NeoMouseState, visualHighlightOverlay: VisualHighlightOverlay) {
    guard appState.startCGXPoint != nil && appState.endCGXPoint != nil else { return }
    mouseUp(.left, at: CGPoint(x: appState.endCGXPoint!, y: appState.endCGYPoint!))
    appState.startCGXPoint = nil
    appState.startCGYPoint = nil
    appState.endCGXPoint = nil
    appState.endCGYPoint = nil
    visualHighlightOverlay.hideOverlay()
    appState.mode = .normal(
        currentPendingOperation: nil
    )
}
