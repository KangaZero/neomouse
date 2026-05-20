import AppKit

/// Namespace for every value type that models a NeoMouse interaction-state.
/// Grouping keeps the public surface searchable (`NemouseType.<tab>`) and
/// avoids polluting the module's top level.
public struct NeomouseType {
    private init() {}  // Type-only — never instantiated.

    // MARK: - Supporting Types

    public struct FindState {
        public var pendingGridDivisionIndex: Int? = nil
        public var pendingInnerGridDivisionIndex: Int? = nil

        public init(
            pendingGridDivisionIndex: Int? = nil,
            pendingInnerGridDivisionIndex: Int? = nil
        ) {
            self.pendingGridDivisionIndex = pendingGridDivisionIndex
            self.pendingInnerGridDivisionIndex = pendingInnerGridDivisionIndex
        }
    }

    public struct VisualState: Codable {
        public var startPos: CGPoint? = nil
        public var endPos: CGPoint? = nil

        public init(startPos: CGPoint? = nil, endPos: CGPoint? = nil) {
            self.startPos = startPos
            self.endPos = endPos
        }
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
        case goToRegister  // " pressed, awaiting register name to go to
        case registerAction(register: String)
        //TODO nice to have
        // case setMacro // 'q' pressed, awaiting macro name
        // case goToMacro // '@' pressed, awaiting set macro name to go to
    }

    // MARK: - Mode

    public enum Mode {
        case disabled
        case normal(
            currentPendingOperation: NormalModePendingOperation,
        )
        case find(
            currentPendingOperation: String?,
            findState: FindState,
        )
        // case visualFind
        case command(
            command: String,
            // Highlighted suggestion in the wildmenu list. nil = no selection;
            // Tab / Shift-Tab cycle this index round-robin through filtered hits.
            // Typing a character resets to nil.
            suggestionIndex: Int?
        )
        case menu
    }

    public enum ConfigMode: String, Decodable, Sendable {
        case disabled
        case normal
        case find
        case command
        case menu
    }
}
