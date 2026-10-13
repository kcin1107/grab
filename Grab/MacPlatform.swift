import AppKit
import SwiftUI

/// The few things SwiftUI has no equivalent for (yet): Finder, the Dock, the pasteboard, system sounds
/// and file icons. Every other file talks to AppKit through here.
@MainActor
enum MacPlatform {
    /// Opens a file in its default app, or a web link in the browser. For code outside a view,
    /// where `openURL` from the environment isn't available.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Shows files in a Finder window, selected.
    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The text on the Dock icon, or nothing when nil.
    static func setDockBadge(_ text: String?) {
        NSApp?.dockTile.badgeLabel = text
    }

    /// URLs on the clipboard, such as a copied link or file.
    static func pasteboardURLs() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    }

    /// Text on the clipboard.
    static func pasteboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Replaces the clipboard with plain text.
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func beep() {
        NSSound.beep()
    }

    /// The Finder icon of a file or folder.
    static func icon(for path: String) -> Image {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
    }
}

/// A file's Finder icon, looked up once per path rather than on every redraw.
struct FileIcon: View {
    let path: String
    let size: CGFloat
    @State private var icon: Image?

    var body: some View {
        (icon ?? Image(systemName: "doc"))
            .resizable()
            .frame(width: size, height: size)
            .task(id: path) { icon = MacPlatform.icon(for: path) }
    }
}
