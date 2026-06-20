import Foundation
import GRDB
import neomouseUtils

public enum ModeName: Equatable, Codable, DatabaseValueConvertible {
    case disabled, normal, find, command
}

//INFO: moveMoved type expanded to all 8 directions, and also added motion to start/end of line/screen. This is to capture more fine-grained info about the motion operation, which can be useful for analysis and recommendations. For example, if we see a lot of motionYPlus (k) operations,etc
public enum MotionOperationType: Equatable, Codable, DatabaseValueConvertible {
    case motionXMinus,  //h
        motionXPlus,  //l
        motionYMinus,  //j
        motionYPlus,  //k
        motionXMin,  //0
        motionXMax,  //$
        motionYMin,  //G
        motionYMax,  //gg
        motionXMid,  //gm
        motionYMid  //M
}

//INFO: refer to types used: https://developer.apple.com/documentation/coregraphics/cgeventtype
public enum MouseOperationType: Equatable, Codable, DatabaseValueConvertible {
    case leftMouseDown,
        rightMouseDown,
        otherMouseDown,
        otherMouseUp,
        leftMouseUp,
        rightMouseUp,
        // mouseMoved,
        leftMouseDragged,
        rightMouseDragged,
        scrollWheelUp,  //CGEventType only has scrollWheel
        scrollWheelDown,
        scrollWheelLeft,
        scrollWheelRight
}

public enum TrackpadOperationType: Equatable, Codable, DatabaseValueConvertible {
    case pinchZoomIn,
        pinchZoomOut,
        smartMagnify,
        rotateClockwise,
        rotateCounterClockwise,
        swipeUp,  //swipe up with 3 or 4 fingers . Maybe show mission control
        swipeDown,  //swipe up with 3 or 4 fingers. Maybe hide mission control
        swipeLeft,  // swipe with 2 or 3 fingers
        swipeRight,  // swipe with 2 or 3 fingers
        spreadWithThumb,  // Maybe just toggle show desktop
        toggleNotificationsCenter  // swipe left from right edge with 2 or 3 fingers
}

public enum OperationName: Equatable, Codable, DatabaseValueConvertible {
    case MotionOperationType(MotionOperationType),
        MouseOperationType(MouseOperationType),
        TrackpadOperationType(TrackpadOperationType),
        //Custom Operations that don't map directly to a single CGEventType or gesture, but are still useful to track for analysis and recommendations. For example, setting a mark and going to a mark are fundamental Vim operations that can be performed with different keys and in different modes, but they don't have a direct mapping to a single CGEventType or gesture. By defining custom operation types for these actions, we can capture them in our data model and use that information for analysis and recommendations.
        toggleNeomouse,
        Esc,
        goToPreviousVisualPosition,  // `gv` in normal mode.
        setMark,
        goToMark,
        jumpAdjacentScreen,
        setMacro,
        goToMacro
}

public struct ExecutedOperation: Codable,
    Identifiable,
    FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "excecuted_operation"
    public var id: Int64?
    public var name: OperationName
    public var isVisual: Bool
    public var startCGXPoint: Double?  //INFO: Only exists when isVisual is true, otherwise it's null
    public var startCGYPoint: Double?  //INFO: Only exists when isVisual is true, otherwise it's null
    public var endCGXPoint: Double
    public var endCGYPoint: Double
    public var keysUsed: String  // INFO: 'ggvG', '10j' etc
    public var mode: ModeName  // INFO: 'ggvG', '10j' etc
    public var createdAt: Date
    public var sessionId: Int64

    //INFO: This is needed for compile-time type-safety
    public enum Columns {
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

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static func getAll(sessionId: Int64) -> [ExecutedOperation]? {
        do {
            return try dbQueue.read { db in
                try ExecutedOperation
                    .filter(ExecutedOperation.Columns.sessionId == sessionId)
                    .order(ExecutedOperation.Columns.createdAt.desc)
                    .fetchAll(db)
            }
        } catch {
            debug("ExecutedOperation.getAll error: ", error)
            return nil
        }
    }

    public static func get(
        id: Int64,
        sessionId: Int64
    ) -> ExecutedOperation? {
        do {
            return try dbQueue.read { db in
                try ExecutedOperation
                    .filter(ExecutedOperation.Columns.sessionId == sessionId)
                    .filter(ExecutedOperation.Columns.id == id)
                    .fetchOne(db)
            }
        } catch {
            debug("ExecutedOperation.get error: ", error)
            return nil
        }
    }

    public static func getAll(
        name: OperationName,
        sessionId: Int64
    ) -> [ExecutedOperation]? {
        do {
            return try dbQueue.read { db in
                try ExecutedOperation
                    .filter(ExecutedOperation.Columns.sessionId == sessionId)
                    .filter(ExecutedOperation.Columns.name == name)
                    .order(ExecutedOperation.Columns.createdAt.desc)
                    .fetchAll(db)
            }
        } catch {
            debug("ExecutedOperation.getAll(name:) error: ", error)
            return nil
        }
    }

    public static func set(
        name: OperationName,
        isVisual: Bool,
        startCGXPoint: Double?,
        startCGYPoint: Double?,
        endCGXPoint: Double,
        endCGYPoint: Double,
        keysUsed: String,
        mode: ModeName,
        sessionId: Int64
    ) {
        do {
            try dbQueue.write { db in
                var newExecutedOperation = ExecutedOperation(
                    name: name,
                    isVisual: isVisual,
                    startCGXPoint: startCGXPoint,
                    startCGYPoint: startCGYPoint,
                    endCGXPoint: endCGXPoint,
                    endCGYPoint: endCGYPoint,
                    keysUsed: keysUsed,
                    mode: mode,
                    createdAt: Date(),
                    sessionId: sessionId
                )
                try newExecutedOperation.insert(db)
            }
        } catch {
            debug("ExecutedOperation.set error: ", error)
        }
    }

    public static func delete(
        id: Int64,
        sessionId: Int64
    ) {
        do {
            try dbQueue.write { db in
                guard
                    let existing =
                        try ExecutedOperation
                        .filter(ExecutedOperation.Columns.sessionId == sessionId)
                        .filter(ExecutedOperation.Columns.id == id)
                        .fetchOne(db)
                else {
                    return debug("Cannot find existing executed operation to delete")
                }
                try existing.delete(db)
            }
        } catch {
            debug("ExecutedOperation.delete error: ", error)
        }
    }
}
