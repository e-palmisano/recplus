import AVFoundation

enum AudioLevelMeter {
    /// Normalized 0…1 RMS level of the buffer's first channel.
    static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += data[i] * data[i]
        }
        return min(sqrt(sum / Float(buffer.frameLength)), 1)
    }
}
