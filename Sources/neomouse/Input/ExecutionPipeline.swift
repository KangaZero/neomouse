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
    static let preHooks: [@MainActor (Command, KeyEventContext) -> Void] = []
    // Recording runs for every command (record-everything decision). front_app
    // / auto-snap are NOT here yet — they still fire coarsely at the dispatch
    // (KeyDispatch). They move here (category-filtered) only once every relevant
    // op flows through execute(), so the coarse calls can be removed without a
    // double-fire window. Until then this post-hook is purely additive.
    static let postHooks: [@MainActor (Command, KeyEventContext) -> Void] = [recordOperation]

    static func execute(_ command: Command, context: KeyEventContext) {
        for hook in preHooks { hook(command, context) }
        command.action()
        for hook in postHooks { hook(command, context) }
    }

    /// Snapshot the command's scalars on the MainActor and hand them to the
    /// serial recorder (never captures `context` / its `NSEvent`).
    private static func recordOperation(_ command: Command, _ context: KeyEventContext) {
        OperationRecorder.shared.enqueue(
            RecordedOperation(
                name: command.name,
                isVisual: command.isVisual,
                startCGXPoint: command.startPoint.map { Double($0.x) },
                startCGYPoint: command.startPoint.map { Double($0.y) },
                endCGXPoint: Double(command.endPoint.x),
                endCGYPoint: Double(command.endPoint.y),
                keysUsed: command.keysUsed,
                mode: command.mode,
                sessionId: command.sessionId))
    }
}

extension NeoMouse {
    /// Run a screen-local cardinal motion through the pipeline: warp to
    /// `target` and record it. The caller keeps ownership of the subsequent
    /// `appState.mode` reset, since motions differ in what pending state they
    /// leave behind (e.g. `gg` parks in `.gg`, `0` leaves the count alone).
    @MainActor
    static func executeMotion(
        _ ctx: KeyEventContext, name: OperationName, keysUsed: String, toScreenLocal target: CGPoint
    ) {
        let appState = ctx.appState
        ExecutionPipeline.execute(
            Command(
                name: name, keysUsed: keysUsed, isVisual: appState.isVisual, mode: .normal,
                startPoint: appState.isVisual ? appState.visual.startPos : nil,
                endPoint: target, sessionId: ctx.sessionId,
                action: { Mouse.moveToScreenLocal(x: target.x, y: target.y) }),
            context: ctx)
    }
}
