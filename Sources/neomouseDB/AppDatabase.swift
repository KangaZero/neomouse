import Foundation
import GRDB

import neomouseUtils

let dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("neomouse.sqlite").path
let dbQueue: DatabaseQueue = {
    do {
        debug("dbPath: \(dbPath)")
        return try DatabaseQueue(path: dbPath)
    } catch {
        fatalError("Failed to open database at \(dbPath): \(error)")
    }
}()

public func initializeDB(forceReIntialize: Bool = false) {
    do {
        try dbQueue.write { db in
            let isTablesExist =
                try db.tableExists("session") && db.tableExists("mark")
                && db.tableExists("register") && db.tableExists("executed_operation")
                && db.tableExists("jump") && db.tableExists("macro")
            if isTablesExist && !forceReIntialize {
                debug("Tables already exist, skipping initialization.")
                return
            }
            // Drop child tables before `session`. FK cascade would handle it,
            // but explicit order keeps reinit deterministic.
            let tables = ["executed_operation", "jump", "macro", "register", "mark", "session"]
            for table in tables {
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
                debug("Dropped table \(table) if it existed")
            }
            // try db.execute(sql: "DROP TABLE IF EXISTS executed_operation")
            // debug("Dropped table 'operation' if it existed.")
            // try db.execute(sql: "DROP TABLE IF EXISTS mark")
            // debug("Dropped table 'mark' if it existed.")
            // try db.execute(sql: "DROP TABLE IF EXISTS session")
            // debug("Dropped table 'session' if it existed.")
            //
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            debug("Created 'session' table")
            var session = Session(id: 1, name: "Cookiezi", createdAt: .now, updatedAt: .now)
            try session.insert(db)
            debug("Created new session: \(session)")

            try db.create(table: "mark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mark", .text).notNull()
                t.column("isVisual", .boolean).notNull()
                t.column("startCGXPoint", .double).notNull()
                t.column("startCGYPoint", .double).notNull()
                t.column("endCGXPoint", .double).notNull()
                t.column("endCGYPoint", .double).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.belongsTo("session", onDelete: .cascade).notNull()
                // Vim semantics: per session, each mark name is unique. Lets
                // setMark rely on a single (sessionId, mark) lookup, and makes
                // duplicates impossible at the SQL level (not just app code).
                t.uniqueKey(["sessionId", "mark"])
            }
            debug("Created 'mark' table")

            try db.create(table: "register") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("register", .text).notNull()
                t.column("content", .blob).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.belongsTo("session", onDelete: .cascade).notNull()
                // Vim semantics: per session, each register name is unique. Lets
                // Register.set rely on a single (sessionId, register) lookup, and
                // makes duplicates impossible at the SQL level (not just app code).
                t.uniqueKey(["sessionId", "register"])
            }
            debug("Created 'register' table")

            try db.create(table: "executed_operation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("isVisual", .boolean).notNull()
                t.column("startCGXPoint", .double)
                t.column("startCGYPoint", .double)
                t.column("endCGXPoint", .double).notNull()
                t.column("endCGYPoint", .double).notNull()
                t.column("keysUsed", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.belongsTo("session", onDelete: .cascade).notNull()
            }
            debug("Created 'executed_operation' table")

            try db.create(table: "jump") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("CGXPoint", .double)
                t.column("CGYPoint", .double)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.belongsTo("session", onDelete: .cascade).notNull()
            }
            debug("Created 'jump' table")

            // try db.create(table: "macro") { t in
            //     t.autoIncrementedPrimaryKey("id")
            //     t.column("macro", .text).notNull()
            //     t.column("keysUsed", .text).notNull()
            //     t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            //     t.belongsTo("session", onDelete: .cascade).notNull()
            // }
            // debug("Created 'macro' table")
        }
    } catch {
        debug("Initialize DB error: ", error)
    }
}
