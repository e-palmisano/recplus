import XCTest
@testable import AudioRecorder

@MainActor
final class RecordingSessionFinalizationTests: XCTestCase {
    func testWaitForPendingFinalizationAwaitsEveryQueuedMixInOrder() async {
        let session = makeSessionHarness(selectedID: "en-US", normalized: "en-US", installed: true).session
        let log = FinalizationLog()

        session.enqueueFinalization {
            try? await Task.sleep(for: .milliseconds(200))
            await log.append(1)
        }
        session.enqueueFinalization { await log.append(2) }
        await session.waitForPendingFinalization()

        let entries = await log.entries
        XCTAssertEqual(entries, [1, 2])
    }

    func testWaitForPendingFinalizationReturnsImmediatelyWhenNothingQueued() async {
        let session = makeSessionHarness(selectedID: "en-US", normalized: "en-US", installed: true).session

        await session.waitForPendingFinalization()
    }
}

private actor FinalizationLog {
    private(set) var entries: [Int] = []

    func append(_ value: Int) {
        entries.append(value)
    }
}
