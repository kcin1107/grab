import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, format, downloads, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .format: String(localized: "Format")
        case .downloads: String(localized: "Downloads")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .format: "slider.horizontal.3"
        case .downloads: "arrow.down.circle"
        case .advanced: "terminal"
        }
    }
}

/// Settings lives in a regular window with the main window's unified toolbar (no title), so the
/// window buttons sit in the same place; the tabs (icon above, name below) are its centre item.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .format: FormatSettingsView()
            case .downloads: DownloadSettings()
            case .advanced: AdvancedSettings()
            }
        }
        // Wide enough for all four tabs in the toolbar (narrower windows push the last ones into an overflow menu).
        .frame(width: 600, height: 440)
        .scenePadding()
        .navigationTitle("Settings")
        .toolbar {
            // One toolbar item per tab, so each is its own control for VoiceOver.
            ToolbarItemGroup(placement: .principal) {
                ForEach(SettingsTab.allCases) { item in
                    SettingsTabButton(tab: item, selection: $tab)
                }
            }
        }
    }
}

/// Opens the Settings window and brings Grab forward.
struct OpenSettingsAction {
    let openWindow: OpenWindowAction

    func callAsFunction() {
        openWindow(id: "settings")
        NSApp.activate()
    }
}

extension EnvironmentValues {
    var openGrabSettings: OpenSettingsAction { OpenSettingsAction(openWindow: openWindow) }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    /// Read here rather than passed in as a Bool: toolbar items don't always redraw when the
    /// toolbar's own inputs change, which left the highlight stuck on an old tab.
    @Binding var selection: SettingsTab
    @State private var hovering = false

    private var isSelected: Bool { selection == tab }
    private func action() { selection = tab }

    var body: some View {
        Button(action: action) {
            // Kept compact so the glass capsule around the tabs has room to breathe
            // without making the toolbar taller (which would move the window buttons).
            VStack(spacing: 1) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(height: 16)
                Text(tab.title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(minWidth: 54)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(isSelected ? 0.10 : hovering ? 0.05 : 0))
            }
            .padding(.horizontal, 2)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @AppStorage(Prefs.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(Prefs.askLocation) private var askLocation = false

    var body: some View {
        Form {
            LabeledContent("Save to") {
                HStack {
                    Label {
                        Text((downloadPath as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: downloadPath))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .lineLimit(1)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Toggle("Always ask where to save", isOn: $askLocation)
            Picker("Simultaneous downloads", selection: $maxConcurrent) {
                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadPath)
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            downloadPath = url.path
        }
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
            .pickerStyle(.segmented)

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
                Text("Also used for Spotify links. Grab picks the best audio on offer and only converts when needed. FLAC and WAV can’t add quality the source doesn’t have; each download shows what it got.")
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
                Toggle("Title, artist & description", isOn: $embedMetadata)
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

    var body: some View {
        Form {
            Section {
                Toggle("Keep yt-dlp and ffmpeg up to date automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) {
                        updater.startAutomaticChecks()
                        toolsUpdater.startAutomaticChecks()
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
                        } else if !manager.ffmpegMissing {
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
                     ? "Grab keeps its own copies of the official yt-dlp release and a signed static ffmpeg build, plus the Deno runtime YouTube needs, checks for updates daily, and verifies every download against its published checksum."
                     : "Using the yt-dlp and ffmpeg installed on this Mac. Keep them current with “brew upgrade yt-dlp ffmpeg”.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Custom yt-dlp path", text: $ytdlpPath, prompt: Text("None"))
                    .onSubmit { manager.refreshVersion() }
            } footer: {
                Text("Overrides both of the above when set.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
