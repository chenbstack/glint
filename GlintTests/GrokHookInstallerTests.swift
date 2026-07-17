import XCTest
@testable import Glint

final class GrokHookInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var hooksURL: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-grok-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        hooksURL = tempDir.appendingPathComponent("glint.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNotInstalledWhenHooksMissing() {
        XCTAssertFalse(GrokHookInstaller.isInstalled(hooksURL: hooksURL))
    }

    func testHookEventsCoverStatusMachineAndGrokSurface() {
        XCTAssertEqual(
            GrokHookInstaller.hookEvents,
            [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "PreCompact",
                "Stop",
                "StopFailure",
            ]
        )
        // Grok has no PermissionRequest hook event (approvals are TUI-native).
        XCTAssertFalse(GrokHookInstaller.hookEvents.contains("PermissionRequest"))
        // NeedsReply is remapped inside glint-report.sh from PreToolUse +
        // ask_user_question — not a registered Grok hook event name.
        XCTAssertFalse(GrokHookInstaller.hookEvents.contains("NeedsReply"))
    }

    func testMergeRegistersHooksTaggedAsGrok() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        XCTAssertTrue(GrokHookInstaller.isInstalled(hooksURL: hooksURL))

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let hooks = (root?["hooks"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(GrokHookInstaller.hookEvents))

        let stop = (hooks["Stop"] as? [Any])?.first as? [String: Any]
        let inner = (stop?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(inner?["command"] as? String, "/tmp/glint-report.sh Stop grok")
        XCTAssertEqual(inner?["type"] as? String, "command")
    }

    /// Grok rejects matchers on lifecycle events; empty/omitted = match-all on
    /// tool events. Official plugins omit matcher entirely — we must too.
    func testMergeOmitsMatcherOnEveryEvent() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let hooks = (root?["hooks"] as? [String: Any]) ?? [:]
        for event in GrokHookInstaller.hookEvents {
            let group = (hooks[event] as? [Any])?.first as? [String: Any]
            XCTAssertNotNil(group, "missing group for \(event)")
            XCTAssertNil(group?["matcher"],
                         "\(event) must not carry matcher (Grok rejects it on lifecycle events)")
            // And the documented lifecycle set is a subset of what we register.
            if GrokHookInstaller.lifecycleEventsRejectingMatcher.contains(event) {
                XCTAssertNil(group?["matcher"])
            }
        }
    }

    func testMergeIsIdempotent() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        let first = try Data(contentsOf: hooksURL)
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        let second = try Data(contentsOf: hooksURL)
        XCTAssertEqual(first, second)
    }

    func testUninstallRemovesHooksFile() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        XCTAssertTrue(GrokHookInstaller.isInstalled(hooksURL: hooksURL))

        GrokHookInstaller.uninstall(hooksURL: hooksURL)

        XCTAssertFalse(GrokHookInstaller.isInstalled(hooksURL: hooksURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }
}
