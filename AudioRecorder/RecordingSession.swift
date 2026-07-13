import Foundation
import Combine
import CoreAudio

/// Coordinates the system-audio and microphone recorders as a single recording
/// session, writing both to separate files in a timestamped session folder.
@MainActor
final class RecordingSession: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSessionFolder: URL?
    @Published var availableMics: [MicDevice] = []
    @Published var selectedMicID: AudioObjectID?

    private let systemRecorder = SystemAudioRecorder()
    private let micRecorder = MicRecorder()
    private var timer: Timer?
    private var startedAt: Date?

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

        let sessionFolder = Self.makeSessionFolder()
        do {
            try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
            try systemRecorder.start(to: sessionFolder.appendingPathComponent("system.caf"))
            // Creating the aggregate device above needs a run loop turn to settle in
            // CoreAudio's HAL before another engine can start, otherwise AVAudioEngine.start()
            // deadlocks on the HAL's internal device-list mutex.
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            try micRecorder.start(to: sessionFolder.appendingPathComponent("microphone.caf"), deviceID: micID)
        } catch {
            errorMessage = error.localizedDescription
            systemRecorder.stop()
            micRecorder.stop()
            return
        }

        lastSessionFolder = sessionFolder
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
    }

    private static func makeSessionFolder() -> URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("AudioRecorder Sessions", isDirectory: true)
            .appendingPathComponent(RecordingFormat.sessionFolderName(for: Date()), isDirectory: true)
    }
}
