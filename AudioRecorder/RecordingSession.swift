import Foundation
import CoreAudio
import Observation
import Speech

/// Coordinates the system-audio and microphone recorders as a single recording
/// session. Each recorder writes to its own temporary `.caf` file; once
/// recording stops, the two files are mixed down into a single AAC file and
/// the temporaries are deleted.
///
/// `@Observable` (not `ObservableObject`) on purpose: invalidation is
/// per-property, so high-frequency updates (pending transcript text on every
/// volatile result, model-download progress) re-render only the views that
/// actually read them — with `@Published` every change re-rendered the whole
/// window (sidebar, toolbar, Liquid Glass layers), which lagged the UI
/// during recording.
@Observable
@MainActor
final class RecordingSession {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var lastRecordingURL: URL?
    var availableMics: [MicDevice] = []
    var selectedMicID: AudioObjectID?
    private(set) var availableTranscriptionLocales: [Locale] = []
    var selectedTranscriptionLocaleID: String {
        didSet {
            guard selectedTranscriptionLocaleID != oldValue else { return }
            UserDefaults.standard.set(selectedTranscriptionLocaleID, forKey: Self.transcriptionLocaleKey)
            promptModelDownloadIfNeeded()
        }
    }
    private(set) var transcriptLines: [TranscriptLine] = []
    private(set) var pendingTranscriptText: String = ""
    private(set) var isDownloadingModel = false
    private(set) var modelDownloadProgress: Double = 0
    /// Non-nil when the just-selected language needs its model downloaded —
    /// drives the confirmation alert in ContentView.
    var modelDownloadPromptLocale: Locale?

    let levels = AudioLevels()

    private let systemRecorder = SystemAudioRecorder()
    private let micRecorder = MicRecorder()
    private var timer: Timer?
    private var clock = PauseClock()

    private var currentSystemCafURL: URL?
    private var currentMicCafURL: URL?
    private var currentBaseName: String?
    /// Set by the UI right after recording starts (non-blocking naming
    /// prompt). Consumed once in `stop()`, then left for the next `start()`
    /// to clear.
    var desiredRecordingName: String?
    private var systemStartedAt: Date?
    private var micStartedAt: Date?

    // `lazy`: the closures below capture `self`, which isn't yet fully
    // initialized at the point a plain stored-property initializer would run.
    // Deferring construction to first access (inside `start()`, well after
    // `init()` returns) sidesteps that. `@ObservationIgnored` because the
    // @Observable macro can't rewrite a `lazy` stored property (and the
    // engine isn't UI state anyway). `TranscriptionEngine` is itself
    // `@unchecked Sendable` (see its doc comment), so no isolation escape
    // hatch is needed here.
    @ObservationIgnored
    private lazy var transcriptionEngine: TranscriptionEngine = TranscriptionEngine(
        onLineFinalized: { [weak self] line in
            Task { @MainActor in self?.transcriptLines.append(line) }
        },
        onPendingTextChanged: { [weak self] text in
            Task { @MainActor in self?.pendingTranscriptText = text }
        },
        onSetupFailed: { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
    )

    private static let transcriptionLocaleKey = "transcriptionLocaleIdentifier"

    init() {
        selectedTranscriptionLocaleID = UserDefaults.standard.string(forKey: Self.transcriptionLocaleKey)
            ?? Locale.current.identifier
        refreshMics()
        Task { [weak self] in
            let locales = await SpeechTranscriber.supportedLocales
                .sorted { Self.localeDisplayName($0) < Self.localeDisplayName($1) }
            self?.availableTranscriptionLocales = locales
            // The persisted/system identifier may not literally match the
            // supported list ("it_IT" vs BCP-47 "it-IT") — normalize via the
            // framework's own equivalence, then fall back to the first
            // supported locale so the picker never shows a dangling value.
            if let self, !locales.contains(where: { $0.identifier == self.selectedTranscriptionLocaleID }) {
                let equivalent = await SpeechTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: self.selectedTranscriptionLocaleID)
                )
                if let resolved = equivalent?.identifier ?? locales.first?.identifier {
                    self.selectedTranscriptionLocaleID = resolved
                }
            }
        }
    }

    static func localeDisplayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// If the selected language's model isn't installed yet, raise the
    /// confirmation prompt (ContentView presents it as an alert).
    func promptModelDownloadIfNeeded() {
        let locale = Locale(identifier: selectedTranscriptionLocaleID)
        Task { [weak self] in
            let installed = await SpeechTranscriber.installedLocales
                .contains { $0.identifier == locale.identifier }
            if !installed {
                self?.modelDownloadPromptLocale = locale
            }
        }
    }

    /// Downloads the transcription model for `locale`, driving
    /// `isDownloadingModel`/`modelDownloadProgress` (shown as a progress
    /// sheet). Errors land in `errorMessage`; `TranscriptionEngine.start`
    /// keeps its own install path as a fallback, so a failed or cancelled
    /// download here just means the download happens at record time instead.
    func downloadModel(for locale: Locale) {
        modelDownloadPromptLocale = nil
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        modelDownloadProgress = 0

        Task { [weak self] in
            do {
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            // KVO can fire very frequently; only publish
                            // visible increments to keep the UI quiet.
                            if fraction - self.modelDownloadProgress >= 0.01 || fraction >= 1.0 {
                                self.modelDownloadProgress = fraction
                            }
                        }
                    }
                    try await request.downloadAndInstall()
                    observation.invalidate()
                }
                self?.isDownloadingModel = false
                self?.modelDownloadProgress = 1.0
            } catch {
                self?.isDownloadingModel = false
                self?.errorMessage = "Model download failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshMics() {
        availableMics = MicDeviceList.available()
        if selectedMicID == nil || !availableMics.contains(where: { $0.id == selectedMicID }) {
            selectedMicID = MicDeviceList.systemDefault() ?? availableMics.first?.id
        }
    }

    func start() {
        guard !isRecording else { return }
        guard let micID = selectedMicID else {
            errorMessage = "No microphone selected."
            return
        }

        errorMessage = nil
        transcriptLines = []
        pendingTranscriptText = ""
        desiredRecordingName = nil

        let sessionsDir = Self.sessionsDirectory()
        let baseName = RecordingFormat.sessionFolderName(for: Date())
        let systemURL = sessionsDir.appendingPathComponent("\(baseName) system.caf")
        let micURL = sessionsDir.appendingPathComponent("\(baseName) microphone.caf")

        // Level publishing is time-gated: system-tap buffers can arrive at
        // 100+ Hz, and a MainActor hop per buffer is wasted work — the meter
        // only needs ~20 Hz.
        var lastMicLevelAt = Date.distantPast
        var lastSystemLevelAt = Date.distantPast

        micRecorder.onBuffer = { [weak self] buffer, format in
            self?.transcriptionEngine.ingest(buffer: buffer, format: format, isSystem: false)
            let now = Date()
            guard now.timeIntervalSince(lastMicLevelAt) >= 0.05 else { return }
            lastMicLevelAt = now
            let level = AudioLevelMeter.rmsLevel(of: buffer)
            Task { @MainActor in self?.levels.mic = level }
        }
        systemRecorder.onBuffer = { [weak self] buffer, format in
            self?.transcriptionEngine.ingest(buffer: buffer, format: format, isSystem: true)
            let now = Date()
            guard now.timeIntervalSince(lastSystemLevelAt) >= 0.05 else { return }
            lastSystemLevelAt = now
            let level = AudioLevelMeter.rmsLevel(of: buffer)
            Task { @MainActor in self?.levels.system = level }
        }

        do {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            // Mic starts first: it doesn't create a CoreAudio aggregate device, so it
            // can't race the system tap's aggregate-device background rebuild for the
            // HAL's internal device-list mutex. Starting the tap (which does create one)
            // second, after a run loop turn to let the mic's engine settle, avoids the
            // deadlock we hit when the order was reversed.
            try micRecorder.start(to: micURL, deviceID: micID)
            let micStartedAt = Date()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try systemRecorder.start(to: systemURL)
            let systemStartedAt = Date()

            self.currentSystemCafURL = systemURL
            self.currentMicCafURL = micURL
            self.currentBaseName = baseName
            self.systemStartedAt = systemStartedAt
            self.micStartedAt = micStartedAt
        } catch {
            errorMessage = error.localizedDescription
            systemRecorder.stop()
            micRecorder.stop()
            return
        }

        elapsedSeconds = 0
        isRecording = true
        isPaused = false
        clock = PauseClock()
        clock.start()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedSeconds = self.clock.elapsed()
            }
        }

        isDownloadingModel = false
        modelDownloadProgress = 0
        transcriptionEngine.start(
            preferredLocale: Locale(identifier: selectedTranscriptionLocaleID),
            onDownloadProgress: { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                // KVO fires frequently; only publish visible increments.
                if progress - self.modelDownloadProgress >= 0.01 || progress >= 1.0 {
                    self.modelDownloadProgress = progress
                }
                // @Observable notifies on every write, even of an equal
                // value — avoid re-setting the same Bool per KVO event.
                let downloading = progress < 1.0
                if self.isDownloadingModel != downloading {
                    self.isDownloadingModel = downloading
                }
            }
        })
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        micRecorder.isPaused = isPaused
        systemRecorder.isPaused = isPaused
        if isPaused {
            clock.pause()
            levels.reset()
        } else {
            clock.start()
        }
    }

    func stop() {
        guard isRecording else { return }
        systemRecorder.stop()
        micRecorder.stop()
        let finalLines = transcriptionEngine.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        levels.reset()
        lastRecordingURL = nil

        guard let systemURL = currentSystemCafURL,
              let micURL = currentMicCafURL,
              let baseName = currentBaseName,
              let systemStartedAt,
              let micStartedAt else { return }

        let sessionsDir = Self.sessionsDirectory()
        let finalBaseName = RecordingNaming.resolveFinalBaseName(
            desiredName: desiredRecordingName,
            fallback: baseName,
            directory: sessionsDir
        )
        let outputURL = sessionsDir.appendingPathComponent("\(finalBaseName).m4a")
        let transcriptURL = sessionsDir.appendingPathComponent("\(finalBaseName).txt")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try AudioMixer.mix(
                    systemURL: systemURL,
                    micURL: micURL,
                    systemStartedAt: systemStartedAt,
                    micStartedAt: micStartedAt,
                    outputURL: outputURL
                )
                try FileManager.default.removeItem(at: systemURL)
                try FileManager.default.removeItem(at: micURL)
                await MainActor.run { self?.lastRecordingURL = outputURL }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }

            if !finalLines.isEmpty {
                try? TranscriptWriter.text(for: finalLines).write(to: transcriptURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func sessionsDirectory() -> URL {
        RecordingStore.defaultDirectory
    }
}
