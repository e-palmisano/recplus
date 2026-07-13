import Foundation

/// A single finalized segment of live transcription, timed relative to the
/// start of the recording it belongs to.
struct TranscriptLine {
    let offset: TimeInterval
    let text: String
}
