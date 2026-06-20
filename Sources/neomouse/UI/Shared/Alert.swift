import AppKit

/// Fatal-style alert. Blocks until dismissed; opens the issue tracker if the
/// user clicks "Report Issue", then terminates the app either way.
@MainActor
func showFatalAlertAndQuit(
    title: String,
    message: String,
    reportURL: URL = URL(string: "https://github.com/KangaZero/neomouse/issues")!
) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.addButton(withTitle: "Report Issue")
    alert.addButton(withTitle: "Quit")
    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(reportURL)
    }
    NSApp.terminate(nil)
}
