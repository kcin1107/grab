import AppKit

/// What SwiftUI has no hook for: quitting. Holds the app's state so it can stop downloads on the way out.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Quitting stops running downloads, so ask first (as Safari does).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.manager.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Grab?")
        alert.informativeText = String(localized: "Downloads are in progress. Quitting stops them; they’ll be paused and can be resumed next time.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.manager.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
