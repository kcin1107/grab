import Foundation
import Network
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DownloadManager {
    var items: [DownloadItem] = []
    var ytdlpVersion: String?

    /// Whether yt-dlp and ffmpeg can be found. Looked up at launch, after setup or an update, when
    /// settings that affect the lookup change and when Grab comes to the front, so redraws don't hit the disk.
    private(set) var ytdlpAvailable = false
    private(set) var ffmpegAvailable = false

    /// True while Grab is downloading or updating its own yt-dlp/ffmpeg.
    var toolsInstalling = false

    let defaults = UserDefaults.standard

    /// False while the Mac has no internet connection; retries wait for it to come back.
    private(set) var isOnline = true
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init() {
        Prefs.registerDefaults()
        refreshTools()
        refreshVersion()
        items = History.load()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.updateRetryMessages()
                if online { self.pump() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Grab.network"))
    }

    /// Saves finished, failed and cancelled downloads so the list survives a restart.
    func saveHistory(includingActive: Bool = false) {
        History.save(includingActive ? items : items.filter { !$0.isActive })
    }

    var activeCount: Int { items.filter(\.isActive).count }
    var hasFinished: Bool { items.contains(where: \.isDone) }

    /// Called when first-run setup or an update of the tools has finished: queued downloads can start,
    /// and the yt-dlp version and which tools are installed may have changed.
    func toolsFinished() {
        refreshTools()
        refreshVersion()
        pump()
    }

    func refreshTools() {
        ytdlpAvailable = Tools.ytdlp != nil
        ffmpegAvailable = !Tools.ffmpegMissing
    }

    /// Looks at the disk again for what views show: the tools, and whether finished downloads are
    /// still where they were saved. Called when Grab comes to the front.
    func refreshFromDisk() {
        refreshTools()
        for item in items { item.refreshFileStatus() }
    }

    func refreshVersion() {
        Task {
            let data = await capture(["--version"])
            let version = data.map { String(decoding: $0, as: UTF8.self) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ytdlpVersion = (version?.isEmpty ?? true) ? nil : version
        }
    }

    // MARK: - Queue

    /// Adds downloads for one or more links. When "Ask where to save" is on, asks once for the batch.
    func add(_ urls: [String], options: DownloadOptions = .current, folder override: String? = nil, clip: ClipRange? = nil) {
        guard !urls.isEmpty else { return }
        guard let folder = override else {
            withDestination(count: urls.count) { [weak self] folder in
                self?.add(urls, options: options, folder: folder, clip: clip)
            }
            return
        }
        for url in urls {
            if Playlists.looksLikePlaylist(url) {
                presentPicker(for: url, options: options, folder: folder)
            } else if let existing = alreadyDownloaded(url, isAudio: options.isAudio || MusicLinks.isMusicLink(url), clip: clip) {
                duplicates.append(DuplicatePrompt(existing: existing, url: url, options: options, folder: folder, clip: clip))
            } else if MusicLinks.isMusicLink(url) {
                addSpotify(url, options: options, folder: folder, clip: clip)
            } else {
                enqueue(url, options: options, folder: folder, clip: clip)
            }
        }
        pump()
    }

    /// Puts a link at the top of the list (the caller pumps the queue).
    private func enqueue(_ url: String, options: DownloadOptions, folder: String, clip: ClipRange?) {
        let item = DownloadItem(url: url, options: options, folder: folder)
        item.clip = clip
        items.insert(item, at: 0)
    }

    /// A download for a video whose details are already known (a search result, a playlist entry).
    func item(url: String, options: DownloadOptions, folder: String, title: String, uploader: String?,
                      duration: Double?, thumbnail: URL?) -> DownloadItem {
        let item = DownloadItem(url: url, options: options, folder: folder)
        item.title = title
        item.uploader = uploader
        item.duration = duration
        item.thumbnail = thumbnail
        return item
    }

    func add(_ url: String, options: DownloadOptions = .current, folder: String? = nil, clip: ClipRange? = nil) {
        add([url], options: options, folder: folder, clip: clip)
    }

    /// Runs `start` with the Downloads setting, or, when "Always ask where to save" is on, with the folder the
    /// user picks. The model never shows the dialog: it publishes `fileRequest`, the window presents it and
    /// calls `start` with the folder (or drops it if the user cancels). One request covers a whole batch.
    func withDestination(count: Int, _ start: @escaping @MainActor (String) -> Void) {
        let folder = defaults.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory()
        if defaults.bool(forKey: Prefs.askLocation) {
            fileRequest = .saveFolder(PendingAdd(count: count, startingFolder: folder, start: start))
        } else {
            start(folder)
        }
    }

    /// The file or folder dialog the window should show, if any (see `FileRequestImporter`).
    var fileRequest: FileRequest?

    /// File → Download Links from File…: every link in the text files the user chose.
    func addLinks(fromFiles urls: [URL]) {
        let links = urls.flatMap(Links.extract(fromFile:))
        guard !links.isEmpty else { MacPlatform.beep(); return }
        add(links)
    }

    // MARK: - Converting files on this Mac

    /// Files dropped on the window (or chosen in File → Convert Files…), waiting for the user to
    /// pick what to turn them into.
    var filesToConvert: [URL] = []

    // MARK: - Search

    /// The search shown in the main window, if any.
    var search: SearchSession?

    // MARK: - Already downloaded

    /// A link that's already been downloaded, waiting for the user to choose what to do.
    struct DuplicatePrompt: Identifiable {
        let id = UUID()
        let existing: DownloadItem
        let url: String
        let options: DownloadOptions
        let folder: String
        let clip: ClipRange?
    }

    var duplicates: [DuplicatePrompt] = []

    /// A finished download of the same video or track (same kind: audio or video), whose file
    /// is still where Grab saved it. Clips never count as duplicates.
    func alreadyDownloaded(_ url: String, isAudio: Bool, clip: ClipRange? = nil) -> DownloadItem? {
        guard clip == nil else { return nil }
        let key = Links.identity(url)
        return items.first { item in
            item.clip == nil && item.options.isAudio == isAudio && item.existingFile != nil
                && Links.identity(item.url) == key
        }
    }

    enum DuplicateChoice { case showInFinder, downloadAgain, cancel }

    func resolve(_ prompt: DuplicatePrompt, with choice: DuplicateChoice) {
        duplicates.removeAll { $0.id == prompt.id }
        switch choice {
        case .showInFinder:
            if let file = prompt.existing.existingFile { MacPlatform.reveal([file]) }
        case .downloadAgain:
            if MusicLinks.isMusicLink(prompt.url) {
                addSpotify(prompt.url, options: prompt.options, folder: prompt.folder, clip: prompt.clip)
            } else {
                enqueue(prompt.url, options: prompt.options, folder: prompt.folder, clip: prompt.clip)
            }
            pump()
        case .cancel:
            break
        }
    }

    // MARK: - Playlist picker

    /// Playlist links waiting for the user to choose videos; the first one is shown.
    var picks: [PlaylistPick] = []

    func cancel(_ item: DownloadItem) {
        guard item.isActive || item.state == .paused else { return }
        item.state = .cancelled
        item.process?.terminate()
        pump()
        saveHistory()
    }

    func retry(_ item: DownloadItem) {
        if item.spotify == nil, MusicLinks.isMusicLink(item.url) {
            // A Spotify link that failed before its tracks were read.
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items.remove(at: index)
            addSpotify(item.url, options: item.options, folder: item.folder, clip: item.clip)
            return
        }
        item.reset()
        item.retryCount = 0
        item.retryAt = nil
        pump()
    }

    func remove(_ item: DownloadItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearFinished() {
        items.removeAll(where: \.isDone)
        saveHistory()
    }

    /// Stops a download but keeps what's been downloaded so far; resuming continues from there.
    func pause(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .queued else { return }
        item.state = .paused
        item.process?.terminate()
        pump()
        saveHistory()
    }

    func resume(_ item: DownloadItem) {
        guard item.state == .paused else { return }
        item.state = .queued
        item.errorMessage = nil
        item.retryCount = 0
        item.retryAt = nil
        pump()
    }

    /// Starts queued items, oldest first, up to the concurrency limit.
    func pump() {
        // On first launch, wait for Grab to finish fetching yt-dlp/ffmpeg instead of failing.
        if toolsInstalling, Tools.ytdlp == nil || Tools.ffmpegMissing {
            updateBadge()
            return
        }
        let limit = max(1, defaults.integer(forKey: Prefs.maxConcurrent))
        var running = items.filter(\.isRunning).count
        let now = Date()
        for item in items.reversed() where item.state == .queued && running < limit {
            // A retry waits for its time, and for the connection to be back.
            if let retryAt = item.retryAt, retryAt > now || !isOnline { continue }
            running += 1
            start(item)
        }
        updateBadge()
    }

    func fail(_ item: DownloadItem, _ message: String) {
        item.state = .failed
        item.errorMessage = message
        pump()
        saveHistory()
    }

    /// Called when Grab quits: remembers unfinished downloads (as paused) and stops yt-dlp,
    /// which would otherwise keep running in the background with nothing watching it.
    func shutDown() {
        saveHistory(includingActive: true)
        for item in items { item.process?.terminate() }
    }

    // MARK: - Running

    private func start(_ item: DownloadItem) {
        item.state = .starting
        item.retryAt = nil
        item.phase = nil
        if let conversion = item.conversion {
            runConversion(item, conversion)
            return
        }
        guard Tools.ytdlp != nil else {
            fail(item, String(localized: "yt-dlp not found. Install it with “brew install yt-dlp” or set its path in Settings."))
            return
        }

        if let track = item.spotify, item.resolvedURL == nil {
            item.phase = String(localized: "Finding on YouTube Music…")
            Task {
                let match = await findMatch(for: track)
                guard item.state == .starting else { return }
                if let match {
                    item.resolvedURL = match
                    launch(item)
                } else {
                    fail(item, String(localized: "Couldn’t find this song on YouTube Music."))
                }
            }
            return
        }
        launch(item)
    }

    private func launch(_ item: DownloadItem) {
        guard let exe = Tools.ytdlp else { return }
        let process = Process()
        process.executableURL = exe
        process.arguments = Self.arguments(for: item, url: item.resolvedURL ?? item.url)
        process.environment = Tools.environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        item.process = process

        let exited = Tools.exitStatus(of: process)
        do {
            try process.run()
        } catch {
            fail(item, error.localizedDescription)
            return
        }

        let errors = Task.detached {
            for await line in PipeLines.stream(err.fileHandleForReading) where line.hasPrefix("ERROR:") {
                let final = Self.errorMessage(from: line)
                await MainActor.run { item.errorMessage = final }
            }
        }
        Task.detached {
            for await line in PipeLines.stream(out.fileHandleForReading) {
                await Self.handle(line, for: item)
            }
            let status = await exited()
            // Let the error text land before deciding what to do next.
            await errors.value
            await self.finish(item, status: status)
        }
    }

    func finish(_ item: DownloadItem, status: Int32, finishingDone: Bool = false) {
        item.process = nil
        guard item.state != .cancelled, item.state != .paused else { pump(); return }

        if status != 0, scheduleRetryIfNetworkProblem(item) { return }

        // The work after the download, in order: chapter files, the music service's own cover
        // art. Only then does the download count as done.
        if status == 0, !finishingDone,
           splitsChapters(item) || artworkToEmbed(for: item) != nil {
            item.state = .processing
            Task {
                if splitsChapters(item) {
                    item.phase = String(localized: "Tagging chapters…")
                    await tagChapters(of: item)
                }
                if let artwork = artworkToEmbed(for: item) {
                    item.phase = String(localized: "Adding cover art…")
                    await embed(artwork, into: item)
                }
                finish(item, status: 0, finishingDone: true)
            }
            return
        }

        defer { pump() }

        defer { saveHistory() }
        if status == 0 {
            item.state = .finished
            item.finishedAt = .now
            item.progress = 1
            if let file = item.fileURL { item.fileSize = Self.size(of: file) }
        } else {
            item.state = .failed
            if item.errorMessage == nil { item.errorMessage = String(localized: "yt-dlp exited with code \(status).") }
        }
    }

    // MARK: - Automatic retry

    static let retryDelays: [TimeInterval] = [5, 15, 30, 60, 120]

    private func isNetworkProblem(_ item: DownloadItem) -> Bool {
        if !isOnline { return true }
        return Self.isNetworkError(item.errorMessage ?? "")
    }

    /// Queues the download again after a pause that grows with each try (up to five). It continues
    /// from the partial file, and waits for the connection if the Mac is offline.
    private func scheduleRetryIfNetworkProblem(_ item: DownloadItem) -> Bool {
        guard item.conversion == nil, isNetworkProblem(item), item.retryCount < Self.retryDelays.count else { return false }
        let delay = Self.retryDelays[item.retryCount]
        item.retryCount += 1
        item.retryAt = Date().addingTimeInterval(delay)
        item.state = .queued
        item.errorMessage = nil
        updateRetryMessages()
        Task {
            try? await Task.sleep(for: .seconds(delay))
            pump()
        }
        pump()
        return true
    }

    private func updateRetryMessages() {
        for item in items where item.state == .queued && item.retryAt != nil {
            item.phase = isOnline
                ? String(localized: "Connection problem · retrying (\(item.retryCount) of \(Self.retryDelays.count))…")
                : String(localized: "Waiting for an internet connection…")
        }
    }

    // MARK: - Cover art

    // MARK: - Chapters

    private func updateBadge() {
        let count = activeCount
        MacPlatform.setDockBadge(count > 0 ? "\(count)" : nil)
    }
}
