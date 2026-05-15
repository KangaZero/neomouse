import Foundation
import GRDB

import neomouseUtils

//TODO decide what counts as a jump
public struct Jump: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "jump"
    public var id: Int64?
    public var CGXPoint: Double
    public var CGYPoint: Double
    public var createdAt: Date
    public var sessionId: Int64

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let CGXPoint = Column(CodingKeys.CGXPoint)
        static let CGYPoint = Column(CodingKeys.CGYPoint)
        static let createdAt = Column(CodingKeys.createdAt)
        static let sessionId = Column(CodingKeys.sessionId)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public func getJump(
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
        debug("getMark error: ", error)
        return nil
    }
}
