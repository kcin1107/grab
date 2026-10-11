import SwiftUI

enum SettingsTab: String {
    case general, format, downloads, advanced
}

/// The Settings scene: the system supplies the toolbar tabs, "Settings…" and ⌘, — each pane is a grouped form.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Format", systemImage: "slider.horizontal.3", value: SettingsTab.format) { FormatSettingsView() }
            Tab("Downloads", systemImage: "arrow.down.circle", value: SettingsTab.downloads) { DownloadSettings() }
            Tab("Advanced", systemImage: "terminal", value: SettingsTab.advanced) { AdvancedSettings() }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @AppStorage(Prefs.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(Prefs.askLocation) private var askLocation = false
    @State private var choosingFolder = false

    private enum Location: Hashable { case folder, ask, other }

    /// Derived from the two prefs, so cancelling "Other…" leaves the previous choice selected.
    private var location: Binding<Location> {
        Binding(
            get: { askLocation ? .ask : .folder },
            set: { choice in
                switch choice {
                case .folder: askLocation = false
                case .ask: askLocation = true
                case .other: choosingFolder = true
                }
            }
        )
    }

    var body: some View {
        Form {
            Picker("File download location", selection: location) {
                Label {
                    Text((downloadPath as NSString).abbreviatingWithTildeInPath)
                } icon: {
                    MacPlatform.icon(for: downloadPath)
                }
                .tag(Location.folder)
                Divider()
                Text("Ask for each download").tag(Location.ask)
                Divider()
                Text("Other…").tag(Location.other)
            }
            Picker("Simultaneous downloads", selection: $maxConcurrent) {
                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                downloadPath = url.path
                askLocation = false
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: downloadPath, isDirectory: true))
    }
}

private struct FormatSettingsView: View {
    private var format = FormatSettings()

    var body: some View {
        Form {
            Picker("Download", selection: format.$kind) {
                Text("Video").tag(MediaKind.video)
                Text("Audio only").tag(MediaKind.audio)
            }

            Section("Video") {
                Picker("Max resolution", selection: format.$resolution) {
                    ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Codec", selection: format.$codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                .disabled(format.container == .webm)
                Picker("Container", selection: format.$container) {
                    ForEach(VideoContainer.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Prefer 60 fps when available", isOn: format.$prefer60fps)
            }
            .disabled(format.kind != .video)

            Section {
                Picker(String(localized: "Format"), selection: format.$audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: format.$audioBitrate) {
                    ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!format.audioFormat.supportsBitrate)
            } header: {
                Text("Audio")
            } footer: {
                Text("Also used for Spotify links; Grab picks the best audio on offer and only converts when needed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @AppStorage(Prefs.embedMetadata) private var embedMetadata = true
    @AppStorage(Prefs.embedThumbnail) private var embedThumbnail = true
    @AppStorage(Prefs.embedSubtitles) private var embedSubtitles = false
    @AppStorage(Prefs.removeSponsors) private var removeSponsors = false
    @AppStorage(Prefs.fileNaming) private var fileNaming: FileNaming = .automatic
    @AppStorage(Prefs.customFileName) private var customFileName = "{artist} - {title}"
    @AppStorage(Prefs.playlistFolders) private var playlistFolders = true

    var body: some View {
        Form {
            Section {
                Toggle("Title, artist and description", isOn: $embedMetadata)
                Toggle("Thumbnail as cover art", isOn: $embedThumbnail)
                Toggle("Subtitles (video only)", isOn: $embedSubtitles)
            } header: {
                Text("Embed")
            }
            Section {
                Toggle("Remove sponsor segments (SponsorBlock)", isOn: $removeSponsors)
            }
            Section {
                Picker("File names", selection: $fileNaming) {
                    ForEach(FileNaming.allCases) { Text($0.label).tag($0) }
                }
                if fileNaming == .custom {
                    TextField("Custom name", text: $customFileName, prompt: Text(verbatim: "{artist} - {title}"))
                    LabeledContent("Preview") {
                        if let preview = FileNaming.preview(customFileName) {
                            Text(preview).foregroundStyle(.secondary)
                        } else {
                            Text("Use at least one placeholder").foregroundStyle(.red)
                        }
                    }
                }
                Toggle("Put albums and playlists in their own folder", isOn: $playlistFolders)
            } header: {
                Text("Files")
            } footer: {
                Group {
                    if fileNaming == .custom {
                        Text("Placeholders: \(FileNaming.tokens.map(\.token).joined(separator: " "))")
                    } else if fileNaming == .automatic {
                        Text("Music is named “Artist - Title” when the artist is known, everything else by its title.")
                    } else {
                        Text("Albums go into Artist/Album, playlists into a folder with their name, when you download two or more items.")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(Updater.self) private var updater
    @Environment(HelperToolsUpdater.self) private var toolsUpdater
    @AppStorage(Prefs.ytdlpPath) private var ytdlpPath = ""
    @AppStorage(Prefs.autoUpdate) private var autoUpdate = true
    @AppStorage(Prefs.nightly) private var nightly = false
    @State private var choosingYtdlp = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep yt-dlp and ffmpeg up to date automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) {
                        updater.startAutomaticChecks()
                        toolsUpdater.startAutomaticChecks()
                        manager.refreshTools()
                        manager.refreshVersion()
                    }
                Toggle("Use yt-dlp nightly builds", isOn: $nightly)
                    .disabled(!autoUpdate)
                    .onChange(of: nightly) { Task { await updater.check(force: true) } }
                LabeledContent("yt-dlp") {
                    HStack(spacing: 8) {
                        if let progress = updater.progress {
                            Text(Updater.progressText(String(localized: "Downloading"), done: progress.done, total: progress.total))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        statusIcon(updater.status)
                        if let version = manager.ytdlpVersion {
                            Text(version).monospacedDigit()
                        } else {
                            Text("Not found").foregroundStyle(.red)
                        }
                    }
                }
                LabeledContent("ffmpeg") {
                    HStack(spacing: 8) {
                        if let progress = toolsUpdater.progress {
                            Text(Updater.progressText(progress.tool, done: progress.done, total: progress.total))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        statusIcon(toolsUpdater.status)
                        if autoUpdate, HelperToolsUpdater.ffmpegInstalled, let version = toolsUpdater.ffmpegVersion {
                            Text(version).monospacedDigit()
                        } else if manager.ffmpegAvailable {
                            Text("Installed on this Mac").foregroundStyle(.secondary)
                        } else {
                            Text("Not found").foregroundStyle(.red)
                        }
                    }
                }
                if autoUpdate {
                    LabeledContent("Deno") {
                        if HelperToolsUpdater.isInstalled("deno"), let version = toolsUpdater.denoVersion {
                            Text(version).monospacedDigit()
                        } else {
                            Text("Not installed yet").foregroundStyle(.secondary)
                        }
                    }
                    .help("JavaScript runtime yt-dlp needs for YouTube")
                    LabeledContent("Last checked") {
                        HStack {
                            Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
                                .foregroundStyle(.secondary)
                            if updater.isBusy || toolsUpdater.isBusy {
                                // A slow or stuck download can always be stopped (and carries
                                // on where it stopped next time).
                                Button("Stop") {
                                    updater.stop()
                                    toolsUpdater.stop()
                                }
                            } else {
                                Button("Check Now") {
                                    Task { await updater.check() }
                                    Task { await toolsUpdater.check() }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text(autoUpdate
                     ? "Grab keeps its own verified copies of yt-dlp, ffmpeg and the Deno runtime YouTube needs, and checks for updates daily."
                     : "Using the yt-dlp and ffmpeg installed on this Mac. Keep them current with “brew upgrade yt-dlp ffmpeg”.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("yt-dlp") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Text(ytdlpPath.isEmpty ? String(localized: "Built-in (auto-updated)") : (ytdlpPath as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { choosingYtdlp = true }
                            if !ytdlpPath.isEmpty {
                                Button("Use Built-in") { ytdlpPath = "" }
                            }
                        }
                        if !ytdlpPath.isEmpty, !FileManager.default.isExecutableFile(atPath: ytdlpPath) {
                            Text("This file isn’t executable.").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .onChange(of: ytdlpPath) { manager.refreshTools() }
            } footer: {
                Text("Overrides the built-in yt-dlp when set.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingYtdlp, allowedContentTypes: [.unixExecutable, .item]) { result in
            if case .success(let url) = result { ytdlpPath = url.path }
        }
        .onAppear { manager.refreshVersion() }
    }

    @ViewBuilder
    private func statusIcon(_ status: Updater.Status) -> some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            }
        case .updated:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Just updated")
                .accessibilityLabel("Just updated")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                .accessibilityLabel("Update failed: \(message)")
        case .idle, .upToDate:
            EmptyView()
        }
    }
}
