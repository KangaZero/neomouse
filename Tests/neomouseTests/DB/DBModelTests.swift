import AppKit
import Foundation
import Testing

import neomouseDB

/// CRUD coverage for every GRDB model. The global `dbQueue` is a single
/// on-disk SQLite file, so these run `.serialized` and each test calls
/// `initializeDB(forceReIntialize: true)` in `init()` to drop + recreate the
/// schema and reseed the one bootstrap session (id 1, "Cookiezi") — giving
/// every test an identical clean slate. Tests black-box through the public
/// model API; `dbQueue` itself is module-internal.
///
/// Not covered: `Macro` — `initializeDB` never creates its table (the
/// `create(table: "macro")` block is commented out), so the model has no
/// backing store to exercise yet.
@Suite("DB models — CRUD on a freshly reinitialized database", .serialized)
struct DBModelTests {
    let sessionId: Int64

    init() {
        initializeDB(forceReIntialize: true)
        sessionId = Session.getLast()?.id ?? -1
    }

    // MARK: - Session

    @Test("the bootstrap session is reachable by id, last, and name")
    func bootstrapSession() {
        #expect(sessionId == 1)
        #expect(Session.getById(sessionId: 1)?.id == 1)
        #expect(Session.getLast()?.id == 1)
        #expect(Session.getByName(sessionName: "Cookiezi")?.id == 1)
        #expect(Session.getByName(sessionName: "does-not-exist") == nil)
    }

    @Test("Session.update persists a rename")
    func sessionUpdate() {
        Session.update(at: 1, newSessionName: "Renamed")
        #expect(Session.getByName(sessionName: "Renamed")?.id == 1)
        // The original name no longer resolves once the rename has persisted.
        #expect(Session.getByName(sessionName: "Cookiezi") == nil)
    }

    // MARK: - Mark

    @Test("Mark.set then get round-trips a non-visual mark")
    func markSetGet() {
        Mark.set(
            mark: "a", isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 100, endCGYPoint: 200, sessionId: sessionId)
        let m = Mark.get(mark: "a", sessionId: sessionId)
        #expect(m?.mark == "a")
        #expect(m?.isVisual == false)
        #expect(m?.endCGXPoint == 100)
        #expect(m?.endCGYPoint == 200)
    }

    @Test("Mark.set rejects multi-character mark names")
    func markRejectsInvalid() {
        Mark.set(
            mark: "ab", isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 1, endCGYPoint: 2, sessionId: sessionId)
        #expect(Mark.get(mark: "ab", sessionId: sessionId) == nil)
        #expect(Mark.getAll(sessionId: sessionId)?.isEmpty == true)
    }

    @Test("Mark.set overwrites the same name in place (one row, new coords)")
    func markUpsert() {
        Mark.set(
            mark: "b", isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 1, endCGYPoint: 2, sessionId: sessionId)
        Mark.set(
            mark: "b", isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 9, endCGYPoint: 9, sessionId: sessionId)
        let bMarks = Mark.getAll(sessionId: sessionId)?.filter { $0.mark == "b" }
        #expect(bMarks?.count == 1)
        #expect(Mark.get(mark: "b", sessionId: sessionId)?.endCGXPoint == 9)
    }

    @Test("Mark.delete removes the mark")
    func markDelete() {
        Mark.set(
            mark: "c", isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 1, endCGYPoint: 1, sessionId: sessionId)
        Mark.delete(mark: "c", sessionId: sessionId)
        #expect(Mark.get(mark: "c", sessionId: sessionId) == nil)
    }

    // MARK: - Register

    private func makeItem(_ string: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        return item
    }

    @Test("Register.set then get round-trips string content")
    func registerSetGet() {
        Register.set(register: "a", item: makeItem("hello"), sessionId: sessionId)
        let r = Register.get(register: "a", sessionId: sessionId)
        #expect(r?.register == "a")
        #expect(r?.pasteboardItem?.string(forType: .string) == "hello")
    }

    @Test("Register.cycleNumbered shifts the ring and mirrors into 0 and 1")
    func registerCycle() {
        Register.cycleNumbered(item: makeItem("first"), sessionId: sessionId)
        #expect(
            Register.get(register: "1", sessionId: sessionId)?.pasteboardItem?
                .string(forType: .string) == "first")
        #expect(
            Register.get(register: "0", sessionId: sessionId)?.pasteboardItem?
                .string(forType: .string) == "first")

        Register.cycleNumbered(item: makeItem("second"), sessionId: sessionId)
        // "first" shifted 1 -> 2; "second" is now in both 1 and 0.
        #expect(
            Register.get(register: "2", sessionId: sessionId)?.pasteboardItem?
                .string(forType: .string) == "first")
        #expect(
            Register.get(register: "1", sessionId: sessionId)?.pasteboardItem?
                .string(forType: .string) == "second")
        #expect(
            Register.get(register: "0", sessionId: sessionId)?.pasteboardItem?
                .string(forType: .string) == "second")
    }

    @Test("Register.delete removes the register")
    func registerDelete() {
        Register.set(register: "z", item: makeItem("x"), sessionId: sessionId)
        Register.delete(register: "z", sessionId: sessionId)
        #expect(Register.get(register: "z", sessionId: sessionId) == nil)
    }

    // MARK: - Jump

    @Test("Jump.set appends rows with incrementing ids")
    func jumpSet() {
        Jump.set(sessionId: sessionId, CGXPoint: 1, CGYPoint: 2)
        Jump.set(sessionId: sessionId, CGXPoint: 3, CGYPoint: 4)
        #expect(Jump.getAll(sessionId: sessionId)?.count == 2)
        #expect(Jump.get(id: 1, sessionId: sessionId)?.CGXPoint == 1)
        #expect(Jump.get(id: 2, sessionId: sessionId)?.CGYPoint == 4)
    }

    @Test("Jump.deleteAfter removes jumps with a greater id")
    func jumpDeleteAfter() {
        for i in 1...3 { Jump.set(sessionId: sessionId, CGXPoint: Double(i), CGYPoint: 0) }
        Jump.deleteAfter(excludingCurrentId: 1, sessionId: sessionId)
        #expect(Jump.getAll(sessionId: sessionId)?.count == 1)
        #expect(Jump.get(id: 1, sessionId: sessionId) != nil)
    }

    // MARK: - ExecutedOperation

    @Test("ExecutedOperation.set then getAll returns the row")
    func execOpSetGetAll() {
        ExecutedOperation.set(
            name: .Esc, isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 5, endCGYPoint: 6, keysUsed: "x", mode: .normal, sessionId: sessionId)
        let all = ExecutedOperation.getAll(sessionId: sessionId)
        #expect(all?.count == 1)
        #expect(all?.first?.keysUsed == "x")
        #expect(all?.first?.name == .Esc)
    }

    @Test("ExecutedOperation.getAll(name:) filters by operation name")
    func execOpByName() {
        ExecutedOperation.set(
            name: .Esc, isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 0, endCGYPoint: 0, keysUsed: "esc", mode: .normal, sessionId: sessionId)
        ExecutedOperation.set(
            name: .setMark, isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 0, endCGYPoint: 0, keysUsed: "ma", mode: .normal, sessionId: sessionId)
        #expect(ExecutedOperation.getAll(name: .Esc, sessionId: sessionId)?.count == 1)
        #expect(
            ExecutedOperation.getAll(name: .setMark, sessionId: sessionId)?.first?.keysUsed == "ma")
    }

    @Test("ExecutedOperation.get by id, then delete")
    func execOpGetDelete() throws {
        ExecutedOperation.set(
            name: .Esc, isVisual: false, startCGXPoint: nil, startCGYPoint: nil,
            endCGXPoint: 0, endCGYPoint: 0, keysUsed: "x", mode: .normal, sessionId: sessionId)
        let id = try #require(ExecutedOperation.getAll(sessionId: sessionId)?.first?.id)
        #expect(ExecutedOperation.get(id: id, sessionId: sessionId)?.id == id)
        ExecutedOperation.delete(id: id, sessionId: sessionId)
        #expect(ExecutedOperation.getAll(sessionId: sessionId)?.isEmpty == true)
    }
}
