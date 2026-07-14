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

    func testScanIgnoresStrayFilesAndBadNames() throws {
        _ = try writeM4A(named: "not-a-session-name")
        try "x".write(to: tempDir.appendingPathComponent("orphan.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: tempDir.appendingPathComponent("2026-07-13 10-00-00 system.caf"))

        XCTAssertTrue(RecordingStore.scan(directory: tempDir).isEmpty)
    }

    func testScanOfMissingDirectoryIsEmpty() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(RecordingStore.scan(directory: missing).isEmpty)
    }
}
