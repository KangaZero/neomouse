import AppKit

// MARK: - Supporting Types
struct FindState {
    var pendingGridDivisionIndex: Int? = nil
    var pendingInnerGridDivisionIndex: Int? = nil
}

struct VisualState: Codable {
    var startPos: CGPoint? = nil
    var endPos: CGPoint? = nil
}

// MARK: - Mode
enum Mode {
    case disabled
    case normal(
        currentPendingOperation: String?,
    )
    case find(
        currentPendingOperation: String?,
        findState: FindState,
    )
    // case visualFind
    case command(
        currentPendingOperation: String?,
        commandOperationsExecuted: [String]?
    )
}
