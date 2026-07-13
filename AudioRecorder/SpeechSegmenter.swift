import Foundation

/// Pure energy-based silence detection, used to decide when a stretch of
/// live transcription should be finalized rather than left as a
/// self-correcting pending line. Mirrors the approach whisper.cpp's own
/// `stream` example uses (RMS energy against a fixed threshold).
enum SpeechSegmenter {
    static func rmsEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    static func isSilent(_ samples: [Float], threshold: Float) -> Bool {
        rmsEnergy(samples) < threshold
    }

    static func shouldFinalizeSegment(silentChunkCount: Int, chunkDuration: TimeInterval, requiredSilenceDuration: TimeInterval) -> Bool {
        Double(silentChunkCount) * chunkDuration >= requiredSilenceDuration
    }
}
