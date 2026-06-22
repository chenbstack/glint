import XCTest
@testable import Glint

final class DevinHookInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-devin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configURL = tempDir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// No config file → not installed. Uses an injected temp path so the
    /// result never depends on whether the dev machine actually runs Devin.
    func testNotInstalledWhenConfigMissing() {
        XCTAssertFalse(DevinHookInstaller.isInstalled(configURL: configURL))
    }

    /// The registered events match Devin's documented hooks that Glint reacts
    /// to — and crucially do NOT include PreCompact / StopFailure (Devin
    /// doesn't emit those). This guards against silently re-adding them.
    func testHookEventsAreTheDevinSupportedSubset() {
        XCTAssertEqual(
            DevinHookInstaller.hookEvents,
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"]
        )
        XCTAssertFalse(DevinHookInstaller.hookEvents.contains("PreCompact"))
        XCTAssertFalse(DevinHookInstaller.hookEvents.contains("StopFailure"))
    }

    /// Merging into an existing Devin config must preserve the user's non-hook
    /// keys, register one entry per supported event, and tag the command with
    /// the `devin` agent kind so panes are attributed correctly.
    func testMergePreservesUserKeysAndRegistersHooks() throws {
        let existing = #"{ "version": 2, "agent": "devin", "permissions": { "exec": true } }"#
        try existing.write(to: configURL, atomically: true, encoding: .utf8)

        DevinHookInstaller.mergeDevinHooks(scriptPath: "/tmp/glint-report.sh", configURL: configURL)

        XCTAssertTrue(DevinHookInstaller.isInstalled(configURL: configURL))

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        XCTAssertEqual(root?["version"] as? Int, 2, "non-hook key dropped")
        XCTAssertEqual(root?["agent"] as? String, "devin", "non-hook key dropped")
        XCTAssertNotNil(root?["permissions"], "non-hook key dropped")

        let hooks = (root?["hooks"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(DevinHookInstaller.hookEvents))

        let stop = (hooks["Stop"] as? [Any])?.first as? [String: Any]
        let inner = (stop?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(inner?["command"] as? String, "/tmp/glint-report.sh Stop devin")
    }

    /// Installing twice is idempotent — no duplicate Glint entries pile up.
    func testMergeIsIdempotent() throws {
        try #"{ "version": 2 }"#.write(to: configURL, atomically: true, encoding: .utf8)
        DevinHookInstaller.mergeDevinHooks(scriptPath: "/tmp/glint-report.sh", configURL: configURL)
        DevinHookInstaller.mergeDevinHooks(scriptPath: "/tmp/glint-report.sh", configURL: configURL)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let stop = (root?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        XCTAssertEqual(stop?.count, 1, "duplicate Glint hook entry after second install")
    }

    /// Uninstall removes Glint's hooks but leaves the user's own config intact.
    func testUninstallRemovesHooksButKeepsUserConfig() throws {
        try #"{ "version": 2 }"#.write(to: configURL, atomically: true, encoding: .utf8)
        DevinHookInstaller.mergeDevinHooks(scriptPath: "/tmp/glint-report.sh", configURL: configURL)
        XCTAssertTrue(DevinHookInstaller.isInstalled(configURL: configURL))

        DevinHookInstaller.uninstall(configURL: configURL)

        XCTAssertFalse(DevinHookInstaller.isInstalled(configURL: configURL))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        XCTAssertEqual(root?["version"] as? Int, 2, "user config should survive uninstall")
    }
}
