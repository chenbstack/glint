import XCTest
@testable import Glint

final class CodexHookInstallerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testMergePreservesUnrelatedHooksAndIsIdempotent() throws {
        let hooksURL = home.appendingPathComponent("hooks.json")
        let existing = #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"user-hook"}]}]},"custom":true}"#
        try existing.write(to: hooksURL, atomically: true, encoding: .utf8)

        try CodexHookInstaller.mergeCodexHooks(scriptPath: "/tmp/glint-report.sh", codexHome: home)
        try CodexHookInstaller.mergeCodexHooks(scriptPath: "/tmp/glint-report.sh", codexHome: home)

        XCTAssertTrue(CodexHookInstaller.isInstalled(in: home))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        XCTAssertEqual(root?["custom"] as? Bool, true)
        let stop = (root?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        XCTAssertEqual(stop?.count, 2)
    }

    func testInvalidJSONIsBackedUpAndNotOverwritten() throws {
        let hooksURL = home.appendingPathComponent("hooks.json")
        try "not json".write(to: hooksURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CodexHookInstaller.mergeCodexHooks(scriptPath: "/tmp/glint-report.sh", codexHome: home)
        ) { error in
            XCTAssertEqual(error as? CodexHookInstallerError, .invalidHooksJSON)
        }
        XCTAssertEqual(try String(contentsOf: hooksURL), "not json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.appendingPathExtension("glint-backup").path))
    }

    func testUninstallOnlyRemovesGlintHooks() throws {
        let hooksURL = home.appendingPathComponent("hooks.json")
        let existing = #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"user-hook"}]}]}}"#
        try existing.write(to: hooksURL, atomically: true, encoding: .utf8)
        try CodexHookInstaller.mergeCodexHooks(scriptPath: "/tmp/glint-report.sh", codexHome: home)

        try CodexHookInstaller.uninstall(from: home)

        XCTAssertFalse(CodexHookInstaller.isInstalled(in: home))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let stop = (root?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        XCTAssertEqual(stop?.count, 1)
    }
}
