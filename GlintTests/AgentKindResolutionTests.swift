import XCTest
@testable import Glint

@MainActor
final class AgentKindResolutionTests: XCTestCase {

    // MARK: agentKind(named:)

    func testClaude() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "claude"), .claude)
    }

    func testClaudeMixedCase() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "Claude"), .claude)
    }

    func testCodex() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "codex"), .codex)
    }

    func testOpenCode() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "opencode"), .opencode)
    }

    func testDevin() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "devin"), .devin)
    }

    func testDevinMixedCase() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "Devin"), .devin)
    }

    func testOmpExact() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "omp"), .omp)
    }

    func testOmpPathSuffix() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "/Users/me/.local/bin/omp"), .omp)
    }

    func testOmpDoesNotMatchSubstring() {
        // Three-letter token must not false-positive on longer names.
        XCTAssertNil(WorkspaceStore.agentKind(named: "compiz"))
        XCTAssertNil(WorkspaceStore.agentKind(named: "prompt"))
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(named: "vim"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(named: ""))
    }

    func testBenignShellReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(named: "zsh"))
    }

    // MARK: agentKind(forProcessName:)

    func testClaudeProcessName() {
        XCTAssertEqual(WorkspaceStore.agentKind(forProcessName: "claude"), .claude)
    }

    func testCodexProcessName() {
        XCTAssertEqual(WorkspaceStore.agentKind(forProcessName: "codex"), .codex)
    }

    func testOpenCodeProcessName() {
        XCTAssertEqual(WorkspaceStore.agentKind(forProcessName: "opencode"), .opencode)
    }

    func testDevinProcessName() {
        XCTAssertEqual(WorkspaceStore.agentKind(forProcessName: "devin"), .devin)
    }

    func testOmpProcessName() {
        XCTAssertEqual(WorkspaceStore.agentKind(forProcessName: "omp"), .omp)
    }

    func testUnknownProcessNameReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(forProcessName: "bash"))
    }

    // Anchor the writer/reader contract: every PaneAgentKind's rawValue must
    // be a process name `agentKind(forProcessName:)` recognizes — that's what
    // structurally keeps `sessionIds[kind.rawValue]` lookups from quietly
    // missing the entry the foreground poller stashed.
    func testRawValueRoundTripsThroughForProcessName() {
        for kind in [PaneAgentKind.claude, .codex, .opencode, .devin, .omp] {
            XCTAssertEqual(WorkspaceStore.agentKind(forProcessName: kind.rawValue), kind,
                           "rawValue '\(kind.rawValue)' must resolve back to \(kind)")
        }
    }
}
