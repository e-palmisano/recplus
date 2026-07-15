import XCTest
import AVFoundation
@testable import AudioRecorder

final class LiveResamplerTests: XCTestCase {
    func testResampleProducesNonEmptyOutputAtTargetRate() throws {
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

        let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.5 }

        let resampler = LiveResampler()
        let samples = try resampler.resampleToMono16k(buffer: buffer, from: sourceFormat, targetFormat: targetFormat)

        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue((1_500...1_700).contains(samples.count)) // ~4800 * (16000/48000) == 1600
    }

    /// Regression: the converter used to be rebuilt on every call (expensive
    /// enough to peg the real-time audio queues). Reusing it across repeated
    /// calls with the same format pair must keep working correctly.
    func testResampleReusesConverterAcrossRepeatedCallsWithSameFormat() throws {
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let resampler = LiveResampler()

        for _ in 0..<5 {
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 480)!
            buffer.frameLength = 480
            for i in 0..<480 { buffer.floatChannelData![0][i] = 0.3 }

            let samples = try resampler.resampleToMono16k(buffer: buffer, from: sourceFormat, targetFormat: targetFormat)
            XCTAssertFalse(samples.isEmpty)
        }
    }
    func testResampleReturnsFloatSamplesForInt16AnalyzerFormat() throws {
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let analyzerFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for i in 0..<1_600 { buffer.floatChannelData![0][i] = 0.25 }

        let samples = try LiveResampler().resampleToMono16k(
            buffer: buffer,
            from: sourceFormat,
            targetFormat: analyzerFormat
        )

        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.25, accuracy: 0.01)
    }

}
