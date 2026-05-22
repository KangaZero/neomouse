// //WARNING: Moved to CoreOpertions
// import AppKit
//
// import neomouseUtils
//
// @MainActor
// func CoreOperations.exitVisualState(appState: NeoMouseState, visualHighlightOverlay: VisualHighlightOverlay) {
//     guard appState.startCGXPoint != nil && appState.endCGXPoint != nil else { return }
//     Mouse.up(.left, at: CGPoint(x: appState.endCGXPoint!, y: appState.endCGYPoint!))
//     //TODO Eventually use Session.Operations Table
//     guard
//         appState.startCGXPoint != nil && appState.startCGYPoint != nil
//             && appState.endCGXPoint != nil && appState.endCGYPoint != nil
//     else {
//         return debug(
//             "Could not retrieve start or end CG points in CoreOperations.exitVisualState",
//             "startCGPoint:\(String(describing: appState.startCGXPoint)), \(String(describing: appState.startCGYPoint)), endCGPoint: \(String(describing: appState.endCGXPoint)), \(String(describing: appState.endCGYPoint))"
//         )
//     }
//     appState.previousVisualStartCGXPoint = appState.startCGXPoint
//     appState.previousVisualStartCGYPoint = appState.startCGYPoint
//     appState.previousVisualEndCGXPoint = appState.endCGXPoint
//     appState.previousVisualEndCGYPoint = appState.endCGYPoint
//     appState.startCGXPoint = nil
//     appState.startCGYPoint = nil
//     appState.endCGXPoint = nil
//     appState.endCGYPoint = nil
//     visualHighlightOverlay.hideOverlay()
//     appState.mode = .normal(
//         currentPendingOperation: .none
//     )
//     appState.operationCountAsString = nil
// }
