import AppKit
import SwiftUI

/// The rows selected in the download list, and what can be done to them. Published with
/// `.focusedValue` so the Downloads menu acts on the same rows as the context menu.
@MainActor
struct DownloadSelection {
    let manager: DownloadManager
    let items: [DownloadItem]
    /// Opens or closes Quick Look for the selection.
    let toggleQuickLook: () -> Void

    /// The selected downloads' files that are still where Grab saved them.
    var files: [URL] {
        items.compactMap { item in
            item.refreshFileStatus()
            guard let file = item.existingFile, DownloadManager.isInside(file, folder: item.folder) else { return nil }
            return file
        }
    }
    var canOpen: Bool { items.contains { $0.existingFile != nil } }
    var canPause: Bool { items.contains { $0.conversion == nil && ($0.state == .downloading || $0.state == .queued) } }
    var canResume: Bool { items.contains { $0.state == .paused } }
    var canCancel: Bool { items.contains { $0.isActive || $0.state == .paused } }
    var canRetry: Bool { items.contains(where: Self.isRetryable) }
    var canCopyLink: Bool { items.contains { $0.conversion == nil } }
    var canRemove: Bool { !items.isEmpty }

    private static func isRetryable(_ item: DownloadItem) -> Bool {
        item.fileMissing || item.state == .failed || item.state == .cancelled
    }

    func open() { files.forEach { NSWorkspace.shared.open($0) } }
    func reveal() { MacPlatform.reveal(files) }
    func pause() { items.forEach { manager.pause($0) } }
    func resume() { items.forEach { manager.resume($0) } }
    func cancel() { items.forEach { manager.cancel($0) } }
    func retry() { items.filter(Self.isRetryable).forEach { manager.retry($0) } }
    func copyLinks() {
        MacPlatform.copy(items.filter { $0.conversion == nil }.map(\.url).joined(separator: "\n"))
    }
    func remove() { withAnimation { items.forEach { manager.remove($0) } } }
}

extension FocusedValues {
    @Entry var downloadSelection: DownloadSelection?
}

/// The context menu of the selected rows: only what applies to them.
struct DownloadContextMenu: View {
    let selection: DownloadSelection

    var body: some View {
        if !selection.items.isEmpty {
            if selection.canOpen {
                Button("Open", action: selection.open)
                Button("Quick Look", action: selection.toggleQuickLook)
                Button("Show in Finder", action: selection.reveal)
                Divider()
            }
            if selection.canPause { Button("Pause", action: selection.pause) }
            if selection.canResume { Button("Resume", action: selection.resume) }
            if selection.canCancel { Button("Cancel", action: selection.cancel) }
            if selection.canRetry { Button("Try Again", action: selection.retry) }
            if selection.canCopyLink { Button("Copy Link", action: selection.copyLinks) }
            Divider()
            Button("Remove from List", role: .destructive, action: selection.remove)
            Divider()
        }
        Button("Clear Finished") { withAnimation { selection.manager.clearFinished() } }
            .disabled(!selection.manager.hasFinished)
    }
}

/// The Downloads menu. Items are disabled while no download is selected in the window.
struct DownloadCommands: Commands {
    let manager: DownloadManager
    @FocusedValue(\.downloadSelection) private var selection

    var body: some Commands {
        CommandMenu("Downloads") {
            Button("Open") { selection?.open() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!(selection?.canOpen ?? false))
            Button("Show in Finder") { selection?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(selection?.canOpen ?? false))
            Button("Quick Look") { selection?.toggleQuickLook() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!(selection?.canOpen ?? false))
            Divider()
            if selection?.canPause == false, selection?.canResume == true {
                Button("Resume") { selection?.resume() }
            } else {
                Button("Pause") { selection?.pause() }
                    .disabled(!(selection?.canPause ?? false))
            }
            Button("Cancel") { selection?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(selection?.canCancel ?? false))
            Button("Try Again") { selection?.retry() }
                .disabled(!(selection?.canRetry ?? false))
            Divider()
            Button("Copy Link") { selection?.copyLinks() }
                .disabled(!(selection?.canCopyLink ?? false))
            Button("Remove from List") { selection?.remove() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(selection?.canRemove ?? false))
            Divider()
            Button("Clear Finished") { withAnimation { manager.clearFinished() } }
                .disabled(!manager.hasFinished)
        }
    }
}
