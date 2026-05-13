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

public enum NormalModePendingOperation: Equatable {
    case none
    case count(Int)  // numeric prefix being assembled (e.g. "10" → 10)
    case g  // `g` pressed once, awaiting completion
    case ctrlW  // Ctrl-w pressed, awaiting window command
    case setMark  // `m` pressed, awaiting mark name
    case goToMark  // `'` pressed, awaiting set mark to go to
    case goToMarkExact  // ``` pressed, awaiting set mark to go to exact location
    //TODO nice to have
    // case setMacro // 'q' pressed, awaiting macro name
    // case goToMacro // '@' pressed, awaiting set macro name to go to
}

// MARK: - Mode
enum Mode {
    case disabled
    case normal(
        currentPendingOperation: String?,
        //TODO change to below
        // currentPendingOperation: NormalModePendingOperation,
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
