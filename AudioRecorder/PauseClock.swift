import Foundation

/// Accumulates elapsed time across pause/resume cycles. Paused intervals are
/// excluded from `elapsed`, matching the recorded audio (paused buffers are
/// dropped, so the file contains only active time).
struct PauseClock {
    private var accumulated: TimeInterval = 0
    private var activeSince: Date?

    var isRunning: Bool { activeSince != nil }

    mutating func start(at date: Date = Date()) {
        guard activeSince == nil else { return }
        activeSince = date
    }

    mutating func pause(at date: Date = Date()) {
        guard let activeSince else { return }
        accumulated += date.timeIntervalSince(activeSince)
        self.activeSince = nil
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (activeSince.map { date.timeIntervalSince($0) } ?? 0)
    }
}
