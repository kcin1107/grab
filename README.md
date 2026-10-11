# Grab

A small Mac app for [yt-dlp](https://github.com/yt-dlp/yt-dlp). Paste a link or a search term, press Return, and the file lands in your Downloads folder (or wherever you choose in Settings).

Grab is a stripped-down personal build of [Pluck](https://github.com/Astrofrogger/pluck) by Astrofrogger. Pluck has no open-source licence, so Grab is for personal use only and isn't distributed.

## What it does

- Downloads from the 1,800+ sites yt-dlp supports, including playlists (pick which items you want)
- Video from 360p to 4K in MP4, MKV or WebM, with a preferred codec
- Audio only as M4A (AAC), MP3, Opus, FLAC or WAV, with a target bitrate
- Clips: download just a time range such as 0:05 to 1:30
- Embeds cover art, tags and subtitles
- Search YouTube and YouTube Music from the link field
- Spotify and Apple Music links, matched to the same song on YouTube Music
- Pause and resume, plus a history of the last 200 downloads
- Converts files already on your Mac: drop a video or song on the window (or use File → Convert Files…) to extract audio, convert to MP4, trim, make a GIF or shrink a video

Grab installs and updates its own copies of yt-dlp, ffmpeg and Deno in `~/Library/Application Support/Grab`, so nothing else needs installing. The app itself doesn't auto-update; rebuild it to get changes.

## Requirements

macOS 26 or later on Apple silicon. Grab works with public videos only: it never reads browser cookies, so anything that needs a login (members-only, age-restricted, private playlists) is out of reach.

## Building

```bash
zsh scripts/build-app.sh
```

That builds `build/Grab.app` with an ad-hoc signature. Add `--install` to copy it to `/Applications`.

For a quick debug build without the app bundle, run `swift build`.
