import SwiftUI

@main
struct GrabApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate
    @State private var model = AppModel()

    private var manager: DownloadManager { model.manager }
    private var updater: Updater { model.updater }
    private var toolsUpdater: HelperToolsUpdater { model.toolsUpdater }

    var body: some Scene {
        Window("Grab", id: "main") {
            ContentView()
                .environment(manager)
                .environment(updater)
                .environment(toolsUpdater)
                .onAppear {
                    app.manager = manager
                    model.start()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 820, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                FileCommands(manager: manager)
            }
            DownloadCommands(manager: manager)
            CommandGroup(replacing: .help) {
                Link("Grab Help", destination: URL(string: "https://github.com/kcin1107/grab#readme")!)
            }
        }

        Settings {
            SettingsView()
                .environment(manager)
                .environment(updater)
                .environment(toolsUpdater)
        }
    }
}

/// File → Download Links from File…, Convert Files… and Download Link from Clipboard. The models
/// never open windows, so the main window is brought back here first.
private struct FileCommands: View {
    let manager: DownloadManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Download Links from File…") {
            openWindow(id: "main")
            manager.fileRequest = .linkFiles
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        Button("Convert Files…") {
            openWindow(id: "main")
            manager.fileRequest = .convertFiles
        }
        .keyboardShortcut("o")
        Divider()
        Button("Download Link from Clipboard") {
            let links = Links.extract(urls: MacPlatform.pasteboardURLs(), text: MacPlatform.pasteboardString())
            if links.isEmpty {
                MacPlatform.beep()
            } else {
                openWindow(id: "main")
                manager.add(links)
            }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
