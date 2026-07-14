import AVFoundation

enum LiveResamplerError: Error {
    case conversionFailed
}

/// Resamples one live audio buffer to the caller-supplied `targetFormat`,
/// returning a plain `[Float]` so the result is safe to hand off across
/// threads (unlike `AVAudioPCMBuffer`, which for the system tap wraps memory
/// that's only valid for the duration of its callback).
enum LiveResampler {
    static func resampleToMono16k(buffer: AVAudioPCMBuffer, from format: AVAudioFormat, targetFormat: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw LiveResamplerError.conversionFailed
        }

        let ratio = targetFormat.sampleRate / format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw LiveResamplerError.conversionFailed
        }

        var didProvideBuffer = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideBuffer {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            didProvideBuffer = true
            return buffer
        }

        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry else { throw LiveResamplerError.conversionFailed }

        let frameLength = Int(outputBuffer.frameLength)
        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
