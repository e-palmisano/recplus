import XCTest
@testable import AudioRecorder

final class RecordControlStateTests: XCTestCase {
    func testIdle_WithMic_RecordEnabled_PauseDisabled() {
        let s = RecordControlState.derive(isRecording: false, isPaused: false, hasMic: true)
        XCTAssertEqual(s.primary, .record)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertFalse(s.secondaryEnabled)
    }

    func testIdle_WithoutMic_RecordDisabled() {
        let s = RecordControlState.derive(isRecording: false, isPaused: false, hasMic: false)
        XCTAssertEqual(s.primary, .record)
        XCTAssertFalse(s.primaryEnabled)
    }

    func testRecording_NotPaused_StopEnabled_PauseEnabled() {
        let s = RecordControlState.derive(isRecording: true, isPaused: false, hasMic: true)
        XCTAssertEqual(s.primary, .stop)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertTrue(s.secondaryEnabled)
    }

    func testRecording_Paused_StopEnabled_ResumeEnabled() {
        let s = RecordControlState.derive(isRecording: true, isPaused: true, hasMic: true)
        XCTAssertEqual(s.primary, .stop)
        XCTAssertTrue(s.primaryEnabled)
        XCTAssertEqual(s.secondary, .resume)
        XCTAssertTrue(s.secondaryEnabled)
    }

    func testIsPausedIgnoredWhenNotRecording() {
        // hasMic false here is irrelevant to secondary; ensures paused flag
        // doesn't leak into the idle state and flip secondary to .resume.
        let s = RecordControlState.derive(isRecording: false, isPaused: true, hasMic: true)
        XCTAssertEqual(s.secondary, .pause)
        XCTAssertFalse(s.secondaryEnabled)
    }
}
