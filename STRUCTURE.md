# Structure

Grab is a SwiftUI app for macOS 26 and later on Apple silicon. It runs yt-dlp, ffmpeg and Deno, which it downloads and updates itself into `~/Library/Application Support/Grab/bin`.

## Project

- `Grab.xcodeproj`: one app target `Grab` (bundle ID `com.nickringelmann.grab`), a unit test target `GrabTests` and a UI test target `GrabUITests`, all in the shared scheme `Grab`. Folders are synchronized groups, so new files are picked up without editing the project.
- Build settings: Swift 6 language mode, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `ARCHS = arm64`, hardened runtime, no app sandbox (Grab has to run yt-dlp and ffmpeg), team `56JJ9GRL32`. Xcode builds are signed ad hoc; releases are signed with Developer ID by `build-app.sh --sign`.
- Version: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the target's build settings; `Resources/Info.plist` reads them.
- No package dependencies.

## Folders

- `Sources/Grab`: the app.
- `Resources`: `Info.plist`, `AppIcon.icon` (Icon Composer, three glass layers) and `Localizable.xcstrings` (English plus de, es, fr, it, ja, ko, nl, pt-BR, zh-Hans).
- `Tests/GrabTests`: Swift Testing unit tests for links, yt-dlp arguments and output parsing, path containment and file naming.
- `Tests/GrabUITests`: XCUITest checks that the input bar fills the window at several widths.
- `scripts`: `build-app.sh` (Release build into `build/Grab.app`; `--sign "<identity>"` signs it with a Developer ID, `--install` copies it to `/Applications`), `notarize.sh` (notarizes and staples `build/Grab.app`, then zips it as `build/Grab.zip`) and `update-strings.sh` (syncs the string catalog with the code).
- `docs/icon.png`: the rendered icon for the README. After changing the icon, refresh it from a build: `sips -s format png -z 512 512 build/Grab.app/Contents/Resources/AppIcon.icns --out docs/icon.png`.

## Sources

- App and state: `GrabApp.swift` (scenes and menus), `AppDelegate.swift` (asks before quitting while downloads run), `AppModel.swift` (owns the queue and the updaters), `Prefs.swift` (settings keys).
- Main window: `ContentView.swift` (input bar under the toolbar, download list, drops and paste), `DownloadRow.swift`, `DownloadSelection.swift` (selection actions, Downloads menu, context menu), `FormatMenu.swift`, `Clip.swift` (time ranges).
- Sheets and Settings: `PlaylistPickerView.swift`, `SearchResultsView.swift`, `ConvertSheet.swift`, `SettingsView.swift`, `FileRequests.swift` (one SwiftUI file dialog driven by the model).
- Downloads: `DownloadManager.swift` (the queue), `YtDlp.swift` (arguments and output parsing), `PostProcessing.swift` (cover art, chapters), `Organizing.swift` (file and folder names), `History.swift`, `Models.swift`.
- Sources of links: `Links.swift`, `Search.swift` (YouTube and YouTube Music), `Playlist.swift`, `Spotify.swift`, `AppleMusic.swift`.
- Conversion: `Converting.swift` (local files through ffmpeg).
- Tools: `Tools.swift` (finding and running tools without blocking), `Updater.swift` (yt-dlp), `HelperToolsUpdater.swift` (ffmpeg, ffprobe, Deno), `CodeSignature.swift`.
- `MacPlatform.swift`: the only AppKit use besides the quit prompt (Show in Finder, Dock badge, pasteboard, beep, file icons, opening files).

## Security

Every yt-dlp run gets `--ignore-config --no-plugin-dirs`. Tool downloads are checked by SHA-256, and ffmpeg, ffprobe and Deno also by their Developer ID team. File operations only act on paths inside the download folder. Grab never reads browser cookies.

## CI

`.github/workflows/xcode-build-analyze.yml` builds and analyzes the `Grab` scheme (Debug, unsigned) on pushes and pull requests to `main`.

## Releases

Tags are `vX.Y.Z` on `main`. A release carries `Grab.zip`, signed and notarized:

1. `zsh scripts/build-app.sh --sign "Developer ID Application: Nick Ringelmann (56JJ9GRL32)"`
2. `zsh scripts/notarize.sh` (uses the keychain profile `grab-notary`, stored once with `xcrun notarytool store-credentials`)
3. Upload `build/Grab.zip` to the release.
