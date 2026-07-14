# Rec+

A native macOS app that records **system audio and microphone at the same time**, then mixes them down into a single, clean recording.

No virtual audio devices, no BlackHole, no routing gymnastics — Rec+ taps the system output directly via Core Audio's process-tap API while normal playback keeps working untouched.

## Features

- **Simultaneous capture** — records the Mac's system output and your microphone in two independent streams, so a stall or dropout in one never corrupts the other.
- **Passive system tap** — listens to the default output device without rerouting it; whatever's playing keeps playing normally through the speakers.
- **Wall-clock aligned mixdown** — on stop, both streams are mixed into a single AAC (`.m4a`) file, aligned by their real start times (not by assuming a fixed gap) so system audio and voice stay in sync.
- **Simple, focused UI** — pick a microphone, hit record, watch the elapsed time, jump straight to the finished file in Finder.

## Requirements

- macOS 14.4+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

The Xcode project is generated from [`project.yml`](project.yml) — don't edit `AudioRecorder.xcodeproj` directly, it's regenerated and not meant to be hand-maintained.

```bash
xcodegen generate
open AudioRecorder.xcodeproj
```

Or build from the command line:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -destination 'platform=macOS' build
```

## Permissions

Rec+ is sandboxed and asks for exactly what it needs, no more:

| Entitlement | Why |
|---|---|
| Microphone | Record your voice alongside system audio |
| System audio capture | Tap the system's output device for recording |
| User-selected files (read/write) | Let you choose where recordings are saved |
| Music library (read/write) | Save recordings alongside your other audio |

macOS will prompt for microphone and system-audio-capture permission on first launch — both are required for a recording with both sources.

## How it works

1. **`MicRecorder`** and **`SystemAudioTap`** each record to their own temporary `.caf` file, started a fraction of a second apart to avoid a Core Audio aggregate-device race.
2. Once you stop, **`AudioMixer`** aligns the two files by wall-clock start time (whichever stream started later gets leading silence inserted) and sums them into a single 48kHz stereo buffer with headroom to avoid clipping.
3. The result is written out as AAC (`.m4a`); the temporary `.caf` files are deleted.

## Project layout

```
AudioRecorder/
├── AudioRecorderApp.swift    # App entry point
├── ContentView.swift         # Main window UI
├── RecordingSession.swift    # Coordinates start/stop across both recorders
├── SystemAudioTap.swift      # Core Audio process-tap for system output
├── MicRecorder.swift         # Microphone capture via AVAudioEngine
├── AudioMixer.swift          # Wall-clock aligned mixdown to AAC
├── CoreAudioSupport.swift    # Core Audio device helpers
└── Formatting.swift          # Time/filename formatting helpers
```

## Tests

```bash
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -destination 'platform=macOS' test
```
