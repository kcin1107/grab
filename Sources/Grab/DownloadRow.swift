import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openURL) private var openURL
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                details
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver reads title, format, uploader and status as one item.
            .accessibilityElement(children: .combine)

            actionButtons
        }
        .padding(.vertical, 4)
        .modifier(FileDrag(file: item.existingFile))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open") { open() }
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnail) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: item.conversion != nil ? "arrow.triangle.2.circlepath" : (item.options.isAudio ? "music.note" : "play.rectangle"))
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 80, height: 45)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let duration = displayedDuration {
                Text(Format.duration(duration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.7), in: .rect(cornerRadius: 3, style: .continuous))
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
    }

    /// The clip's own length for clips, otherwise the video's.
    private var displayedDuration: Double? {
        guard let clip = item.clip else { return item.duration }
        let end = min(clip.end ?? item.duration ?? .infinity, item.duration ?? .infinity)
        return end.isFinite ? max(end - clip.start, 0) : nil
    }

    private var details: some View {
        HStack(spacing: 6) {
            if let service = item.spotify?.service ?? MusicLinks.service(of: item.url) {
                Text(service.name)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    // Dark enough for the white text to stay readable.
                    .background(service == .spotify ? Color(red: 0.07, green: 0.5, blue: 0.22)
                                                    : Color(red: 0.78, green: 0.08, blue: 0.2), in: .capsule)
                    .help(service == .spotify ? String(localized: "Matched on YouTube Music and tagged with Spotify’s metadata")
                                              : String(localized: "Matched on YouTube Music and tagged with Apple Music’s metadata and cover"))
            }
            if let conversion = item.conversion {
                Label(conversion.label(options: item.options), systemImage: conversion.preset.symbol)
                    .labelStyle(.titleAndIcon)
                Text("·")
                Text(URL(fileURLWithPath: conversion.source).lastPathComponent)
            } else {
                Label(item.options.longLabel, systemImage: item.options.symbol)
                    .labelStyle(.titleAndIcon)
            }
            if let clip = item.clip {
                Text("·")
                Label(clip.displayLabel, systemImage: "scissors")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Clip \(clip.displayLabel)")
            }
            if let uploader = item.uploader, item.conversion == nil {
                Text("·")
                Text(uploader)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued where item.phase != nil:
            Label(item.phase ?? "", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)

        case .queued:
            Label("Waiting…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(item.phase ?? String(localized: "Fetching info…"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: item.progress)
                    .accessibilityLabel("Download progress")
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
                Text(downloadStats)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
                Text(item.phase ?? String(localized: "Finishing up…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .finished where item.fileMissing:
            Label("File moved or deleted", systemImage: "questionmark.folder")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .finished:
            HStack(spacing: 6) {
                Label {
                    Text(item.fileSize.map { String(localized: "Done · \(Format.bytes($0))") } ?? String(localized: "Done"))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.caption)
                if let count = item.chapterCount {
                    Label("\(count) chapters", systemImage: "list.number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Split into one file per chapter, in a folder")
                }
                if item.isLossless {
                    Text("Lossless")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(.secondary)
                        .help("The source was lossless and the file wasn’t converted to a lossy format")
                }
                if let source = item.sourceAudio {
                    // The quality that was actually downloaded, so a FLAC made from a 136 kbps
                    // stream doesn't pass for lossless.
                    Text("· \(source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Downloaded audio quality, before conversion")
                }
            }

        case .failed:
            Label {
                Text(item.errorMessage ?? String(localized: "Download failed"))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .font(.caption)
            .lineLimit(1)
            .help(item.errorMessage ?? "")

        case .paused:
            HStack(spacing: 8) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .accessibilityLabel("Download progress")
                    .frame(maxWidth: 160)
                Label(String(localized: "Paused · \(percent)"), systemImage: "pause.circle")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var percent: String {
        item.progress.formatted(.percent.precision(.fractionLength(0)))
    }

    private var downloadStats: String {
        var parts = [percent]
        if item.conversion != nil { parts.insert(String(localized: "Converting"), at: 0) }
        if let speed = item.speed { parts.append("\(Format.bytes(Int64(speed)))/s") }
        if let eta = item.eta, eta > 0 { parts.append(String(localized: "\(Format.duration(eta)) left")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .downloading where item.conversion != nil, .queued where item.conversion != nil:
                cancelButton
            case .downloading, .queued:
                symbolButton("pause.circle.fill", label: "Pause Download", help: "Pause") { manager.pause(item) }
                cancelButton
            case .paused:
                symbolButton("play.circle.fill", label: "Resume Download", help: "Resume") { manager.resume(item) }
                cancelButton
            case .starting, .processing:
                cancelButton
            case .finished where item.fileMissing:
                symbolButton("arrow.clockwise.circle.fill", label: "Download Again", help: "Download Again") { manager.retry(item) }
            case .finished:
                symbolButton("magnifyingglass.circle.fill", label: "Show in Finder", help: "Show in Finder") { reveal() }
            case .failed, .cancelled:
                symbolButton("arrow.clockwise.circle.fill", label: "Try Again", help: "Try Again") { manager.retry(item) }
            }
        }
    }

    private var cancelButton: some View {
        symbolButton("xmark.circle.fill", label: "Cancel Download", help: "Cancel") { manager.cancel(item) }
    }

    /// A borderless round symbol button, the way Safari's download list draws its actions.
    private func symbolButton(_ symbol: String, label: LocalizedStringKey, help: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).imageScale(.large)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(help)
    }

    private func open() {
        item.refreshFileStatus()
        guard let file = item.existingFile, DownloadManager.isInside(file, folder: item.folder) else { return }
        openURL(file)
    }

    private func reveal() {
        item.refreshFileStatus()
        guard let file = item.existingFile, DownloadManager.isInside(file, folder: item.folder) else { return }
        MacPlatform.reveal([file])
    }
}

/// Drags a finished download's file into Finder, Mail, an editor… Nothing to drag until it exists.
private struct FileDrag: ViewModifier {
    let file: URL?

    func body(content: Content) -> some View {
        if let file {
            content.draggable(file)
        } else {
            content
        }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
