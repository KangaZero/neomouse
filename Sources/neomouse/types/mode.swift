//TODO move this over to neomouseTypes
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
    case g  // `g` pressed once, awaiting completion
    case gg  // `gg`
    case ggv  // for select all similar to vim's `ggVG`
    case ctrlW  // Ctrl-w pressed, awaiting window command
    case setMark  // `m` pressed, awaiting mark name
    // `'` pressed, awaiting set mark to go to exact location. Similar to vim `
    case goToMark
    // ``` pressed, awaiting set mark to go to exact location with exact visual state for said mark
    case goToMarkExactState
    //TODO nice to have
    // case setMacro // 'q' pressed, awaiting macro name
    // case goToMacro // '@' pressed, awaiting set macro name to go to
}

// MARK: - Mode
enum Mode {
    case disabled
    case normal(
        currentPendingOperation: NormalModePendingOperation,
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
