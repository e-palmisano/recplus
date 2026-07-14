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

    func testIdle_RecordAlwaysEnabled() {
        // Record stays enabled with no microphone: pressing it surfaces
        // RecordingSession's "No microphone selected." error, not a dead button.
        let s = RecordControlState.derive(isRecording: false, isPaused: false)
        XCTAssertEqual(s.primary, .record)
        XCTAssertTrue(s.primaryEnabled)
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
