import XCTest
@testable import Glint

final class OmpHookInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var extensionURL: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-omp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        extensionURL = tempDir.appendingPathComponent("hooks/omp-agent-bridge.ts")
        settingsURL = tempDir.appendingPathComponent("omp-agent/settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        extensionURL = nil
        settingsURL = nil
    }

    func testInstallWritesExtensionAndRegistersSettings() {
        XCTAssertFalse(OmpHookInstaller.isInstalled(extensionURL: extensionURL, settingsURL: settingsURL))
        OmpHookInstaller.installIfNeeded(
            socketPath: "/tmp/glint-test.sock",
            extensionURL: extensionURL,
            settingsURL: settingsURL
        )
        XCTAssertTrue(OmpHookInstaller.isInstalled(extensionURL: extensionURL, settingsURL: settingsURL))

        let body = try! String(contentsOf: extensionURL)
        XCTAssertTrue(body.contains(OmpHookInstaller.marker))
        XCTAssertTrue(body.contains("\"omp\""))
        XCTAssertTrue(body.contains("UserPromptSubmit"))
        XCTAssertTrue(body.contains("PermissionRequest"))
        XCTAssertTrue(body.contains("StopFailure"))
        XCTAssertTrue(body.contains("NeedsReply"))
        XCTAssertTrue(body.contains("GLINT_PANE_ID"))
        XCTAssertTrue(body.contains("client.end(line)"))

        let settings = try! JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let list = settings["extensions"] as! [String]
        XCTAssertTrue(list.contains(OmpHookInstaller.settingsExtensionRef))
    }

    func testInstallIsIdempotent() {
        OmpHookInstaller.installIfNeeded(socketPath: "/tmp/a.sock",
                                         extensionURL: extensionURL,
                                         settingsURL: settingsURL)
        let firstBody = try! String(contentsOf: extensionURL)
        let firstSettings = try! Data(contentsOf: settingsURL)
        OmpHookInstaller.installIfNeeded(socketPath: "/tmp/b.sock",
                                         extensionURL: extensionURL,
                                         settingsURL: settingsURL)
        let secondBody = try! String(contentsOf: extensionURL)
        let secondSettings = try! Data(contentsOf: settingsURL)
        XCTAssertEqual(firstBody, secondBody)
        // settings should still list exactly one Glint ref
        let root = try! JSONSerialization.jsonObject(with: secondSettings) as! [String: Any]
        let list = root["extensions"] as! [String]
        XCTAssertEqual(list.filter { $0 == OmpHookInstaller.settingsExtensionRef }.count, 1)
        XCTAssertEqual(firstSettings, secondSettings)
    }

    func testInstallPreservesOtherSettingsKeysAndExtensions() throws {
        let prior: [String: Any] = [
            "theme": "dark",
            "extensions": ["~/other-ext.ts"],
        ]
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: prior, options: [.prettyPrinted])
        try data.write(to: settingsURL)

        OmpHookInstaller.installIfNeeded(socketPath: "/tmp/a.sock",
                                         extensionURL: extensionURL,
                                         settingsURL: settingsURL)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertEqual(root["theme"] as? String, "dark")
        let list = root["extensions"] as! [String]
        XCTAssertTrue(list.contains("~/other-ext.ts"))
        XCTAssertTrue(list.contains(OmpHookInstaller.settingsExtensionRef))
    }

    func testUninstallRemovesFileAndSettingsEntry() throws {
        // Seed a settings file with an unrelated extension so we verify we
        // only remove our own entry, not the whole file.
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let prior: [String: Any] = ["extensions": ["~/keep.ts"]]
        try JSONSerialization.data(withJSONObject: prior).write(to: settingsURL)

        OmpHookInstaller.installIfNeeded(socketPath: "/tmp/a.sock",
                                         extensionURL: extensionURL,
                                         settingsURL: settingsURL)
        XCTAssertTrue(OmpHookInstaller.isInstalled(extensionURL: extensionURL, settingsURL: settingsURL))

        OmpHookInstaller.uninstall(extensionURL: extensionURL, settingsURL: settingsURL)
        XCTAssertFalse(OmpHookInstaller.isInstalled(extensionURL: extensionURL, settingsURL: settingsURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extensionURL.path))

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let list = root["extensions"] as! [String]
        XCTAssertEqual(list, ["~/keep.ts"])
    }

    func testUninstallLeavesForeignExtensionFileAlone() throws {
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "// not glint managed\nexport default function () {}\n"
            .write(to: extensionURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(OmpHookInstaller.isInstalled(extensionURL: extensionURL, settingsURL: settingsURL))
        OmpHookInstaller.uninstall(extensionURL: extensionURL, settingsURL: settingsURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path))
    }

    func testExtensionBodyExportsDefaultFactory() {
        XCTAssertTrue(OmpHookInstaller.extensionBody.contains("export default function"))
        XCTAssertTrue(OmpHookInstaller.extensionBody.contains("pi.on(\"agent_start\""))
        XCTAssertTrue(OmpHookInstaller.extensionBody.contains("pi.on(\"agent_end\""))
        XCTAssertTrue(OmpHookInstaller.extensionBody.contains("pi.on(\"tool_call\""))
        XCTAssertTrue(OmpHookInstaller.extensionBody.contains("pi.on(\"tool_approval_requested\""))
    }
}
