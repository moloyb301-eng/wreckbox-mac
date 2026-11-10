# WreckBox for macOS

Native macOS app (Swift, SwiftUI) for the WreckBox DJ library: it analyses tracks, writes clean tags and keeps the library in step with a phone.

## Features
- **Playlist import:** Spotify, YouTube and YouTube Music playlists become one local library under `Music/DJ Library`.
- **Analysis:** BPM, musical key and energy, written into the files so Rekordbox and other DJ software read them.
- **Identify:** names unknown tracks from their audio (Chromaprint fingerprint → AcoustID → MusicBrainz, artwork from the Cover Art Archive), with every suggestion confirmed by the user.
- **Scan and import:** finds music elsewhere on the Mac and files selected folders into the library.
- **Phone sync:** sends the library to the WreckBox Android app over a direct Wi-Fi link.
- **Updates:** checks for new releases and installs them from inside the app.

## Layout
```
Sources/    Swift app (SwiftUI) and the library engine
analysis/   audio analysis helpers
scripts/    build, release and developer checks
```

## Install
Apple Silicon, macOS 13 or later. See [INSTALL.md](INSTALL.md), or get the latest build from [WreckBox releases](https://github.com/moloyb301-eng/wreckbox-releases).

## Related
- [wreckbox](https://github.com/moloyb301-eng/wreckbox): Rust engine and the Flutter app (Windows, macOS, Android)
