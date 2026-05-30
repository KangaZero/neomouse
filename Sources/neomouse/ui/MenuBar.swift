import AppKit
import SwiftUI

import neomouseConfig
import neomouseTypes
import neomouseUtils

/// Status-bar item — mode-colored cursor icon plus a count badge whenever
/// normal-mode has a pending operation count (e.g. typing `12` before `g`).
/// Inspired by OmniWM's workspace pill; here the pill answers "what's
/// NeoMouse doing right now" at a glance.
///
/// Architecture notes:
///   * MenuBar is a Scene, not a View. SwiftUI's MenuBarExtra is the Scene
///     primitive for status bar items. Its `label:` closure builds the
///     icon area; its trailing closure builds the dropdown.
///   * The icon needs colored SF Symbols, which the `systemImage:` overload
///     of MenuBarExtra forces into template (monochrome). The
///     `content:label:` overload + `.symbolRenderingMode(.palette)` +
///     `.foregroundStyle(...)` is the only way to get colors in macOS 13+.
///   * `@ObservedObject` (not `@StateObject`) because NeoMouse.sharedState
///     is owned by `NeoMouse: App`. We only observe it here.
struct MenuBar: Scene {
    @ObservedObject var state: NeoMouseState = NeoMouse.sharedState

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            // No Settings scene declared → the default `App > Settings…`
            // command would open an empty SwiftUI window. Replace with nothing.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

// MARK: - Label (icon + optional count badge)

private struct MenuBarLabel: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(modeColor)
            if let countText = operationCountText {
                Text(countText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(modeColor)
            }
        }
    }

    /// SF Symbol per mode. Picked for at-a-glance recognizability rather
    /// than literal accuracy — `cursorarrow.motionlines` reads as "active
    /// cursor"; `scope` reads as "fine targeting"; etc.
    private var iconName: String {
        switch state.mode {
        case .disabled: return "power.circle.fill"
        case .normal:
            return state.isVisual ? "cursorarrow.click.2" : "cursorarrow.motionlines"
        case .find: return "magnifyingglass"
        case .command: return "terminal.fill"
        case .menu(.marks): return "bookmark.fill"
        case .menu(.register): return "tray.full.fill"
        case .specialFind: return "scope"
        }
    }

    /// Mode → color. Red = off, green = ready, yellow = selecting, blue =
    /// searching, orange = typing, purple/teal = menu open, pink = pinpoint.
    /// Color is a fast visual signal — the user shouldn't have to read the
    /// dropdown to know NeoMouse's state.
    private var modeColor: Color {
        switch state.mode {
        case .disabled: return .red
        case .normal: return state.isVisual ? .yellow : .green
        case .find: return .blue
        case .command: return .orange
        case .menu(.marks): return .purple
        case .menu(.register): return .teal
        case .specialFind: return .pink
        }
    }

    /// The count buffer shown next to the icon when the user has typed
    /// digits in normal mode (e.g. `12` before `g`). Nil in all other modes
    /// and when no count is pending.
    private var operationCountText: String? {
        if case .normal(_, let count) = state.mode, let count, !count.isEmpty {
            return count
        }
        return nil
    }
}

// MARK: - Dropdown content

private struct MenuBarContent: View {
    @ObservedObject var state: NeoMouseState

    var body: some View {
        // Status row — disabled Button renders as gray non-interactive text
        // in the menu, which is the macOS-native way to show a "current
        // state" header inside MenuBarExtra. Text() alone also works but
        // styling is less consistent across macOS versions.
        Button("Mode: \(modeDescription)") {}
            .disabled(true)

        Section {
            Button(isDisabled ? "Activate  ⌘E" : "Deactivate  ⌘E") {
                toggleActivation()
            }
        }

        Section("Open") {
            Button("Marks") { openMenu(.marks) }
            Button("Registers") { openMenu(.register) }
            Button("Command Line") { openCommandLine() }
            Button("Help") { HelpDialog.shared.toggle() }
        }

        Section("Diagnostics") {
            // The log file is created at module load when running from a
            // bundled .app, so it exists by the time the menu opens.
            // `currentLogFileURL` is nil for bare-binary `swift run` — in
            // that case stdout is the live channel and we surface an
            // explanatory disabled item rather than a broken Open.
            if let logURL = currentLogFileURL {
                Button("Show Debug Log") {
                    NSWorkspace.shared.open(logURL)
                }
                Button("Reveal Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            } else {
                Button("Debug log: stdout only (no file)") {}
                    .disabled(true)
            }
        }

        Section {
            Button("Restart") { restart() }
            Button("Quit NeoMouse") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: - Display state

    private var modeDescription: String {
        switch state.mode {
        case .disabled:
            return "Disabled"
        case .normal(let op, let count):
            var parts: [String] = ["Normal"]
            if state.isVisual { parts.append("Visual") }
            if op != .none { parts.append("\(op)") }
            if let count, !count.isEmpty { parts.append("count=\(count)") }
            return parts.joined(separator: " · ")
        case .find(_, _, let isQuickFind):
            return isQuickFind ? "Find · Quick" : "Find"
        case .command(let cmd, _):
            return "Command · :\(cmd)"
        case .menu(.marks):
            return "Marks Menu"
        case .menu(.register):
            return "Registers Menu"
        case .specialFind:
            return "Special Find"
        }
    }

    private var isDisabled: Bool {
        if case .disabled = state.mode { return true }
        return false
    }

    // MARK: - Actions
    //
    // These mirror what the Cmd+E handler / `:marks` / `:registers` / `:`
    // / `:restart` commands do in NeoMouseApp.swift + CommandLine.swift.
    // Slight duplication is intentional: menu-bar is an alternate entry
    // point with the same effects, kept in one file for findability.

    /// Mirror of the Cmd+E handler at NeoMouseApp.swift:286. Same cleanup
    /// sequence — exit visual, reset grid, hide all overlays, drop to
    /// .disabled. Re-activation just sets normal mode + toast.
    private func toggleActivation() {
        if case .disabled = state.mode {
            state.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
            ToastManager.shared.show("NeoMouse Activated - Normal Mode")
        } else {
            if state.isVisual {
                NeoMouse.CoreOperations.exitVisualState(
                    appState: state,
                    visualHighlightOverlay: VisualHighlightOverlay.shared
                )
            }
            state.gridDivisions = Config.Grid.defaultDivisions
            state.mode = .disabled
            GridOverlay.shared.hideGrid()
            HelpDialog.shared.hide()
            CommandLine.shared.hide()
            MarksMenu.shared.hide()
            RegisterMenu.shared.hide()
            ToastManager.shared.show("NeoMouse Deactivated")
        }
    }

    /// Open the Marks / Registers menu. Mirrors `:marks` / `:registers`
    /// from CommandLine.swift. Requires the app to be active — if it was
    /// disabled, we flip to normal first so the menu's `.menu(window:)`
    /// guard doesn't trip.
    private func openMenu(_ window: NeomouseType.MenuWindow) {
        if case .disabled = state.mode {
            state.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
        }
        state.mode = .menu(window: window)
        switch window {
        case .marks:
            MarksMenu.shared.passAppState(state: state)
            MarksMenu.shared.toggle()
        case .register:
            RegisterMenu.shared.passAppState(state: state)
            RegisterMenu.shared.toggle()
        }
    }

    /// Drop into command mode with an empty buffer — equivalent to pressing
    /// `:` in normal mode. Used so the menu bar can be a starting point for
    /// the user to type any command without remembering the chord.
    private func openCommandLine() {
        if case .disabled = state.mode {
            state.mode = .normal(currentPendingOperation: .none, operationCountAsString: nil)
        }
        state.mode = .command(command: "", suggestionIndex: nil)
        CommandLine.shared.passAppState(state: state)
        CommandLine.shared.toggle()
    }

    /// Mirror of `:restart` from CommandLine.swift. Delegates the actual
    /// relaunch logic to `System.restart()` — that helper picks `open` for
    /// bundled .apps and `swift run` for bare-binary dev launches, so this
    /// works under brew/nix/manual install + `just release-test` as well as
    /// `swift run` from the repo.
    private func restart() {
        if let err = System.restart() {
            return ToastManager.shared.show("restart: \(err)")
        }
        ToastManager.shared.show("Restarting…")
        // Defer the exit so the toast renders and SwiftUI returns to its
        // run loop before we yank the process out from under AppKit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Release any held synthesized mouse button so a restart from
            // visual mode doesn't leave the user mid-drag.
            if let loc = Mouse.location() {
                Mouse.up(.left, at: loc)
                Mouse.up(.right, at: loc)
            }
            exit(0)
        }
    }
}
