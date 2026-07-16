import Foundation
import AVFoundation
import Speech

enum TranscriptionSetupError: Error {
    case notAvailable
    case localeNotSupported
    case noAudioFormat
}

protocol TranscriptionModelClient: Sendable {
    func normalizedLocale(for preferredLocale: Locale) async -> Locale?
    func isInstalled(locale: Locale) async -> Bool
    func prepare(locale: Locale) async throws -> PreparedTranscriptionModel
    func install(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws
    func release(_ model: PreparedTranscriptionModel) async
    func recordPreloadRequested(locale: Locale) async
    func recordRecordingStart(locale: Locale, preparedIdentity: UUID?) async
}

final class PreparedTranscriptionModel: @unchecked Sendable {
    let locale: Locale
    let identity: UUID
    let transcriber: SpeechTranscriber?
    let analyzer: SpeechAnalyzer?
    let format: AVAudioFormat?
    let reservedLocale: Locale?

    init(
        locale: Locale,
        identity: UUID = UUID(),
        transcriber: SpeechTranscriber? = nil,
        analyzer: SpeechAnalyzer? = nil,
        format: AVAudioFormat? = nil,
        reservedLocale: Locale? = nil
    ) {
        self.locale = locale
        self.identity = identity
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        self.reservedLocale = reservedLocale
    }
}

struct NormalizedSelectionIdentity: Equatable, Sendable {
    let generation: Int
    let localeIdentifier: String
}

struct PreloadOperationMarker: Equatable, Sendable {
    let operationID: UUID
    let generation: Int
    let localeIdentifier: String
}

/// Coordinates live transcription: receives raw audio buffers from both
/// recorders as they arrive, resamples and mixes them, and streams the
/// result into Apple's on-device SpeechAnalyzer. Reports results via
/// callbacks rather than `@Published` properties so it can be a plain class
/// fed from background audio threads — `RecordingSession` (the `@MainActor`
/// `ObservableObject` the UI actually observes) owns the published state and
/// just forwards these callbacks into it.
// @unchecked Sendable: all mutable state below (not just the accumulators)
// is only ever touched while holding `bufferLock`, including the fields
// `stop()` mutates — `stop()` can run on the caller's thread concurrently
// with the feed task's `mixLoop()`, and without the lock that's an
// unsynchronized cross-thread mutation of `Array`/`String` storage, which is
// undefined behavior in Swift (can crash), not just a logic race.
final class TranscriptionEngine: @unchecked Sendable {
    private static let mixInterval: TimeInterval = 1.0

    private let onLineFinalized: (TranscriptLine) -> Void
    private let onPendingTextChanged: (String) -> Void
    private let onSetupFailed: (String) -> Void
    private let modelClient: any TranscriptionModelClient

    private let bufferLock = NSLock()
    private var systemAccumulator: [Float] = []
    private var micAccumulator: [Float] = []
    private var pendingText: String = ""

    // One resampler per source: each is only ever called from that source's
    // own serial audio callback, and caches its `AVAudioConverter` across
    // calls (see LiveResampler's doc comment) instead of rebuilding it per
    // buffer.
    private let micResampler = LiveResampler()
    private let systemResampler = LiveResampler()

    // Authoritative record of finalized lines, appended synchronously inside
    // `finalizeLine` on whatever thread calls it. `onLineFinalized` is a
    // fire-and-forget UI notification that hops to `@MainActor`
    // asynchronously — it must never be the source of truth read by `stop()`,
    // since a caller reading `RecordingSession.transcriptLines` immediately
    // after `stop()` returns could race ahead of that hop and miss the last
    // line. `finalizedLines` has no such race: it's set before
    // `finalizeLine` returns.
    private var finalizedLines: [TranscriptLine] = []

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var reservedLocale: Locale?
    private var startedAt: Date?
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    // Preload lifecycle state
    private var preparedModel: PreparedTranscriptionModel?
    private var preloadTask: Task<Void, Never>?
    private var selectionGeneration = 0
    private var activePreparedLocale: Locale?
    private var activeRecordingPreparedModel: PreparedTranscriptionModel?
    private var preloadMarker: PreloadOperationMarker?

    init(
        modelClient: any TranscriptionModelClient = SpeechTranscriptionModelClient(),
        onLineFinalized: @escaping (TranscriptLine) -> Void,
        onPendingTextChanged: @escaping (String) -> Void,
        onSetupFailed: @escaping (String) -> Void
    ) {
        self.modelClient = modelClient
        self.onLineFinalized = onLineFinalized
        self.onPendingTextChanged = onPendingTextChanged
        self.onSetupFailed = onSetupFailed
    }

    /// Starts the background transcription pipeline. Locale/asset resolution
    /// happens inside the task, so a slow or failing setup never blocks
    /// `start()`'s caller (`RecordingSession.start()`, which must return
    /// promptly). `onDownloadProgress` reports 0...1 only while a model asset
    /// is actually being installed — `AssetInventory.assetInstallationRequest`
    /// returns `nil` when the locale's asset is already installed, so the
    /// already-cached case reports completion immediately with no visible
    /// progress UI (unlike WhisperKit, which always did a network round-trip
    /// even for cached models).
    func start(preferredLocale: Locale, onDownloadProgress: @escaping @Sendable (Double) -> Void) {
        bufferLock.withLock {
            systemAccumulator = []
            micAccumulator = []
            pendingText = ""
            finalizedLines = []
        }
        startedAt = Date()

        feedTask = Task {
            do {
                guard SpeechTranscriber.isAvailable else { throw TranscriptionSetupError.notAvailable }
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
                    throw TranscriptionSetupError.localeNotSupported
                }
                try await AssetInventory.reserve(locale: locale)
                reservedLocale = locale

                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
                self.transcriber = transcriber

                // Asset install must come FIRST: `bestAvailableAudioFormat`
                // reads the model's sampling rates, so on a machine where the
                // locale's asset isn't installed yet it fails ("No GeneralASR
                // asset for language …") and setup dies before the download
                // was ever requested.
                let installed = await SpeechTranscriber.installedLocales.contains(locale)
                if !installed {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                            onDownloadProgress(progress.fractionCompleted)
                        }
                        try await request.downloadAndInstall()
                        observation.invalidate()
                    }
                }
                onDownloadProgress(1.0)

                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw TranscriptionSetupError.noAudioFormat
                }
                targetFormat = format

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                try await analyzer.prepareToAnalyze(in: format, withProgressReadyHandler: nil)

                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                inputContinuation = continuation
                resultsTask = Task { [weak self] in
                    guard let results = self?.transcriber?.results else { return }
                    do {
                        for try await result in results {
                            guard let self else { return }
                            let text = String(result.text.characters)
                            if result.isFinal {
                                self.finalizeLine(text: text)
                            } else {
                                self.bufferLock.withLock { self.pendingText = text }
                                self.onPendingTextChanged(text)
                            }
                        }
                    } catch {
                        // Results stream ended (or errored) — nothing further to consume.
                    }
                }

                try await analyzer.start(inputSequence: stream)
                await self.mixLoop()
            } catch {
                // Transcription unavailable (locale/permission/download failure) —
                // recording continues audio-only. Report completion so the UI
                // doesn't show a stuck progress bar, and surface the reason so
                // the failure isn't silent.
                onDownloadProgress(1.0)
                onSetupFailed(Self.setupFailureMessage(for: error))
            }
        }
    }

    /// Safe to call from any thread — this is invoked directly from the mic
    /// and system-tap audio callbacks, which run on non-main threads and (for
    /// the system tap) hand over buffers that are only valid synchronously.
    /// Resampling happens immediately, before this function returns; only the
    /// resulting plain `[Float]` is stored for the mix loop to pick up.
    func ingest(buffer: AVAudioPCMBuffer, format: AVAudioFormat, isSystem: Bool) {
        let resampler = isSystem ? systemResampler : micResampler
        guard let target = targetFormat,
              let samples = try? resampler.resampleToMono16k(buffer: buffer, from: format, targetFormat: target) else { return }

        bufferLock.withLock {
            if isSystem {
                systemAccumulator.append(contentsOf: samples)
            } else {
                micAccumulator.append(contentsOf: samples)
            }
        }
    }

    private func mixLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.mixInterval * 1_000_000_000))
            guard let format = targetFormat else { continue }

            let chunk = bufferLock.withLock { () -> [Float] in
                let chunk = LiveMixer.sum(systemAccumulator, micAccumulator)
                systemAccumulator = []
                micAccumulator = []
                return chunk
            }

            guard !chunk.isEmpty, let buffer = Self.makeBuffer(samples: chunk, format: format) else { continue }
            inputContinuation?.yield(AnalyzerInput(buffer: buffer))
        }
    }

    private static func setupFailureMessage(for error: Error) -> String {
        switch error {
        case TranscriptionSetupError.notAvailable:
            return "Live transcription is not available on this Mac. Recording continues audio-only."
        case TranscriptionSetupError.localeNotSupported:
            return "Live transcription does not support your system language. Recording continues audio-only."
        case TranscriptionSetupError.noAudioFormat:
            return "The transcription model could not be prepared. Recording continues audio-only."
        default:
            return "Live transcription unavailable: \(error.localizedDescription). Recording continues audio-only."
        }
    }

    private static func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                channelData[0].update(from: base, count: samples.count)
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            for index in samples.indices {
                let sample = max(-1, min(1, samples[index]))
                channelData[0][index] = Int16((sample * Float(Int16.max)).rounded())
            }
        default:
            return nil
        }

        return buffer
    }

    private func finalizeLine(text: String) {
        if !text.isEmpty {
            let offset = Date().timeIntervalSince(startedAt ?? Date())
            let line = TranscriptLine(offset: offset, text: text)
            bufferLock.withLock { finalizedLines.append(line) }
            onLineFinalized(line)
        }
        bufferLock.withLock { pendingText = "" }
        onPendingTextChanged("")
    }

    /// Cancels the mix loop, finalizes any still-pending (volatile) text
    /// synchronously — same simplification as before: the trailing fragment
    /// becomes the last line without awaiting one more analysis pass, so a
    /// recording stopped mid-sentence doesn't lose it but also doesn't block
    /// this synchronous call. Proper `SpeechAnalyzer` teardown (flushing
    /// through `finalize(through:)`, releasing the locale reservation) happens
    /// in a detached task afterward — safe because `start()` always builds a
    /// fresh `analyzer`/`transcriber` next time, so a slightly delayed
    /// cleanup can never observe or corrupt the next session's state.
    @discardableResult
    func stop() -> [TranscriptLine] {
        feedTask?.cancel()
        feedTask = nil
        inputContinuation?.finish()
        inputContinuation = nil

        let stillPending = bufferLock.withLock { pendingText }
        if !stillPending.isEmpty {
            finalizeLine(text: stillPending)
        }

        let capturedAnalyzer = analyzer
        let capturedResultsTask = resultsTask
        let capturedLocale = reservedLocale
        analyzer = nil
        transcriber = nil
        reservedLocale = nil
        resultsTask = nil

        Task.detached {
            if let capturedAnalyzer {
                try? await capturedAnalyzer.finalize(through: nil)
            }
            await capturedResultsTask?.value
            if let capturedLocale {
                await AssetInventory.release(reservedLocale: capturedLocale)
            }
        }

        return bufferLock.withLock { finalizedLines }
    }

    /// Records a preload request for the specified locale and sets up the cancellable
    /// seam for background preload coordination. Task 1 records the request and creates
    /// the infrastructure; actual installation check and model preparation happen in Task 2.
    /// Returns immediately; the seam setup happens asynchronously.
    func preload(preferredLocale: Locale) {
        preloadTask = Task {
            await _preload(preferredLocale: preferredLocale)
        }
    }

    private func _preload(preferredLocale: Locale) async {
        // Normalize the locale
        guard let normalized = await modelClient.normalizedLocale(for: preferredLocale) else {
            return
        }

        // Record that preload was requested
        await modelClient.recordPreloadRequested(locale: normalized)

        // Create a marker for this operation (stored for Task 2 deduplication)
        let marker = PreloadOperationMarker(
            operationID: UUID(),
            generation: selectionGeneration,
            localeIdentifier: normalized.identifier
        )
        preloadMarker = marker

        // Task 1 seam: stub implementation. Task 2 adds isInstalled check,
        // prepare call, and publication logic here.
    }

    /// Invalidates the previously selected locale, cancels any in-flight preload,
    /// releases the resident prepared resource, and advances the selection generation
    /// so any newly-arriving results are ignored.
    /// Does not start a new preload.
    func invalidateSelection(preferredLocale: Locale) {
        preloadTask?.cancel()
        preloadTask = nil
        selectionGeneration += 1

        if let model = preparedModel {
            preparedModel = nil
            activePreparedLocale = nil
            Task {
                await modelClient.release(model)
            }
        }

        preloadMarker = nil
    }

    /// Releases the resident prepared model without invalidating the selection.
    /// Used during app termination to clean up resources.
    func releasePreparedResources() {
        if let model = preparedModel {
            preparedModel = nil
            activePreparedLocale = nil
            Task {
                await modelClient.release(model)
            }
        }
    }

    #if DEBUG
    var preparedLocaleForTesting: Locale? { preparedModel?.locale }
    var activePreparedIdentityForTesting: UUID? { activeRecordingPreparedModel?.identity }
    var inFlightPreloadLocaleForTesting: String? { preloadMarker?.localeIdentifier }
    #endif
}

/// Production implementation of TranscriptionModelClient that wraps the
/// Speech framework APIs. This is a placeholder for now; the actual implementation
/// will be added in Task 3.
struct SpeechTranscriptionModelClient: TranscriptionModelClient {
    func normalizedLocale(for preferredLocale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale)
    }

    func isInstalled(locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains(locale)
    }

    func prepare(locale: Locale) async throws -> PreparedTranscriptionModel {
        fatalError("prepare not yet implemented in Task 3")
    }

    func install(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        fatalError("install not yet implemented in Task 3")
    }

    func release(_ model: PreparedTranscriptionModel) async {
        // Placeholder for release logic
    }

    func recordPreloadRequested(locale: Locale) async {
        // Production: no-op
    }

    func recordRecordingStart(locale: Locale, preparedIdentity: UUID?) async {
        // Production: no-op
    }
}
