import AppKit
import Foundation
import Observation

/// One video or track in a playlist the user is picking from.
struct PlaylistEntry: Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    let subtitle: String?
    let duration: Double?
    let thumbnail: URL?
    /// Set for Spotify and Apple Music albums and playlists, so the download is matched and tagged like a track link.
    var spotify: SpotifyTrack?

    static func == (a: PlaylistEntry, b: PlaylistEntry) -> Bool { a.id == b.id }
}

/// A playlist link waiting for the user to choose what to download.
@MainActor
@Observable
final class PlaylistPick: Identifiable {
    enum Phase: Equatable { case loading, ready, failed(String) }

    let id = UUID()
    let sourceURL: String
    let folder: String
    let options: DownloadOptions

    var phase: Phase = .loading
    var title = String(localized: "Playlist")
    var owner: String?
    var entries: [PlaylistEntry] = []
    var selected: Set<PlaylistEntry.ID> = []
    /// Entries left out because they're private, deleted or otherwise unavailable.
    var hiddenCount = 0
    /// Entries already downloaded (file still there); not selected to begin with.
    var downloaded: Set<PlaylistEntry.ID> = []
    /// Subfolder for 2+ items: "Artist/Album" for albums, the playlist's name otherwise.
    var folderPath: String?

    init(sourceURL: String, folder: String, options: DownloadOptions) {
        self.sourceURL = sourceURL
        self.folder = folder
        self.options = options
    }

    var selectedEntries: [PlaylistEntry] { entries.filter { selected.contains($0.id) } }
    var allSelected: Bool { !entries.isEmpty && selected.count == entries.count }

    func selectAll() { selected = Set(entries.map(\.id)) }
    func selectNone() { selected = [] }

    func toggle(_ entry: PlaylistEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }
}

enum Playlists {
    /// Links that point at a list rather than one video. Single videos skip the picker entirely,
    /// so they never wait for an extra lookup.
    static func looksLikePlaylist(_ link: String) -> Bool {
        if let music = MusicLinks.parse(link) { return music.kind != .track }
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" {
            return path.hasPrefix("/playlist") || items.contains { $0.name == "list" && !($0.value ?? "").isEmpty }
        }
        if host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") { return path.contains("/sets/") }
        return false
    }

    /// For a video link that also names a playlist (watch?v=…&list=…), the video to start with.
    static func focusedVideoID(in link: String) -> String? {
        guard let url = URL(string: link) else { return nil }
        if url.host?.lowercased() == "youtu.be" { return url.pathComponents.dropFirst().first }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    static let limit = 500

    /// Reads a playlist from yt-dlp's flat listing (titles, lengths and thumbnails, no downloading).
    static func parse(_ data: Data) -> (title: String?, owner: String?, entries: [PlaylistEntry], hidden: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["_type"] as? String == "playlist",
              let raw = json["entries"] as? [[String: Any]] else { return nil }
        var entries: [PlaylistEntry] = []
        var hidden = 0
        for e in raw {
            let title = e["title"] as? String ?? ""
            guard let url = (e["url"] as? String) ?? (e["webpage_url"] as? String),
                  !title.isEmpty, !["[Private video]", "[Deleted video]"].contains(title) else {
                hidden += 1
                continue
            }
            let thumb = ((e["thumbnails"] as? [[String: Any]])?.last?["url"] as? String).flatMap(URL.init)
            entries.append(PlaylistEntry(
                id: (e["id"] as? String) ?? url, url: url, title: title,
                subtitle: (e["channel"] as? String) ?? (e["uploader"] as? String),
                duration: e["duration"] as? Double, thumbnail: thumb))
        }
        return (json["title"] as? String, (json["uploader"] as? String) ?? (json["channel"] as? String), entries, hidden)
    }
}

extension DownloadManager {
    // MARK: - Playlist picker

    func presentPicker(for url: String, options: DownloadOptions, folder: String) {
        let pick = PlaylistPick(sourceURL: url, folder: folder, options: options)
        picks.append(pick)
        AppDelegate.openMainWindow?()
        Task { await load(pick) }
    }

    func load(_ pick: PlaylistPick) async {
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
                        "--playlist-end", "\(Playlists.limit)"] + ["--", pick.sourceURL]
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
            if let track = entry.spotify {
                return DownloadItem(spotify: track, options: options, folder: folder)
            }
            return item(url: entry.url, options: options, folder: folder, title: entry.title,
                        uploader: entry.subtitle, duration: entry.duration, thumbnail: entry.thumbnail)
        }
        // Newest first in the list, so the playlist's first video ends up at the top of the batch.
        items.insert(contentsOf: newItems, at: 0)
        cancelPick(pick)
        pump()
    }

    /// Spotify and Apple Music track links: read the song's details, then match it on YouTube Music.
    func addSpotify(_ url: String, options: DownloadOptions, folder: String, clip: ClipRange? = nil) {
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

    /// Finds the best YouTube source for a Spotify track: the top YouTube Music song result when its
    /// title matches, otherwise the YouTube video whose title matches and length is closest.
    func findMatch(for track: SpotifyTrack) async -> String? {
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

    nonisolated static func entries(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["entries"] as? [[String: Any]]
    }
}
