import Foundation

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
