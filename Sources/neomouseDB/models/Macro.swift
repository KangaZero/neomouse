import Foundation
import GRDB

import neomouseUtils

public struct Macro: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "macro"
    public var id: Int64?
    public var macro: String
    public var keysUsed: String
    public var createdAt: Date
    public var sessionId: Int64

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let macro = Column(CodingKeys.macro)
        static let keysUsed = Column(CodingKeys.keysUsed)
        static let createdAt = Column(CodingKeys.createdAt)
        static let sessionId = Column(CodingKeys.sessionId)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static func get(
        macro: String,
        sessionId: Int64
    ) -> Macro? {
        do {
            return try dbQueue.read { db in
                try Macro
                    .filter(Macro.Columns.sessionId == sessionId)
                    .filter(Macro.Columns.macro == macro)
                    .fetchOne(db)
            }
        } catch {
            debug("Macro - get error: ", error)
            return nil
        }
    }

    public static func set(
        macro: String,
        sessionId: Int64,
        keysUsedToSet: String
    ) {
        do {
            try dbQueue.write { db in
                if var existing =
                    try Macro
                    .filter(Macro.Columns.sessionId == sessionId)
                    .filter(Macro.Columns.macro == macro)
                    .fetchOne(db)
                {
                    debug("Macro - set: Overwritting existing macro")
                    existing.keysUsed = keysUsedToSet
                    try existing.update(db)
                } else {
                    debug("Macro - set: Creating new macro")
                    var newMacro = Macro(
                        macro: macro,
                        keysUsed: keysUsedToSet,
                        createdAt: Date(),
                        sessionId: sessionId
                    )
                    try newMacro.insert(db)
                }
            }
        } catch {
            debug("Macro - set error: ", error)
        }
    }

    public static func delete(
        macro: String,
        sessionId: Int64
    ) {
        do {
            try dbQueue.write { db in
                guard
                    let existing =
                        try Macro
                        .filter(Macro.Columns.sessionId == sessionId)
                        .filter(Macro.Columns.macro == macro)
                        .fetchOne(db)
                else {
                    return debug("Cannot find existing macro to delete")
                }
                try existing.delete(db)
            }
        } catch {
            debug("Macro - delete error: ", error)
        }
    }
}
