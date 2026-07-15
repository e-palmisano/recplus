import XCTest
@testable import AudioRecorder

final class RecordingNamingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingNamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSanitizeTrimsWhitespace() {
        XCTAssertEqual(RecordingNaming.sanitize("  Interview  "), "Interview")
    }

    func testSanitizeStripsSlashAndColon() {
        XCTAssertEqual(RecordingNaming.sanitize("Q1/Q2: Review"), "Q1-Q2- Review")
    }

    func testSanitizeOfWhitespaceOnlyIsEmpty() {
        XCTAssertEqual(RecordingNaming.sanitize("   "), "")
    }

    func testUniqueBaseNameWithNoCollisionReturnsPreferred() {
        XCTAssertEqual(RecordingNaming.uniqueBaseName(preferred: "Standup", in: tempDir), "Standup")
    }

    func testUniqueBaseNameAppendsSuffixOnCollision() throws {
        try Data().write(to: tempDir.appendingPathComponent("Standup.m4a"))
        XCTAssertEqual(RecordingNaming.uniqueBaseName(preferred: "Standup", in: tempDir), "Standup 2")
    }

    func testUniqueBaseNameSkipsMultipleCollisions() throws {
        try Data().write(to: tempDir.appendingPathComponent("Standup.m4a"))
        try Data().write(to: tempDir.appendingPathComponent("Standup 2.m4a"))
        XCTAssertEqual(RecordingNaming.uniqueBaseName(preferred: "Standup", in: tempDir), "Standup 3")
    }

    func testResolveFinalBaseNameUsesDesiredNameWhenPresent() {
        let result = RecordingNaming.resolveFinalBaseName(
            desiredName: "Weekly Sync", fallback: "2026-07-15 10-00-00", directory: tempDir)
        XCTAssertEqual(result, "Weekly Sync")
    }

    func testResolveFinalBaseNameFallsBackWhenDesiredNameIsNil() {
        let result = RecordingNaming.resolveFinalBaseName(
            desiredName: nil, fallback: "2026-07-15 10-00-00", directory: tempDir)
        XCTAssertEqual(result, "2026-07-15 10-00-00")
    }

    func testResolveFinalBaseNameFallsBackWhenDesiredNameIsBlank() {
        let result = RecordingNaming.resolveFinalBaseName(
            desiredName: "   ", fallback: "2026-07-15 10-00-00", directory: tempDir)
        XCTAssertEqual(result, "2026-07-15 10-00-00")
    }

    func testResolveFinalBaseNameAppendsSuffixOnCollision() throws {
        try Data().write(to: tempDir.appendingPathComponent("Weekly Sync.m4a"))
        let result = RecordingNaming.resolveFinalBaseName(
            desiredName: "Weekly Sync", fallback: "2026-07-15 10-00-00", directory: tempDir)
        XCTAssertEqual(result, "Weekly Sync 2")
    }
}
