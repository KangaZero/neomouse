import Foundation
import GRDB

import neomouseUtils

func seedSession(session: Session) {
    do {
        try dbQueue.write { db in
            for i in 0..<5 {
                var newSession = Session(id: Int64(i), name: "Seed \(i)", createdAt: Date(), updatedAt: Date())
                try newSession.insert(db)
            }
        }
    } catch {
        debug("Seed Session error: ", error)
    }
}

func seedMark(numberOfMarks: Int = 5) {
    let markCharacters: [String] = "0123456789abcdefghijklmnopqrstuvwxyz".map {
        String($0)
    }
    guard numberOfMarks > 0, numberOfMarks <= markCharacters.count else {
        debug(
            "Invalid numberOfMarks \(numberOfMarks): must be in 1...\(markCharacters.count)")
        return
    }

    guard let currentScreen = getCurrentScreenSize() else {
        debug("Could not get current screen size in seedMark")
        return
    }
    do {
        try dbQueue.write { db in
            for i in 0..<numberOfMarks {
                let startX = Double.random(in: 0...currentScreen.width)
                let startY = Double.random(in: 0...currentScreen.height)
                let endX = Double.random(in: 0...currentScreen.width)
                let endY = Double.random(in: 0...currentScreen.height)
                let isVisual = Int.random(in: 1..<2) == 1 ? true : false
                Mark.set(
                    mark: markCharacters[i],
                    isVisual: isVisual,
                    startCGXPoint: isVisual ? startX : nil,
                    startCGYPoint: isVisual ? startY : nil,
                    endCGXPoint: endX,
                    endCGYPoint: endY,
                    sessionId: 1
                )
            }
        }
    } catch {
        debug("Seed Mark error: ", error)
    }

}
