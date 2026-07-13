import Foundation

enum TranscriptWriter {
    static func text(for lines: [TranscriptLine]) -> String {
        lines
            .map { "[\(RecordingFormat.transcriptTimestamp($0.offset))] \($0.text)" }
            .joined(separator: "\n")
    }
}
