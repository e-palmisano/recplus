import XCTest
import AVFoundation
@testable import AudioRecorder

final class RecordingStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes a 1-second silent AAC file named like a real session recording.
    private func writeM4A(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        try file.write(from: buffer)
        return url
    }

    func testScanPairsTranscriptsAndSortsNewestFirst() throws {
        _ = try writeM4A(named: "2026-07-13 10-00-00")
        _ = try writeM4A(named: "2026-07-14 09-30-00")
        try "ciao".write(
            to: tempDir.appendingPathComponent("2026-07-14 09-30-00.txt"),
            atomically: true, encoding: .utf8)

        let recordings = RecordingStore.scan(directory: tempDir)

        XCTAssertEqual(recordings.count, 2)
        XCTAssertEqual(recordings[0].name, "2026-07-14 09-30-00", "newest first")
        XCTAssertNotNil(recordings[0].transcriptURL)
        XCTAssertNil(recordings[1].transcriptURL)
        XCTAssertEqual(recordings[0].duration, 1.0, accuracy: 0.1)
    }

    func testScanIgnoresNonM4aFiles() throws {
        _ = try writeM4A(named: "not-a-session-name")
        try "x".write(to: tempDir.appendingPathComponent("orphan.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: tempDir.appendingPathComponent("2026-07-13 10-00-00 system.caf"))

        let recordings = RecordingStore.scan(directory: tempDir)
        XCTAssertEqual(recordings.count, 1, "only the .m4a should be included")
        XCTAssertEqual(recordings[0].name, "not-a-session-name")
    }

    func testScanIncludesCustomNamedM4a() throws {
        _ = try writeM4A(named: "My Meeting")

        let recordings = RecordingStore.scan(directory: tempDir)
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].name, "My Meeting")
        XCTAssertEqual(recordings[0].date.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testScanOfMissingDirectoryIsEmpty() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(RecordingStore.scan(directory: missing).isEmpty)
    }

    func testRenameMovesAudioAndTranscriptPair() throws {
        let audioURL = try writeM4A(named: "Old Name")
        let transcriptURL = tempDir.appendingPathComponent("Old Name.txt")
        try "hello".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let store = RecordingStore(directory: tempDir)
        let recording = Recording(url: audioURL, date: Date(), duration: 1, transcriptURL: transcriptURL)

        try store.rename(recording, to: "New Name")

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("New Name.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("New Name.txt").path))
    }

    func testRenameWithoutTranscriptMovesOnlyAudio() throws {
        let audioURL = try writeM4A(named: "Old Name")
        let store = RecordingStore(directory: tempDir)
        let recording = Recording(url: audioURL, date: Date(), duration: 1, transcriptURL: nil)

        try store.rename(recording, to: "New Name")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("New Name.m4a").path))
    }

    func testRenameAppendsSuffixOnCollision() throws {
        _ = try writeM4A(named: "Target")
        let audioURL = try writeM4A(named: "Old Name")
        let store = RecordingStore(directory: tempDir)
        let recording = Recording(url: audioURL, date: Date(), duration: 1, transcriptURL: nil)

        try store.rename(recording, to: "Target")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Target 2.m4a").path))
    }

    func testRenameIsNoOpWhenNameUnchanged() throws {
        let audioURL = try writeM4A(named: "Same Name")
        let store = RecordingStore(directory: tempDir)
        let recording = Recording(url: audioURL, date: Date(), duration: 1, transcriptURL: nil)

        try store.rename(recording, to: "Same Name")

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRenameIsNoOpForBlankName() throws {
        let audioURL = try writeM4A(named: "Old Name")
        let store = RecordingStore(directory: tempDir)
        let recording = Recording(url: audioURL, date: Date(), duration: 1, transcriptURL: nil)

        try store.rename(recording, to: "   ")

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRenameRollsBackAudioMoveWhenTranscriptMoveFails() throws {
        let audioURL = try writeM4A(named: "Old Name")
        let oldTranscriptURL = tempDir.appendingPathComponent("Old Name.txt")
        try "hello".write(to: oldTranscriptURL, atomically: true, encoding: .utf8)
        // Pre-existing file at the destination transcript path blocks the second
        // move deterministically (uniqueBaseName only checks .m4a collisions, so
        // "New Name" is chosen with no suffix even though "New Name.txt" exists).
        try "blocker".write(
            to: tempDir.appendingPathComponent("New Name.txt"), atomically: true, encoding: .utf8)
        let store = RecordingStore(directory: tempDir)
        let recording = Recording(url: audioURL, date: Date(), duration: 1, transcriptURL: oldTranscriptURL)

        XCTAssertThrowsError(try store.rename(recording, to: "New Name"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "audio rolled back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldTranscriptURL.path), "old transcript untouched")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("New Name.m4a").path),
            "no orphaned renamed audio")
    }
}
