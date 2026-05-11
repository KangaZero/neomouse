import AppKit

@MainActor
func exitVisualMode(appState: NeoMouseState, visualHighlightOverlay: VisualHighlightOverlay) {
    guard appState.startCGXPoint != nil && appState.endCGXPoint != nil else { return }
    mouseUp(.left, at: CGPoint(x: appState.endCGXPoint!, y: appState.endCGYPoint!))
    //TODO Eventually use Session.Operations Table
    guard
        appState.startCGXPoint != nil && appState.startCGYPoint != nil
            && appState.endCGXPoint != nil && appState.endCGYPoint != nil
    else {
        return debug(
            "Could not retrieve start or end CG points in exitVisualMode",
            "startCGPoint:\(String(describing: appState.startCGXPoint)), \(String(describing: appState.startCGYPoint)), endCGPoint: \(String(describing: appState.endCGXPoint)), \(String(describing: appState.endCGYPoint))"
        )
    }
    appState.previousStartCGXPoint = appState.startCGXPoint
    appState.previousStartCGYPoint = appState.startCGYPoint
    appState.previousEndCGXPoint = appState.endCGXPoint
    appState.previousEndCGYPoint = appState.endCGYPoint
    appState.startCGXPoint = nil
    appState.startCGYPoint = nil
    appState.endCGXPoint = nil
    appState.endCGYPoint = nil
    visualHighlightOverlay.hideOverlay()
    appState.mode = .normal(
        currentPendingOperation: nil
    )
}
