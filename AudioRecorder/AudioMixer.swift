import Foundation
import AVFoundation

/// Mixes the separately recorded system-audio and microphone `.caf` files into
/// a single AAC (.m4a) file, aligning them by their real wall-clock start times
/// rather than assuming any fixed gap between the two recorders starting.
enum AudioMixer {
    /// How many leading silent frames each stream needs so both start at the same
    /// wall-clock instant. Exactly one of the two returned values is always 0.
    static func offsetFrames(systemStartedAt: Date, micStartedAt: Date, sampleRate: Double) -> (systemLead: Int, micLead: Int) {
        let gapSeconds = micStartedAt.timeIntervalSince(systemStartedAt)
        let gapFrames = Int((abs(gapSeconds) * sampleRate).rounded())
        return gapSeconds >= 0 ? (systemLead: 0, micLead: gapFrames) : (systemLead: gapFrames, micLead: 0)
    }

    /// Sums two buffers sample-by-sample after applying each one's leading silence
    /// offset, with a headroom multiplier so simultaneous peaks don't clip.
    static func mixedBuffer(system: AVAudioPCMBuffer, systemLeadFrames: Int, mic: AVAudioPCMBuffer, micLeadFrames: Int, headroom: Float) -> AVAudioPCMBuffer {
        let format = system.format
        let channelCount = Int(format.channelCount)
        let totalFrames = max(systemLeadFrames + Int(system.frameLength), micLeadFrames + Int(mic.frameLength))

        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
        output.frameLength = AVAudioFrameCount(totalFrames)

        for channel in 0..<channelCount {
            let out = output.floatChannelData![channel]
            out.update(repeating: 0, count: totalFrames)

            let sys = system.floatChannelData![channel]
            for i in 0..<Int(system.frameLength) {
                out[systemLeadFrames + i] += sys[i] * headroom
            }

            let mc = mic.floatChannelData![channel]
            for i in 0..<Int(mic.frameLength) {
                out[micLeadFrames + i] += mc[i] * headroom
            }

            for i in 0..<totalFrames {
                out[i] = max(-1, min(1, out[i]))
            }
        }

        return output
    }

    /// Reads an entire audio file into memory and resamples it to `targetFormat`.
    static func resampledBuffer(fileURL: URL, targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw "Failed to allocate read buffer for \(fileURL.lastPathComponent)."
        }
        try file.read(into: sourceBuffer)

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw "Failed to allocate resample buffer for \(fileURL.lastPathComponent)."
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw "Failed to create audio converter for \(fileURL.lastPathComponent)."
        }

        var didProvideBuffer = false
        var outError: NSError?
        let status = converter.convert(to: outputBuffer, error: &outError) { _, outStatus in
            if didProvideBuffer {
                outStatus.pointee = .endOfStream
                return nil
            }

            outStatus.pointee = .haveData
            didProvideBuffer = true
            return sourceBuffer
        }

        if let error = outError {
            throw error
        }
        guard status == .haveData else {
            throw "Audio conversion failed with status \(status.rawValue)."
        }

        return outputBuffer
    }
}
