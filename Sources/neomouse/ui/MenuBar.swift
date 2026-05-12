import AppKit
import SwiftUI

struct MenuBar: Scene {
    var body: some Scene {
        MenuBarExtra("NeoMouse", systemImage: "cursorarrow.motionlines") {
            Button("Quit NeoMouse") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
