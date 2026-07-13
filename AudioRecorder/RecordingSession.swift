import Foundation
import Combine
import CoreAudio

/// Coordinates the system-audio and microphone recorders as a single recording
/// session. Each recorder writes to its own temporary `.caf` file; once
/// recording stops, the two files are mixed down into a single AAC file and
/// the temporaries are deleted.
@MainActor
final class RecordingSession: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published var availableMics: [MicDevice] = []
    @Published var selectedMicID: AudioObjectID?

    private let systemRecorder = SystemAudioRecorder()
    private let micRecorder = MicRecorder()
    private var timer: Timer?
    private var startedAt: Date?

    private var currentSystemCafURL: URL?
    private var currentMicCafURL: URL?
    private var currentOutputURL: URL?
    private var systemStartedAt: Date?
    private var micStartedAt: Date?

    init() {
        refreshMics()
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

        let sessionsDir = Self.sessionsDirectory()
        let baseName = RecordingFormat.sessionFolderName(for: Date())
        let systemURL = sessionsDir.appendingPathComponent("\(baseName) system.caf")
        let micURL = sessionsDir.appendingPathComponent("\(baseName) microphone.caf")
        let outputURL = sessionsDir.appendingPathComponent("\(baseName).m4a")

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
            self.currentOutputURL = outputURL
            self.systemStartedAt = systemStartedAt
            self.micStartedAt = micStartedAt
        } catch {
            errorMessage = error.localizedDescription
            systemRecorder.stop()
            micRecorder.stop()
            return
        }

        startedAt = Date()
        elapsedSeconds = 0
        isRecording = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        systemRecorder.stop()
        micRecorder.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        lastRecordingURL = nil

        guard let systemURL = currentSystemCafURL,
              let micURL = currentMicCafURL,
              let outputURL = currentOutputURL,
              let systemStartedAt,
              let micStartedAt else { return }

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
        }
    }

    private static func sessionsDirectory() -> URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("AudioRecorder Sessions", isDirectory: true)
    }
}
