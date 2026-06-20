import AppKit

import neomouseDB
import neomouseTypes
import neomouseUtils

/// One executable unit of work plus the metadata the pre/post hooks need.
///
/// `startPoint` / `endPoint` are the **intended** target, supplied by the call
/// site — hooks must NOT re-read `Mouse.location()` (racy for async warps,
/// meaningless for non-moving ops). `endPoint` is non-optional because the
/// `executed_operation` row requires it; `startPoint` is set only for visual
/// operations (mirrors `ExecutedOperation.startCGXPoint?`).
@MainActor
struct Command {
    let name: OperationName
    var category: CommandCategory { name.category }
    let keysUsed: String
    let isVisual: Bool
    let mode: ModeName
    let startPoint: CGPoint?
    let endPoint: CGPoint
    let sessionId: Int64
    let action: () -> Void
}

/// Runs a `Command` through `preHooks → action → postHooks`.
///
/// Hooks are immutable, MainActor-isolated `let` arrays — sound under Swift 6
/// strict concurrency (no global mutable state, no `nonisolated(unsafe)`). The
/// keyHandler already runs inside `MainActor.assumeIsolated`, so dispatching
/// through here stays on the main actor. The three after-hooks (auto-snap,
/// front_app_follows_mouse, recording) are populated in the next step; call
/// sites are converted to `execute(_:context:)` after that.
@MainActor
enum ExecutionPipeline {
    static let preHooks: [(Command, KeyEventContext) -> Void] = []
    static let postHooks: [(Command, KeyEventContext) -> Void] = []

    static func execute(_ command: Command, context: KeyEventContext) {
        for hook in preHooks { hook(command, context) }
        command.action()
        for hook in postHooks { hook(command, context) }
    }
}
