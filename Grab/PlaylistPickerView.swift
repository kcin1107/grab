import SwiftUI

/// Choose which videos of a playlist to download: one, several or all.
struct PlaylistPickerView: View {
    @Environment(DownloadManager.self) private var manager
    @Bindable var pick: PlaylistPick
    /// Rows highlighted in the table (for the Space key); what gets downloaded is `pick.selected`.
    @State private var highlighted: Set<PlaylistEntry.ID> = []

    /// An entry with its position in the playlist, for the "#" column.
    private struct Row: Identifiable {
        let number: Int
        let entry: PlaylistEntry
        var id: PlaylistEntry.ID { entry.id }
    }

    private var rows: [Row] {
        pick.entries.enumerated().map { Row(number: $0.offset + 1, entry: $0.element) }
    }

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
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.phase == .loading ? String(localized: "Reading playlist…") : pick.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if pick.phase == .ready {
                Toggle(isOn: Binding(get: { pick.allSelected },
                                     set: { $0 ? pick.selectAll() : pick.selectNone() })) {
                    Text("Select All")
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var summary: String {
        switch pick.phase {
        case .loading: return String(localized: "Looking up the videos in this link.")
        case .failed: return String(localized: "Couldn’t read this playlist.")
        case .ready:
            var parts = [String(localized: "\(pick.selected.count) of \(pick.entries.count) selected")]
            if let owner = pick.owner { parts.append(owner) }
            if pick.hiddenCount > 0 { parts.append(String(localized: "\(pick.hiddenCount) unavailable hidden")) }
            if !pick.downloaded.isEmpty { parts.append(String(localized: "\(pick.downloaded.count) already downloaded")) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        switch pick.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn’t Read Playlist", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
                .frame(maxHeight: .infinity)
        case .ready:
            table
        }
    }

    private var table: some View {
        Table(rows, selection: $highlighted) {
            TableColumn("") { row in
                Toggle(isOn: Binding(get: { pick.selected.contains(row.id) },
                                     set: { _ in pick.toggle(row.entry) })) {
                    Text(row.entry.title)
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            .width(24)
            TableColumn("#") { row in
                Text("\(row.number)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 28, ideal: 36, max: 48)
            TableColumn("Title") { row in
                HStack(spacing: 6) {
                    Text(row.entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pick.downloaded.contains(row.id) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                            .help("Already downloaded")
                            .accessibilityLabel("Downloaded")
                    }
                }
            }
            TableColumn(pick.entries.first?.spotify != nil ? "Artist" : "Uploader") { row in
                Text(row.entry.subtitle ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Duration") { row in
                Text(row.entry.duration.map(Format.duration) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 70, max: 90)
        }
        .onKeyPress(.space) {
            guard !highlighted.isEmpty else { return .ignored }
            // Checks them all, or unchecks them all when every highlighted row is already checked.
            if highlighted.isSubset(of: pick.selected) {
                pick.selected.subtract(highlighted)
            } else {
                pick.selected.formUnion(highlighted)
            }
            return .handled
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if pick.entries.first?.spotify != nil {
                // Spotify always downloads audio, in the audio format from Settings.
                Label("Saves as \(DownloadOptions.current.audioFormat.shortLabel)", systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Change the audio format in Settings → Format")
            } else {
                FormatMenu()
            }
            Spacer()
            Button("Cancel", role: .cancel) { manager.cancelPick(pick) }
                .keyboardShortcut(.cancelAction)
            Button(downloadTitle) { manager.confirm(pick) }
                .keyboardShortcut(.defaultAction)
                .disabled(pick.phase != .ready || pick.selected.isEmpty)
        }
    }

    private var downloadTitle: String {
        switch pick.selected.count {
        case 0: String(localized: "Download")
        case 1: String(localized: "Download 1 Item")
        case pick.entries.count where pick.entries.count > 1: String(localized: "Download All \(pick.entries.count)")
        default: String(localized: "Download \(pick.selected.count) Items")
        }
    }
}
