import XCTest
@testable import AudioRecorder

final class TranscriptWriterTests: XCTestCase {
    func testTextJoinsLinesWithTimestamps() {
        let lines = [
            TranscriptLine(offset: 0, text: "Ciao a tutti"),
            TranscriptLine(offset: 65, text: "Iniziamo la riunione")
        ]

        let result = TranscriptWriter.text(for: lines)

        XCTAssertEqual(result, "[00:00] Ciao a tutti\n[01:05] Iniziamo la riunione")
    }

    func testTextIsEmptyStringForNoLines() {
        XCTAssertEqual(TranscriptWriter.text(for: []), "")
    }
}
