import Foundation

import neomouseTypes
import neomouseUtils

/// Plain `Sendable` snapshot of one executed operation. The keyHandler's
/// post-hook builds this on the MainActor from scalar values (never capturing
/// `KeyEventContext` / `NSEvent`, which aren't `Sendable`) and hands it to the
/// recorder for off-critical-path persistence.
public struct RecordedOperation: Sendable {
    public let name: OperationName
    public let isVisual: Bool
    public let startCGXPoint: Double?
    public let startCGYPoint: Double?
    public let endCGXPoint: Double
    public let endCGYPoint: Double
    public let keysUsed: String
    public let mode: ModeName
    public let sessionId: Int64

    public init(
        name: OperationName, isVisual: Bool, startCGXPoint: Double?, startCGYPoint: Double?,
        endCGXPoint: Double, endCGYPoint: Double, keysUsed: String, mode: ModeName, sessionId: Int64
    ) {
        self.name = name
        self.isVisual = isVisual
        self.startCGXPoint = startCGXPoint
        self.startCGYPoint = startCGYPoint
        self.endCGXPoint = endCGXPoint
        self.endCGYPoint = endCGYPoint
        self.keysUsed = keysUsed
        self.mode = mode
        self.sessionId = sessionId
    }
}

/// Serial, ordered sink for operation recording.
///
/// The post-hook calls `enqueue(_:)` synchronously on the MainActor — no
/// `Task`-per-keystroke, no `await` on the keystroke critical path. A single
/// consumer drains the `AsyncStream` in FIFO submission order and writes each
/// row via `ExecutedOperation.set`, so insertion order (and therefore the
/// `createdAt.desc` reads in `getAll`) tracks keystroke order even under
/// key-repeat — which a fan-out of detached Tasks could not guarantee.
public actor OperationRecorder {
    public static let shared = OperationRecorder()

    // Immutable Sendable `let` → safe to touch from `nonisolated enqueue`.
    private let continuation: AsyncStream<RecordedOperation>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: RecordedOperation.self)
        self.continuation = continuation
        Task { await self.consume(stream) }
    }

    /// Append a record. Synchronous + `nonisolated` so the MainActor caller
    /// pays only a buffer append; `AsyncStream.yield` preserves submission order.
    public nonisolated func enqueue(_ op: RecordedOperation) {
        continuation.yield(op)
    }

    private func consume(_ stream: AsyncStream<RecordedOperation>) async {
        for await op in stream {
            ExecutedOperation.set(
                name: op.name, isVisual: op.isVisual,
                startCGXPoint: op.startCGXPoint, startCGYPoint: op.startCGYPoint,
                endCGXPoint: op.endCGXPoint, endCGYPoint: op.endCGYPoint,
                keysUsed: op.keysUsed, mode: op.mode, sessionId: op.sessionId)
        }
    }
}
