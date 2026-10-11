import AppKit

/// Owns the app's long-lived state: the download queue and the yt-dlp and helper tool updaters.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = DownloadManager()
    let updater = Updater()
    let toolsUpdater = HelperToolsUpdater()

    /// Set by the main window once it appears, so file commands can bring it back.
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.onStatusChange = { [weak self] in self?.toolsChanged() }
        toolsUpdater.onStatusChange = { [weak self] in self?.toolsChanged() }
        updater.startAutomaticChecks()
        toolsUpdater.startAutomaticChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Relaunching Grab from Finder, Spotlight or the Dock while it's running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMainWindow?() }
        return true
    }

    /// Lets queued downloads start once first-run setup of yt-dlp, ffmpeg and Deno has finished.
    private func toolsChanged() {
        manager.toolsInstalling = updater.isBusy || toolsUpdater.isBusy
        manager.refreshVersion()
        manager.pump()
    }
}
