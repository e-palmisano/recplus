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
}
