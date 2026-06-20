import neomouseTypes

extension OperationName {
    /// Coarse category used by the execution pipeline to filter after-hooks
    /// (auto-snap and `front_app_follows_mouse` only fire for `.motion`) and
    /// to tag recorded operations for later analysis.
    ///
    /// Deliberately **total** — no `default:` clause — so adding a new
    /// `OperationName` case is a compile error until it's been categorized.
    public var category: CommandCategory {
        switch self {
        case .MotionOperationType:
            return .motion
        case .MouseOperationType, .TrackpadOperationType:
            // No dedicated mouse/click bucket; clicks, scrolls, and trackpad
            // gestures all live under .gesture.
            return .gesture
        case .toggleNeomouse, .Esc:
            return .global
        case .goToPreviousVisualPosition, .visualToggle, .visualLineSelect,
            .visualSwapAnchor, .visualYank:
            return .visual
        case .selectRegister, .registerYank, .registerDelete, .registerPaste:
            return .register
        case .find, .quickGridFind, .specialFind:
            return .find
        // goToMark warps the cursor, so it's a motion (auto-snap / front-app
        // hooks treat it like one). jumpAdjacentScreen is multi-display
        // navigation → .screen. (Whether either should also trigger
        // front_app_follows_mouse is issue #3 open question 3.)
        case .goToMark, .snapToGrid:
            return .motion
        case .jumpAdjacentScreen:
            return .screen
        case .toggleHelp, .openCommandLine:
            return .ui
        case .setMark, .setMacro, .goToMacro, .exCommand:
            return .command
        }
    }
}
