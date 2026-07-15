import Foundation
import AVFoundation
import Observation

/// Lists finished recordings in the sessions directory for the history sidebar.
@Observable
final class RecordingStore {
    let directory: URL
    private(set) var recordings: [Recording] = []

    init(directory: URL = RecordingStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("AudioRecorder Sessions", isDirectory: true)
    }

    func refresh() {
        recordings = Self.scan(directory: directory)
    }

    /// Renames `recording`'s `.m4a` (and its `.txt` transcript, if any) to
    /// `newName`. A blank name or a name equal to the current one is a no-op.
    /// Collisions get an automatic numeric suffix — never an overwrite, never
    /// a blocking error. If the transcript move fails after the audio move
    /// already succeeded, the audio move is rolled back so the pair never
    /// ends up split across two names.
    func rename(_ recording: Recording, to newName: String) throws {
        let sanitized = RecordingNaming.sanitize(newName)
        guard !sanitized.isEmpty, sanitized != recording.name else { return }

        let finalBaseName = RecordingNaming.uniqueBaseName(preferred: sanitized, in: directory)
        let newAudioURL = directory.appendingPathComponent("\(finalBaseName).m4a")
        try FileManager.default.moveItem(at: recording.url, to: newAudioURL)

        if let oldTranscriptURL = recording.transcriptURL {
            let newTranscriptURL = directory.appendingPathComponent("\(finalBaseName).txt")
            do {
                try FileManager.default.moveItem(at: oldTranscriptURL, to: newTranscriptURL)
            } catch {
                try? FileManager.default.moveItem(at: newAudioURL, to: recording.url)
                throw error
            }
        }
    }

    static func scan(directory: URL) -> [Recording] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url in
                let baseName = url.deletingPathExtension().lastPathComponent
                guard let date = RecordingFormat.sessionDate(from: baseName) else { return nil }

                let transcriptURL = url.deletingPathExtension().appendingPathExtension("txt")
                let hasTranscript = fm.fileExists(atPath: transcriptURL.path)

                let duration: TimeInterval
                if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
                    duration = Double(file.length) / file.processingFormat.sampleRate
                } else {
                    duration = 0
                }

                return Recording(
                    url: url,
                    date: date,
                    duration: duration,
                    transcriptURL: hasTranscript ? transcriptURL : nil
                )
            }
            .sorted { $0.date > $1.date }
    }
}
