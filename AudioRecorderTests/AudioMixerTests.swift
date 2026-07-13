import XCTest
@testable import AudioRecorder

final class AudioMixerTests: XCTestCase {
    func testOffsetFramesGivesMicLeadWhenMicStartsAfterSystem() {
        let systemStart = Date(timeIntervalSince1970: 1000)
        let micStart = Date(timeIntervalSince1970: 1000.5) // 0.5s later
        let result = AudioMixer.offsetFrames(systemStartedAt: systemStart, micStartedAt: micStart, sampleRate: 48_000)
        XCTAssertEqual(result.systemLead, 0)
        XCTAssertEqual(result.micLead, 24_000) // 0.5s * 48kHz
    }

    func testOffsetFramesGivesSystemLeadWhenSystemStartsAfterMic() {
        let systemStart = Date(timeIntervalSince1970: 1000.25) // 0.25s later
        let micStart = Date(timeIntervalSince1970: 1000)
        let result = AudioMixer.offsetFrames(systemStartedAt: systemStart, micStartedAt: micStart, sampleRate: 48_000)
        XCTAssertEqual(result.systemLead, 12_000) // 0.25s * 48kHz
        XCTAssertEqual(result.micLead, 0)
    }

    func testOffsetFramesIsZeroWhenBothStartTogether() {
        let same = Date(timeIntervalSince1970: 2000)
        let result = AudioMixer.offsetFrames(systemStartedAt: same, micStartedAt: same, sampleRate: 48_000)
        XCTAssertEqual(result.systemLead, 0)
        XCTAssertEqual(result.micLead, 0)
    }
}
