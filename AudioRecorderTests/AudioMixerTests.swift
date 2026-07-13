import XCTest
import AVFoundation
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

    func testMixedBufferSumsAlignedSamplesWithHeadroom() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!

        let system = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        system.frameLength = 4
        for i in 0..<4 { system.floatChannelData![0][i] = 0.4 }

        let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        mic.frameLength = 2
        for i in 0..<2 { mic.floatChannelData![0][i] = 0.2 }

        // mic starts 2 frames after system: overlap only on frames 2-3.
        let mixed = AudioMixer.mixedBuffer(system: system, systemLeadFrames: 0, mic: mic, micLeadFrames: 2, headroom: 1.0)

        XCTAssertEqual(mixed.frameLength, 4)
        let out = mixed.floatChannelData![0]
        XCTAssertEqual(out[0], 0.4, accuracy: 0.0001)   // system only
        XCTAssertEqual(out[1], 0.4, accuracy: 0.0001)   // system only
        XCTAssertEqual(out[2], 0.6, accuracy: 0.0001)   // system(0.4) + mic(0.2)
        XCTAssertEqual(out[3], 0.6, accuracy: 0.0001)   // system(0.4) + mic(0.2)
    }

    func testMixedBufferClampsToValidRange() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!

        let system = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        system.frameLength = 1
        system.floatChannelData![0][0] = 0.9

        let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        mic.frameLength = 1
        mic.floatChannelData![0][0] = 0.9

        let mixed = AudioMixer.mixedBuffer(system: system, systemLeadFrames: 0, mic: mic, micLeadFrames: 0, headroom: 1.0)

        XCTAssertEqual(mixed.floatChannelData![0][0], 1.0, accuracy: 0.0001) // 1.8 clamped to 1.0
    }
}
