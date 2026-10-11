import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openURL) private var openURL
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openSettings) private var openSettings
    @Environment(HelperToolsUpdater.self) private var toolsUpdater
    @Environment(Updater.self) private var updater
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @AppStorage(Prefs.autoUpdate) private var autoUpdate = true
    @State private var urlText = ""
    /// The selected row: where the arrow keys start from.
    @State private var selectedID: DownloadItem.ID?
    @State private var shownPickID: PlaylistPick.ID?
    @State private var clipping = false
    @State private var clipStart = ""
    @State private var clipEnd = ""
    @State private var previewURL: URL?
    @FocusState private var listFocused: Bool
    @State private var isTargeted = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Several links pasted at once (one per line, or separated by spaces) download together.
    private var fieldLinks: [String] { Links.extract(fromText: trimmed) }
    private var isMultiple: Bool { fieldLinks.count > 1 }
    private var isValid: Bool { isMultiple || Links.validated(trimmed) != nil }

    /// Words rather than a link: Return searches YouTube.
    private var isSearch: Bool { !trimmed.isEmpty && !isValid && !clipping }

    var body: some View {
        VStack(spacing: 0) {
            // First launch (or a tool gone): what's being set up, as it goes, or what went wrong.
            if !manager.ffmpegAvailable || !manager.ytdlpAvailable {
                if manager.toolsInstalling {
                    setupBanner
                } else {
                    toolsBanner
                }
            }
            inputBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, clipping ? 10 : 16)

            if clipping {
                clipBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if manager.items.isEmpty {
                emptyState
            } else {
                downloadList
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Grab")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .overlay { if isTargeted { dropHighlight } }
        .dropDestination(for: DroppedItem.self) { items, _ in handle(items) }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: isTargeted = true
            default: isTargeted = false
            }
        }
        // ⌘V with the list focused (the link field handles its own paste).
        .onPasteCommand(of: [.url, .plainText]) { _ in pasteFromClipboard() }
        .onAppear { fieldFocused = true }
        // Tools installed, or downloads moved or deleted, while Grab was in the background.
        .onChange(of: appearsActive) { if appearsActive { manager.refreshFromDisk() } }
        .alert(duplicateTitle, isPresented: Binding(
            get: { manager.picks.isEmpty && !manager.duplicates.isEmpty },
            set: { shown in if !shown, let prompt = manager.duplicates.first { manager.resolve(prompt, with: .cancel) } }
        ), presenting: manager.duplicates.first) { prompt in
            Button("Show in Finder") { manager.resolve(prompt, with: .showInFinder) }
            Button("Download Again") { manager.resolve(prompt, with: .downloadAgain) }
            Button("Cancel", role: .cancel) { manager.resolve(prompt, with: .cancel) }
        } message: { prompt in
            Text("It’s saved as “\(prompt.existing.existingFile?.lastPathComponent ?? prompt.existing.title)”.")
        }
        .sheet(item: Binding(get: { manager.picks.isEmpty ? manager.search : nil },
                             set: { if $0 == nil { manager.search = nil } })) { session in
            SearchResultsView(session: session)
                .environment(manager)
        }
        .sheet(isPresented: Binding(get: { !manager.filesToConvert.isEmpty && manager.picks.isEmpty },
                                    set: { if !$0 { manager.filesToConvert = [] } })) {
            ConvertSheet(files: manager.filesToConvert)
                .environment(manager)
        }
        .sheet(item: Binding(get: { manager.picks.first }, set: { newValue in
            // Closing the sheet cancels only the playlist that was on screen, never the next one.
            if newValue == nil, let shown = manager.picks.first(where: { $0.id == shownPickID }) {
                manager.cancelPick(shown)
            }
        })) { pick in
            PlaylistPickerView(pick: pick)
                .environment(manager)
                .onAppear { shownPickID = pick.id }
        }
    }

    private var subtitle: String {
        let active = manager.activeCount
        return active == 0 ? "" : String(localized: "\(active) downloading")
    }

    private var duplicateTitle: String {
        guard let prompt = manager.duplicates.first else { return "" }
        return String(localized: "“\(prompt.existing.title)” is already downloaded")
    }

    // MARK: - Banners

    /// What's downloading right now, e.g. "yt-dlp: 34% (12 of 37 MB)".
    private var setupProgress: String? {
        if let progress = updater.progress { return Updater.progressText("yt-dlp", done: progress.done, total: progress.total) }
        if let progress = toolsUpdater.progress { return Updater.progressText(progress.tool, done: progress.done, total: progress.total) }
        return nil
    }

    private var setupBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setting up yt-dlp and ffmpeg… Downloads will start as soon as they’re ready.")
                    .font(.callout)
                if let setupProgress {
                    Text(setupProgress).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: Design.Radius.card))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// A tool Grab needs is missing and setting it up failed (or automatic setup is off).
    private var toolsBanner: some View {
        let automatic = autoUpdate
        let ytdlpMissing = !manager.ytdlpAvailable
        let problem = [updater.failureMessage, toolsUpdater.failureMessage].compactMap { $0 }.first
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel("Warning")
            VStack(alignment: .leading, spacing: 2) {
                Text(ytdlpMissing
                     ? (automatic ? "Couldn’t download yt-dlp, so nothing can be downloaded yet." : "yt-dlp isn’t installed, so nothing can be downloaded.")
                     : (automatic ? "Couldn’t download ffmpeg, so merging video and converting audio will fail."
                                  : "ffmpeg isn’t installed, so merging video and converting audio will fail."))
                    .font(.callout)
                if automatic, let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if automatic {
                Button("Try Again") {
                    Task { await updater.check(force: ytdlpMissing) }
                    Task { await toolsUpdater.check(force: !manager.ffmpegAvailable) }
                }
                .buttonStyle(.glass)
            } else {
                Button("Copy Install Command") {
                    MacPlatform.copy(ytdlpMissing ? "brew install yt-dlp ffmpeg" : "brew install ffmpeg")
                }
                .buttonStyle(.glass)
                .help("Needs Homebrew from brew.sh")
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: Design.Radius.card))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Input

    private var inputBar: some View {
        GlassEffectContainer(spacing: Design.Spacing.controls) {
            HStack(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    Image(systemName: "link")
                        .font(.system(size: Design.Size.icon - 2, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Paste a link, or type to search YouTube", text: $urlText)
                        .textFieldStyle(.plain)
                        .font(Design.Typography.control)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                    if isMultiple {
                        Text("\(fieldLinks.count) links")
                            .font(Design.Typography.badge)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                            .transition(.opacity.combined(with: .scale))
                    }
                    if !urlText.isEmpty {
                        Button {
                            urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Clear Link")
                        .help("Clear")
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .barControl()

                FormatMenu(inBar: true)

                Button {
                    withAnimation(.snappy(duration: 0.25)) { clipping.toggle() }
                } label: {
                    Image(systemName: "scissors")
                        .foregroundStyle(clipping ? Color.accentColor : Color.primary)
                }
                .buttonStyle(BarButtonStyle())
                .disabled(isMultiple)
                .accessibilityLabel(clipping ? "Download Whole Video" : "Download a Clip")
                .help(clipping ? "Download the whole video" : "Download only part of the video")

                Button(action: submit) {
                    Image(systemName: isSearch ? "magnifyingglass" : "arrow.down")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(BarButtonStyle(prominent: true))
                .disabled(!(isValid || isSearch) || (clipping && clip == nil))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(isSearch ? String(localized: "Search") : String(localized: "Download"))
                .help(isSearch ? String(localized: "Search YouTube") : String(localized: "Download"))
            }
        }
        .animation(.snappy(duration: 0.2), value: urlText.isEmpty)
    }

    // MARK: - Clip

    /// The range typed in the clip row, or nil when it isn't valid (or not set).
    private var clip: ClipRange? { ClipRange.from(start: clipStart, end: clipEnd) }

    private var clipBar: some View {
        HStack(spacing: 0) {
            ClipRangeFields(prefix: "Clip from", start: $clipStart, end: $clipEnd)
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, Design.Spacing.inset)
        .frame(height: Design.Size.control)
        .glassEffect(in: .capsule)
        .onSubmit(submit)
    }

    private func submit() {
        if isSearch {
            manager.startSearch(trimmed)
            return
        }
        guard isValid else { return }
        if isMultiple {
            manager.add(fieldLinks)
        } else if clipping {
            guard let clip else { MacPlatform.beep(); return }
            manager.add(trimmed, clip: clip)
            withAnimation(.snappy(duration: 0.25)) { clipping = false }
            clipStart = ""
            clipEnd = ""
        } else {
            manager.add(trimmed)
        }
        withAnimation(.snappy) { urlText = "" }
    }

    /// ⌘V outside the link field: links on the clipboard start downloading.
    private func pasteFromClipboard() {
        guard !fieldFocused else { return }
        let links = Links.extract(urls: MacPlatform.pasteboardURLs(), text: MacPlatform.pasteboardString())
        if links.isEmpty { MacPlatform.beep() } else { manager.add(links) }
    }

    // MARK: - List

    private var downloadList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(manager.items) { item in
                    DownloadRow(item: item,
                                isSelected: selectedID == item.id,
                                onSelect: { select(item.id) },
                                onQuickLook: { quickLook(item) })
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .animation(.smooth, value: manager.items.map(\.id))
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Click a row to select it; Space opens Quick Look, ↑/↓ move the selection.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let item = selectedItem else { return .ignored }
            quickLook(item)
            return .handled
        }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .quickLookPreview($previewURL)
    }

    private var selectedItem: DownloadItem? {
        manager.items.first { $0.id == selectedID }
    }

    private func select(_ id: DownloadItem.ID) {
        selectedID = id
        fieldFocused = false
        listFocused = true
    }

    private func quickLook(_ item: DownloadItem) {
        select(item.id)
        item.refreshFileStatus()
        guard let file = item.existingFile else { MacPlatform.beep(); return }
        previewURL = previewURL == file ? nil : file
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let ids = manager.items.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = min(max(current + offset, 0), ids.count - 1)
        selectedID = ids[next]
        if previewURL != nil { previewURL = manager.items[next].existingFile }
        return .handled
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Downloading", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("Paste one or more links above, or drop links, a list of links, or a video or song to convert anywhere in this window.")
        } actions: {
            // Reading the clipboard is the user's own action, so there's no privacy prompt.
            PasteButton(payloadType: DroppedItem.self) { items in handle(items) }
        }
        .frame(maxHeight: .infinity)
    }

    /// Links (or text containing them) start downloading; text files are read for their links;
    /// videos and songs from this Mac open the convert sheet.
    private func handle(_ items: [DroppedItem]) {
        var links: [String] = []
        var media: [URL] = []
        for item in items {
            switch item {
            case .url(let url) where url.isFileURL:
                if Converting.isMedia(url) {
                    media.append(url)
                } else if Converting.isText(url) {
                    links += Links.extract(fromFile: url)
                }
            case .url(let url):
                if let link = Links.validated(url.absoluteString) { links.append(link) }
            case .text(let text):
                // Selected text from a browser or a note, with one or more links in it.
                links += Links.extract(fromText: text)
            }
        }
        if !links.isEmpty { manager.add(links) }
        if !media.isEmpty { manager.openConverter(for: media) }
        if links.isEmpty, media.isEmpty { MacPlatform.beep() }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: Design.Radius.panel, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openURL(URL(fileURLWithPath: downloadPath, isDirectory: true))
            } label: {
                Label("Show Downloads Folder", systemImage: "folder")
            }
            .help("Open \((downloadPath as NSString).abbreviatingWithTildeInPath)")

            Button {
                withAnimation { manager.clearFinished() }
            } label: {
                Label("Clear Finished", systemImage: "checklist.checked")
            }
            .disabled(!manager.hasFinished)
            .help("Clear finished downloads")

            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }
}

/// Something dropped on the window or pasted: a file or web address, or text that may hold links.
enum DroppedItem: Transferable {
    case url(URL)
    case text(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { DroppedItem.url($0) })
        ProxyRepresentation(importing: { DroppedItem.text($0) })
    }
}
