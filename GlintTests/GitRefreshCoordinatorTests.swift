import XCTest
@testable import Glint

final class GitRefreshCoordinatorTests: XCTestCase {
    /// First request for a workspace dispatches immediately (no trailing delay).
    func testFirstRequestRunsImmediately() {
        let coordinator = GitRefreshCoordinator(minInterval: 0.3)
        let id = UUID()
        let ran = expectation(description: "immediate run")

        coordinator.request(id) { ran.fulfill() }

        // timeout < minInterval: a trailing path would still be pending here.
        wait(for: [ran], timeout: 0.15)
    }

    /// Repeated requests inside the window collapse into the initial immediate
    /// dispatch plus exactly one trailing refresh (not one per request).
    func testCoalescesRapidRequestsIntoOneTrailing() {
        let coordinator = GitRefreshCoordinator(minInterval: 0.3)
        let id = UUID()
        var count = 0
        let immediate = expectation(description: "immediate")

        coordinator.request(id) { count += 1; immediate.fulfill() }
        // Two more within the window — both must fold into the single trailing.
        coordinator.request(id) { count += 1 }
        coordinator.request(id) { count += 1 }

        wait(for: [immediate], timeout: 0.5)
        XCTAssertEqual(count, 1)

        let settled = expectation(description: "trailing settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // immediate + exactly one trailing
            XCTAssertEqual(count, 2)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.5)
    }

    /// Once the window has fully elapsed, the next request is immediate again
    /// (the throttle resets) and spawns no extra trailing refresh.
    func testRequestAfterWindowRunsImmediatelyWithoutTrailing() {
        let coordinator = GitRefreshCoordinator(minInterval: 0.3)
        let id = UUID()
        var count = 0
        let first = expectation(description: "first")

        coordinator.request(id) { count += 1; first.fulfill() }
        wait(for: [first], timeout: 0.5)

        // Wait past the window so the next request is on the immediate path.
        let second = expectation(description: "second immediate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            coordinator.request(id) { count += 1; second.fulfill() }
        }
        wait(for: [second], timeout: 1.0)
        XCTAssertEqual(count, 2)

        // Confirm no trailing was scheduled by the second (immediate) request.
        let settled = expectation(description: "no extra trailing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(count, 2)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)
    }

    /// `cancel` drops a not-yet-fired trailing refresh for the workspace.
    func testCancelDropsPendingTrailing() {
        let coordinator = GitRefreshCoordinator(minInterval: 0.3)
        let id = UUID()
        var count = 0
        let immediate = expectation(description: "immediate")

        coordinator.request(id) { count += 1; immediate.fulfill() }
        wait(for: [immediate], timeout: 0.5)
        XCTAssertEqual(count, 1)

        // Second request schedules a trailing; cancel it before it fires.
        coordinator.request(id) { count += 1 }
        coordinator.cancel(id)

        let settled = expectation(description: "trailing never fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            XCTAssertEqual(count, 1)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.5)
    }

    /// Per-workspace isolation: throttling one workspace does not delay another.
    func testPerWorkspaceIsolation() {
        let coordinator = GitRefreshCoordinator(minInterval: 0.3)
        let a = expectation(description: "a")
        let b = expectation(description: "b")

        coordinator.request(UUID()) { a.fulfill() }
        coordinator.request(UUID()) { b.fulfill() }

        // Two different workspaces → both immediate, neither blocks the other.
        wait(for: [a, b], timeout: 0.3)
    }
}
