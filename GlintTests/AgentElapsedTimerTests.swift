import XCTest
@testable import Glint

/// The turn timer, shown both on sidebar workspace cards and in the pane
/// summary popover. Both surfaces read `agentElapsedReferenceDate`, so each
/// status is classified exactly once and the two cannot drift apart.
final class AgentElapsedTimerTests: XCTestCase {
    private let turnStart = Date(timeIntervalSince1970: 100)
    private let lastHook = Date(timeIntervalSince1970: 125)
    private let now = Date(timeIntervalSince1970: 900)

    /// Mid-turn the number has to keep climbing — including through
    /// `needsPermission`, where the turn is blocked on the user but not over.
    func testBusyStatusesTrackTheLiveClock() {
        for status in [PaneAgentStatus.thinking, .tool, .compacting, .needsPermission] {
            XCTAssertEqual(
                agentElapsedReferenceDate(status: status, updatedAt: lastHook, now: now),
                now,
                "\(status) is still a running turn — the timer must stay live"
            )
        }
    }

    /// Once the turn ends the label freezes at the last hook. Without this a
    /// finished row keeps counting and reads as if the agent were still busy.
    func testTurnEndStatusesFreezeAtTheLastHook() {
        for status in [PaneAgentStatus.justCompleted, .failed, .needsReply] {
            XCTAssertEqual(
                agentElapsedReferenceDate(status: status, updatedAt: lastHook, now: now),
                lastHook,
                "\(status) ends the turn — the timer must stop"
            )
        }
    }

    /// What a frozen row actually reads: how long the turn took, not how long
    /// ago it ended. 100s → 125s is a 25-second turn, whatever the clock says.
    func testFrozenLabelReadsAsTheTurnDuration() {
        let reference = agentElapsedReferenceDate(status: .justCompleted,
                                                  updatedAt: lastHook,
                                                  now: now)
        XCTAssertEqual(agentElapsedLabel(since: turnStart, now: reference), "0:25")
    }
}
