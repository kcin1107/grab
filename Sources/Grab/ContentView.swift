import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(HelperToolsUpdater.self) private var toolsUpdater
    @Environment(Updater.self) private var updater
    @AppStorage(Prefs.autoUpdate) private var autoUpdate = true
    @State private var urlText = ""
    @State private var selection: Set<DownloadItem.ID> = []
    @State private var shownPickID: PlaylistPick.ID?
    /// Narrow windows show the Download button as an icon, so the link field keeps its room.
    @State private var isNarrow = false
    @State private var previewURL: URL?
    @State private var isTargeted = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Several links pasted at once (one per line, or separated by spaces) download together.
    private var fieldLinks: [String] { Links.extract(fromText: trimmed) }
    private var isMultiple: Bool { fieldLinks.count > 1 }
    private var isValid: Bool { isMultiple || Links.validated(trimmed) != nil }

    /// Words rather than a link: Return searches YouTube.
    private var isSearch: Bool { !trimmed.isEmpty && !isValid }

    var body: some View {
        Group {
            if manager.items.isEmpty {
                emptyState
            } else {
                downloadList
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onGeometryChange(for: Bool.self) { $0.size.width < 720 } action: { isNarrow = $0 }
        // First launch (or a tool gone): what's being set up, as it goes, or what went wrong.
        .safeAreaInset(edge: .top, spacing: 0) {
            if !manager.ffmpegAvailable || !manager.ytdlpAvailable {
                if manager.toolsInstalling {
                    setupNotice
                } else {
                    toolsNotice
                }
            }
        }
        // The link field, format menu and Download in a bar under the toolbar: there the field
        // can fill the width, which toolbar items can't do in SwiftUI.
        .safeAreaBar(edge: .top) { inputBar }
        .navigationTitle("Grab")
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
        // Dialogs asked for by menu commands and models; with a sheet open, the dialog waits for it to close
        // (the search sheet hosts its own, above).
        .fileRequestImporter(manager, isActive: manager.picks.isEmpty && manager.search == nil && manager.filesToConvert.isEmpty)
        // Rows that were removed or cleared are no longer selected.
        .onChange(of: manager.items.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
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
                // The sheet stays open while results are added, so "Ask where to save" shows its dialog here.
                .fileRequestImporter(manager, isActive: manager.picks.isEmpty)
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

    private var duplicateTitle: String {
        guard let prompt = manager.duplicates.first else { return "" }
        return String(localized: "“\(prompt.existing.title)” is already downloaded")
    }

    // MARK: - Notices

    /// What's downloading right now, e.g. "yt-dlp: 34% (12 of 37 MB)".
    private var setupProgress: String? {
        if let progress = updater.progress { return Updater.progressText("yt-dlp", done: progress.done, total: progress.total) }
        if let progress = toolsUpdater.progress { return Updater.progressText(progress.tool, done: progress.done, total: progress.total) }
        return nil
    }

    private var setupNotice: some View {
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
        .padding(10)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
        .padding([.horizontal, .bottom], 10)
    }

    /// A tool Grab needs is missing and setting it up failed (or automatic setup is off).
    private var toolsNotice: some View {
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
            } else {
                Button("Copy Install Command") {
                    MacPlatform.copy(ytdlpMissing ? "brew install yt-dlp ffmpeg" : "brew install ffmpeg")
                }
                .help("Needs Homebrew from brew.sh")
            }
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 10, style: .continuous))
        .padding([.horizontal, .bottom], 10)
    }

    // MARK: - Input

    private var linkField: some View {
        TextField("Paste a link or search YouTube", text: $urlText)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("linkField")
            .focused($fieldFocused)
            .onSubmit(submit)
            .onExitCommand { urlText = "" }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            linkField
            FormatMenu()
            submitButton
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "Download", "Download 3" for several links, or "Search" for words rather than a link.
    private var submitTitle: String {
        if isSearch { return String(localized: "Search") }
        if isMultiple { return String(localized: "Download \(fieldLinks.count)") }
        return String(localized: "Download")
    }

    private func submit() {
        if isSearch {
            manager.startSearch(trimmed)
            return
        }
        guard isValid else { return }
        if isMultiple {
            manager.add(fieldLinks)
        } else {
            manager.add(trimmed)
        }
        withAnimation(reduceMotion ? nil : .snappy) { urlText = "" }
    }

    /// ⌘V outside the link field: links on the clipboard start downloading.
    private func pasteFromClipboard() {
        guard !fieldFocused else { return }
        let links = Links.extract(urls: MacPlatform.pasteboardURLs(), text: MacPlatform.pasteboardString())
        if links.isEmpty { MacPlatform.beep() } else { manager.add(links) }
    }

    // MARK: - List

    private var selectedItems: [DownloadItem] {
        manager.items.filter { selection.contains($0.id) }
    }

    private func downloadSelection(for ids: Set<DownloadItem.ID>) -> DownloadSelection {
        DownloadSelection(manager: manager,
                          items: manager.items.filter { ids.contains($0.id) },
                          toggleQuickLook: toggleQuickLook)
    }

    private var downloadList: some View {
        List(manager.items, selection: $selection) { item in
            DownloadRow(item: item)
        }
        .listStyle(.inset)
        .animation(reduceMotion ? nil : .smooth, value: manager.items.map(\.id))
        .contextMenu(forSelectionType: DownloadItem.ID.self) { ids in
            DownloadContextMenu(selection: downloadSelection(for: ids))
        } primaryAction: { ids in
            downloadSelection(for: ids).open()
        }
        .onDeleteCommand { downloadSelection(for: selection).remove() }
        .copyable(selectedItems.filter { $0.conversion == nil }.map(\.url))
        // Space toggles Quick Look for the selected files.
        .onKeyPress(.space) {
            guard !selection.isEmpty else { return .ignored }
            toggleQuickLook()
            return .handled
        }
        .quickLookPreview($previewURL, in: downloadSelection(for: selection).files)
        .focusedValue(\.downloadSelection, downloadSelection(for: selection))
    }

    private func toggleQuickLook() {
        if previewURL != nil {
            previewURL = nil
        } else if let file = downloadSelection(for: selection).files.first {
            previewURL = file
        } else {
            MacPlatform.beep()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Downloading", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("Paste a link above, or drop links or media files here.")
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
        ConcentricRectangle()
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: ConcentricRectangle())
            .padding(8)
            .allowsHitTesting(false)
    }

    private var submitButton: some View {
        Button(action: submit) {
            if isNarrow {
                Label(submitTitle, systemImage: isSearch ? "magnifyingglass" : "arrow.down")
                    .labelStyle(.iconOnly)
            } else {
                Text(submitTitle)
            }
        }
        .accessibilityIdentifier("submitButton")
        .buttonStyle(.borderedProminent)
        .disabled(!(isValid || isSearch))
        .help(isSearch ? String(localized: "Search YouTube") : String(localized: "Download"))
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
