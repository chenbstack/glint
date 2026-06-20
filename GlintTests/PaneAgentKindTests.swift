import XCTest
@testable import Glint

final class PaneAgentKindTests: XCTestCase {

    // MARK: displayName

    func testClaudeDisplayName() {
        XCTAssertEqual(PaneAgentKind.claude.displayName, "Claude")
    }

    func testCodexDisplayName() {
        XCTAssertEqual(PaneAgentKind.codex.displayName, "Codex")
    }

    func testOpenCodeDisplayName() {
        XCTAssertEqual(PaneAgentKind.opencode.displayName, "OpenCode")
    }

    func testDevinDisplayName() {
        XCTAssertEqual(PaneAgentKind.devin.displayName, "Devin")
    }

    // MARK: iconKind

    func testClaudeIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.claude.iconKind, .claude))
    }

    func testCodexIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.codex.iconKind, .codex))
    }

    func testOpenCodeIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.opencode.iconKind, .opencode))
    }

    func testDevinIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.devin.iconKind, .devin))
    }

    // MARK: helpers

    /// WorkspaceIconKind isn't Equatable, so compare by matching the expected
    /// case via a switch.
    private func isIconKind(_ actual: WorkspaceIconKind, _ expected: WorkspaceIconKind) -> Bool {
        switch (actual, expected) {
        case (.claude, .claude), (.codex, .codex),
             (.opencode, .opencode), (.devin, .devin),
             (.shell, .shell), (.ssh, .ssh), (.vim, .vim),
             (.python, .python), (.node, .node), (.git, .git):
            return true
        default:
            return false
        }
    }
}
