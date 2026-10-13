import Foundation
import Observation

/// Owns the app's long-lived state: the download queue and the yt-dlp and helper tool updaters.
@MainActor
@Observable
final class AppModel {
    let manager = DownloadManager()
    let updater = Updater()
    let toolsUpdater = HelperToolsUpdater()

    @ObservationIgnored private var toolsWatcher: Task<Void, Never>?

    /// Starts the automatic update checks and lets queued downloads start once first-run setup of
    /// yt-dlp, ffmpeg and Deno has finished.
    func start() {
        guard toolsWatcher == nil else { return }
        let busy = Observations { [updater, toolsUpdater] in updater.isBusy || toolsUpdater.isBusy }
        toolsWatcher = Task { [manager] in
            for await busy in busy {
                manager.toolsInstalling = busy
                if !busy { manager.toolsFinished() }
            }
        }
        updater.startAutomaticChecks()
        toolsUpdater.startAutomaticChecks()
    }
}
