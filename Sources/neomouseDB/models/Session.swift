import Foundation
import GRDB

import neomouseUtils

public struct Session: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "session"
    public var id: Int64?
    var name: String
    var createdAt: Date
    var updatedAt: Date

    static let marks = hasMany(Mark.self)
    static let jumps = hasMany(Jump.self)
    static let macros = hasMany(Macro.self)
    static let executed_operations = hasMany(ExecutedOperation.self)

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    //INFO This only when id is incremental
    public static func getLast() -> Session? {
        do {
            return try dbQueue.read { db in
                let sessionCount = try Session.all().fetchCount(db)
                guard sessionCount > 0 else {
                    debug("No sessions found in fn getSessionById")
                    return nil
                }
                return try Session.order(Session.Columns.id.desc).fetchOne(db)
            }
        } catch {
            debug("getLastSession error: ", error)
            return nil
        }
    }

    public static func getById(sessionId: Int64) -> Session? {
        do {
            return try dbQueue.read { db in
                guard let session = try Session.filter(Session.Columns.id == sessionId).fetchOne(db) else {
                    debug("Cannot find existing session in fn getSessionById")
                    return nil
                }
                return session
            }
        } catch {
            debug("getSessionById error: ", error)
            return nil
        }
    }

    public static func getByName(sessionName: String) -> Session? {
        do {
            return try dbQueue.read { db in
                guard let session = try Session.filter(Session.Columns.name == sessionName).fetchOne(db) else {
                    debug("Cannot find existing session in fn getSessionByName")
                    return nil
                }
                return session
            }
        } catch {
            debug("getSessionById error: ", error)
            return nil
        }
    }

    /// Updates an existing session in the database.
    ///
    /// Always refreshes `updatedAt`. Optionally updates the session name
    /// if `newSessionName` is provided.
    ///
    /// - Parameters:
    ///   - sessionId: The unique identifier of the session to update.
    ///   - newSessionName: A new name for the session, or `nil` to leave it unchanged.
    ///
    /// ## Example
    /// ```swift
    /// // Rename a session
    /// updateSession(at: 1, newSessionName: "My Session")
    ///
    /// // Just bump updatedAt
    /// updateSession(at: 1)
    /// ```
    public static func update(at sessionId: Int64, newSessionName: String?) {
        do {
            try dbQueue.write { db in
                guard var session = try Session.filter(Session.Columns.id == sessionId).fetchOne(db) else {
                    return debug("Cannot find existing session in fn updateSession")
                }
                session.updatedAt = .now
                if let newSessionName {
                    session.name = newSessionName
                }
                try session.update(db)
            }
        } catch {
            debug("updateSession error: ", error)
        }
    }
}
