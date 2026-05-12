// import Foundation
// import GRDB
//
// enum ModeUnionType: String, Codable {
//     case disabled, normal, find, command
// }
// extension ModeUnionType: DatabaseValueConvertible {}
//
// private struct Session: Codable, FetchableRecord, PersistableRecord {
//     static let databaseTableName = "sessions"
//     /// Int64 is the recommended type for auto-incremented database ids.
//     /// Use nil for those that are not inserted yet in the database.
//     var id: Int64?
//     static let marks = hasMany(MarkRecord.self)
//     static let operations = hasMany(OperationRecord.self)
// }
//
// extension Session {
// static func new() -> Session {
// Session(id:s
//     }
//     }
//
//
//
//
// private struct MarkRecord: Codable, FetchableRecord, MutablePersistableRecord {
//     static let databaseTableName = "marks"
//     var id: Int64?
//     var sessionId: Int64
//     var mark: String
//     var cgPointX: Double
//     var cgPointY: Double
//     // var visualState: String?
//
//     mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
// }
//
// private struct OperationRecord: Codable, FetchableRecord, MutablePersistableRecord {
//     static let databaseTableName = "operations"
//     var id: Int64?
//     var sessionId: Int64
//     var mode: ModeUnionType
//     var operationName: String
//     var operationExecuted: String
//     var cgPointX: Double
//     var cgPointY: Double
//     var visualState: String?
//
//     mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
// }
// //
// // extension MarkRecord {
// //     fileprivate init(_ marks: Marks, sessionId: UUID) {
// //         id = nil
// //         self.sessionId = sessionId
// //         mark = marks.mark
// //         cgPointX = marks.cgPoint.x
// //         cgPointY = marks.cgPoint.y
// //         visualState = marks.visualState.flatMap {
// //             (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) }
// //         }
// //     }
// //
// //     fileprivate func toMarks() -> Marks {
// //         Marks(
// //             mark: mark,
// //             visualState:
// //                 visualState
// //                 .flatMap { $0.data(using: .utf8) }
// //                 .flatMap { try? JSONDecoder().decode(VisualState.self, from: $0) },
// //             cgPoint: CGPoint(x: cgPointX, y: cgPointY)
// //         )
// //     }
// // }
// // extension OperationRecord {
// //     fileprivate init(_ op: Operation, sessionId: UUID) {
// //         id = nil
// //         self.sessionId = sessionId
// //         mode = op.mode
// //         operationName = op.operationName
// //         operationExecuted = op.operationExecuted
// //         cgPointX = op.cgPoint.x
// //         cgPointY = op.cgPoint.y
// //         visualState = op.visualState.flatMap {
// //             (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) }
// //         }
// //     }
// //
// //     fileprivate func toOperation() -> Operation {
// //         Operation(
// //             mode: mode,
// //             operationName: operationName,
// //             operationExecuted: operationExecuted,
// //             cgPoint: CGPoint(x: cgPointX, y: cgPointY),
// //             visualState:
// //                 visualState
// //                 .flatMap { $0.data(using: .utf8) }
// //                 .flatMap { try? JSONDecoder().decode(VisualState.self, from: $0) }
// //         )
// //     }
// // }
// //
// // // MARK: - AppDatabase
// //
// // struct AppDatabase {
// //     static let shared: AppDatabase = {
// //         do { return try makeDefault() } catch { fatalError("AppDatabase init failed: \(error)") }
// //     }()
// //
// //     private let dbQueue: DatabaseQueue
// //
// //     private static func makeDefault() throws -> AppDatabase {
// //         let appSupport = try FileManager.default.url(
// //             for: .applicationSupportDirectory, in: .userDomainMask,
// //             appropriateFor: nil, create: true)
// //         let dir = appSupport.appendingPathComponent("NeoMouse")
// //         try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
// //         let db = AppDatabase(
// //             dbQueue: try DatabaseQueue(path: dir.appendingPathComponent("db.sqlite").path))
// //         try db.migrate()
// //         return db
// //     }
// //
// //     private func migrate() throws {
// //         var migrator = DatabaseMigrator()
// //         migrator.registerMigration("v1") { db in
// //             try db.create(table: "sessions") { t in
// //                 t.primaryKey("id", .text)
// //             }
// //             try db.create(table: "marks") { t in
// //                 t.autoIncrementedPrimaryKey("id")
// //                 t.column("sessionId", .text).notNull().references("sessions", onDelete: .cascade)
// //                 t.column("mark", .text).notNull()
// //                 t.column("cgPointX", .double).notNull()
// //                 t.column("cgPointY", .double).notNull()
// //                 t.column("visualState", .text)
// //             }
// //             try db.create(table: "operations") { t in
// //                 t.autoIncrementedPrimaryKey("id")
// //                 t.column("sessionId", .text).notNull().references("sessions", onDelete: .cascade)
// //                 t.column("mode", .text).notNull()
// //                 t.column("operationName", .text).notNull()
// //                 t.column("operationExecuted", .text).notNull()
// //                 t.column("cgPointX", .double).notNull()
// //                 t.column("cgPointY", .double).notNull()
// //                 t.column("visualState", .text)
// //             }
// //         }
// //         try migrator.migrate(dbQueue)
// //     }
// //
// //     func fetchSession(id: UUID) throws -> Session? {
// //         try dbQueue.read { db in
// //             guard try SessionRecord.fetchOne(db, key: id) != nil else { return nil }
// //             let marks =
// //                 try MarkRecord
// //                 .filter(Column("sessionId") == id)
// //                 .fetchAll(db)
// //                 .map { $0.toMarks() }
// //             let operations =
// //                 try OperationRecord
// //                 .filter(Column("sessionId") == id)
// //                 .fetchAll(db)
// //                 .map { $0.toOperation() }
// //             return Session(id: id, marks: marks, operations: operations)
// //         }
// //     }
// //
// //     func saveSession(_ session: Session) throws {
// //         try dbQueue.write { db in
// //             try SessionRecord(id: session.id).save(db)
// //             try MarkRecord.filter(Column("sessionId") == session.id).deleteAll(db)
// //             for mark in session.marks {
// //                 var record = MarkRecord(mark, sessionId: session.id)
// //                 try record.insert(db)
// //             }
// //             try OperationRecord.filter(Column("sessionId") == session.id).deleteAll(db)
// //             for op in session.operations {
// //                 var record = OperationRecord(op, sessionId: session.id)
// //                 try record.insert(db)
// //             }
// //         }
// //     }
// //
// //     func deleteSession(id: UUID) throws {
// //         try dbQueue.write { db in
// //             _ = try SessionRecord.deleteOne(db, key: id)
// //         }
// //     }
// // }
