import Foundation
import AVFoundation
import WhisperKit

/// Coordinates live transcription: receives raw audio buffers from both
/// recorders as they arrive, resamples and mixes them, and runs WhisperKit
/// on a rolling window with silence-based segment finalization. Reports
/// results via callbacks rather than `@Published` properties so it can be a
/// plain class fed from background audio threads — `RecordingSession` (the
/// `@MainActor` `ObservableObject` the UI actually observes) owns the
/// published state and just forwards these callbacks into it.
// @unchecked Sendable: all mutable state below (not just the accumulators)
// is only ever touched while holding `bufferLock`, including the fields
// `stop()` mutates — `stop()` can run on the caller's thread concurrently
// with the loop task's `tick()`, and without the lock that's an unsynchronized
// cross-thread mutation of `Array`/`String` storage, which is undefined
// behavior in Swift (can crash), not just a logic race.
final class TranscriptionEngine: @unchecked Sendable {
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private static let inferenceInterval: TimeInterval = 1.0
    private static let silenceThreshold: Float = 0.01
    private static let requiredSilenceDuration: TimeInterval = 0.6
    private static let modelVariant = "small"

    private let onLineFinalized: (TranscriptLine) -> Void
    private let onPendingTextChanged: (String) -> Void

    private let bufferLock = NSLock()
    private var systemAccumulator: [Float] = []
    private var micAccumulator: [Float] = []

    private var whisperKit: WhisperKit?
    private var rollingSamples: [Float] = []
    private var silentSeconds: TimeInterval = 0
    private var startedAt: Date?
    private var loopTask: Task<Void, Never>?
    private var pendingText: String = ""

    // Authoritative record of finalized lines, appended synchronously inside
    // `finalizeCurrentSegment` on whatever thread calls it. `onLineFinalized`
    // is a fire-and-forget UI notification that hops to `@MainActor`
    // asynchronously — it must never be the source of truth read by `stop()`,
    // since a caller reading `RecordingSession.transcriptLines` immediately
    // after `stop()` returns could race ahead of that hop and miss the last
    // line. `finalizedLines` has no such race: it's set before
    // `finalizeCurrentSegment` returns.
    private var finalizedLines: [TranscriptLine] = []

    init(onLineFinalized: @escaping (TranscriptLine) -> Void, onPendingTextChanged: @escaping (String) -> Void) {
        self.onLineFinalized = onLineFinalized
        self.onPendingTextChanged = onPendingTextChanged
    }

    /// Starts the background inference loop. Model download/load happens
    /// inside the loop's task, so a slow or failing load never blocks
    /// `start()`'s caller (`RecordingSession.start()`, which must return
    /// promptly). `onDownloadProgress` reports 0...1 while WhisperKit fetches
    /// the model — a cache hit (already downloaded) reports completion near-
    /// instantly since `WhisperKit.download` checks local files first.
    func start(onDownloadProgress: @escaping @Sendable (Double) -> Void) {
        bufferLock.withLock {
            rollingSamples = []
            systemAccumulator = []
            micAccumulator = []
            silentSeconds = 0
            pendingText = ""
            finalizedLines = []
        }
        startedAt = Date()

        loopTask = Task {
            do {
                let modelFolder = try await WhisperKit.download(variant: Self.modelVariant) { progress in
                    onDownloadProgress(progress.fractionCompleted)
                }
                let kit = try await WhisperKit(WhisperKitConfig(model: Self.modelVariant, modelFolder: modelFolder.path, download: false))
                bufferLock.withLock { self.whisperKit = kit }
                await self.runLoop()
            } catch {
                // Transcription unavailable (download/load failure) — recording continues
                // audio-only. Report completion so the UI doesn't show a stuck progress bar.
                onDownloadProgress(1.0)
            }
        }
    }

    /// Safe to call from any thread — this is invoked directly from the mic
    /// and system-tap audio callbacks, which run on non-main threads and (for
    /// the system tap) hand over buffers that are only valid synchronously.
    /// Resampling happens immediately, before this function returns; only the
    /// resulting plain `[Float]` is stored for the background loop to pick up.
    func ingest(buffer: AVAudioPCMBuffer, format: AVAudioFormat, isSystem: Bool) {
        guard let samples = try? LiveResampler.resampleToMono16k(buffer: buffer, from: format, targetFormat: Self.targetFormat) else { return }

        bufferLock.withLock {
            if isSystem {
                systemAccumulator.append(contentsOf: samples)
            } else {
                micAccumulator.append(contentsOf: samples)
            }
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.inferenceInterval * 1_000_000_000))
            await tick()
        }
    }

    private func tick() async {
        let chunk = bufferLock.withLock {
            let chunk = LiveMixer.sum(systemAccumulator, micAccumulator)
            systemAccumulator = []
            micAccumulator = []
            return chunk
        }

        guard !chunk.isEmpty else { return }

        // Snapshot everything `transcribe()` needs into locals before the
        // `await` below — the lock must not be held across a suspension
        // point (that would block `stop()`, possibly for the full duration
        // of an inference pass, freezing the UI it's called from).
        let (samplesToTranscribe, kit) = bufferLock.withLock { () -> ([Float], WhisperKit?) in
            rollingSamples.append(contentsOf: chunk)
            if SpeechSegmenter.isSilent(chunk, threshold: Self.silenceThreshold) {
                silentSeconds += Self.inferenceInterval
            } else {
                silentSeconds = 0
            }
            return (rollingSamples, whisperKit)
        }

        guard let kit else { return }
        let results = (try? await kit.transcribe(audioArray: samplesToTranscribe, decodeOptions: DecodingOptions(language: "it"))) ?? []
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let shouldFinalize = bufferLock.withLock {
            let silentChunkCount = Int(silentSeconds / Self.inferenceInterval)
            return SpeechSegmenter.shouldFinalizeSegment(silentChunkCount: silentChunkCount, chunkDuration: Self.inferenceInterval, requiredSilenceDuration: Self.requiredSilenceDuration)
        }

        if shouldFinalize {
            finalizeCurrentSegment(text: text)
        } else {
            bufferLock.withLock { pendingText = text }
            onPendingTextChanged(text)
        }
    }

    private func finalizeCurrentSegment(text: String) {
        if !text.isEmpty {
            let offset = Date().timeIntervalSince(startedAt ?? Date())
            let line = TranscriptLine(offset: offset, text: text)
            bufferLock.withLock { finalizedLines.append(line) }
            onLineFinalized(line)
        }
        bufferLock.withLock {
            pendingText = ""
            rollingSamples = []
            silentSeconds = 0
        }
        onPendingTextChanged("")
    }

    /// Cancels the inference loop, finalizes any still-pending text (rather
    /// than dropping it) so a recording stopped mid-sentence doesn't lose
    /// that last fragment, and returns the complete, authoritative list of
    /// finalized lines — callers that need the full transcript synchronously
    /// (writing the `.txt` file) must use this return value, not
    /// `RecordingSession.transcriptLines`, which can lag behind it (see
    /// `finalizedLines`'s doc comment above).
    @discardableResult
    func stop() -> [TranscriptLine] {
        loopTask?.cancel()
        loopTask = nil
        let stillPending = bufferLock.withLock { pendingText }
        if !stillPending.isEmpty {
            finalizeCurrentSegment(text: stillPending)
        }
        bufferLock.withLock { whisperKit = nil }
        return bufferLock.withLock { finalizedLines }
    }
}
