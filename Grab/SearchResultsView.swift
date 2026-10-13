import SwiftUI

/// Results for words typed into the link field: download any of them with one click.
struct SearchResultsView: View {
    @Environment(DownloadManager.self) private var manager
    @Bindable var session: SearchSession
    @State private var selection: Set<SearchResult.ID> = []
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            content
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .presentationSizing(.fitted)
        .onChange(of: session.requestID, initial: true) {
            query = session.query
            selection = []
        }
        .onChange(of: query) { selection = [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search YouTube", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit(submitSearch)
                Button("Search", action: submitSearch)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Picker("Search in", selection: Binding(get: { session.kind },
                                                   set: { manager.startSearch(query, kind: $0) })) {
                ForEach(SearchSession.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Search Failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your internet connection and try again.")
            } actions: {
                Button("Retry") { manager.startSearch(session.query, kind: session.kind) }
            }
            .frame(maxHeight: .infinity)
        case .ready where session.results.isEmpty:
            ContentUnavailableView.search(text: session.query)
                .frame(maxHeight: .infinity)
        case .ready:
            List(session.results, selection: $selection) { result in
                SearchResultRow(result: result, isMusic: session.kind == .music,
                                isAdded: session.added.contains(result.id),
                                existing: manager.alreadyDownloaded(result.url, isAudio: isAudio)?.existingFile)
            }
            .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
                let pending = downloadable(ids)
                Button("Download") { download(pending) }
                    .disabled(pending.isEmpty)
            } primaryAction: { ids in
                download(downloadable(ids))
            }
        }
    }

    private func submitSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manager.startSearch(query, kind: session.kind)
    }

    private var isAudio: Bool { session.kind == .music || DownloadOptions.current.isAudio }

    /// The chosen results that haven't been added or downloaded already, in list order.
    private func downloadable(_ ids: Set<SearchResult.ID>) -> [SearchResult] {
        session.results.filter { result in
            ids.contains(result.id) && !session.added.contains(result.id)
                && manager.alreadyDownloaded(result.url, isAudio: isAudio)?.existingFile == nil
        }
    }

    private func download(_ results: [SearchResult]) {
        for result in results { manager.download(result, from: session) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.kind == .music {
                Label("Saves as \(DownloadOptions.current.audioFormat.shortLabel)", systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Change the audio format in Settings → Format")
            } else {
                FormatMenu()
            }
            Spacer()
            if !session.added.isEmpty {
                Text(session.added.count == 1 ? String(localized: "1 added")
                                              : String(localized: "\(session.added.count) added"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Done", role: .cancel) { manager.search = nil }
                .keyboardShortcut(.cancelAction)
            Button("Download") { download(downloadable(selection)) }
                .keyboardShortcut(queryFocused ? nil : .defaultAction)
                .disabled(downloadable(selection).isEmpty)
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let isMusic: Bool
    let isAdded: Bool
    let existing: URL?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnail) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: isMusic ? "music.note" : "play.rectangle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: isMusic ? 44 : 78, height: 44)
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let subtitle = result.subtitle { Text(subtitle) }
                    if let views = result.views {
                        Text("·")
                        Text(Searching.views(views))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            // Title, artist and views read as one item; the status stays its own control.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let duration = result.duration {
                Text(Format.duration(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if isAdded {
            Label("Added", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        } else if let existing {
            Button { MacPlatform.reveal([existing]) } label: {
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help("Already downloaded. Click to show it in Finder.")
        }
    }
}
