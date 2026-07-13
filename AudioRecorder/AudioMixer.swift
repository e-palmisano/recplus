import Foundation
import AVFoundation

/// Mixes the separately recorded system-audio and microphone `.caf` files into
/// a single AAC (.m4a) file, aligning them by their real wall-clock start times
/// rather than assuming any fixed gap between the two recorders starting.
enum AudioMixer {
    private static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private static let headroom: Float = 0.9

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

    /// Mixes `systemURL` and `micURL` into a single AAC file at `outputURL`,
    /// aligned by their real start times so neither track drifts against the other.
    static func mix(systemURL: URL, micURL: URL, systemStartedAt: Date, micStartedAt: Date, outputURL: URL) throws {
        let systemBuffer = try resampledBuffer(fileURL: systemURL, targetFormat: canonicalFormat)
        let micBuffer = try resampledBuffer(fileURL: micURL, targetFormat: canonicalFormat)

        let (systemLead, micLead) = offsetFrames(systemStartedAt: systemStartedAt, micStartedAt: micStartedAt, sampleRate: canonicalFormat.sampleRate)
        let mixed = mixedBuffer(system: systemBuffer, systemLeadFrames: systemLead, mic: micBuffer, micLeadFrames: micLead, headroom: headroom)

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: canonicalFormat.sampleRate,
            AVNumberOfChannelsKey: canonicalFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw "Failed to create AAC output file at \(outputURL.lastPathComponent): \(error.localizedDescription)"
        }
        do {
            try outputFile.write(from: mixed)
        } catch {
            throw "Failed to write mixed audio to \(outputURL.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
