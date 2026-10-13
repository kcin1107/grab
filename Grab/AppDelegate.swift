import AppKit

/// Bridges macOS termination callbacks to the queue owned by the SwiftUI app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: DownloadManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        sizeWindowForUITests()
        #endif
    }

    #if DEBUG
    /// UI tests launch with `-GrabUITestWindowWidth <points>` to check the input bar at a given window
    /// width. Neither a saved frame nor `-NSWindow Frame` can be set from the command line, and
    /// XCUITest can't resize windows itself.
    private func sizeWindowForUITests() {
        let width = UserDefaults.standard.integer(forKey: "GrabUITestWindowWidth")
        guard width > 0 else { return }
        Task {
            for _ in 0..<50 {
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    var frame = window.frame
                    frame.size.width = CGFloat(width)
                    window.setFrame(frame, display: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    #endif

    /// Quitting stops running downloads, so ask first (as Safari does).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager, manager.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Grab?")
        alert.informativeText = String(localized: "Downloads are in progress. Quitting stops them; they’ll be paused and can be resumed next time.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
