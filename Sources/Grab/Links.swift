import AppKit

enum Links {
    /// Accepts web links and Spotify and Apple Music links only.
    static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if MusicLinks.parse(trimmed) != nil { return trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return trimmed
    }

    /// Every distinct link on a pasteboard: copied URLs first, then any found in selected text.
    static func extract(from pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        var found = unique(urls.compactMap { validated($0.absoluteString) })
        if let text = pasteboard.string(forType: .string) {
            found = unique(found + extract(fromText: text))
        }
        return found
    }

    /// Every distinct web, Spotify or Apple Music link in a piece of text, in order: one per line, separated by
    /// spaces, or mixed in with other words.
    static func extract(fromText text: String) -> [String] {
        var found: [String] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let link = validated(url.absoluteString) { found.append(link) }
            }
        }
        if found.isEmpty, let link = validated(text) { found.append(link) }
        return unique(found)
    }

    /// The links in a text file, such as a list someone sent or exported.
    static func extract(fromFile url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), data.count < 10_000_000 else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return extract(fromText: text)
    }

    private static func unique(_ links: [String]) -> [String] {
        var seen = Set<String>()
        return links.filter { seen.insert($0).inserted }
    }
}

enum WebPage {
    /// Fetches a page as Safari would and returns the JSON inside the script tag that opens with
    /// `scriptTag`, or nil if the page doesn't have one.
    static func embeddedJSON(at url: URL, scriptTag: String) async throws -> Any? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let start = html.range(of: scriptTag),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8))
    }
}
