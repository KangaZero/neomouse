import Foundation

import neomouseConfig
import neomouseUtils

/// Watches the resolved settings.toml file for writes and fires a callback
/// with the freshly decoded `Config` (or the decode error). Debounced so an
/// editor that saves on every keystroke doesn't trigger N reloads per
/// character — the callback fires at most once per `debounceInterval` after
/// the last write event.
///
/// File-system event quirk: most editors do an atomic save (write to a temp
/// file, then `rename(2)` over the target). That invalidates our descriptor,
/// so we listen for `.delete` / `.rename` and re-`open` against the resolved
/// URL after a short delay before scheduling the reload.
///
/// Lifetime: created once at app start (NeoMouseApp.init) and held for the
/// life of the process. `stop()` is called from
/// `AppDelegate.applicationWillTerminate` to cancel the dispatch source and
/// close the fd.
@MainActor
final class SettingsWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWork: DispatchWorkItem?

    private let onReload: (Result<Config, Config.LoadError>) -> Void
    private let debounceInterval: DispatchTimeInterval = .milliseconds(250)

    init(onReload: @escaping (Result<Config, Config.LoadError>) -> Void) {
        self.onReload = onReload
        guard let url = Config.resolvedURL else {
            debug(
                "SettingsWatcher: no resolvedURL — hot reload disabled until a settings.toml exists at a resolved path"
            )
            return
        }
        startWatching(url: url)
    }

    private func startWatching(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else {
            debug("SettingsWatcher: open(O_EVTONLY) failed for \(url.path) — hot reload disabled")
            return
        }
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source = src
        src.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd != -1 { close(fd) }
            self?.fileDescriptor = -1
        }
        src.resume()
        debug("SettingsWatcher: watching \(url.path)")
    }

    private func handleFileEvent() {
        guard let src = source else { return }
        if src.data.contains(.delete) || src.data.contains(.rename) {
            // Atomic save: our fd is now pointing at the old (deleted/renamed)
            // inode. Cancel + re-watch the resolved path after a short tick so
            // the new file has settled.
            src.cancel()
            source = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(75)) { [weak self] in
                guard let self else { return }
                if let url = Config.resolvedURL {
                    self.startWatching(url: url)
                }
                self.scheduleReload()
            }
        } else {
            // .write / .extend — in-place save. Just reload.
            scheduleReload()
        }
    }

    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performReload()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func performReload() {
        guard let url = Config.resolvedURL else { return }
        do {
            let config = try Config.loadConfig(from: url)
            onReload(.success(config))
        } catch {
            onReload(.failure(error))
        }
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        source?.cancel()
        source = nil
    }
}
