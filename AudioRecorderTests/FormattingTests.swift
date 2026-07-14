import XCTest
@testable import AudioRecorder

final class FormattingTests: XCTestCase {
    func testElapsedTimeStringFormatsHoursMinutesSeconds() {
        XCTAssertEqual(RecordingFormat.elapsedTimeString(0), "00:00:00")
        XCTAssertEqual(RecordingFormat.elapsedTimeString(65), "00:01:05")
        XCTAssertEqual(RecordingFormat.elapsedTimeString(3725), "01:02:05")
    }

    func testSessionFolderNameIsSortableAndFilesystemSafe() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 13
        components.hour = 14
        components.minute = 5
        components.second = 9
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let name = RecordingFormat.sessionFolderName(for: date)

        XCTAssertEqual(name, "2026-07-13 14-05-09")
        XCTAssertFalse(name.contains(":"), "colons are invalid in macOS filenames")
    }

    func testTranscriptTimestampFormatsMinutesSeconds() {
        XCTAssertEqual(RecordingFormat.transcriptTimestamp(0), "00:00")
        XCTAssertEqual(RecordingFormat.transcriptTimestamp(65), "01:05")
        XCTAssertEqual(RecordingFormat.transcriptTimestamp(3725), "62:05")
    }

    func testSessionDateRoundTripsSessionFolderName() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 13
        components.hour = 14
        components.minute = 5
        components.second = 9
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let name = RecordingFormat.sessionFolderName(for: date)

        XCTAssertEqual(RecordingFormat.sessionDate(from: name), date)
    }

    func testSessionDateRejectsGarbage() {
        XCTAssertNil(RecordingFormat.sessionDate(from: "not a date"))
        XCTAssertNil(RecordingFormat.sessionDate(from: ""))
    }
}
