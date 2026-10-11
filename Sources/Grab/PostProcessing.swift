import AppKit

// The steps after yt-dlp has finished: album art, chapter tags, sizes.
extension DownloadManager {
    /// Chapter files get their own titles and track numbers (the whole video is then removed).
    func splitsChapters(_ item: DownloadItem) -> Bool {
        item.splitChapters && item.conversion == nil && item.clip == nil
    }

    /// Apple Music's album art, for songs saved in a format that holds a cover.
    func artworkToEmbed(for item: DownloadItem) -> URL? {
        guard let artwork = item.spotify?.artwork, item.clip == nil, !item.hasArtwork,
              let file = item.fileURL, ["m4a", "mp3", "flac"].contains(file.pathExtension.lowercased()),
              defaults.bool(forKey: Prefs.embedThumbnail) else { return nil }
        return artwork
    }

    /// Swaps YouTube Music's thumbnail for the service's album art (streams copied as-is).
    func embed(_ artwork: URL, into item: DownloadItem) async {
        guard let file = item.fileURL, Self.isInside(file, folder: item.folder), let ffmpeg = Tools.path("ffmpeg"),
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
        let output = await Tools.run(ffmpeg, args + [temp.path], environment: Tools.environment) { item.process = $0 }
        if output?.status == 0, (try? FileManager.default.replaceItemAt(file, withItemAt: temp)) != nil {
            item.hasArtwork = true
        } else {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    /// After `--split-chapters`: each chapter file gets its chapter as title, a track number and
    /// the video as album (yt-dlp copies the whole video's tags into every piece). The full-length
    /// file is removed and the row points at the folder. Videos without chapters are left alone,
    /// and so is anything yt-dlp didn't report writing in this run.
    func tagChapters(of item: DownloadItem) async {
        guard let file = item.fileURL, Self.isInside(file, folder: item.folder), let ffmpeg = Tools.path("ffmpeg") else { return }
        let pieces = item.chapterFiles
            .filter { Self.isInside($0, folder: item.folder) && FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = pieces.first else { return }
        let folder = first.deletingLastPathComponent()
        let album = item.title
        for (index, piece) in pieces.enumerated() {
            guard item.state != .cancelled else { return }
            // "03 - Chapter Title.m4a" → "Chapter Title"
            let name = piece.deletingPathExtension().lastPathComponent
            let title = name.range(of: #"^\d+ - "#, options: .regularExpression).map { String(name[$0.upperBound...]) } ?? name
            let temp = folder.appendingPathComponent(".grab-tag-\(UUID().uuidString).\(piece.pathExtension)")
            let arguments = ["-y", "-v", "error", "-i", piece.path, "-map", "0", "-dn", "-c", "copy",
                             "-map_metadata", "0", "-map_chapters", "-1",
                             "-metadata", "title=\(title)", "-metadata", "track=\(index + 1)/\(pieces.count)",
                             "-metadata", "album=\(album)", temp.path]
            let output = await Tools.run(ffmpeg, arguments, environment: Tools.environment) { item.process = $0 }
            if output?.status == 0 {
                _ = try? FileManager.default.replaceItemAt(piece, withItemAt: temp)
            } else {
                try? FileManager.default.removeItem(at: temp)
            }
        }
        guard item.state != .cancelled else { return }
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
}
