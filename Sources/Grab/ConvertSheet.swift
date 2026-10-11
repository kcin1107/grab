import SwiftUI

/// Shown when videos or songs from this Mac are dropped on the window (or chosen in File →
/// Convert Files…): pick what to turn them into, optionally for just part of the file.
struct ConvertSheet: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.audioFormat) private var audioFormat: AudioFormat = .m4a
    @AppStorage("compressPercent") private var percent = 50
    @AppStorage("gifWidth") private var gifWidth = 480
    @State private var preset: Conversion.Preset = .audio
    /// nil: Automatic, 0: Original, otherwise a height.
    @State private var resolution: Int?
    @State private var onlyPart = false
    @State private var partStart = ""
    @State private var partEnd = ""
    @State private var details: [URL: (size: Int64, info: Converting.MediaInfo?)] = [:]
    let files: [URL]

    private var hasVideo: Bool { files.contains(where: Converting.isVideo) }

    /// Trim always needs a part; the other options can optionally use one.
    private var usesPart: Bool { preset == .trim || onlyPart }

    /// The part to convert, or nil for the whole file.
    private var clip: ClipRange? { usesPart ? ClipRange.from(start: partStart, end: partEnd) : nil }
    private var canConvert: Bool {
        guard !usesPart || clip != nil else { return false }
        if preset.needsVideo && !hasVideo { return false }
        return preset != .compress || details.count == files.count
    }

    /// The options in the order they're offered. Ones that need video are left out for audio-only files.
    private var presets: [Conversion.Preset] {
        [Conversion.Preset.audio, .mp4, .trim, .gif, .compress].filter { hasVideo || !$0.needsVideo }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Form {
                Section {
                    Picker("Convert to", selection: $preset) {
                        ForEach(presets) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(preset.detail)
                }
                settings
                if preset != .trim {
                    Section {
                        Toggle("Only part of the file", isOn: $onlyPart)
                        if onlyPart { partFields }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 500)
        .task { await loadDetails() }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            FileIcon(path: files.first?.path ?? "", size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) Files"))
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if files.count > 1 {
                    Text(files.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let file = files.first, let detail = details[file] {
                    Text([detail.info?.duration.map(Format.duration), detail.size > 0 ? Format.bytes(detail.size) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Convert") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConvert)
        }
    }

    private func start() {
        manager.convert(files, preset: preset,
                        percent: preset == .compress ? percent : nil,
                        resolution: preset == .compress ? resolution : nil,
                        clip: clip,
                        gifWidth: preset == .gif ? gifWidth : nil)
        dismiss()
    }

    // MARK: - Settings of the chosen option

    @ViewBuilder
    private var settings: some View {
        switch preset {
        case .audio:
            Section {
                Picker("Audio format", selection: $audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
            }
        case .mp4:
            EmptyView()
        case .trim:
            Section { partFields }
        case .gif:
            gifSettings
        case .compress:
            compressSettings
        }
    }

    private var partFields: some View {
        ClipRangeFields(prefix: "From", start: $partStart, end: $partEnd, spacing: 8, fieldWidth: 70)
    }

    // MARK: - GIF

    /// The length of what becomes a GIF: the part, or the longest file.
    private var gifLength: Double? {
        let longest = files.compactMap { details[$0]?.info?.duration }.max()
        guard let clip else { return longest }
        let end = clip.end ?? longest
        return end.map { $0 - clip.start }
    }

    private var gifSettings: some View {
        Section {
            Picker("Size", selection: $gifWidth) {
                Text("Small (320 px)").tag(320)
                Text("Medium (480 px)").tag(480)
                Text("Large (720 px)").tag(720)
            }
            if let length = gifLength, length > 20 {
                Label("GIFs of \(Format.duration(length)) get very big. Pick a shorter part below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Compress

    private var compressSettings: some View {
        Section {
            LabeledContent("Target size") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(percent) }, set: { percent = Int($0) }), in: 10...90, step: 5)
                        .frame(width: 200)
                        .accessibilityValue("\(percent)%")
                    Text("\(percent)%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            if hasVideo {
                Picker("Resolution", selection: $resolution) {
                    Text("Automatic").tag(Int?.none)
                    Text(originalLabel).tag(Int?.some(0))
                    ForEach(Converting.resolutions(below: tallest), id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                }
                .help("Automatic keeps the resolution unless the file gets so small that a lower one looks sharper")
            }
            estimate
        }
    }

    private var tallest: Int { files.compactMap { details[$0]?.info?.height }.max() ?? 0 }

    private var originalLabel: String {
        tallest > 0 ? String(localized: "Original (\(tallest)p)") : String(localized: "Original")
    }

    /// What each file becomes at the chosen size: the same numbers the encoder will aim for.
    /// With a part chosen, the "original" is that part's share of the file.
    private var plans: [(original: Int64, result: Int64, compression: Converting.Compression?)] {
        files.compactMap { file in
            guard let detail = details[file] else { return nil }
            guard var info = detail.info, let full = info.duration, full > 0 else {
                return (detail.size, detail.size * Int64(percent) / 100, nil)
            }
            var size = detail.size
            if let clip {
                let length = max(min(clip.end ?? full, full) - clip.start, 0.1)
                size = Int64(Double(size) * length / full)
                info.duration = length
            }
            let c = Converting.compression(info: info, sourceSize: size, percent: percent, resolution: resolution)
            let kbps = Double((c.videoKbps ?? 0) + c.audioKbps)
            return (size, Int64(kbps * 1000 / 8 * (info.duration ?? full) * 1.03), c)
        }
    }

    @ViewBuilder
    private var estimate: some View {
        if details.count < files.count {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            let plans = plans
            let original = plans.reduce(0) { $0 + $1.original }
            let result = min(plans.reduce(0) { $0 + $1.result }, original)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.bytes(original)) → about \(Format.bytes(result))")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("Saves \(Format.bytes(original - result))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if resolution == nil, let lowered = plans.compactMap({ $0.compression?.height }).max() {
                    Label("Lowered to \(lowered)p to stay sharp", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if plans.contains(where: { $0.compression?.isRough == true }) {
                    Label("At this size the quality drops noticeably", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .animation(.snappy, value: percent)
        }
    }

    private func loadDetails() async {
        for file in files {
            let size = DownloadManager.size(of: file) ?? 0
            let info = await manager.mediaInfo(for: file)
            details[file] = (size, info)
        }
    }
}
