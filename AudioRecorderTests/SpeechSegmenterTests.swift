import XCTest
@testable import AudioRecorder

final class SpeechSegmenterTests: XCTestCase {
    func testRmsEnergyOfSilenceIsZero() {
        XCTAssertEqual(SpeechSegmenter.rmsEnergy([0, 0, 0, 0]), 0, accuracy: 0.0001)
    }

    func testRmsEnergyOfConstantSignal() {
        // RMS of a constant 0.5 signal is 0.5.
        XCTAssertEqual(SpeechSegmenter.rmsEnergy([0.5, 0.5, 0.5, 0.5]), 0.5, accuracy: 0.0001)
    }

    func testRmsEnergyOfEmptyArrayIsZero() {
        XCTAssertEqual(SpeechSegmenter.rmsEnergy([]), 0, accuracy: 0.0001)
    }

    func testIsSilentBelowThreshold() {
        XCTAssertTrue(SpeechSegmenter.isSilent([0.001, 0.002, -0.001], threshold: 0.01))
    }

    func testIsSilentFalseAboveThreshold() {
        XCTAssertFalse(SpeechSegmenter.isSilent([0.5, 0.5, -0.5], threshold: 0.01))
    }

    func testShouldFinalizeSegmentWhenSilenceMeetsDuration() {
        // 3 chunks * 0.2s each = 0.6s of silence, required is 0.6s.
        XCTAssertTrue(SpeechSegmenter.shouldFinalizeSegment(silentChunkCount: 3, chunkDuration: 0.2, requiredSilenceDuration: 0.6))
    }

    func testShouldNotFinalizeSegmentWhenSilenceIsShort() {
        XCTAssertFalse(SpeechSegmenter.shouldFinalizeSegment(silentChunkCount: 2, chunkDuration: 0.2, requiredSilenceDuration: 0.6))
    }
}
