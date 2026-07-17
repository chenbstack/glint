import XCTest
@testable import Glint

final class WorkspaceIconKindTests: XCTestCase {

    // MARK: sfSymbol

    func testShellHasSFSymbol() {
        XCTAssertNotNil(WorkspaceIconKind.shell.sfSymbol)
    }

    func testClaudeHasNoSFSymbol() {
        XCTAssertNil(WorkspaceIconKind.claude.sfSymbol)
    }

    func testCodexHasNoSFSymbol() {
        XCTAssertNil(WorkspaceIconKind.codex.sfSymbol)
    }

    func testOpenCodeHasNoSFSymbol() {
        XCTAssertNil(WorkspaceIconKind.opencode.sfSymbol)
    }

    func testDevinHasNoSFSymbol() {
        XCTAssertNil(WorkspaceIconKind.devin.sfSymbol)
    }

    func testOmpHasNoSFSymbol() {
        XCTAssertNil(WorkspaceIconKind.omp.sfSymbol)
        XCTAssertNil(WorkspaceIconKind.grok.sfSymbol)
    }

    // MARK: letter

    func testClaudeLetter() {
        XCTAssertEqual(WorkspaceIconKind.claude.letter, "✦")
    }

    func testCodexLetter() {
        XCTAssertEqual(WorkspaceIconKind.codex.letter, "λ")
    }

    func testOpenCodeLetter() {
        XCTAssertEqual(WorkspaceIconKind.opencode.letter, "O")
    }

    func testDevinLetter() {
        XCTAssertEqual(WorkspaceIconKind.devin.letter, "D")
    }

    func testOmpLetter() {
        XCTAssertEqual(WorkspaceIconKind.omp.letter, "π")
        XCTAssertEqual(WorkspaceIconKind.grok.letter, "G")
    }

    func testOtherLetterUsesInitial() {
        XCTAssertEqual(WorkspaceIconKind.other("htop").letter, "H")
    }
}
