# Recorder UI Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Start/Pause/Stop prominent via a floating glass control cluster at the bottom of the recorder screen, and make the live transcript panel always visible with clear state placeholders.

**Architecture:** Extract the control-button state derivation into a pure, unit-tested `RecordControlState` value type. Add a `RecordControlCluster` SwiftUI view that consumes it and binds to `RecordingSession`. Add a `placeholder` parameter to `TranscriptPanel` so it renders meaningfully when empty. Restructure `RecorderView` to always show the panel and overlay the cluster. Strip the duplicate Record/Pause items from `ContentView`'s toolbar (mic picker + menu commands remain). No audio/transcription/mixer code changes.

**Tech Stack:** SwiftUI (macOS 26 / Liquid Glass), Swift 6.0 strict concurrency, XCTest, XcodeGen.

**Reference spec:** `docs/specs/2026-07-14-recorder-ui-restyle-design.md`

## Global Constraints

- **Platform:** macOS 26.0+; **Swift:** 6.0 strict concurrency. `RecordingSession` is `@MainActor` — new SwiftUI views that observe it are MainActor-isolated automatically.
- **Project:** XcodeGen. `project.yml` globs `AudioRecorder/` and `AudioRecorderTests/` (lines 10–11, 46–47) — new `.swift` files in those dirs are auto-included. **Never** hand-edit `AudioRecorder.xcodeproj`; rerun `xcodegen generate`.
- **Gate:** `Scripts/ci.sh` must print `CI OK`. It runs `xcodegen generate`, a Debug build (`CODE_SIGNING_ALLOWED=NO`), and the test suite.
- **Module:** `PRODUCT_MODULE_NAME` is `AudioRecorder`; tests use `@testable import AudioRecorder`.
- **Off-limits:** `RecordingSession`, `TranscriptionEngine`, `AudioMixer`, `MicRecorder`, `SystemAudioTap`, `LiveMixer`, `LiveResampler` — no edits.
- **Copy language:** English, to match existing UI strings. (Localization framework is out of scope per spec.)
- **Glass styling:** reuse `GlassEffectContainer` / `.glassEffect(in:)` / `.buttonStyle(.glassProminent)` already used elsewhere — do not invent new materials.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `AudioRecorder/RecordControlState.swift` | create | Pure `RecordControlState` value type + `derive(...)` factory. No SwiftUI imports. Unit-tested. |
| `AudioRecorder/RecordControlCluster.swift` | create | SwiftUI view: two buttons (Pause/Resume secondary, Record/Stop primary) inside a glass capsule. Consumes `RecordControlState`, binds to `RecordingSession`. |
| `AudioRecorder/TranscriptPanel.swift` | modify | Add `placeholder: AnyView` parameter; render it when transcript is empty. |
| `AudioRecorder/RecorderView.swift` | modify | Always-visible transcript panel (with state-derived placeholder); overlay `RecordControlCluster` at bottom; keep meters / model-download / error / Finder states. |
| `AudioRecorder/ContentView.swift` | modify | Remove Pause + Record/Stop toolbar items; keep mic `Picker` + `ToolbarSpacer`. |
| `AudioRecorderTests/RecordControlStateTests.swift` | create | Unit tests for the pure derivation. |

---

### Task 1: `RecordControlState` pure derivation + tests

**Files:**
- Create: `AudioRecorder/RecordControlState.swift`
- Create: `AudioRecorderTests/RecordControlStateTests.swift`

**Interfaces:**
- Produces: `RecordControlState` (struct, `Equatable`, `Sendable`) with:
  - `enum Primary: Equatable { case record, stop }` and `enum Secondary: Equatable { case pause, resume }`
  - stored: `primary: Primary`, `primaryEnabled: Bool`, `secondary: Secondary`, `secondaryEnabled: Bool`
  - `static func derive(isRecording: Bool, isPaused: Bool, hasMic: Bool) -> Self`

- [ ] **Step 1: Write the failing test**

`AudioRecorderTests/RecordControlStateTests.swift`:
```swift
import XCTest
@testable import AudioRecorder

final class RecordControlStateTests: XCTestCase {
    func testIdle_WithMic_RecordEnabled_PauseDisabled() {
        let s = RecordControlState.derive(isRecording: false, isPaused: false, hasMic: true)
        XCTAssertEqual(s.primary, .record)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertFalse(s.secondaryEnabled)
    }

    func testIdle_WithoutMic_RecordDisabled() {
        let s = RecordControlState.derive(isRecording: false, isPaused: false, hasMic: false)
        XCTAssertEqual(s.primary, .record)
        XCTAssertFalse(s.primaryEnabled)
    }

    func testRecording_NotPaused_StopEnabled_PauseEnabled() {
        let s = RecordControlState.derive(isRecording: true, isPaused: false, hasMic: true)
        XCTAssertEqual(s.primary, .stop)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertTrue(s.secondaryEnabled)
    }

    func testRecording_Paused_StopEnabled_ResumeEnabled() {
        let s = RecordControlState.derive(isRecording: true, isPaused: true, hasMic: true)
        XCTAssertEqual(s.primary, .stop)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .resume)
        XCTAssertTrue(s.secondaryEnabled)
    }

    func testIsPausedIgnoredWhenNotRecording() {
        // hasMic false here is irrelevant to secondary; ensures paused flag
        // doesn't leak into the idle state and flip secondary to .resume.
        let s = RecordControlState.derive(isRecording: false, isPaused: true, hasMic: true)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertFalse(s.secondaryEnabled)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (compile error — type absent)**

Run: `xcodegen generate && xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/RecordControlStateTests 2>&1 | tail -20`
Expected: FAIL / compile error — `RecordControlState` does not exist.

- [ ] **Step 3: Implement `RecordControlState`**

`AudioRecorder/RecordControlState.swift`:
```swift
import Foundation

/// Pure derivation of the floating control cluster's button states.
/// Kept free of SwiftUI concerns so it is unit-testable. The matching
/// `RecordControlCluster` view turns this value into buttons.
struct RecordControlState: Equatable, Sendable {
    enum Primary: Equatable, Sendable { case record, stop }
    enum Secondary: Equatable, Sendable { case pause, resume }

    let primary: Primary
    let primaryEnabled: Bool
    let secondary: Secondary
    let secondaryEnabled: Bool

    /// - Parameters:
    ///   - isRecording: whether a recording is currently active.
    ///   - isPaused: whether the active recording is paused. Ignored when
    ///     `isRecording` is false (prevents a stale paused flag from
    ///     flipping the idle secondary to `.resume`).
    ///   - hasMic: whether a microphone is selected — gates Record.
    static func derive(isRecording: Bool, isPaused: Bool, hasMic: Bool) -> Self {
        if isRecording {
            return .init(
                primary: .stop,
                primaryEnabled: true,
                secondary: isPaused ? .resume : .pause,
                secondaryEnabled: true
            )
        }
        return .init(
            primary: .record,
            primaryEnabled: hasMic,
            secondary: .pause,
            secondaryEnabled: false
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/RecordControlStateTests 2>&1 | tail -20`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AudioRecorder/RecordControlState.swift AudioRecorderTests/RecordControlStateTests.swift
git commit -m "feat: add RecordControlState pure derivation with tests"
```

---

### Task 2: `RecordControlCluster` SwiftUI view

**Files:**
- Create: `AudioRecorder/RecordControlCluster.swift`

**Interfaces:**
- Consumes: `RecordControlState.derive(...)` (Task 1); `RecordingSession` (`@ObservedObject`) — reads `isRecording`, `isPaused`, `selectedMicID`; calls `start()`, `stop()`, `togglePause()`.
- Produces: `RecordControlCluster` view used by `RecorderView` (Task 3).

- [ ] **Step 1: Implement the view**

`AudioRecorder/RecordControlCluster.swift`:
```swift
import SwiftUI

/// Floating glass control cluster: Pause/Resume (secondary) and
/// Record/Stop (primary, red). State is derived via `RecordControlState`
/// so the logic stays testable; this view only renders + binds actions.
struct RecordControlCluster: View {
    @ObservedObject var session: RecordingSession

    private var state: RecordControlState {
        .derive(
            isRecording: session.isRecording,
            isPaused: session.isPaused,
            hasMic: session.selectedMicID != nil
        )
    }

    var body: some View {
        HStack(spacing: 18) {
            secondaryButton
            primaryButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    private var primaryButton: some View {
        Button {
            session.isRecording ? session.stop() : session.start()
        } label: {
            Label(
                session.isRecording ? "Stop" : "Record",
                systemImage: session.isRecording ? "stop.fill" : "record.circle.fill"
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .disabled(!state.primaryEnabled)
        .help(session.isRecording ? "Stop recording" : "Start recording")
    }

    private var secondaryButton: some View {
        Button {
            session.togglePause()
        } label: {
            Label(
                state.secondary == .resume ? "Resume" : "Pause",
                systemImage: state.secondary == .resume ? "play.fill" : "pause.fill"
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 34, height: 34)
        }
        .disabled(!state.secondaryEnabled)
        .help(state.secondary == .resume ? "Resume recording" : "Pause recording")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `Scripts/ci.sh 2>&1 | tail -8`
Expected: ends with `CI OK` (the new view compiles and isn't wired in yet; all existing tests still pass).

- [ ] **Step 3: Commit**

```bash
git add AudioRecorder/RecordControlCluster.swift
git commit -m "feat: add RecordControlCluster glass view"
```

---

### Task 3: TranscriptPanel placeholder + RecorderView restructure

**Why one task:** `TranscriptPanel` gains a required `placeholder` parameter, which breaks its only call site (`RecorderView`). Editing both files in one task keeps every commit green — no red-build HEAD between commits.

**Files:**
- Modify: `AudioRecorder/TranscriptPanel.swift`
- Modify: `AudioRecorder/RecorderView.swift`

**Interfaces:**
- Produces: `TranscriptPanel(lines:pendingText:placeholder:)` — `placeholder: AnyView`, rendered when `lines.isEmpty && pendingText.isEmpty`. The only caller (`RecorderView`) is updated in this same task.
- Consumes: `RecordControlCluster(session:)` (Task 2); `RecordingSession` published state (`isRecording`, `isPaused`, `isDownloadingModel`, `modelDownloadProgress`, `transcriptLines`, `pendingTranscriptText`, `errorMessage`, `lastRecordingURL`).

- [ ] **Step 1: Add the placeholder parameter to TranscriptPanel**

In `AudioRecorder/TranscriptPanel.swift`, replace the whole file with:

```swift
import SwiftUI
import AppKit

/// Glass panel showing finalized transcript lines plus the pending (still
/// changing) tail, with autoscroll and a copy-to-clipboard button. When
/// there is no transcript text yet, `placeholder` is shown in place of the
/// scroll content so the panel is never an empty box.
struct TranscriptPanel: View {
    let lines: [TranscriptLine]
    let pendingText: String
    let placeholder: AnyView

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if lines.isEmpty && pendingText.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text("[\(RecordingFormat.transcriptTimestamp(line.offset))] \(line.text)")
                                    .font(.body)
                                    .id(index)
                            }
                            if !pendingText.isEmpty {
                                Text(pendingText)
                                    .font(.body.italic())
                                    .foregroundStyle(.secondary)
                                    .id("pending")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .onChange(of: lines.count) { _, newCount in
                        guard newCount > 0 else { return }
                        if pendingText.isEmpty {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        } else {
                            proxy.scrollTo("pending", anchor: .bottom)
                        }
                    }
                    .onChange(of: pendingText) { _, _ in
                        proxy.scrollTo("pending", anchor: .bottom)
                    }
                }
            }

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(TranscriptWriter.text(for: lines), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy transcript")
            .padding(8)
            .disabled(lines.isEmpty)
        }
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}
```

- [ ] **Step 2: Restructure RecorderView — always-visible panel + floating cluster overlay**

Overwrite the whole file `AudioRecorder/RecorderView.swift` with:

```swift
import SwiftUI
import AppKit

/// Live recording detail: hero timer, level meters, an always-visible
/// transcript panel (with state-aware placeholder), and a floating
/// glass control cluster. The transcript persists after stop and is
/// cleared on the next start.
struct RecorderView: View {
    @ObservedObject var session: RecordingSession

    private var timerColor: Color {
        guard session.isRecording else { return .secondary }
        return session.isPaused ? .orange : .red
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 20) {
                Text(RecordingFormat.elapsedTimeString(session.elapsedSeconds))
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .foregroundStyle(timerColor)
                    .contentTransition(.numericText())

                if session.isRecording {
                    VStack(spacing: 8) {
                        LevelMeterView(symbolName: "mic.fill", level: session.micLevel)
                        LevelMeterView(symbolName: "speaker.wave.2.fill", level: session.systemLevel)
                    }
                    .padding(14)
                    .frame(maxWidth: 340)
                    .glassEffect(in: .rect(cornerRadius: 12))
                }

                TranscriptPanel(
                    lines: session.transcriptLines,
                    pendingText: session.pendingTranscriptText,
                    placeholder: AnyView(transcriptPlaceholder)
                )
                .frame(minHeight: 200, idealHeight: 280)

                if session.isDownloadingModel {
                    ProgressView(value: session.modelDownloadProgress) {
                        Text("Downloading transcription model…")
                            .font(.caption)
                    }
                    .frame(maxWidth: 280)
                }

                if let errorMessage = session.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if let url = session.lastRecordingURL, !session.isRecording {
                    Button("Show Last Recording in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(24)
            .padding(.bottom, 72)   // clear the floating cluster
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: session.isRecording)
            .animation(.easeInOut(duration: 0.25), value: session.transcriptLines.isEmpty)

            RecordControlCluster(session: session)
                .padding(.bottom, 18)
        }
    }

    /// State-aware placeholder shown inside the always-visible transcript panel.
    @ViewBuilder private var transcriptPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: session.isRecording ? "waveform" : "record.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            if session.isDownloadingModel {
                Text("Downloading transcription model…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if session.isRecording {
                Text("Listening…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Press the red button to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Live transcription will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
```

- [ ] **Step 3: Build + test (full gate)**

Run: `Scripts/ci.sh 2>&1 | tail -8`
Expected: ends with `CI OK`. Both files compile together; existing tests pass; the panel + cluster are wired in.

- [ ] **Step 4: Commit (single green commit)**

```bash
git add AudioRecorder/TranscriptPanel.swift AudioRecorder/RecorderView.swift
git commit -m "feat: always-visible transcript + floating control cluster"
```

---

### Task 4: `ContentView` toolbar cleanup

**Files:**
- Modify: `AudioRecorder/ContentView.swift` (remove the Pause + Record/Stop `ToolbarItem`s, keep the mic `Picker` and `ToolbarSpacer`)

- [ ] **Step 1: Remove the duplicate toolbar items**

In `AudioRecorder/ContentView.swift`, replace the entire `.toolbar { … }` block (the one spanning the Pause item and the Record/Stop item) with the trimmed version that keeps only the microphone picker:

```swift
        .toolbar {
            ToolbarItem {
                Picker("Microphone", selection: $session.selectedMicID) {
                    ForEach(session.availableMics) { mic in
                        Text(mic.name).tag(Optional(mic.id))
                    }
                }
                .disabled(session.isRecording)
                .help("Input microphone")
            }

            ToolbarSpacer()
        }
```

- [ ] **Step 2: Build + test (full gate)**

Run: `Scripts/ci.sh 2>&1 | tail -8`
Expected: `CI OK`. No remaining references to the removed toolbar buttons.

- [ ] **Step 3: Commit**

```bash
git add AudioRecorder/ContentView.swift
git commit -m "refactor: drop duplicate Record/Pause toolbar items"
```

---

### Task 5: Integration verification (manual matrix)

**Files:** none modified — verification only.

- [ ] **Step 1: Regenerate, clean build, run the suite**

Run: `Scripts/ci.sh 2>&1 | tail -8`
Expected: `CI OK`.

- [ ] **Step 2: Launch the app for manual verification**

Run: `open AudioRecorder.xcodeproj`
In Xcode: ⌘R to run `Rec+`.

- [ ] **Step 3: Walk the manual matrix** (from spec §Testing). For each row, confirm the behavior; note any miss as a follow-up before declaring done.

1. **Idle** — cluster visible bottom-center; Pause dimmed; Record enabled (red, prominent); transcript panel visible with "Press the red button to start." placeholder.
2. **Start** (press Record) — timer turns red and advances; mic + system meters appear; cluster flips primary to Stop + enables Pause; transcript placeholder becomes "Listening…" then live text appears with a final line + italic pending tail.
3. **Pause / Resume** (press Pause) — timer orange; meters zeroed; transcript freezes. Press Resume (now `play.fill`) — timer red again, transcript resumes.
4. **Stop** (press Stop) — recording stops; final transcript persists in the panel; "Show Last Recording in Finder" link appears.
5. **Toolbar** — mic picker present, disabled while recording; **no** Record/Pause buttons in toolbar.
6. **Keyboard** — ⌘R starts/stops, ⌘P pauses/resumes; cluster reflects each change.
7. **Sidebar** — select a past recording → `PlaybackView` renders unchanged.
8. **Minimum window size** — drag window to minimum (640×400); confirm the floating cluster does not overlap the transcript text (bottom inset of 72 should clear it).
9. **No mic selected** — (temporarily) clear `selectedMicID`; Record is dimmed; pressing it is a no-op (no crash, no error toast — the dim communicates state).

- [ ] **Step 4: If all pass, final commit is already in place from Task 4**

No further commit. The implementation is complete.

---

## Self-Review

**Spec coverage:**
- §Design 1 (floating cluster, 2 buttons) → Tasks 1, 2, 3.
- §Design 2 (always-visible transcript + placeholder state table) → Task 3 (idle / downloading / listening / live / stopped states all handled: idle & stopped-empty via `transcriptPlaceholder`, downloading via `isDownloadingModel` branch, listening via `isRecording` branch, live via existing panel).
- §Design 3 (toolbar cleanup, keep picker + menu commands) → Task 4. Menu commands live in `AudioRecorderApp.swift` and are untouched (confirmed in Global Constraints).
- §Design 4 (meters, in-recording, compacted above transcript) → Task 3 keeps the existing meter block, now directly above the always-visible panel.
- §Testing (ci.sh + manual matrix) → Tasks 1–4 gate on ci.sh; Task 5 is the manual matrix.

**Placeholder scan:** no TBD/TODO/"handle edge cases" left; every code step contains the actual code.

**Type consistency:** `RecordControlState.derive(isRecording:isPaused:hasMic:)` signature identical in Task 1 (defined) and Task 2 (called). `TranscriptPanel(lines:pendingText:placeholder:)` is defined and called within Task 3. `RecordControlCluster(session:)` identical in Task 2 (defined) and Task 3 (used).

**Risks carried from spec:** floating-cluster overlap at min window size → checked in matrix row 8 (bottom inset 72; adjust if needed). Removing toolbar buttons → mitigated by menu + keyboard parity, checked in matrix rows 5–6.
