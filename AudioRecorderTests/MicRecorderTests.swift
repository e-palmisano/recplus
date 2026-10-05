import XCTest
import AVFoundation
import CoreAudio
@testable import AudioRecorder

final class MicRecorderTests: XCTestCase {
    func testConvertKeepsStreamContinuousAcrossBuffersWhenDeviceRateChanges() throws {
        let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: deviceFormat, to: fileFormat))

        var convertedFrames = 0
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            let converted = try XCTUnwrap(MicRecorder.convert(buffer, with: converter))
            XCTAssertEqual(converted.format.sampleRate, 48_000)
            convertedFrames += Int(converted.frameLength)
        }

        // 1 s of 16 kHz input must come out as ~1 s at 48 kHz. Ending the
        // stream after the first buffer would stall the converter (~0.1 s).
        XCTAssertEqual(Double(convertedFrames), 48_000, accuracy: 600)
    }

    func testPaddingFramesFillOnlyRealGapsInTheDeviceTimeline() {
        let nanosPerSecond: UInt64 = 1_000_000_000
        let expected = AudioConvertNanosToHostTime(10 * nanosPerSecond)
        let late = { (seconds: Double) in AudioConvertNanosToHostTime(10 * nanosPerSecond + UInt64(seconds * 1e9)) }

        XCTAssertEqual(MicRecorder.paddingFrames(expectedHostTime: nil, actualHostTime: late(0.75), sampleRate: 48_000), 0)
        XCTAssertEqual(MicRecorder.paddingFrames(expectedHostTime: expected, actualHostTime: late(0.002), sampleRate: 48_000), 0)
        XCTAssertEqual(MicRecorder.paddingFrames(expectedHostTime: expected, actualHostTime: expected, sampleRate: 48_000), 0)
        XCTAssertEqual(Double(MicRecorder.paddingFrames(expectedHostTime: expected, actualHostTime: late(0.75), sampleRate: 48_000)), 36_000, accuracy: 2)
        // A buffer arriving early (overlap) must never produce negative padding.
        XCTAssertEqual(MicRecorder.paddingFrames(expectedHostTime: late(0.75), actualHostTime: expected, sampleRate: 48_000), 0)
        // A bogus timestamp ~30 h ahead is capped instead of overflowing
        // AVAudioFrameCount (UInt32 tops out at ~24.8 h of 48 kHz frames).
        XCTAssertEqual(
            MicRecorder.paddingFrames(expectedHostTime: expected, actualHostTime: late(30 * 3_600), sampleRate: 48_000),
            Int(MicRecorder.maxPaddingSeconds * 48_000)
        )
    }

    func testFormatsMatchIgnoresChannelLayoutButNotRateChannelsOrSampleType() {
        let base = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!

        XCTAssertTrue(MicRecorder.formatsMatch(base, AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!))
        XCTAssertFalse(MicRecorder.formatsMatch(base, AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true)!))
        XCTAssertFalse(MicRecorder.formatsMatch(base, AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!))
        XCTAssertFalse(MicRecorder.formatsMatch(base, AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!))
    }
}
