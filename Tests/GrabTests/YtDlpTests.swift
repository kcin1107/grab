import Foundation
import Testing
@testable import Grab

@MainActor
struct YtDlpTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GrabTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    private func makeItem(folder: String = "/tmp/grab-test") -> DownloadItem {
        DownloadItem(url: "https://example.com/video", options: DownloadOptions(), folder: folder)
    }

    // MARK: Arguments

    @Test func argumentsStartWithIsolationAndEndWithSeparatedURL() {
        let url = "https://example.com/watch?v=1"
        let args = DownloadManager.arguments(for: makeItem(), url: url)
        #expect(Array(args.prefix(2)) == ["--ignore-config", "--no-plugin-dirs"])
        #expect(args.suffix(2) == ["--", url])
        let separator = args.lastIndex(of: "--")
        #expect(separator == args.count - 2)
    }

    @Test func argumentsDownloadIntoItemFolder() {
        let args = DownloadManager.arguments(for: makeItem(folder: "/tmp/somewhere"), url: "https://example.com")
        let index = args.firstIndex(of: "-P")
        #expect(index != nil)
        if let index { #expect(args[index + 1] == "/tmp/somewhere") }
    }

    @Test func clipAddsSectionArgument() {
        let item = makeItem()
        item.clip = ClipRange(start: 5, end: 90)
        let args = DownloadManager.arguments(for: item, url: "https://example.com")
        let index = args.firstIndex(of: "--download-sections")
        #expect(index != nil)
        if let index { #expect(args[index + 1] == "*5-90") }
    }

    // MARK: Output lines

    @Test func progressLineUpdatesItem() {
        let item = makeItem()
        DownloadManager.handle("GRAB|downloading|50|100|NA|2048|10", for: item)
        #expect(item.state == .downloading)
        #expect(item.progress == 0.5)
        #expect(item.speed == 2048)
        #expect(item.eta == 10)
    }

    @Test func progressFallsBackToEstimateAndClamps() {
        let item = makeItem()
        DownloadManager.handle("GRAB|downloading|300|NA|200|NA|NA", for: item)
        #expect(item.progress == 1)
        #expect(item.speed == nil)
    }

    @Test func shortProgressLineIsIgnored() {
        let item = makeItem()
        DownloadManager.handle("GRAB|downloading|50", for: item)
        #expect(item.state == .queued)
        #expect(item.progress == 0)
    }

    @Test func cancelledItemIgnoresOutput() {
        let item = makeItem()
        item.state = .cancelled
        DownloadManager.handle("GRAB|downloading|50|100|NA|1|1", for: item)
        #expect(item.state == .cancelled)
    }

    @Test func fileLineInsideFolderIsAccepted() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = makeItem(folder: folder.path)
        let file = folder.appendingPathComponent("Song.mp4")
        DownloadManager.handle("GRABFILE \(file.path)", for: item)
        #expect(item.fileURL?.lastPathComponent == "Song.mp4")
    }

    @Test func fileLineOutsideFolderIsRejected() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = makeItem(folder: folder.path)
        DownloadManager.handle("GRABFILE /etc/hosts", for: item)
        DownloadManager.handle("GRABFILE \(folder.path)/../escape.mp4", for: item)
        #expect(item.fileURL == nil)
    }

    @Test func splitChaptersLineIsCollected() {
        let item = makeItem()
        DownloadManager.handle("[SplitChapters] Chapter 001; Destination: /tmp/grab-test/Album/01 - Intro.m4a", for: item)
        DownloadManager.handle("[SplitChapters] Chapter 002; Destination: /tmp/grab-test/Album/02 - Next.m4a", for: item)
        #expect(item.chapterFiles.map(\.lastPathComponent) == ["01 - Intro.m4a", "02 - Next.m4a"])
    }

    @Test func postprocessLineSetsProcessing() {
        let item = makeItem()
        DownloadManager.handle("GRABPP|ExtractAudio", for: item)
        #expect(item.state == .processing)
    }

    // MARK: Paths

    @Test func isInsideHandlesPrefixesAndDotDot() {
        let folder = "/tmp/grab-folder"
        #expect(DownloadManager.isInside(URL(fileURLWithPath: "/tmp/grab-folder/a.mp4"), folder: folder))
        #expect(DownloadManager.isInside(URL(fileURLWithPath: "/tmp/grab-folder/sub/a.mp4"), folder: folder))
        #expect(!DownloadManager.isInside(URL(fileURLWithPath: "/tmp/grab-folder"), folder: folder))
        #expect(!DownloadManager.isInside(URL(fileURLWithPath: "/tmp/grab-folder-other/a.mp4"), folder: folder))
        #expect(!DownloadManager.isInside(URL(fileURLWithPath: "/tmp/grab-folder/../a.mp4"), folder: folder))
        #expect(!DownloadManager.isInside(URL(fileURLWithPath: "/tmp/grab-folder/sub/../../a.mp4"), folder: folder))
    }

    @Test func isInsideResolvesSymlinks() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(!DownloadManager.isInside(link.appendingPathComponent("hosts"), folder: folder.path))
    }

    @Test func tidiedNameDropsTrailingDots() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let messy = folder.appendingPathComponent("Title..mp4")
        try Data().write(to: messy)
        let tidy = DownloadManager.tidiedName(messy)
        #expect(tidy.lastPathComponent == "Title.mp4")
        #expect(FileManager.default.fileExists(atPath: tidy.path))
    }

    @Test func tidiedNameLeavesCleanNamesAndTakenTargets() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clean = folder.appendingPathComponent("Title.mp4")
        #expect(DownloadManager.tidiedName(clean) == clean)
        let messy = folder.appendingPathComponent("Title..mp4")
        try Data().write(to: messy)
        try Data().write(to: clean)
        #expect(DownloadManager.tidiedName(messy) == messy)
    }
}
