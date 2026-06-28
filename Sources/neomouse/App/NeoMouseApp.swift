import AppKit
import Combine
import SwiftUI

import neomouseConfig
import neomouseDB
import neomouseUtils
import neomouseTypes

@main
struct NeoMouse: App {
    static var keyEventTap: CFMachPort?
    static var keyEventTapRunLoopSource: CFRunLoopSource?
    static var keyHandler: ((NSEvent) -> Void)?
    static var mouseMonitor: Any?
    static var pasteboardWatcher: Timer?
    static var modeObserver: AnyCancellable?
    static var isVisualObserver: AnyCancellable?
    static var settingsWatcher: SettingsWatcher?

    // ⚠️⚠️ STRICTLY for the ⌘E activate/deactivate chord — NOTHING ELSE. ⚠️⚠️
    //
    // The keyHandler closure returns Void and so cannot tell the CGEventTap to
    // drop an event. This one-shot flag is the ONLY sanctioned bridge, and it
    // exists for ONE reason: ⌘E must never reach the focused app (deactivating
    // would otherwise type an "e"). It is reset to false at the top of EVERY
    // keystroke in `makeKeyHandler` and set true ONLY in the deactivation
    // branch; `KeyEventTap` reads it to decide whether to swallow.
    //
    // DO NOT reuse this as a general "swallow this key" mechanism. Any other
    // per-key swallowing belongs in KeyEventTap's pass-through filter, not here.
    static var swallowCurrentKeyEvent = false
    static let sharedState: NeoMouseState = {
        // Deploy the bundled default `settings.toml` to ~/.config/neomouse/
        // on first launch so brew/nix/manual installs all get a usable
        // template at the standard resolved path — no extra step required.
        // No-op when the user already has a settings.toml there.
        deployBundledDefaultsIfMissing()

        guard let url = Config.resolvedURL else {
            debug("No settings.toml found at any resolved path; using built-in defaults")
            return NeoMouseState()
        }
        do {
            let config = try Config.loadConfig(from: url)
            debug("Loaded config from \(url.path)")
            return NeoMouseState(config: config)
        } catch {
            debug("Config load failed (\(error)); falling back to built-in defaults")
            // Stash the failure so we can toast it once the overlay UI is up
            // (no UI exists this early). Surfaced by
            // notifyStartupConfigErrorIfNeeded() at the end of launch setup.
            startupConfigError = "\(error)"
            return NeoMouseState()
        }
    }()

    /// A settings.toml load/decode failure captured during `sharedState` init,
    /// pending a user-facing toast once the UI is ready. nil = clean load (or a
    /// first run with no config file yet, which is not an error).
    static var startupConfigError: String?

    /// Toast the startup config error (if any) so a broken settings.toml is
    /// visible at launch — not just buried in the debug log. The hot-reload
    /// path already toasts on failure; this closes the startup gap. Deferred one
    /// runloop tick so the toast overlay exists by the time we show it.
    @MainActor
    static func notifyStartupConfigErrorIfNeeded() {
        guard let message = startupConfigError else { return }
        startupConfigError = nil
        DispatchQueue.main.async {
            ToastManager.shared.show("settings.toml error — using defaults: \(message)")
        }
    }

    /// Copy the bundled default `settings.toml` (shipped in the .app at
    /// `Contents/Resources/settings.toml`) to `~/.config/neomouse/settings.toml`
    /// if no file is already there. Respects user customizations — never
    /// overwrites. No source = no-op (this is normal under bare `swift run`
    /// where Bundle.main has no Resources; devs deploy via `just init`).
    private static func deployBundledDefaultsIfMissing() {
        let fm = FileManager.default
        let target = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neomouse/settings.toml")
        if fm.fileExists(atPath: target.path) { return }
        guard let source = Bundle.main.url(forResource: "settings", withExtension: "toml") else {
            debug(
                "No bundled settings.toml in Bundle.main; skipping default deploy (use `just init` for dev)"
            )
            return
        }
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: source, to: target)
            debug("Deployed default settings.toml from bundle to \(target.path)")
        } catch {
            debug("Failed to deploy bundled settings.toml: \(error)")
        }
    }
    @StateObject private var appState = NeoMouse.sharedState
    // Bridges SwiftUI's value-type App into AppKit's reference-type lifecycle
    // so we receive applicationWillTerminate before the process exits.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        //TODO add checks to make sure no unintended behavior of out of bounds access happens
        // eg.. gridDivisions * gridDivisions <=findModeGridDivisionCharacters.count, and similar for
        // innerGridDivisions
        // Dev seed gate. Run with `FORCE_REINTIALIZE=1 swift run` to force reinitialization of the DB and seeding of extra sessions and marks. This is useful for testing and development, but should not be used in production as it will delete existing data.
        initializeDB(forceReIntialize: ProcessInfo.processInfo.environment["FORCE_REINTIALIZE"] == "1" ? true : false)
        // extra sessions + random marks. No-op otherwise.
        if ProcessInfo.processInfo.environment["NEOMOUSE_SEED"] == "1" {
            seedAll()
        }

        appState.currentSession = Session.getLast()
        guard let currentSession = appState.currentSession else {
            debug("No session was found")
            showFatalAlertAndQuit(
                title: "NeoMouse failed to start",
                message: """
                    No session was found in the database. This is unexpected — \
                    please report it so we can fix it.
                    """
            )
            return
        }
        // `Session.id` is `Int64?` (GRDB autoincrement). It's populated by the
        // insert that ran during `initializeDB` above, so it's never nil here
        // in practice — but rather than `currentSession.id!` repeatedly, bind
        // once and surface a clear error if the invariant is ever broken.
        guard let sessionId = currentSession.id else {
            debug("Session loaded but had no id; was it persisted?")
            showFatalAlertAndQuit(
                title: "NeoMouse failed to start",
                message: """
                    The session loaded from the database is missing its row id. \
                    This indicates a DB corruption issue — please report it.
                    """
            )
            return
        }

        //TODO Reenable once able to have register when proper content copying
        // Seed register "0" with whatever's on the clipboard at launch.
        if let currentPasteboardItem = Pasteboard.getFirst() {
            Register.set(
                register: "0",
                item: currentPasteboardItem,
                sessionId: sessionId)
            // debug("Pasteboard: \(Pasteboard.preview(currentPasteboardItem))")
        }
        debug("currentSession: \(String(describing: currentSession))")
        let _allScreensBoundingRect = Screen.allBoundingRect()
        debug("allScreensRect: \(String(describing: _allScreensBoundingRect))")
        let appState = NeoMouse.sharedState
        // KeyCast subscribes to $mode here so the vim-showcmd pill can
        // appear/disappear reactively as soon as a pending op is set/cleared.
        KeyCast.shared.passAppState(state: appState)
        // Wire appState into MarksMenu / RegisterMenu once at launch so their
        // refresh() calls work from .setMark / Register.set sites before the
        // menus have ever been shown.
        MarksMenu.shared.passAppState(state: appState)
        RegisterMenu.shared.passAppState(state: appState)
        CursorSurroundedGridOverlay.shared.passAppState(state: appState)

        NeoMouse.installKeyEventTap()

        NeoMouse.keyHandler = NeoMouse.makeKeyHandler(
            appState: appState,
            currentSession: currentSession,
            sessionId: sessionId
        )

        NeoMouse.installVisualModeObserver(appState: appState)
        NeoMouse.installPasteboardModeObserver(appState: appState)
        NeoMouse.installSettingsReloadObserver(appState: appState)
        NeoMouse.notifyStartupConfigErrorIfNeeded()
    }

    var body: some Scene {
        MenuBar()
    }
}
