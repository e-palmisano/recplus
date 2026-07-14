# Recorder UI Restyle — Design

**Date:** 2026-07-14
**Scope:** `RecorderView` screen restyle + toolbar cleanup. No changes to audio capture, mixdown, or transcription pipelines.

## Problem

Two concrete UI complaints on the current macOS build:

1. **Start / Pause / Stop are not prominent.** They live as small items in the window toolbar (`ContentView.toolbar`). The Record button uses `.buttonStyle(.glassProminent)` but is still toolbar-sized; Pause only materializes there while recording.
2. **No real-time transcription visible.** `TranscriptPanel` is rendered conditionally — `if !session.transcriptLines.isEmpty || !session.pendingTranscriptText.isEmpty` (`RecorderView.swift:33`). The transcription engine mixes on a 1 s interval (`TranscriptionEngine.mixInterval = 1.0`) and `SpeechAnalyzer` adds latency on top, so for the first several seconds of a recording — and for the entire idle state — **no panel exists at all**. The user sees only the timer and reasonably concludes transcription is broken.

## Goals

- Controls always visible and prominent, in the content area (not chrome).
- Transcript area always present, with clear state feedback at every phase.
- Preserve every existing behavior: pause/resume, live levels, model download progress, error reporting, history sidebar, menu commands, keyboard shortcuts.

## Non-Goals

- No changes to `TranscriptionEngine`, `AudioMixer`, `MicRecorder`, `SystemAudioTap`, `RecordingSession` audio/pause logic.
- No new localization infrastructure (Italian placeholder copy is fine for now; reuse existing English if present).
- No redesign of `PlaybackView` or the sidebar.
- No persistence changes — transcript reset behavior on `start()` stays as-is.

## Design

### 1. Layout: floating bottom control cluster (chosen option C)

A glass control cluster anchored at the bottom-center of the recorder detail, floating above the content (not full-width, not docked to the window edge).

```
┌──────────────────────────────────────┐
│            00:00  (hero timer)        │
│                                      │
│   [ mic level  ▓▓▓▓░░░░░ ]           │
│   [ sys level  ▓▓░░░░░░░ ]           │
│                                      │
│   ┌──────────────────────────────┐   │
│   │  transcript / placeholder    │   │  ← always visible
│   │  …                           │   │
│   └──────────────────────────────┘   │
│                                      │
│       ╭───────────────────╮          │
│       │     ⏸      ●      │          │  ← floating glass cluster (2 buttons)
│       ╰───────────────────╯          │
```

Buttons, left → right: **Pause/Resume** (secondary) and **Record/Stop** (primary, red). The primary button toggles between Record (idle) and Stop (recording) — same semantics as today's toolbar button (`session.isRecording ? session.stop() : session.start()`).

**Disabled (dimmed at ~32% opacity) when not applicable:**
- Idle: Pause disabled, Record enabled (primary shows ●).
- Recording: primary flips to Stop (enabled, shows ⏹), Pause enabled.
- Paused: Pause flips to Resume (enabled), Stop enabled.

The cluster uses `GlassEffectContainer` + `.glassEffect(in: .rect(cornerRadius: 18))` consistent with the rest of the Liquid Glass UI. A drop shadow lifts it off the content.

### 2. Transcript area: always visible

`TranscriptPanel` rendering moves from conditional to unconditional. The panel shows different content based on derived state — **no new `@Published` properties required** on `RecordingSession`:

| State | Condition | Shown |
|---|---|---|
| Idle | `!isRecording && transcriptLines.isEmpty` | Placeholder: "Premi il tasto rosso per iniziare. La trascrizione apparirà qui in tempo reale." + dimmed record glyph. |
| Model downloading | `isRecording && isDownloadingModel` | Placeholder: "Scaricamento modello di trascrizione…" + the existing `ProgressView` value. |
| Listening (no text yet) | `isRecording && !isDownloadingModel && transcriptLines.isEmpty && pendingTranscriptText.isEmpty` | Placeholder: "In ascolto…" + subtle pulse. |
| Live | `!transcriptLines.isEmpty || !pendingTranscriptText.isEmpty` | Existing finalized lines + pending (italic) tail. Unchanged rendering. |
| Stopped with transcript | `!isRecording && !transcriptLines.isEmpty` | Final transcript persists (current behavior — cleared on next `start()`). |

`TranscriptPanel` gains an optional `placeholder: AnyView` parameter; when `lines.isEmpty && pendingText.isEmpty` it renders the placeholder in place of the scroll content. `RecorderView` derives the right placeholder from `RecordingSession` state (idle / downloading / listening) and passes it in — the panel itself stays state-agnostic. Autoscroll behavior only fires when lines exist; placeholder states do not scroll.

### 3. Toolbar cleanup

`ContentView.toolbar`:
- **Remove** the `Pause` toolbar item and the `Record/Stop` toolbar item (lines ~60–86). They are now redundant with the floating cluster.
- **Keep** the microphone `Picker` (disabled while recording, as today).
- **Keep** `ToolbarSpacer` placement of the picker.

Menu commands in `AudioRecorderApp.swift` (Start/Stop ⌘R, Pause/Resume ⌘P, Show in Finder ⇧⌘F) are **untouched** — they call into `RecordingSession` directly and continue to work; the floating cluster buttons bind to the same methods.

### 4. Level meters

Keep current behavior (rendered only while recording), but visually compact them to sit directly above the transcript panel inside the existing `GlassEffectContainer`. No logic change to `LevelMeterView`.

## Component Changes

| File | Change |
|---|---|
| `AudioRecorder/RecorderView.swift` | Restructure `body`: hero timer → meters → always-visible transcript panel → new floating `RecordControlCluster` overlay (`.overlay(alignment: .bottom)` or a `ZStack`). Replace conditional transcript `if` with always-rendered panel + placeholder. Wire model-download / error / "show in Finder" states as before. |
| `AudioRecorder/RecordControlCluster.swift` (new) | Small SwiftUI view: two buttons — Pause/Resume (secondary) + Record/Stop (primary, red, toggles). Binds to `RecordingSession` (`isRecording`, `isPaused`, `selectedMicID`) and calls `start()` / `stop()` / `togglePause()`. Disabled-state derivation lives here. |
| `AudioRecorder/TranscriptPanel.swift` | Add `placeholder: AnyView` parameter rendered when `lines.isEmpty && pendingText.isEmpty`. Copy button stays disabled when empty. Autoscroll guards unchanged. |
| `AudioRecorder/ContentView.swift` | Remove Pause + Record/Stop toolbar items; keep mic picker + `ToolbarSpacer`. |

`RecordingSession`, `TranscriptionEngine`, `AudioMixer`, recorders: **no changes**.

## Error / Edge-Case Handling

- **Transcription unavailable** (locale unsupported, permission denied, download failed): engine already catches and reports completion (`TranscriptionEngine.start` catch block). The transcript area stays in "In ascolto…" indefinitely in that case — acceptable; `errorMessage` renders as today. No new handling needed for this restyle.
- **No microphone selected** (`selectedMicID == nil`): `session.start()` sets `errorMessage` and returns. Record button remains enabled; the error surfaces in the existing error text area. Consider disabling Record when `selectedMicID == nil` — **decision: keep enabled** to preserve current "click → see the message" feedback rather than a dead button. Revisit if it feels wrong.
- **Empty transcript after stop**: panel shows the stopped-with-empty state ("Nessuna trascrizione" or the persisted lines). Falls out of the state table naturally.
- **Window resize**: floating cluster stays centered via `alignment: .bottom` constraint; transcript panel `minHeight`/`idealHeight` retained.

## Testing

This is a permanent UI change to a macOS SwiftUI app — verification is visual + behavioral, not unit tests.

- **Smoke test (primary gate):** `Scripts/ci.sh` must still print `CI OK` (existing unit tests for `AudioMixer`, `PauseClock`, `Formatting`, etc. must remain green — the restyle must not touch their dependencies).
- **Manual verification matrix** (run the app via `xcodegen generate && open AudioRecorder.xcodeproj`, ⌘R):
  1. Idle screen: cluster visible, Pause/Stop dimmed, Record enabled; transcript placeholder visible.
  2. Start: timer turns red, meters appear, cluster flips Record→Stop + Pause enabled, transcript moves to "In ascolto…" then live text.
  3. Pause/Resume: timer orange, meters zeroed, transcript freezes; resume restores.
  4. Stop: final transcript persists in panel; "Show Last Recording in Finder" appears.
  5. Toolbar: mic picker present and disables while recording; **no** Record/Pause buttons in toolbar.
  6. Keyboard: ⌘R and ⌘P still drive the same actions reflected in the cluster.
  7. Sidebar selection: PlaybackView unaffected.
- **Regression check:** confirm `TranscriptPanel` copy button still disabled when empty; autoscroll still pins to the pending tail.

No new unit tests are added — the change is pure view composition with no new logic worth pinning (disabled-state derivation is trivial and visible in the manual matrix). If during implementation a non-trivial helper emerges (e.g. a `controlState` enum), add a unit test for it.

## Risks

- **Floating cluster overlapping transcript at small window heights.** Mitigation: transcript `minHeight` already constrained; cluster is an overlay — if overlap appears at `minHeight: 400`, add bottom padding to the scroll content equal to cluster height. Confirm in the manual matrix at minimum window size.
- **Removing toolbar buttons may confuse users who relied on them.** Mitigation: menu commands + keyboard shortcuts remain; the cluster is strictly more prominent.

## Out of Scope (explicit)

- PlaybackView restyle.
- Sidebar / history redesign.
- Transcript search, edit, or export.
- Theming / accent color settings.
- Localization framework.
