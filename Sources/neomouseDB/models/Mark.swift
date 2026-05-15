import Foundation
import GRDB

import neomouseUtils

public struct Mark: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mark"
    public var id: Int64?
    public var mark: String
    public var isVisual: Bool
    public var startCGXPoint: Double?  //NOTE: Only exists when isVisual == true
    public var startCGYPoint: Double?  //NOTE: Only exists when isVisual == true
    public var endCGXPoint: Double  //Serves as the x position when isVisual == false
    public var endCGYPoint: Double  //Serves as the y position when isVisual == false
    public var createdAt: Date
    public var sessionId: Int64

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let mark = Column(CodingKeys.mark)
        static let isVisual = Column(CodingKeys.isVisual)
        static let startCGXPoint = Column(CodingKeys.startCGXPoint)
        static let startCGYPoint = Column(CodingKeys.startCGYPoint)
        static let endCGXPoint = Column(CodingKeys.endCGXPoint)
        static let endCGYPoint = Column(CodingKeys.endCGYPoint)
        static let createdAt = Column(CodingKeys.createdAt)
        static let sessionId = Column(CodingKeys.sessionId)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
    public static func get(
        mark: String,
        sessionId: Int64
    ) -> Mark? {
        do {
            return try dbQueue.read { db in
                try Mark
                    .filter(Mark.Columns.sessionId == sessionId)
                    .filter(Mark.Columns.mark == mark)
                    .fetchOne(db)
            }
        } catch {
            debug("Mark - get error: ", error)
            return nil
        }
    }
    /// Upsert a mark by (sessionId, mark). Matches Vim's `ma` overwrite semantics:
    /// pressing `ma` twice from different positions keeps the second position, not
    /// two rows. If an existing mark with the same (sessionId, mark) is found, its
    /// CG points are updated; otherwise a new row is inserted.
    public static func set(
        mark: String,
        isVisual: Bool,
        startCGXPoint: Double?,
        startCGYPoint: Double?,
        endCGXPoint: Double,
        endCGYPoint: Double,
        sessionId: Int64
    ) {
        do {
            try dbQueue.write { db in
                if var existing =
                    try Mark
                    .filter(Mark.Columns.sessionId == sessionId)
                    .filter(Mark.Columns.mark == mark)
                    .fetchOne(db)
                {
                    debug("Mark - get: Overwritting existing mark in")
                    existing.startCGXPoint = startCGXPoint
                    existing.startCGYPoint = startCGYPoint
                    existing.endCGXPoint = endCGXPoint
                    existing.endCGYPoint = endCGYPoint
                    try existing.update(db)
                } else {
                    debug("Mark - get: Creating new mark in with mark \(mark)")
                    var newMark = Mark(
                        mark: mark,
                        isVisual: isVisual,
                        startCGXPoint: startCGXPoint,
                        startCGYPoint: startCGYPoint,
                        endCGXPoint: endCGXPoint,
                        endCGYPoint: endCGYPoint,
                        createdAt: Date(),
                        sessionId: sessionId
                    )
                    try newMark.insert(db)
                }
            }
        } catch {
            debug("Mark - get: error: ", error)
        }
    }

    public static func delete(
        mark: String,
        sessionId: Int64
    ) {
        do {
            try dbQueue.write { db in
                guard
                    let existing =
                        try Mark
                        .filter(Mark.Columns.sessionId == sessionId)
                        .filter(Mark.Columns.mark == mark)
                        .fetchOne(db)
                else {
                    return debug("Mark - delete: Cannot find existing mark to delete")
                }
                try existing.delete(db)
            }
        } catch {
            debug("Mark - delete: error: ", error)
        }
    }
}
