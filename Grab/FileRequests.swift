import SwiftUI
import UniformTypeIdentifiers

/// Downloads waiting for the user to choose a folder (when "Always ask where to save" is on).
struct PendingAdd: Identifiable {
    let id = UUID()
    let count: Int
    /// The Downloads setting, where the dialog opens.
    let startingFolder: String
    /// Adds the downloads once a folder is chosen.
    let start: @MainActor (String) -> Void
}

/// A file or folder dialog a model or menu command wants shown. Models never present UI themselves:
/// they publish this on `DownloadManager.fileRequest` and `FileRequestImporter` shows it.
enum FileRequest: Identifiable {
    case linkFiles
    case convertFiles
    case saveFolder(PendingAdd)

    var id: String {
        switch self {
        case .linkFiles: "linkFiles"
        case .convertFiles: "convertFiles"
        case .saveFolder(let pending): pending.id.uuidString
        }
    }
}

extension View {
    /// Shows the manager's `fileRequest` as a file dialog while `isActive`. A window can only show one
    /// dialog or sheet at a time, so the main window turns it on when no sheet is showing and the search
    /// sheet (which stays open while downloads are added) hosts its own.
    func fileRequestImporter(_ manager: DownloadManager, isActive: Bool = true) -> some View {
        modifier(FileRequestImporter(manager: manager, isActive: isActive))
    }
}

private struct FileRequestImporter: ViewModifier {
    let manager: DownloadManager
    let isActive: Bool
    /// The request being shown. Kept after SwiftUI closes the dialog so the completion can still read it.
    @State private var shown: FileRequest?

    func body(content: Content) -> some View {
        content
            .onChange(of: manager.fileRequest?.id) {
                if let request = manager.fileRequest { shown = request }
            }
            .fileImporter(isPresented: Binding(
                get: { isActive && manager.fileRequest != nil },
                set: { presented in
                    // Closed without a result handler running: drop the request instead of reopening it.
                    if !presented { Task { @MainActor in finish(shown) } }
                }
            ), allowedContentTypes: contentTypes, allowsMultipleSelection: allowsMultiple) { result in
                complete(result)
            } onCancellation: {
                finish(shown)
            }
            .fileDialogDefaultDirectory(defaultDirectory)
            .fileDialogConfirmationLabel(confirmationLabel)
            .fileDialogMessage(message)
    }

    private var contentTypes: [UTType] {
        switch shown {
        case .convertFiles: [.audiovisualContent]
        case .saveFolder: [.folder]
        default: [.text]
        }
    }

    private var allowsMultiple: Bool {
        if case .saveFolder = shown { false } else { true }
    }

    private var defaultDirectory: URL? {
        if case .saveFolder(let pending) = shown { URL(fileURLWithPath: pending.startingFolder, isDirectory: true) } else { nil }
    }

    private var confirmationLabel: String {
        if case .saveFolder = shown { String(localized: "Download Here") } else { String(localized: "Choose") }
    }

    private var message: String {
        switch shown {
        case .linkFiles: String(localized: "Choose a text file with links, one per line or mixed with other text.")
        case .convertFiles: String(localized: "Choose videos or songs to convert.")
        case .saveFolder(let pending):
            pending.count == 1 ? String(localized: "Choose where to save this download.")
                : String(localized: "Choose where to save these \(pending.count) downloads.")
        case nil: ""
        }
    }

    private func complete(_ result: Result<[URL], any Error>) {
        let request = shown
        finish(request)
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        switch request {
        case .linkFiles: manager.addLinks(fromFiles: urls)
        case .convertFiles: manager.openConverter(for: urls)
        case .saveFolder(let pending): pending.start(urls[0].path)
        case nil: break
        }
    }

    /// Clears the request, unless a newer one has already replaced it.
    private func finish(_ request: FileRequest?) {
        if manager.fileRequest?.id == request?.id { manager.fileRequest = nil }
    }
}
