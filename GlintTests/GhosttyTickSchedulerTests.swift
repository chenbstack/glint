import XCTest
@testable import Glint

final class GhosttyTickSchedulerTests: XCTestCase {
    func testCoalescesWakeupsBeforeQueuedTickRuns() {
        var queued: [() -> Void] = []
        let scheduler = GhosttyTickScheduler { queued.append($0) }
        var ticks = 0

        for _ in 0..<100 {
            scheduler.schedule { ticks += 1 }
        }

        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(ticks, 0)
        queued.removeFirst()()
        XCTAssertEqual(ticks, 1)
    }

    func testWakeupDuringTickSchedulesAnotherTick() {
        var queued: [() -> Void] = []
        let scheduler = GhosttyTickScheduler { queued.append($0) }
        var ticks = 0

        scheduler.schedule {
            ticks += 1
            scheduler.schedule { ticks += 1 }
        }

        queued.removeFirst()()
        XCTAssertEqual(ticks, 1)
        XCTAssertEqual(queued.count, 1)
        queued.removeFirst()()
        XCTAssertEqual(ticks, 2)
    }

    func testConcurrentWakeupsStillEnqueueOnce() {
        let queuedLock = NSLock()
        var queued: [() -> Void] = []
        let scheduler = GhosttyTickScheduler { block in
            queuedLock.lock()
            queued.append(block)
            queuedLock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            scheduler.schedule {}
        }

        queuedLock.lock()
        let count = queued.count
        queuedLock.unlock()
        XCTAssertEqual(count, 1)
    }
}
