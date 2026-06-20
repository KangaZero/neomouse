import Foundation
import Testing

import neomouseDB
import neomouseTypes

/// Pure (no database) coverage of the `OperationName` → `CommandCategory`
/// mapping and the Codable encoding of the operation enums — including the
/// `exCommand(name:)` associated-value case the recorder will persist.
@Suite("OperationName categorization + encoding")
struct OperationCategoryTests {
    @Test("each operation maps to its expected category")
    func categoryMapping() {
        #expect(OperationName.MotionOperationType(.motionXMinus).category == .motion)
        #expect(OperationName.MotionOperationType(.motionToLine).category == .motion)
        #expect(OperationName.MotionOperationType(.motionToColumn).category == .motion)
        #expect(OperationName.snapToGrid.category == .motion)
        #expect(OperationName.goToMark.category == .motion)
        #expect(OperationName.MouseOperationType(.leftMouseDown).category == .gesture)
        #expect(OperationName.TrackpadOperationType(.pinchZoomIn).category == .gesture)
        #expect(OperationName.jumpAdjacentScreen.category == .screen)
        #expect(OperationName.visualToggle.category == .visual)
        #expect(OperationName.goToPreviousVisualPosition.category == .visual)
        #expect(OperationName.registerPaste.category == .register)
        #expect(OperationName.find.category == .find)
        #expect(OperationName.specialFind.category == .find)
        #expect(OperationName.toggleHelp.category == .ui)
        #expect(OperationName.openCommandLine.category == .ui)
        #expect(OperationName.toggleNeomouse.category == .global)
        #expect(OperationName.Esc.category == .global)
        #expect(OperationName.setMark.category == .command)
        #expect(OperationName.exCommand(name: "numbers").category == .command)
    }

    @Test("OperationName round-trips through Codable, including exCommand's payload")
    func operationNameCodableRoundTrip() throws {
        let cases: [OperationName] = [
            .MotionOperationType(.motionToColumn),
            .Esc,
            .visualYank,
            .exCommand(name: "relativenumbers"),
        ]
        for op in cases {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(OperationName.self, from: data)
            #expect(decoded == op)
        }
    }

    @Test("CommandCategory round-trips through its String raw value")
    func categoryCodableRoundTrip() throws {
        for category in CommandCategory.allCases {
            let data = try JSONEncoder().encode(category)
            #expect(try JSONDecoder().decode(CommandCategory.self, from: data) == category)
        }
    }
}
