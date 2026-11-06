# Audio Editor

A native macOS (Apple silicon) editor for spoken-word podcasts.

## What it does (v0.1)

- **Multitrack alignment.** Drag regions along and between tracks. Edges snap to other regions, markers and the playhead (hold ⌥ to turn snapping off). Arrow keys nudge the selected region by 10 ms, or 100 ms with ⇧. You can also type exact start, length and offset values in the inspector.
- **Fades.** Drag the round handles on a region's top corners, or type the values. Each track has its own volume and mute. Each region has its own gain and keeps any inner volume changes (ducking), shown as a yellow line.
- **MP3 export with podcast metadata.** ID3v2.3 tags carry title, subtitle, show, author, owner, episode number, year, genre, summary, copyright, feed link, email, keywords, the explicit flag, cover art and optional chapters from markers. Episode Info previews the cover art, which you can choose, replace, remove or drop in. The mix can be normalized to a loudness target such as -16 LUFS, with a peak limiter set to -2 dBFS, which leaves about -1 dBFS after MP3 encoding.
- **Opens Hindenburg sessions (`.nhsx`).** Tracks, regions, fades, gains, volume changes, markers and episode info carry over. Tracks that used Voice Profiler or Compressor get this app's Voice processing instead. Projects save as `.aeproj` JSON next to your audio, and edits never touch the audio files.

## Build

You need macOS 14 or later and Xcode 15+ (or the Command Line Tools).

```sh
swift test                 # engine tests
scripts/build-app.sh       # builds "build/Audio Editor.app"
open "build/Audio Editor.app"
```

## Layout

- `Sources/EditorCore`: the engine, with no UI. It covers the project model, `.nhsx` import, mixer, fades and gain envelopes, the EBU R128 loudness meter, the limiter, ID3 tags and MP3 export.
- `Sources/AudioEditor`: the macOS app (SwiftUI, an AppKit timeline, AVFoundation decoding and playback). Decoded audio is cached in `~/Library/Caches/AudioEditor`.
- `Sources/CLame`: an unmodified copy of libmp3lame 3.100 (LGPL, see `Sources/CLame/COPYING`).
