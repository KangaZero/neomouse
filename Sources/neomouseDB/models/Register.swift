import AppKit
import Foundation
import GRDB

import neomouseUtils

/// A vim-style register, storing whatever `NSPasteboardItem` was yanked.
///
/// `NSPasteboardItem` isn't `NSSecureCoding`, but its content is just a map of
/// pasteboard-type → bytes. We flatten that to `[String: Data]`, archive the
/// dictionary (NSDictionary IS secure-codable), and reconstruct the item on
/// read. Round-trips every type the source app wrote — `.string`, `.rtf`,
/// `.html`, `.png`, etc. — so paste-from-register is byte-identical to the
/// original copy.
public struct Register: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "register"
    public var id: Int64?
    public var register: String  //INFO: follow same naming as Vim — single letter / digit / quote
    public var content: Data  //INFO: NSKeyedArchiver blob of [typeRawValue: Data]
    /// URL the source app exposed at copy time (public.url / Chrome's
    /// org.chromium.source-url). nil for plain text/image copies.
    public var originURL: String?
    /// Bundle ID of the app that was frontmost when this entry was written.
    /// Resolved to icon + display name at render time. nil for launch-time
    /// seeds where "frontmost" isn't a meaningful concept.
    public var sourceAppBundleId: String?
    public var createdAt: Date
    public var sessionId: Int64

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let register = Column(CodingKeys.register)
        static let content = Column(CodingKeys.content)
        static let originURL = Column(CodingKeys.originURL)
        static let sourceAppBundleId = Column(CodingKeys.sourceAppBundleId)
        static let createdAt = Column(CodingKeys.createdAt)
        static let sessionId = Column(CodingKeys.sessionId)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decode `content` back into an `NSPasteboardItem`. `nil` if the blob is
    /// corrupted (shouldn't happen — we wrote it ourselves).
    public var pasteboardItem: NSPasteboardItem? {
        do {
            let classes: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self]
            guard
                let dict = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: content)
                    as? [String: Data]
            else { return nil }
            let item = NSPasteboardItem()
            for (key, value) in dict {
                item.setData(value, forType: NSPasteboard.PasteboardType(key))
            }
            return item
        } catch {
            debug("Register.pasteboardItem decode error: ", error)
            return nil
        }
    }

    public static func get(register: String, sessionId: Int64) -> Register? {
        do {
            guard
                register.count == 1,
                register.first!.isLetter == true || register.first!.isNumber == true
            else {
                debug("Register - get: Invalid register \(register). registers must be a single letter or number.")
                return nil
            }
            let row = try dbQueue.read { db in
                try Register
                    .filter(Columns.sessionId == sessionId)
                    .filter(Columns.register == register)
                    .fetchOne(db)
            }
            return row
        } catch {
            debug("Register.get error: ", error)
            return nil
        }
    }

    public static func getAll(sessionId: Int64) -> [Register]? {
        do {
            return try dbQueue.read { db in
                try Register
                    .filter(Columns.sessionId == sessionId)
                    .fetchAll(db)
            }
        } catch {
            debug("Register.getAll error: ", error)
            return nil
        }
    }

    /// Upsert a register by (sessionId, register). Last write wins, matching
    /// Vim's `"ay` overwrite semantics — one row per (session, register name).
    public static func set(register: String, item: NSPasteboardItem, sessionId: Int64) {
        do {
            guard
                register.count == 1,
                register.first!.isLetter == true || register.first!.isNumber == true
            else {
                return debug(
                    "Register - get: Invalid register \(register). registers must be a single letter or number.")
            }
            let data = try encode(item)
            let originURL = extractOriginURL(from: item)
            // NSWorkspace.frontmostApplication reflects the app that was on top
            // when the synthesized ⌘C ran. NeoMouse is a non-activating event
            // tap, so for yank flows this stays as Safari/Chrome/etc. across
            // the brief DispatchQueue.main.async hop. For the launch-time seed
            // it'll be the terminal/Xcode that spawned us — accurate, if not
            // particularly useful.
            let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            try dbQueue.write { db in
                if var existing =
                    try Register
                    .filter(Columns.sessionId == sessionId)
                    .filter(Columns.register == register)
                    .fetchOne(db)
                {
                    existing.content = data
                    existing.originURL = originURL
                    existing.sourceAppBundleId = bundleId
                    existing.createdAt = Date()
                    try existing.update(db)
                } else {
                    var newRegister = Register(
                        register: register,
                        content: data,
                        originURL: originURL,
                        sourceAppBundleId: bundleId,
                        createdAt: Date(),
                        sessionId: sessionId
                    )
                    try newRegister.insert(db)
                }
            }
        } catch {
            debug("Register.set error: ", error)
        }
    }

    /// Pull a usable URL string out of the pasteboard item. Prefers
    /// `public.url` (set by every Mac browser on hyperlink-copy and by Finder
    /// for file copies). Falls back to Chrome's private
    /// `org.chromium.source-url`, which is set whenever the user copies text
    /// from a page and carries the page URL itself. Returns nil for anything
    /// else.
    private static func extractOriginURL(from item: NSPasteboardItem) -> String? {
        if let s = item.string(forType: .URL), !s.isEmpty { return s }
        let chromeKey = NSPasteboard.PasteboardType("org.chromium.source-url")
        if let s = item.string(forType: chromeKey), !s.isEmpty { return s }
        return nil
    }

    public static func delete(register: String, sessionId: Int64) {
        do {
            try dbQueue.write { db in
                guard
                    let existing =
                        try Register
                        .filter(Columns.sessionId == sessionId)
                        .filter(Columns.register == register)
                        .fetchOne(db)
                else {
                    return debug("Cannot find existing register to delete")
                }
                try existing.delete(db)
            }
        } catch {
            debug("Register.delete error: ", error)
        }
    }

    private static func encode(_ item: NSPasteboardItem) throws -> Data {
        var dict: [String: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) {
                dict[type.rawValue] = data
            }
        }
        return try NSKeyedArchiver.archivedData(
            withRootObject: dict as NSDictionary,
            requiringSecureCoding: true
        )
    }
}
