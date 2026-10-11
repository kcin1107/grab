import AppKit
import Foundation
import Observation

/// One search result: a YouTube video or a YouTube Music song.
struct SearchResult: Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    var subtitle: String?
    let duration: Double?
    let views: Int?
    let thumbnail: URL?
}

/// Searching YouTube (videos) or YouTube Music (songs) from the link field.
@MainActor
@Observable
final class SearchSession: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case videos, music
        var id: String { rawValue }
        var label: String {
            switch self {
            case .videos: String(localized: "Videos")
            case .music: String(localized: "Music")
            }
        }
    }

    enum Phase: Equatable { case loading, ready, failed }

    let id = UUID()
    let query: String
    let kind: Kind
    var phase: Phase = .loading
    var results: [SearchResult] = []
    /// Results added to the download list from this search.
    var added: Set<SearchResult.ID> = []

    init(query: String, kind: Kind) {
        self.query = query
        self.kind = kind
    }
}

enum Searching {
    static let count = 15

    /// The YouTube Music page of song results for a search.
    static func musicSearchURL(query: String) -> String {
        var c = URLComponents(string: "https://music.youtube.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url!.absoluteString + "#songs"
    }

    /// yt-dlp arguments for a flat search (titles and details only, nothing downloaded).
    static func arguments(query: String, kind: SearchSession.Kind) -> [String] {
        let target: String
        switch kind {
        case .videos:
            target = "ytsearch\(count):\(query)"
        case .music:
            target = musicSearchURL(query: query)
        }
        return ["--flat-playlist", "--dump-single-json", "--no-warnings", "--playlist-items", "1:\(count)", "--", target]
    }

    static func parse(_ data: Data) -> [SearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { e in
            guard let id = e["id"] as? String, let url = e["url"] as? String,
                  let title = e["title"] as? String, !title.isEmpty else { return nil }
            let thumb = ((e["thumbnails"] as? [[String: Any]])?.last?["url"] as? String).flatMap(URL.init)
                ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
            return SearchResult(id: id, url: url, title: title,
                                subtitle: (e["channel"] as? String) ?? (e["uploader"] as? String),
                                duration: e["duration"] as? Double, views: e["view_count"] as? Int,
                                thumbnail: thumb)
        }
    }

    /// YouTube Music's song search only gives titles; YouTube's public oEmbed adds the artist.
    static func addArtists(to results: [SearchResult]) async -> [SearchResult] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, result) in results.enumerated() where result.subtitle == nil {
                group.addTask {
                    var c = URLComponents(string: "https://www.youtube.com/oembed")!
                    c.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(result.id)"),
                                    URLQueryItem(name: "format", value: "json")]
                    let request = URLRequest(url: c.url!, timeoutInterval: 6)
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let author = json["author_name"] as? String else { return (index, nil) }
                    // Auto-generated music channels are called "Artist - Topic".
                    let artist = author.hasSuffix(" - Topic") ? String(author.dropLast(8)) : author
                    return (index, artist)
                }
            }
            var updated = results
            for await (index, artist) in group where artist != nil { updated[index].subtitle = artist }
            return updated
        }
    }

    /// "10M views", "1.4K views", using the user's locale.
    static func views(_ count: Int) -> String {
        let formatted = count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        return String(localized: "\(formatted) views")
    }
}

extension DownloadManager {
    // MARK: - Search

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

    func run(_ session: SearchSession) async {
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
        items.insert(item(url: result.url, options: options, folder: folder, title: result.title,
                          uploader: result.subtitle, duration: result.duration, thumbnail: result.thumbnail), at: 0)
        session.added.insert(result.id)
        pump()
    }
}
