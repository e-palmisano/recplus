import XCTest
import AVFoundation
@testable import AudioRecorder

final class AudioLevelMeterTests: XCTestCase {
    private func makeBuffer(fill: (Int) -> Float, frames: AVAudioFrameCount = 4800) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = fill(i) }
        return buffer
    }

    func testSilenceIsZero() {
        let buffer = makeBuffer(fill: { _ in 0 })
        XCTAssertEqual(AudioLevelMeter.rmsLevel(of: buffer), 0, accuracy: 0.001)
    }

    func testFullScaleSineIsAboutPointSevenOhSeven() {
        let buffer = makeBuffer(fill: { i in sin(2 * .pi * 440 * Float(i) / 48000) })
        XCTAssertEqual(AudioLevelMeter.rmsLevel(of: buffer), 0.707, accuracy: 0.01)
    }

    func testEmptyBufferIsZero() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 0
        XCTAssertEqual(AudioLevelMeter.rmsLevel(of: buffer), 0)
    }
}
