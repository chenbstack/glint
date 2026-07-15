import XCTest
@testable import Glint

final class MascotAssetTests: XCTestCase {

    // MARK: Devin

    func testDevinIdle() {
        XCTAssertEqual(MascotAsset.devin(for: .idle), "DevinIdle")
    }

    func testDevinNil() {
        XCTAssertEqual(MascotAsset.devin(for: nil), "DevinIdle")
    }

    func testDevinThinking() {
        XCTAssertEqual(MascotAsset.devin(for: .thinking), "DevinThinking")
    }

    func testDevinToolCall() {
        XCTAssertEqual(MascotAsset.devin(for: .tool), "DevinToolCall")
    }

    func testDevinCompressing() {
        XCTAssertEqual(MascotAsset.devin(for: .compacting), "DevinCompressing")
    }

    func testDevinNeedsPermission() {
        XCTAssertEqual(MascotAsset.devin(for: .needsPermission), "DevinNeedsPermission")
    }

    func testDevinDone() {
        XCTAssertEqual(MascotAsset.devin(for: .justCompleted), "DevinDone")
    }

    func testDevinFailed() {
        XCTAssertEqual(MascotAsset.devin(for: .failed), "DevinFailed")
    }

    // MARK: OMP

    func testOmpIdle() {
        XCTAssertEqual(MascotAsset.omp(for: .idle), "OmpIdle")
    }

    func testOmpNil() {
        XCTAssertEqual(MascotAsset.omp(for: nil), "OmpIdle")
    }

    func testOmpThinking() {
        XCTAssertEqual(MascotAsset.omp(for: .thinking), "OmpThinking")
    }

    func testOmpToolCall() {
        XCTAssertEqual(MascotAsset.omp(for: .tool), "OmpToolCall")
    }

    func testOmpCompressing() {
        XCTAssertEqual(MascotAsset.omp(for: .compacting), "OmpCompressing")
    }

    func testOmpNeedsPermission() {
        XCTAssertEqual(MascotAsset.omp(for: .needsPermission), "OmpNeedsPermission")
    }

    func testOmpDone() {
        XCTAssertEqual(MascotAsset.omp(for: .justCompleted), "OmpDone")
    }

    func testOmpFailed() {
        XCTAssertEqual(MascotAsset.omp(for: .failed), "OmpFailed")
    }

    // MARK: Existing agents (regression)

    func testClaudeIdleMascot() {
        XCTAssertEqual(MascotAsset.claude(for: .idle, isSpark: false), "ClaudeIdle")
    }

    func testClaudeIdleSpark() {
        XCTAssertEqual(MascotAsset.claude(for: .idle, isSpark: true), "ClaudeSparkIdle")
    }

    func testClaudeThinkingMascot() {
        XCTAssertEqual(MascotAsset.claude(for: .thinking, isSpark: false), "ClaudeThinking")
    }

    func testCodexIdle() {
        XCTAssertEqual(MascotAsset.codex(for: .idle), "CodexIdle")
    }

    func testCodexThinking() {
        XCTAssertEqual(MascotAsset.codex(for: .thinking), "CodexThinking")
    }

    func testOpenCodeIdle() {
        XCTAssertEqual(MascotAsset.opencode(for: .idle), "OpenCodeIdle")
    }

    func testOpenCodeThinking() {
        XCTAssertEqual(MascotAsset.opencode(for: .thinking), "OpenCodeThinking")
    }
}
