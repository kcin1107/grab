import AppKit
import Foundation
import Network
import Observation
import UniformTypeIdentifiers

enum Prefs {
    static let downloadPath = "downloadPath"
    static let kind = "kind"
    static let resolution = "resolution"
    static let codec = "codec"
    static let container = "container"
    static let prefer60fps = "prefer60fps"
    static let audioFormat = "audioFormat"
    static let audioBitrate = "audioBitrate"
    static let maxConcurrent = "maxConcurrent"
    static let embedMetadata = "embedMetadata"
    static let embedThumbnail = "embedThumbnail"
    static let embedSubtitles = "embedSubtitles"
    static let removeSponsors = "removeSponsors"
    static let cookiesBrowser = "cookiesBrowser"
    static let ytdlpPath = "ytdlpPath"
    static let autoUpdate = "autoUpdate"
    static let nightly = "nightly"
    static let askLocation = "askLocation"
    static let fileNaming = "fileNaming"
    static let customFileName = "customFileName"
    static let playlistFolders = "playlistFolders"
    static let searchKind = "searchKind"
    static let splitChapters = "splitChapters"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            downloadPath: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path,
            kind: MediaKind.video.rawValue,
            resolution: Resolution.best.rawValue,
            codec: VideoCodec.compatible.rawValue,
            container: VideoContainer.mp4.rawValue,
            prefer60fps: false,
            audioFormat: AudioFormat.m4a.rawValue,
            audioBitrate: AudioBitrate.best.rawValue,
            maxConcurrent: 3,
            embedMetadata: true,
            embedThumbnail: true,
            embedSubtitles: false,
            removeSponsors: false,
            cookiesBrowser: "none",
            ytdlpPath: "",
            autoUpdate: true,
            nightly: false,
            askLocation: false,
            fileNaming: FileNaming.automatic.rawValue,
            customFileName: "{artist} - {title}",
            playlistFolders: true,
            splitChapters: false,
        ])
    }
}

@MainActor
@Observable
final class DownloadManager {
    var items: [DownloadItem] = []
    var ytdlpVersion: String?

    /// True while Grab is downloading or updating its own yt-dlp/ffmpeg.
    var toolsInstalling = false

    private let defaults = UserDefaults.standard

    /// False while the Mac has no internet connection; retries wait for it to come back.
    private(set) var isOnline = true
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init() {
        Prefs.registerDefaults()
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

    // MARK: - Locating yt-dlp

    nonisolated static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    var executableURL: URL? {
        let custom = defaults.string(forKey: Prefs.ytdlpPath) ?? ""
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if defaults.bool(forKey: Prefs.autoUpdate), Updater.isInstalled {
            return Updater.binaryURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in Self.searchPaths + ["\(home)/.local/bin"] {
            let path = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// yt-dlp needs ffmpeg to merge video and audio and to convert audio.
    var ffmpegMissing: Bool {
        !toolDirectories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/ffmpeg") }
    }

    /// Grab's own tools come first when auto-update is on, then the usual install locations.
    private var toolDirectories: [String] {
        (defaults.bool(forKey: Prefs.autoUpdate) ? [Updater.directory.path] : []) + Self.searchPaths
    }

    /// Apps launched from Finder get a minimal PATH, so add the usual places ffmpeg lives.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (toolDirectories + [existing]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        // Grab's static ffmpeg doesn't use the macOS keychain for HTTPS certificates; without a
        // bundle it can't fetch anything itself (clips, some streams). Use the system's.
        if env["SSL_CERT_FILE"] == nil, FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        return env
    }

    func refreshVersion() {
        Task {
            let data = await capture(["--version"])
            let version = data.map { String(decoding: $0, as: UTF8.self) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ytdlpVersion = (version?.isEmpty ?? true) ? nil : version
        }
    }

    /// Runs yt-dlp to completion and returns stdout, or nil if it couldn't run or failed.
    private func capture(_ arguments: [String]) async -> Data? {
        guard let exe = executableURL else { return nil }
        let env = environment
        return await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = arguments
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        }.value
    }

    // MARK: - Queue

    /// Adds downloads for one or more links. When "Ask where to save" is on, asks once for the batch.
    func add(_ urls: [String], options: DownloadOptions = .current, folder override: String? = nil, clip: ClipRange? = nil) {
        guard !urls.isEmpty, let folder = override ?? destinationFolder(count: urls.count) else { return }
        for url in urls {
            if Playlists.looksLikePlaylist(url) {
                presentPicker(for: url, options: options, folder: folder)
            } else if let existing = alreadyDownloaded(url, isAudio: options.isAudio || MusicLinks.isMusicLink(url), clip: clip) {
                duplicates.append(DuplicatePrompt(existing: existing, url: url, options: options, folder: folder, clip: clip))
                AppDelegate.openMainWindow?()
            } else if MusicLinks.isMusicLink(url) {
                addSpotify(url, options: options, folder: folder, clip: clip)
            } else {
                let item = DownloadItem(url: url, options: options, folder: folder)
                item.clip = clip
                items.insert(item, at: 0)
            }
        }
        pump()
    }

    func add(_ url: String, options: DownloadOptions = .current, folder: String? = nil, clip: ClipRange? = nil) {
        add([url], options: options, folder: folder, clip: clip)
    }

    /// The Downloads setting, or a folder the user picks when "Always ask where to save" is on.
    private func destinationFolder(count: Int) -> String? {
        let folder = defaults.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory()
        return defaults.bool(forKey: Prefs.askLocation) ? askForFolder(starting: folder, count: count) : folder
    }

    /// File → Download Links from File…: every link in a text file.
    func chooseLinkFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose a text file with links, one per line or mixed with other text.")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let links = panel.urls.flatMap(Links.extract(fromFile:))
        guard !links.isEmpty else { NSSound.beep(); return }
        add(links)
        AppDelegate.openMainWindow?()
    }

    // MARK: - Converting files on this Mac

    /// Files dropped on the window (or chosen in File → Convert Files…), waiting for the user to
    /// pick what to turn them into.
    var filesToConvert: [URL] = []

    func chooseFilesToConvert() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose videos or songs to convert.")
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openConverter(for: panel.urls)
        AppDelegate.openMainWindow?()
    }

    /// Videos and songs open the convert sheet.
    func openConverter(for files: [URL]) {
        filesToConvert = files.filter(Converting.isMedia)
    }

    func convert(_ files: [URL], preset: Conversion.Preset, percent: Int? = nil, resolution: Int? = nil,
                 clip: ClipRange? = nil, gifWidth: Int? = nil) {
        guard !files.isEmpty, let folder = destinationFolder(count: files.count) else { return }
        let format = DownloadOptions.current
        for file in files {
            var options = DownloadOptions()
            if preset == .audio {
                options.kind = .audio
                options.audioFormat = format.audioFormat
                options.audioBitrate = format.audioBitrate
            }
            let item = DownloadItem(url: file.absoluteString, options: options, folder: folder)
            item.title = file.deletingPathExtension().lastPathComponent
            item.conversion = Conversion(source: file.path, preset: preset, percent: percent, resolution: resolution,
                                         clip: clip, gifWidth: gifWidth)
            item.clip = clip
            item.splitChapters = false
            items.insert(item, at: 0)
            Task { item.thumbnail = await Converting.thumbnail(for: file) }
        }
        pump()
    }

    /// Length, codecs and size of a file, for the size estimate in the convert sheet.
    func mediaInfo(for file: URL) async -> Converting.MediaInfo? {
        guard let ffprobe = tool("ffprobe") else { return nil }
        return await Converting.probe(file, ffprobe: ffprobe)
    }

    func tool(_ name: String) -> String? {
        toolDirectories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runConversion(_ item: DownloadItem, _ conversion: Conversion) {
        let source = URL(fileURLWithPath: conversion.source)
        guard FileManager.default.fileExists(atPath: source.path) else {
            fail(item, Converting.Failure.sourceMissing.localizedDescription)
            return
        }
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            fail(item, Converting.Failure.noFFmpeg.localizedDescription)
            return
        }
        item.phase = String(localized: "Reading file…")
        Task {
            let info = await Converting.probe(source, ffprobe: ffprobe)
            guard item.state == .starting else { return }
            guard var info else { fail(item, Converting.Failure.unreadable.localizedDescription); return }
            item.duration = info.duration
            // A part of the file: plan (and size estimates) for that part only.
            var sourceSize = Self.size(of: source) ?? 0
            var cut: [String] = []
            var limit: [String] = []
            if let clip = conversion.clip {
                let full = info.duration ?? 0
                let end = full > 0 ? min(clip.end ?? full, full) : clip.end
                cut = ["-ss", String(clip.start)]
                if let end {
                    let length = max(end - clip.start, 0.1)
                    limit = ["-t", String(length)]
                    if full > 0 { sourceSize = Int64(Double(sourceSize) * length / full) }
                    info.duration = length
                }
            }
            item.sourceAudio = Self.describeAudio(codec: info.audioCodec, bitrate: info.audioBitrate.map { $0 / 1000 })
            let plan: Converting.Plan
            // Two-pass encodes keep their analysis here; removed when the conversion ends.
            let passLog = FileManager.default.temporaryDirectory
                .appendingPathComponent("grab-pass-\(UUID().uuidString)").path
            do {
                plan = try Converting.plan(conversion, options: item.options, info: info,
                                           sourceExtension: source.pathExtension.lowercased(),
                                           sourceSize: sourceSize, passLog: passLog)
            } catch {
                fail(item, error.localizedDescription)
                return
            }
            let output = Converting.outputURL(folder: item.folder,
                                              name: source.deletingPathExtension().lastPathComponent + plan.suffix,
                                              fileExtension: plan.fileExtension)
            let input = ["-hide_banner", "-nostdin", "-y", "-v", "error", "-progress", "pipe:1", "-nostats"]
                + cut + ["-i", source.path] + limit
            var passes = [input + plan.arguments + [output.path]]
            if let first = plan.firstPass { passes.insert(input + first + ["/dev/null"], at: 0) }
            Task {
                let status = await runFFmpeg(item, ffmpeg: ffmpeg, passes: passes, duration: info.duration)
                for suffix in ["-0.log", "-0.log.mbtree", "-0.log.temp", "-0.log.mbtree.temp"] {
                    try? FileManager.default.removeItem(atPath: passLog + suffix)
                }
                if status == 0 {
                    item.fileURL = output
                } else {
                    try? FileManager.default.removeItem(at: output)
                }
                finish(item, status: status)
            }
        }
    }

    /// Runs ffmpeg once per pass, with one progress bar across all of them. Returns the exit
    /// status of the last pass that ran.
    private func runFFmpeg(_ item: DownloadItem, ffmpeg: String, passes: [[String]], duration: Double?) async -> Int32 {
        let started = Date()
        var status: Int32 = 0
        for (index, arguments) in passes.enumerated() {
            guard item.state == .starting || item.state == .downloading else { return 15 }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            item.process = process
            do {
                try process.run()
            } catch {
                item.errorMessage = error.localizedDescription
                return 1
            }
            item.phase = nil
            let errors = Task.detached {
                var last: String?
                for await line in PipeLines.stream(err.fileHandleForReading) where !line.isEmpty { last = line }
                return last
            }
            let count = Double(passes.count)
            for await line in PipeLines.stream(out.fileHandleForReading) where line.hasPrefix("out_time_us=") {
                guard let micro = Double(line.dropFirst("out_time_us=".count)), let duration, duration > 0,
                      item.state == .starting || item.state == .downloading else { continue }
                let progress = (Double(index) + min(max(micro / 1_000_000 / duration, 0), 1)) / count
                item.state = .downloading
                item.progress = progress
                let elapsed = Date().timeIntervalSince(started)
                item.eta = progress > 0.02 ? elapsed / progress - elapsed : nil
            }
            await Task.detached { process.waitUntilExit() }.value
            status = process.terminationStatus
            if status != 0 {
                if let last = await errors.value { item.errorMessage = last }
                return status
            }
        }
        return status
    }

    private func askForFolder(starting path: String, count: Int) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = String(localized: "Download Here")
        panel.message = count == 1 ? String(localized: "Choose where to save this download.") : String(localized: "Choose where to save these \(count) downloads.")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Search

    /// The search shown in the main window, if any.
    var search: SearchSession?

    /// Searches YouTube or YouTube Music for text typed into a link field.
    func startSearch(_ query: String, kind: SearchSession.Kind? = nil) {
        // Opens on the tab used last, so music searches go straight to Music.
        let remembered = SearchSession.Kind(rawValue: defaults.string(forKey: Prefs.searchKind) ?? "") ?? .videos
        let chosen = kind ?? remembered
        defaults.set(chosen.rawValue, forKey: Prefs.searchKind)
        let session = SearchSession(query: query, kind: chosen)
        search = session
        AppDelegate.openMainWindow?()
        Task { await run(session) }
    }

    /// Switches between Videos and Music for the current query.
    func changeSearchKind(_ kind: SearchSession.Kind) {
        guard let current = search, current.kind != kind else { return }
        startSearch(current.query, kind: kind)
    }

    private func run(_ session: SearchSession) async {
        guard let data = await capture(Searching.arguments(query: session.query, kind: session.kind)) else {
            if search?.id == session.id { session.phase = .failed }
            return
        }
        guard search?.id == session.id else { return }
        session.results = Searching.parse(data)
        session.phase = .ready
        // Music results show straight away; artist names fill in as they arrive.
        if session.kind == .music {
            let withArtists = await Searching.addArtists(to: session.results)
            if search?.id == session.id { session.results = withArtists }
        }
    }

    /// Downloads a result. Music results are saved as audio in the user's audio format.
    func download(_ result: SearchResult, from session: SearchSession) {
        var options = DownloadOptions.current
        if session.kind == .music { options.kind = .audio }
        guard let folder = destinationFolder(count: 1) else { return }
        let item = DownloadItem(url: result.url, options: options, folder: folder)
        item.title = result.title
        item.uploader = result.subtitle
        item.duration = result.duration
        item.thumbnail = result.thumbnail
        items.insert(item, at: 0)
        session.added.insert(result.id)
        pump()
    }

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
            if let file = prompt.existing.existingFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        case .downloadAgain:
            if MusicLinks.isMusicLink(prompt.url) {
                addSpotify(prompt.url, options: prompt.options, folder: prompt.folder, clip: prompt.clip)
            } else {
                let item = DownloadItem(url: prompt.url, options: prompt.options, folder: prompt.folder)
                item.clip = prompt.clip
                items.insert(item, at: 0)
            }
            pump()
        case .cancel:
            break
        }
    }

    // MARK: - Playlist picker

    /// Playlist links waiting for the user to choose videos; the first one is shown.
    var picks: [PlaylistPick] = []

    private func presentPicker(for url: String, options: DownloadOptions, folder: String) {
        let pick = PlaylistPick(sourceURL: url, folder: folder, options: options)
        picks.append(pick)
        AppDelegate.openMainWindow?()
        Task { await load(pick) }
    }

    private func load(_ pick: PlaylistPick) async {
        if let link = MusicLinks.parse(pick.sourceURL) {
            do {
                let collection = try await MusicLinks.fetch(link)
                pick.title = collection.name
                pick.owner = link.service == .spotify ? String(localized: "Spotify \(link.kind.rawValue)")
                                                      : String(localized: "Apple Music \(link.kind.rawValue)")
                if link.kind == .album, let artist = collection.tracks.first?.artists.first {
                    pick.folderPath = Folders.sanitize(artist) + "/" + Folders.sanitize(collection.name)
                } else {
                    pick.folderPath = Folders.sanitize(collection.name)
                }
                pick.entries = collection.tracks.map { track in
                    PlaylistEntry(id: track.id, url: track.url, title: track.title,
                                  subtitle: track.artists.joined(separator: ", "),
                                  duration: track.duration, thumbnail: track.cover, spotify: track)
                }
            } catch {
                pick.phase = .failed(error.localizedDescription)
                return
            }
        } else {
            let args = ["--flat-playlist", "--dump-single-json", "--no-warnings", "--yes-playlist",
                        "--playlist-end", "\(Playlists.limit)"] + cookieArguments() + ["--", pick.sourceURL]
            guard let data = await capture(args), let playlist = Playlists.parse(data) else {
                // Not a playlist after all, or unreadable: download the link as a single video.
                cancelPick(pick)
                items.insert(DownloadItem(url: pick.sourceURL, options: pick.options, folder: pick.folder), at: 0)
                pump()
                return
            }
            pick.title = playlist.title ?? String(localized: "Playlist")
            pick.folderPath = Folders.sanitize(pick.title)
            pick.owner = playlist.owner
            pick.entries = playlist.entries
            pick.hiddenCount = playlist.hidden
        }

        // Mark what's already downloaded; those aren't selected to begin with.
        let isAudio = pick.options.isAudio || pick.entries.first?.spotify != nil
        pick.downloaded = Set(pick.entries.filter { alreadyDownloaded($0.url, isAudio: isAudio) != nil }.map(\.id))

        // A video link inside a playlist starts with just that video; a playlist link with everything new.
        if let focus = Playlists.focusedVideoID(in: pick.sourceURL), pick.entries.contains(where: { $0.id == focus }) {
            pick.selected = [focus]
        } else {
            pick.selected = Set(pick.entries.map(\.id)).subtracting(pick.downloaded)
            if pick.selected.isEmpty { pick.selectAll() }
        }
        pick.phase = pick.entries.isEmpty ? .failed(String(localized: "This playlist has no videos Grab can download.")) : .ready
    }

    func cancelPick(_ pick: PlaylistPick) {
        picks.removeAll { $0.id == pick.id }
    }

    /// Queues the chosen entries, in playlist order.
    func confirm(_ pick: PlaylistPick) {
        // Uses the format picked in the sheet (stored like the main window's choice).
        var options = DownloadOptions.current
        let spotifyItems = pick.selectedEntries.contains { $0.spotify != nil }
        if spotifyItems { options.kind = .audio }
        // Two or more items from an album or playlist go into their own folder.
        var folder = pick.folder
        if pick.selected.count > 1, defaults.bool(forKey: Prefs.playlistFolders), let sub = pick.folderPath {
            folder = (pick.folder as NSString).appendingPathComponent(sub)
        }
        let newItems = pick.selectedEntries.map { entry -> DownloadItem in
            let item: DownloadItem
            if let track = entry.spotify {
                item = DownloadItem(spotify: track, options: options, folder: folder)
            } else {
                item = DownloadItem(url: entry.url, options: options, folder: folder)
                item.title = entry.title
                item.uploader = entry.subtitle
                item.duration = entry.duration
                item.thumbnail = entry.thumbnail
            }
            return item
        }
        // Newest first in the list, so the playlist's first video ends up at the top of the batch.
        items.insert(contentsOf: newItems, at: 0)
        cancelPick(pick)
        pump()
    }

    func cookieArguments() -> [String] {
        // Only when the cookies can actually be read: otherwise yt-dlp stops every download with
        // "could not find … cookies database" (macOS 27 blocks Chrome, Brave, Edge and Firefox).
        guard let browser = CookieBrowser(rawValue: defaults.string(forKey: Prefs.cookiesBrowser) ?? ""),
              browser.isInstalled, browser.hasReadableCookies, let value = browser.argument else { return [] }
        return ["--cookies-from-browser", value]
    }

    /// Spotify and Apple Music track links: read the song's details, then match it on YouTube Music.
    private func addSpotify(_ url: String, options: DownloadOptions, folder: String, clip: ClipRange? = nil) {
        // Music services are always audio; keep the chosen audio format even if video is selected.
        var audio = options
        audio.kind = .audio
        let service = MusicLinks.service(of: url) ?? .spotify

        let placeholder = DownloadItem(url: url, options: audio, folder: folder)
        placeholder.title = service.name
        placeholder.state = .starting
        placeholder.phase = service == .spotify ? String(localized: "Reading Spotify link…")
                                                : String(localized: "Reading Apple Music link…")
        items.insert(placeholder, at: 0)

        guard let link = MusicLinks.parse(url) else {
            fail(placeholder, MusicLinks.unsupported(service))
            return
        }

        Task {
            do {
                let collection = try await MusicLinks.fetch(link)
                guard placeholder.state != .cancelled,
                      let index = items.firstIndex(where: { $0.id == placeholder.id }) else { return }
                let tracks = collection.tracks.map { track in
                    let item = DownloadItem(spotify: track, options: audio, folder: folder)
                    item.clip = clip
                    return item
                }
                items.replaceSubrange(index...index, with: tracks)
                pump()
            } catch {
                fail(placeholder, error.localizedDescription)
            }
        }
    }

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
        if toolsInstalling, executableURL == nil || ffmpegMissing {
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

    private func fail(_ item: DownloadItem, _ message: String) {
        item.state = .failed
        item.errorMessage = message
        pump()
        saveHistory()
    }

    /// Called when Grab quits: remembers unfinished downloads (as interrupted) and stops yt-dlp,
    /// which would otherwise keep running in the background with nothing watching it.
    func shutDown() {
        saveHistory(includingActive: true)
        for item in items { item.process?.terminate() }
    }

    // MARK: - Running

    private func arguments(for item: DownloadItem, url: String) -> [String] {
        let options = item.options
        var args = [
            "--newline", "--progress", "--no-simulate",
            "--socket-timeout", "20", "--retries", "10", "--fragment-retries", "10",
            "--progress-template",
            "download:GRAB|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:GRABPP|%(progress.postprocessor)s",
            "--print", "video:GRABMETA %(.{title,uploader,channel,duration,thumbnail,acodec,abr,artist,track,language})j",
            "--print", "after_move:GRABFILE %(filepath)s",
            "-P", item.folder,
        ]
        args += options.arguments
        // Only download part of the video; cut exactly at the chosen times.
        let clipSuffix = item.clip?.fileSuffix ?? ""
        // The user's file name style (Settings → Downloads), plus the clip range for clips.
        let outputName = FileNaming.template(isAudio: options.isAudio) + clipSuffix + ".%(ext)s"
        if let clip = item.clip {
            args += ["--download-sections", clip.sectionArgument, "--force-keyframes-at-cuts"]
        } else if item.splitChapters, item.spotify == nil {
            // One file per chapter, in a folder named like the whole video would have been.
            args += ["--split-chapters",
                     "-o", "chapter:" + FileNaming.template(isAudio: options.isAudio) + "/%(section_number)02d - %(section_title)s.%(ext)s"]
        }

        if let track = item.spotify {
            // Tag the file with Spotify's metadata rather than YouTube's.
            let artist = track.artists.joined(separator: ", ")
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(track.title)):%(title)s"]
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(track.title)):%(track)s"]
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(artist)):%(artist)s"]
            if let album = track.album {
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(album)):%(album)s"]
            }
            // Album position and year, so the song sorts right in Apple Music (meta_ fields go
            // straight into the file's tags).
            if let number = track.trackNumber {
                let value = track.trackCount.map { "\(number)/\($0)" } ?? "\(number)"
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(value)):%(meta_track)s"]
            }
            if let disc = track.discNumber {
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(String(disc))):%(meta_disc)s"]
            }
            if let year = track.year {
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(year)):%(meta_date)s"]
            }
            args += ["-o", outputName, "--no-playlist", "--embed-metadata"]
            if options.canEmbedThumbnail {
                // YouTube Music art is 16:9 with bars; crop it to a square cover.
                args += ["--embed-thumbnail", "--convert-thumbnails", "jpg",
                         "--ppa", "ThumbnailsConvertor+FFmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""]
            }
        } else {
            args += ["-o", outputName]
            // Playlists go through the picker, so a link here always means one video.
            args.append("--no-playlist")
            if defaults.bool(forKey: Prefs.embedMetadata) { args.append("--embed-metadata") }
            if defaults.bool(forKey: Prefs.embedThumbnail), options.canEmbedThumbnail { args.append("--embed-thumbnail") }
            if defaults.bool(forKey: Prefs.embedSubtitles), !options.isAudio {
                args += ["--write-subs", "--embed-subs", "--sub-langs", "all,-live_chat"]
            }
            if defaults.bool(forKey: Prefs.removeSponsors) { args += ["--sponsorblock-remove", "sponsor"] }
        }

        // A raw stream found by loading a page is a link that page chose. Never send the user's
        // browser cookies along with it (the page was loaded logged out anyway).
        args += cookieArguments()
        args += ["--", url]
        return args
    }

    private func start(_ item: DownloadItem) {
        item.state = .starting
        item.retryAt = nil
        item.phase = nil
        if let conversion = item.conversion {
            runConversion(item, conversion)
            return
        }
        guard executableURL != nil else {
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

    /// Finds the best YouTube source for a Spotify track: the top YouTube Music song result when its
    /// title matches, otherwise the YouTube video whose title matches and length is closest.
    private func findMatch(for track: SpotifyTrack) async -> String? {
        let flat = ["--flat-playlist", "--dump-single-json", "--no-warnings"]

        if let data = await capture(flat + ["--playlist-items", "1:5", Spotify.musicSearchURL(for: track)]),
           let entries = Self.entries(data),
           let hit = entries.first(where: { Spotify.titlesMatch($0["title"] as? String ?? "", track) }),
           let url = hit["url"] as? String {
            return url
        }

        guard let data = await capture(flat + [Spotify.videoSearchQuery(for: track)]),
              let entries = Self.entries(data), !entries.isEmpty else { return nil }
        let target = track.duration ?? 0
        let scored = entries.compactMap { e -> (url: String, score: Double)? in
            guard let url = e["url"] as? String else { return nil }
            var score = 0.0
            if Spotify.titlesMatch(e["title"] as? String ?? "", track) { score += 100 }
            if let d = e["duration"] as? Double, target > 0 { score -= min(abs(d - target), 60) }
            return (url, score)
        }
        return scored.max { $0.score < $1.score }?.url
    }

    private nonisolated static func entries(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["entries"] as? [[String: Any]]
    }

    private func launch(_ item: DownloadItem) {
        guard let exe = executableURL else { return }
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments(for: item, url: item.resolvedURL ?? item.url)
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        item.process = process

        do {
            try process.run()
        } catch {
            fail(item, error.localizedDescription)
            return
        }

        let errors = Task.detached {
            for await line in PipeLines.stream(err.fileHandleForReading) where line.hasPrefix("ERROR:") {
                // "ERROR: [youtube] abc123: Video unavailable" → "Video unavailable"
                var message = line
                    .replacingOccurrences(of: "ERROR: ", with: "")
                    .replacingOccurrences(of: #"^\[[^\]]+\] [^:]+: "#, with: "", options: .regularExpression)
                if message.localizedCaseInsensitiveContains("cookies database")
                    || message.localizedCaseInsensitiveContains("decrypt") {
                    message = String(localized: "Couldn’t read this browser’s cookies. Pick another browser (or None) in Settings → Advanced.")
                }
                let lower = message.lowercased()
                if lower.contains("logged-in") || lower.contains("login required") || lower.contains("log in to")
                    || (lower.contains("--cookies") && !lower.contains("cookies database")) {
                    message = String(localized: "This site needs you to be logged in. Log in with your browser, then choose that browser under Settings → Advanced → Use cookies from.")
                } else if lower.contains("drm protected") {
                    message = String(localized: "This video is DRM-protected and can’t be downloaded.")
                }
                let final = message
                await MainActor.run { item.errorMessage = final }
            }
        }
        Task.detached {
            for await line in PipeLines.stream(out.fileHandleForReading) {
                await self.handle(line, for: item)
            }
            process.waitUntilExit()
            // Let the error text land before deciding what to do next.
            await errors.value
            await self.finish(item, status: process.terminationStatus)
        }
    }

    private func handle(_ line: String, for item: DownloadItem) {
        guard item.state != .cancelled else { return }

        if line.hasPrefix("GRAB|") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return }
            let done = Double(f[2]) ?? 0
            let total = Double(f[3]) ?? Double(f[4]) ?? 0
            if total > 0 { item.progress = min(done / total, 1) }
            item.speed = Double(f[5])
            item.eta = Double(f[6])
            item.state = .downloading
        } else if line.hasPrefix("GRABPP|") {
            item.state = .processing
            item.phase = Self.describe(postprocessor: String(line.dropFirst("GRABPP|".count)))
        } else if line.hasPrefix("GRABMETA ") {
            let json = Data(line.dropFirst("GRABMETA ".count).utf8)
            guard let meta = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            if item.thumbnail == nil, let thumb = meta["thumbnail"] as? String { item.thumbnail = URL(string: thumb) }
            if item.options.isAudio {
                item.sourceAudio = Self.describeAudio(codec: meta["acodec"] as? String, bitrate: meta["abr"] as? Double)
            }
            // ffmpeg cuts clips without reporting progress; say what's happening meanwhile.
            if item.clip != nil, item.state == .starting { item.phase = String(localized: "Cutting clip…") }
            // Spotify items keep their own title, artist and length.
            guard item.spotify == nil else { return }
            if let t = meta["title"] as? String { item.title = t }
            item.uploader = (meta["uploader"] as? String) ?? (meta["channel"] as? String)
            item.duration = meta["duration"] as? Double
        } else if line.hasPrefix("GRABFILE ") {
            item.fileURL = Self.tidiedName(URL(fileURLWithPath: String(line.dropFirst("GRABFILE ".count))))
        }
    }

    /// A title ending in a full stop gives "Title..mp4": drop the stray dots (and spaces) before
    /// the extension. Leaves the file alone if the tidy name is already taken.
    nonisolated static func tidiedName(_ file: URL) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let tidy = base.replacingOccurrences(of: "[.\\s]+$", with: "", options: .regularExpression)
        guard tidy != base, !tidy.isEmpty, !file.pathExtension.isEmpty else { return file }
        let target = file.deletingLastPathComponent().appendingPathComponent(tidy).appendingPathExtension(file.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path),
              (try? FileManager.default.moveItem(at: file, to: target)) != nil else { return file }
        return target
    }

    /// "Opus 272 kbps", "AAC 256 kbps"… from yt-dlp's codec id and average bitrate.
    static func describeAudio(codec: String?, bitrate: Double?) -> String? {
        guard let codec = codec?.lowercased(), codec != "none" else { return nil }
        let name = switch codec {
        case let c where c.hasPrefix("mp4a") || c == "aac": "AAC"
        case let c where c.hasPrefix("opus"): "Opus"
        case let c where c.hasPrefix("vorbis"): "Vorbis"
        case let c where c.hasPrefix("mp3"): "MP3"
        case let c where c.hasPrefix("flac"): "FLAC"
        case let c where c.hasPrefix("alac"): "ALAC"
        case let c where c.hasPrefix("pcm"): "PCM"
        default: codec.uppercased()
        }
        guard let bitrate, bitrate > 0 else { return name }
        return "\(name) \(Int(bitrate.rounded())) kbps"
    }

    private static func describe(postprocessor: String) -> String {
        switch postprocessor {
        case "Merger": String(localized: "Merging audio & video…")
        case "ExtractAudio": String(localized: "Converting audio…")
        case "EmbedThumbnail", "ThumbnailsConvertor": String(localized: "Embedding artwork…")
        case "FFmpegMetadata", "Metadata", "MetadataParser": String(localized: "Writing metadata…")
        case "EmbedSubtitle": String(localized: "Embedding subtitles…")
        case "SponsorBlock", "ModifyChapters": String(localized: "Removing sponsors…")
        case "SplitChapters": String(localized: "Splitting into chapters…")
        default: String(localized: "Finishing up…")
        }
    }

    /// Chapter files get their own titles and track numbers (the whole video is then removed).
    private func splitsChapters(_ item: DownloadItem) -> Bool {
        item.splitChapters && item.conversion == nil && item.clip == nil
    }

    private func finish(_ item: DownloadItem, status: Int32, finishingDone: Bool = false) {
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

    /// yt-dlp errors that mean the connection failed, not the video.
    private static let networkErrors = [
        "timed out", "timeout", "connection", "network is unreachable", "temporary failure in name resolution",
        "nodename nor servname", "getaddrinfo", "unable to download", "incompleteread", "remote end closed",
        "eof occurred", "ssl", "errno 50", "errno 51", "errno 54", "errno 60", "errno 61", "http error 5",
        "giving up after",
    ]

    private func isNetworkProblem(_ item: DownloadItem) -> Bool {
        if !isOnline { return true }
        let message = item.errorMessage?.lowercased() ?? ""
        if ["unavailable", "private", "drm", "logged in", "log in", "copyright", "removed"].contains(where: message.contains) {
            return false
        }
        return Self.networkErrors.contains(where: message.contains)
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

    /// Apple Music's album art, for songs saved in a format that holds a cover.
    private func artworkToEmbed(for item: DownloadItem) -> URL? {
        guard let artwork = item.spotify?.artwork, item.clip == nil, !item.hasArtwork,
              let file = item.fileURL, ["m4a", "mp3", "flac"].contains(file.pathExtension.lowercased()),
              defaults.bool(forKey: Prefs.embedThumbnail) else { return nil }
        return artwork
    }

    /// Swaps YouTube Music's thumbnail for the service's album art (streams copied as-is).
    private func embed(_ artwork: URL, into item: DownloadItem) async {
        guard let file = item.fileURL, let ffmpeg = tool("ffmpeg"),
              let (data, response) = try? await URLSession.shared.data(from: artwork),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
        let folder = file.deletingLastPathComponent()
        let image = folder.appendingPathComponent(".grab-cover-\(UUID().uuidString).jpg")
        let temp = folder.appendingPathComponent(".grab-cover-\(UUID().uuidString).\(file.pathExtension)")
        guard (try? data.write(to: image)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: image) }
        var args = ["-y", "-v", "error", "-i", file.path, "-i", image.path, "-map", "0:a", "-map", "1:0",
                    "-c", "copy", "-map_metadata", "0", "-disposition:v:0", "attached_pic"]
        if file.pathExtension.lowercased() == "mp3" {
            args += ["-id3v2_version", "3", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        }
        let env = environment
        let ok = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = args + [temp.path]
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
        if ok, (try? FileManager.default.replaceItemAt(file, withItemAt: temp)) != nil {
            item.hasArtwork = true
        } else {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: - Chapters

    /// After `--split-chapters`: each chapter file gets its chapter as title, a track number and
    /// the video as album (yt-dlp copies the whole video's tags into every piece). The full-length
    /// file is removed and the row points at the folder. Videos without chapters are left alone.
    private func tagChapters(of item: DownloadItem) async {
        guard let file = item.fileURL, let ffmpeg = tool("ffmpeg") else { return }
        let folder = file.deletingPathExtension()
        let pieces = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !pieces.isEmpty else { return }
        let album = item.title
        let env = environment
        await Task.detached {
            for (index, piece) in pieces.enumerated() {
                // "03 - Chapter Title.m4a" → "Chapter Title"
                let name = piece.deletingPathExtension().lastPathComponent
                let title = name.range(of: #"^\d+ - "#, options: .regularExpression).map { String(name[$0.upperBound...]) } ?? name
                let temp = folder.appendingPathComponent(".grab-tag-\(UUID().uuidString).\(piece.pathExtension)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-y", "-v", "error", "-i", piece.path, "-map", "0", "-dn", "-c", "copy",
                               "-map_metadata", "0", "-map_chapters", "-1",
                               "-metadata", "title=\(title)", "-metadata", "track=\(index + 1)/\(pieces.count)",
                               "-metadata", "album=\(album)", temp.path]
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    _ = try? FileManager.default.replaceItemAt(piece, withItemAt: temp)
                } else {
                    try? FileManager.default.removeItem(at: temp)
                }
            }
        }.value
        try? FileManager.default.removeItem(at: file)
        item.fileURL = folder
        item.chapterCount = pieces.count
    }

    /// A file's size, or everything in a folder (chapter splits).
    static func size(of url: URL) -> Int64? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        guard isFolder.boolValue else {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func updateBadge() {
        let count = activeCount
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}

/// Lines from a pipe as they arrive. This deliberately avoids `FileHandle.bytes`: two of those
/// reading at once (yt-dlp's stdout and stderr) block each other, so progress only reached the
/// app when yt-dlp exited. `readabilityHandler` reads each pipe independently.
enum PipeLines {
    private final class Buffer: @unchecked Sendable { var data = Data() }

    static func stream(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = Buffer()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    if !buffer.data.isEmpty { continuation.yield(String(decoding: buffer.data, as: UTF8.self)) }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.data.append(chunk)
                while let newline = buffer.data.firstIndex(of: 0x0A) {
                    var line = buffer.data[buffer.data.startIndex..<newline]
                    if line.last == 0x0D { line = line.dropLast() }
                    continuation.yield(String(decoding: line, as: UTF8.self))
                    buffer.data.removeSubrange(buffer.data.startIndex...newline)
                }
            }
        }
    }
}
