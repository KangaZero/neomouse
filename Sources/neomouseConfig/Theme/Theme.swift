import CoreGraphics
import Foundation

// User-overridable theme model for every neomouse UI element (except the
// menu-bar status icon, which is intentionally tied to the mode/state
// color scheme). Each subsection of `Config.Theme` maps to one TOML table
// — e.g. `[theme.toast]` decodes into `Config.Theme.Toast`.
//
// All sub-fields are optional in the TOML; missing keys fall back to
// the hardcoded values that ship in this file. So a brand-new settings.toml
// with no `[theme.*]` blocks renders neomouse exactly as it always has.
//
// SwiftUI / NSColor / Font conversion lives in the executable target
// (`Sources/neomouse/ui/Theme+SwiftUI.swift`) because neomouseConfig is kept
// SwiftUI/AppKit-free so it can be reused from non-UI targets / tests.

extension Config {
    /// Top-level theme container. Each property is a sub-theme for one UI
    /// element (or one shared element family — GridTheme covers both the
    /// find-mode grid and the cursor-surrounded special-find grid).
    public struct Theme: Decodable, Sendable {
        public var grid: GridTheme
        public var numbersOverlay: NumbersOverlayTheme
        public var commandLine: CommandLineTheme
        public var marksMenu: MarksMenuTheme
        public var registerMenu: RegisterMenuTheme
        public var helpDialog: HelpDialogTheme
        public var visualHighlight: VisualHighlightTheme
        public var toast: ToastTheme
        public var keyCast: KeyCastTheme

        public init(
            grid: GridTheme = GridTheme(),
            numbersOverlay: NumbersOverlayTheme = NumbersOverlayTheme(),
            commandLine: CommandLineTheme = CommandLineTheme(),
            marksMenu: MarksMenuTheme = MarksMenuTheme(),
            registerMenu: RegisterMenuTheme = RegisterMenuTheme(),
            helpDialog: HelpDialogTheme = HelpDialogTheme(),
            visualHighlight: VisualHighlightTheme = VisualHighlightTheme(),
            toast: ToastTheme = ToastTheme(),
            keyCast: KeyCastTheme = KeyCastTheme()
        ) {
            self.grid = grid
            self.numbersOverlay = numbersOverlay
            self.commandLine = commandLine
            self.marksMenu = marksMenu
            self.registerMenu = registerMenu
            self.helpDialog = helpDialog
            self.visualHighlight = visualHighlight
            self.toast = toast
            self.keyCast = keyCast
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case grid, numbersOverlay, commandLine, marksMenu, registerMenu
            case helpDialog, visualHighlight, toast, keyCast
        }

        public init(from decoder: any Decoder) throws {
            try validateKnownKeys(
                decoder: decoder, keyedBy: CodingKeys.self, sectionName: "theme")
            let c = try decoder.container(keyedBy: CodingKeys.self)
            grid = try c.decodeIfPresent(GridTheme.self, forKey: .grid) ?? GridTheme()
            numbersOverlay =
                try c.decodeIfPresent(NumbersOverlayTheme.self, forKey: .numbersOverlay)
                ?? NumbersOverlayTheme()
            commandLine =
                try c.decodeIfPresent(CommandLineTheme.self, forKey: .commandLine) ?? CommandLineTheme()
            marksMenu =
                try c.decodeIfPresent(MarksMenuTheme.self, forKey: .marksMenu) ?? MarksMenuTheme()
            registerMenu =
                try c.decodeIfPresent(RegisterMenuTheme.self, forKey: .registerMenu) ?? RegisterMenuTheme()
            helpDialog =
                try c.decodeIfPresent(HelpDialogTheme.self, forKey: .helpDialog) ?? HelpDialogTheme()
            visualHighlight =
                try c.decodeIfPresent(VisualHighlightTheme.self, forKey: .visualHighlight)
                ?? VisualHighlightTheme()
            toast = try c.decodeIfPresent(ToastTheme.self, forKey: .toast) ?? ToastTheme()
            keyCast = try c.decodeIfPresent(KeyCastTheme.self, forKey: .keyCast) ?? KeyCastTheme()
        }
    }
}
