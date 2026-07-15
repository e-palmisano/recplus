import XCTest
@testable import AudioRecorder

final class RecordControlStateTests: XCTestCase {
    func testIdle_RecordEnabled_PauseDisabled() {
        let s = RecordControlState.derive(isRecording: false, isPaused: false)
        XCTAssertEqual(s.primary, .record)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertFalse(s.secondaryEnabled)
    }

    func testRecording_NotPaused_StopEnabled_PauseEnabled() {
        let s = RecordControlState.derive(isRecording: true, isPaused: false)
        XCTAssertEqual(s.primary, .stop)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertTrue(s.secondaryEnabled)
    }

    func testRecording_Paused_StopEnabled_ResumeEnabled() {
        let s = RecordControlState.derive(isRecording: true, isPaused: true)
        XCTAssertEqual(s.primary, .stop)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .resume)
        XCTAssertTrue(s.secondaryEnabled)
    }

    func testIsPausedIgnoredWhenNotRecording() {
        let s = RecordControlState.derive(isRecording: false, isPaused: true)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertFalse(s.secondaryEnabled)
    }
}
