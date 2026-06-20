/// Coarse classification of every recordable NeoMouse operation.
///
/// Lives in the GRDB-free types layer so both `neomouseDB` (which maps each
/// `OperationName` to a category) and the executable's hook pipeline (which
/// filters after-hooks by category — e.g. auto-snap and `front_app_follows_mouse`
/// only fire for `.motion`) can categorize without taking a GRDB dependency.
///
/// `String`-backed so it round-trips cleanly through Codable / any future
/// persisted form, and `CaseIterable` so tests can sweep every category.
public enum CommandCategory: String, Codable, Sendable, CaseIterable {
    /// Cursor-moving operations: hjkl, line/column/screen jumps, grid snap.
    case motion
    /// Visual-mode selection ops (toggle, line-select, swap anchor, yank).
    case visual
    /// Numbered/named register ops (select, yank, delete, paste).
    case register
    /// Find-mode grid targeting (find, quick grid find, special find).
    case find
    /// Mouse buttons / scroll / trackpad gestures.
    case gesture
    /// Multi-display navigation (jump to adjacent screen).
    case screen
    /// Ex-style commands and stateful actions (`:numbers`, set mark/macro, …).
    case command
    /// Transient UI surfaces (help dialog, command line).
    case ui
    /// App-global toggles (enable/disable NeoMouse, Esc).
    case global
}
