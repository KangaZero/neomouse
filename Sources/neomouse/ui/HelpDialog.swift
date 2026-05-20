import AppKit
import SwiftUI

import neomouseUtils

/// Floating help window listing every neomouse keybind. Press `?` in normal
/// mode to toggle. Standard NSWindow (not NSPanel) so the title-bar close
/// button renders + the user can scroll + select text inside. `level =
/// .floating` keeps it above the focused app; `orderFront(nil)` (vs
/// makeKeyAndOrderFront) means showing it doesn't steal focus — focus only
/// switches when the user actually clicks inside.
@MainActor
final class HelpDialog {
    static let shared = HelpDialog()
    private var window: NSWindow?

    func toggle() {
        if let window, window.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // Gate: only available in normal mode. Stops `?` from opening the
        // help panel while typing in command mode, picking a target in
        // find mode, etc.
        guard case .normal = NeoMouse.sharedState.mode else {
            debug(
                "HelpDialog.show: refused — (automatically hiding if shown) only available in normal mode (current: \(NeoMouse.sharedState.mode))"
            )
            hide()
            return
        }
        guard
            let currentScreen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            }) ?? NSScreen.main
        else {
            debug("HelpDialog.show: no screen available")
            return
        }
        let size = CGSize(width: 700, height: 850)
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            win = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "NeoMouse Help"
            win.level = .floating
            // Clicking the title-bar close button should just hide, not
            // deallocate the window — toggle() can show it again later.
            win.isReleasedWhenClosed = false
            win.hidesOnDeactivate = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: HelpDialogView())
            window = win
        }
        let origin = CGPoint(
            x: currentScreen.visibleFrame.midX - size.width / 2,
            y: currentScreen.visibleFrame.midY - size.height / 2
        )
        win.setFrameOrigin(origin)
        // orderFront, not makeKeyAndOrderFront — show without stealing focus.
        win.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct HelpDialogView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Activation") {
                    row("Cmd-E", "Toggle neomouse (activate / deactivate)")
                    row("?", "Toggle this help")
                }
                section("Motion") {
                    row("h / j / k / l", "Move cursor left / down / up / right")
                    row("0", "Go to left edge of screen")
                    row("$", "Go to right edge of screen")
                    row("gg", "Go to top of screen")
                    row("G", "Go to bottom of screen")
                    row("M", "Go to vertical middle")
                    row("gm", "Go to horizontal middle")
                    row("<count><motion>", "Repeat motion <count> times (e.g. 10j)")
                    row("Ctrl-W w", "Jump to next display")
                }
                section("Find") {
                    row("f", "Enter find mode (grid jump)")
                    row("<char><char>", "Two keystrokes pick outer + inner cell")
                }
                section("Visual") {
                    row("v", "Toggle character visual mode at cursor")
                    row("V", "Toggle line visual mode")
                    row("o / O", "Swap visual anchor and cursor")
                    row("y", "Yank visual region (screenshot to clipboard)")
                    row("gv", "Reselect previous visual region")
                    row("Esc", "Exit visual mode / reset pending op")
                }
                section("Marks") {
                    row("m{a-z0-9}", "Set mark at cursor")
                    row("'{a-z0-9}", "Jump to mark (cursor endpoint only)")
                    row("`{a-z0-9}", "Jump to mark, restoring visual state if set")
                }
                section("Registers") {
                    row("\"{a-z0-9}", "Select register for next action")
                    row("\"{r}y", "Yank clipboard contents into register r")
                    row("\"{r}d", "Cut into register r")
                    row("\"{r}p", "Paste from register r")
                }
                section("Gestures") {
                    row("r / R", "Rotate clockwise / counter-clockwise")
                    row("+ / -", "Pinch zoom in / out")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundColor(.accentColor)
            rows()
        }
    }

    private func row(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .frame(width: 140, alignment: .leading)
                .foregroundColor(.primary)
            Text(description)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
