import Foundation
import GRDB

import neomouseUtils

let dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("neomouse.sqlite").path
let dbQueue: DatabaseQueue = {
    do {
        return try DatabaseQueue(path: dbPath)
    } catch {
        fatalError("Failed to open database at \(dbPath): \(error)")
    }
}()

enum ModeName: String, Codable, DatabaseValueConvertible {
    case disabled, normal, find, command
}

enum OperationName: String, Codable, DatabaseValueConvertible {
    case motionXMinus, motionXPlus, motionYMinus, motionYPlus, motionXMin, motionXMax, motionYMin,
        motionYMax, motionXMid, motionYMid, clickLeft, clickRight, clickMiddle, scrollUp,
        scrollDown, scrollLeft, scrollRight
}

public func initializeDB(forceReSeed: Bool) {
    do {
        try dbQueue.write { db in
            let isTablesExist =
                try db.tableExists("session") && db.tableExists("mark")
                && db.tableExists("operation")
            if isTablesExist && !forceReSeed {
                debug("Tables already exist, skipping initialization.")
                return
            }
            try db.execute(sql: "DROP TABLE IF EXISTS operation")
            debug("Dropped table 'mark' if it operation.")
            try db.execute(sql: "DROP TABLE IF EXISTS mark")
            debug("Dropped table 'mark' if it existed.")
            try db.execute(sql: "DROP TABLE IF EXISTS session")
            debug("Dropped table 'session' if it existed.")

            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(table: "mark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mark", .text).notNull()
                t.column("endCGXPoint", .double).notNull()
                t.column("endCGYPoint", .double).notNull()
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.belongsTo("session", onDelete: .cascade).notNull()
            }
            try db.create(table: "operation") { t in
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
        }
    } catch {
        debug("Initialize DB error: ", error)

    }
}

func seedSession() {
    do {
        try dbQueue.write { db in
            var newSession = Session(name: "Seed Session", createdAt: Date(), updatedAt: Date())
            try newSession.insert(db)
        }
    } catch {
        debug("Seed Session error: ", error)
    }
}

func seedMark(numberOfMarks: Int) {
    let markCharacters: [String] = "0123456789abcdefghijklmnopqrstuvwxyz".map {
        String($0)
    }
    guard numberOfMarks <= markCharacters.count || numberOfMarks <= 0 else {
        debug(
            "Number of marks to seed exceeds available unique characters: \(markCharacters.count) or is 0 or less: ",
            numberOfMarks)
        return
    }

    guard let currentScreen = getCurrentScreenSize() else {
        debug("Could not get current screen size in seedMark")
        return
    }
    do {
        try dbQueue.write { db in
            for i in 0..<numberOfMarks {
                var newMark = Mark(
                    mark: markCharacters[i],
                    endCGXPoint: Double.random(in: 0...currentScreen.width),
                    endCGYPoint: Double.random(in: 0...currentScreen.height),
                    createdAt: Date(),
                    sessionId: 1)
                try newMark.insert(db)
            }
        }
    } catch {
        debug("Seed Mark error: ", error)
    }

}

struct Session: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "session"
    var id: Int64?
    var name: String
    var createdAt: Date
    var updatedAt: Date

    static let marks = hasMany(Mark.self)
    static let operations = hasMany(Operation.self)

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Mark: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mark"
    var id: Int64?
    var mark: String
    var endCGXPoint: Double
    var endCGYPoint: Double
    var createdAt: Date
    var sessionId: Int64

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let mark = Column(CodingKeys.mark)
        static let endCGXPoint = Column(CodingKeys.endCGXPoint)
        static let endCGYPoint = Column(CodingKeys.endCGYPoint)
        static let createdAt = Column(CodingKeys.createdAt)
        static let sessionId = Column(CodingKeys.sessionId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Operation: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "operation"
    var id: Int64?
    var name: OperationName
    var isVisual: Bool
    var startCGXPoint: Double?  //INFO: Only exists when isVisual is true, otherwise it's null
    var startCGYPoint: Double?  //INFO: Only exists when isVisual is true, otherwise it's null
    var endCGXPoint: Double
    var endCGYPoint: Double
    var keysUsed: String  // INFO: 'ggvG', '10j' etc
    var mode: ModeName  // INFO: 'ggvG', '10j' etc
    var createdAt: Date
    var sessionId: Int64

    //INFO: This is needed for compile-time type-safety
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let isVisual = Column(CodingKeys.isVisual)
        static let startCGXPoint = Column(CodingKeys.startCGXPoint)
        static let startCGYPoint = Column(CodingKeys.startCGYPoint)
        static let endCGXPoint = Column(CodingKeys.endCGXPoint)
        static let endCGYPoint = Column(CodingKeys.endCGYPoint)
        static let keysUsed = Column(CodingKeys.keysUsed)
        static let mode = Column(CodingKeys.mode)
        static let createdAt = Column(CodingKeys.createdAt)  // or executedAt
        static let sessionId = Column(CodingKeys.sessionId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
