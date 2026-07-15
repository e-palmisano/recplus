import AVFoundation

enum LiveResamplerError: Error {
    case conversionFailed
}

/// Resamples one live audio buffer to mono Float32 at the analyzer's sample
/// rate, returning a plain `[Float]` so the result can be mixed and handed
/// across threads safely. The analyzer's preferred PCM representation may be
/// Int16, which is applied only after the mic and system streams are mixed.
///
/// Not thread-safe: `AVAudioConverter` is expensive to construct (internal
/// DSP/filter setup), so this caches one and reuses it across calls instead
/// of rebuilding it per buffer — rebuilding per call was pegging the mic/tap
/// audio queues (dozens of calls/sec at real-time-ish priority) and starving
/// the main thread. Callers must use one instance per audio source (mic,
/// system) from that source's own serial callback only.
final class LiveResampler {
    private var converter: AVAudioConverter?
    private var cachedFrom: AVAudioFormat?
    private var cachedTo: AVAudioFormat?

    func resampleToMono16k(buffer: AVAudioPCMBuffer, from format: AVAudioFormat, targetFormat: AVAudioFormat) throws -> [Float] {
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw LiveResamplerError.conversionFailed
        }

        if converter == nil || cachedFrom != format || cachedTo != mixFormat {
            guard let newConverter = AVAudioConverter(from: format, to: mixFormat) else {
                throw LiveResamplerError.conversionFailed
            }
            converter = newConverter
            cachedFrom = format
            cachedTo = mixFormat
        }
        guard let converter else { throw LiveResamplerError.conversionFailed }
        // Each call converts one independent chunk (we always signal
        // .endOfStream below), not a continuous stream — without reset() a
        // reused converter refuses further input after its first call.
        converter.reset()

        let ratio = mixFormat.sampleRate / format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: outputCapacity) else {
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
        guard let channelData = outputBuffer.floatChannelData else { throw LiveResamplerError.conversionFailed }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
