/// Sums two independently-arriving mono sample streams. Unlike `AudioMixer`
/// (used for the final offline `.m4a`), this does not attempt sample-accurate
/// wall-clock alignment — mic and system audio start within ~200ms of each
/// other already (see `RecordingSession.start`), and small misalignment
/// doesn't meaningfully affect transcription quality. Shorter arrays are
/// zero-padded so uneven chunk sizes between the two producers never crash.
enum LiveMixer {
    static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        let count = max(a.count, b.count)
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<a.count { result[i] += a[i] }
        for i in 0..<b.count { result[i] += b[i] }
        return result
    }
}
