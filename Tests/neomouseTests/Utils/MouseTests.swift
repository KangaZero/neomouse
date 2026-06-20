import Testing

import neomouseUtils

/// `Mouse` is the cursor driver: every function posts a real CGEvent
/// (`CGEvent.post`, click/scroll/drag), warps the cursor
/// (`CGWarpMouseCursorPosition`), or queries live `CGDisplay` / cursor state.
/// None of it is unit-testable without either physically moving the cursor
/// (CI-hostile, flaky) or a testability refactor that injects an
/// event-posting / display seam so fakes can record the calls.
///
/// The pure motion *logic* that feeds these side effects IS covered:
/// grid-target resolution in `MotionTargetsTests`, the pending-operation
/// reducer in `PendingOpReducerTests`, and display adjacency in `ScreenTests`.
/// Direct `Mouse.*` coverage is deferred to that refactor (see issue #5).
@Suite("Mouse (cursor driver)")
struct MouseTests {
    @Test(
        "Mouse.* needs a testability seam",
        .disabled("side-effecting: posts CGEvents / warps the real cursor — deferred to #5"))
    func deferredPendingTestabilityRefactor() {
        // Intentionally empty: documents that Mouse coverage is a known gap,
        // visible as a skipped test in the run rather than silently absent.
    }
}
