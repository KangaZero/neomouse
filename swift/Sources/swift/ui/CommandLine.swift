import AppKit
import SwiftUI

@MainActor
final class CommandLine {
    static let shared = CommandLine()
    private var window: NSPanel?
    private weak var appState: NeoMouseState?
    @State var commandText: String = ""

    private func show() {

        guard
            let currentScreen =
                (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }),
            let appState
        else {
            return debug(
                "Could not retrieve current screen in CommandLine.show and/or appState is \(appState == nil ? "nil" : "not nil")"
            )
        }
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CommandLineView(state: appState))

        let x = currentScreen.visibleFrame.maxX - 320
        let y = currentScreen.visibleFrame.minY + 20
        panel.setFrameOrigin(CGPoint(x: x, y: y))

        panel.orderFront(nil)
        window = panel
    }
    struct CommandLineView: View {
        @ObservedObject var state: NeoMouseState
        @State private var commandText: String = ""

        var filteredSuggestions: [String] {
            if commandText.isEmpty {
                return state.commands
            }
            return state.commands.filter { $0.localizedCaseInsensitiveContains(commandText) }
        }
        var body: some View {
            NavigationStack {
                GroupBox(
                    label: Label("Command Line", systemImage: "building.columns")
                ) {
                    Text("Content goes here")
                }
                .searchable(text: $commandText, prompt: "Type a command...") {
                    ForEach(filteredSuggestions, id: \.self) { suggestion in  //suggestion == command
                        Text(suggestion)
                            .searchCompletion(suggestion)
                    }
                }
            }
        }
    }
}
