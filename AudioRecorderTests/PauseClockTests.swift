import XCTest
@testable import AudioRecorder

final class PauseClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testElapsedGrowsWhileRunning() {
        var clock = PauseClock()
        clock.start(at: t0)
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(5)), 5, accuracy: 0.001)
        XCTAssertTrue(clock.isRunning)
    }

    func testPauseExcludesPausedInterval() {
        var clock = PauseClock()
        clock.start(at: t0)
        clock.pause(at: t0.addingTimeInterval(3))          // 3s active
        XCTAssertFalse(clock.isRunning)
        // 2s paused — elapsed frozen at 3
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(5)), 3, accuracy: 0.001)
        clock.start(at: t0.addingTimeInterval(5))          // resume
        // 4 more active seconds → 7 total
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(9)), 7, accuracy: 0.001)
    }

    func testFreshClockIsZeroAndStopped() {
        let clock = PauseClock()
        XCTAssertEqual(clock.elapsed(at: t0), 0)
        XCTAssertFalse(clock.isRunning)
    }

    func testDoublePauseAndDoubleStartAreIdempotent() {
        var clock = PauseClock()
        clock.start(at: t0)
        clock.start(at: t0.addingTimeInterval(1))          // ignored, already running
        clock.pause(at: t0.addingTimeInterval(2))
        clock.pause(at: t0.addingTimeInterval(3))          // ignored, already paused
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(10)), 2, accuracy: 0.001)
    }
}
