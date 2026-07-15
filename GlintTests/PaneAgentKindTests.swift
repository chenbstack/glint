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

    func testOmpDisplayName() {
        XCTAssertEqual(PaneAgentKind.omp.displayName, "OMP")
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

    func testOmpIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.omp.iconKind, .omp))
    }

    // MARK: isValid(sessionId:)

    func testValidSessionIdAcceptsAlphanumericAndPunct() {
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: "01HK2X3F4Y5Z6A7B"))
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: "abc_def-123"))
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: "A"))
    }

    func testValidSessionIdRejectsEmpty() {
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: ""))
    }

    func testValidSessionIdRejectsTooLong() {
        let s = String(repeating: "a", count: PaneAgentKind.sessionIdMaxLength + 1)
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: s))
    }

    func testValidSessionIdAcceptsMaxLength() {
        let s = String(repeating: "a", count: PaneAgentKind.sessionIdMaxLength)
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: s))
    }

    func testValidSessionIdRejectsDisallowedChars() {
        // Anything that would smuggle a second shell token must fail.
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a;b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a\nb"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a/b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a.b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a\"b"))
    }

    // MARK: restoreCommand

    func testRestoreCommandWithValidIdUsesResumeForm() {
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123"),
                       "claude --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123"),
                       "codex resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.opencode.restoreCommand(sessionId: "abc-123"),
                       "opencode --session abc-123\n")
        XCTAssertEqual(PaneAgentKind.devin.restoreCommand(sessionId: "abc-123"),
                       "devin --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.omp.restoreCommand(sessionId: "abc-123"),
                       "omp -r abc-123\n")
    }

    func testRestoreCommandNilFallsBackToContinue() {
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: nil),
                       "claude --continue\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: nil),
                       "codex resume --last\n")
        XCTAssertEqual(PaneAgentKind.opencode.restoreCommand(sessionId: nil),
                       "opencode --continue\n")
        XCTAssertEqual(PaneAgentKind.devin.restoreCommand(sessionId: nil),
                       "devin --continue\n")
        XCTAssertEqual(PaneAgentKind.omp.restoreCommand(sessionId: nil),
                       "omp -c\n")
    }

    func testRestoreCommandRejectsInjectedIdAndDowngradesToContinue() {
        // Defense in depth: an id that bypassed any outer gate must NOT be
        // interpolated into the TTY string. Caller forgets validation → we
        // still emit the safe fallback rather than a primed shell.
        let injected = "abc\n; rm -rf /tmp/nope\n"
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: injected),
                       "claude --continue\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: injected),
                       "codex resume --last\n")
    }

    // MARK: restoreCommand — non-default Codex Home prefix

    func testRestoreCommandCodexHomePrefixesResume() {
        // A non-default-home Codex pane must re-prefix its resume command with
        // the same CODEX_HOME it launched under, or restart resumes against
        // ~/.codex where the session doesn't exist (#45 for multi-home).
        let home = "/Users/test/codex-secondary"
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123", codexHome: home),
                       "CODEX_HOME='\(home)' codex resume abc-123\n")
        // Fallback form (--last) carries the prefix too.
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: nil, codexHome: home),
                       "CODEX_HOME='\(home)' codex resume --last\n")
    }

    func testRestoreCommandCodexHomeIgnoredForDefaultAndOtherKinds() {
        // Default home (nil) ⇒ no prefix; other agents ignore the home entirely.
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123", codexHome: nil),
                       "codex resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123", codexHome: "/x"),
                       "claude --resume abc-123\n")
    }

    // MARK: helpers

    /// WorkspaceIconKind isn't Equatable, so compare by matching the expected
    /// case via a switch.
    private func isIconKind(_ actual: WorkspaceIconKind, _ expected: WorkspaceIconKind) -> Bool {
        switch (actual, expected) {
        case (.claude, .claude), (.codex, .codex),
             (.opencode, .opencode), (.devin, .devin), (.omp, .omp),
             (.shell, .shell), (.ssh, .ssh), (.vim, .vim),
             (.python, .python), (.node, .node), (.git, .git):
            return true
        default:
            return false
        }
    }
}
