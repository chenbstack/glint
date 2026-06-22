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

    func testUnknownReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(named: "vim"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(named: ""))
    }

    func testBenignShellReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentKind(named: "zsh"))
    }

    // MARK: agentToken(forProcessName:)

    func testClaudeToken() {
        XCTAssertEqual(WorkspaceStore.agentToken(forProcessName: "claude"), "claude")
    }

    func testCodexToken() {
        XCTAssertEqual(WorkspaceStore.agentToken(forProcessName: "codex"), "codex")
    }

    func testOpenCodeToken() {
        XCTAssertEqual(WorkspaceStore.agentToken(forProcessName: "opencode"), "opencode")
    }

    func testDevinToken() {
        XCTAssertEqual(WorkspaceStore.agentToken(forProcessName: "devin"), "devin")
    }

    func testUnknownTokenReturnsNil() {
        XCTAssertNil(WorkspaceStore.agentToken(forProcessName: "bash"))
    }
}
