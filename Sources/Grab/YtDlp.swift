import Foundation

// What Grab knows about yt-dlp: the arguments it is run with, and how its output is read.
extension DownloadManager {
    /// Options that stop yt-dlp loading configuration files or plugins found on disk (a
    /// yt-dlp.conf in the download folder would otherwise be read, and could add --exec).
    nonisolated static let isolation = ["--ignore-config", "--no-plugin-dirs"]

    /// Runs yt-dlp to completion and returns stdout, or nil if it couldn't run or failed.
    func capture(_ arguments: [String]) async -> Data? {
        guard let exe = Tools.ytdlp else { return nil }
        let env = Tools.environment
        guard let output = await Tools.run(exe.path, Self.isolation + arguments, environment: env) else { return nil }
        return output.status == 0 ? output.stdout : nil
    }

    /// The yt-dlp command line for one download.
    static func arguments(for item: DownloadItem, url: String) -> [String] {
        let defaults = UserDefaults.standard
        let options = item.options
        var args = Self.isolation + [
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

        args += ["--", url]
        return args
    }

    /// Applies one line of yt-dlp's standard output (progress, details, file names) to its download.
    static func handle(_ line: String, for item: DownloadItem) {
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
            let file = URL(fileURLWithPath: String(line.dropFirst("GRABFILE ".count)))
            if Self.isInside(file, folder: item.folder) { item.fileURL = Self.tidiedName(file) }
        } else if line.hasPrefix("[SplitChapters] Chapter "), let range = line.range(of: "; Destination: ") {
            // "[SplitChapters] Chapter 001; Destination: <path>": one line per chapter file written.
            item.chapterFiles.append(URL(fileURLWithPath: String(line[range.upperBound...])))
        }
    }

    /// Whether a path (read from yt-dlp's output) is inside a folder, once both are standardized
    /// and their symlinks resolved. Anything outside is never touched.
    nonisolated static func isInside(_ url: URL, folder: String) -> Bool {
        let root = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
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

    static func describe(postprocessor: String) -> String {
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

    /// A readable message from one "ERROR:" line on yt-dlp's standard error.
    nonisolated static func errorMessage(from line: String) -> String {
        // "ERROR: [youtube] abc123: Video unavailable" → "Video unavailable"
        let message = line
            .replacingOccurrences(of: "ERROR: ", with: "")
            .replacingOccurrences(of: #"^\[[^\]]+\] [^:]+: "#, with: "", options: .regularExpression)
        let lower = message.lowercased()
        if lower.contains("logged-in") || lower.contains("login required") || lower.contains("log in to")
            || lower.contains("--cookies") {
            return String(localized: "This site needs you to be logged in, which Grab doesn’t support.")
        } else if lower.contains("drm protected") {
            return String(localized: "This video is DRM-protected and can’t be downloaded.")
        }
        return message
    }

    /// Whether an error message from yt-dlp means the connection failed, not the video.
    static func isNetworkError(_ message: String) -> Bool {
        let message = message.lowercased()
        if ["unavailable", "private", "drm", "logged in", "log in", "copyright", "removed"].contains(where: message.contains) {
            return false
        }
        return [
            "timed out", "timeout", "connection", "network is unreachable", "temporary failure in name resolution",
            "nodename nor servname", "getaddrinfo", "unable to download", "incompleteread", "remote end closed",
            "eof occurred", "ssl", "errno 50", "errno 51", "errno 54", "errno 60", "errno 61", "http error 5",
            "giving up after",
        ].contains(where: message.contains)
    }
}
