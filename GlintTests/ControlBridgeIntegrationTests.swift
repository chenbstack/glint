import Darwin
import GhosttyKit
import XCTest
@testable import Glint

/// Uses a private control directory, the real server and the bundled CLI.
/// Never opens the user's control socket or changes their control preference.
@MainActor
final class ControlBridgeIntegrationTests: XCTestCase {
    private struct CLIResult {
        let status: Int32
        let output: String
        let error: String
    }

    private func cli(_ arguments: [String]) async throws -> CLIResult {
        let executable = ControlCLIIntegration.executableURL
        return try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CLIResult(status: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self),
                             error: String(decoding: diagnostics, as: UTF8.self))
        }.value
    }

    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/gc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private nonisolated static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                _ = strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, buffer.count)
            }
        }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    private nonisolated static func exchange(_ fd: Int32, _ object: [String: Any]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { throw POSIXError(.EIO) }
            response.append(buffer, count: n)
            if let newline = response.firstIndex(of: 0x0A) {
                return try XCTUnwrap(JSONSerialization.jsonObject(with: response.prefix(upTo: newline)) as? [String: Any])
            }
        }
    }

    func testCLIReadsAndWritesRealBackgroundTerminal() async throws {
        let root = try directory()
        let store = WorkspaceStore(activity: PaneActivityStore())
        let local = Workspace.fresh(name: "Local", accentHex: "5E5CE6", symbol: "L")
        let target = Workspace.fresh(name: "CLI", accentHex: "5E5CE6", symbol: "C")
        store.workspaces = [local, target]
        store.selectedWorkspaceID = local.id
        let pane = try XCTUnwrap(target.selectedTab?.focusedPane)
        let handle = "\(target.id.uuidString):\(pane.value)"
        let bridge = ControlBridge(runDirectory: root, isEnabled: { true })
        bridge.start()
        defer { bridge.stop() }
        XCTAssertTrue(bridge.isRunning)
        let prefix = ["--socket", bridge.socketPath]
        let listed = try await cli(prefix + ["panes", "list"])
        XCTAssertEqual(listed.status, 0, listed.error)
        XCTAssertTrue(listed.output.contains(handle))
        let firstRead = try await cli(prefix + ["pane", "read", handle])
        XCTAssertEqual(firstRead.status, 0, firstRead.error)
        XCTAssertEqual(store.selectedWorkspaceID, local.id)
        let view = store.surfaceView(workspaceID: target.id, paneID: pane, cwd: "/tmp")
        let surface = try XCTUnwrap(view.surface)
        let marker = "\u{1b}[2J\u{1b}[HCLI 你好😀\r\n"
        marker.withCString { ghostty_surface_process_output(surface, $0, UInt(marker.utf8.count)) }
        let read = try await cli(prefix + ["pane", "read", handle])
        XCTAssertEqual(read.status, 0, read.error)
        XCTAssertTrue(read.output.contains("CLI 你好😀"), read.output)
        let sent = try await cli(prefix + ["pane", "send", handle, "--text", "CLI-input-你好"])
        XCTAssertEqual(sent.status, 0, sent.error)
        let key = try await cli(prefix + ["pane", "key", handle, "left"])
        XCTAssertEqual(key.status, 0, key.error)
        XCTAssertEqual(store.selectedWorkspaceID, local.id)
        XCTAssertTrue(store.isWorkspaceRemotelyControlled(target.id))
        let focused = try await cli(prefix + ["pane", "focus", handle])
        XCTAssertEqual(focused.status, 0, focused.error)
        XCTAssertEqual(store.selectedWorkspaceID, target.id)
    }

    func testOffSwitchAndRestartRevokeEveryCommandAndOldConnections() async throws {
        let root = try directory()
        let store = WorkspaceStore(activity: PaneActivityStore())
        let local = Workspace.fresh(name: "Local", accentHex: "5E5CE6", symbol: "L")
        let target = Workspace.fresh(name: "Target", accentHex: "5E5CE6", symbol: "T")
        store.workspaces = [local, target]
        store.selectedWorkspaceID = local.id
        let pane = try XCTUnwrap(target.selectedTab?.focusedPane)
        let handle = "\(target.id.uuidString):\(pane.value)"
        var enabled = true
        let bridge = ControlBridge(runDirectory: root, isEnabled: { enabled })
        bridge.start()
        defer { bridge.stop() }
        let path = bridge.socketPath
        let oldToken = try String(contentsOfFile: bridge.tokenPath)
        let connection = try await Task.detached { try Self.connect(path) }.value
        defer { close(connection) }
        let first = try await Task.detached { try Self.exchange(connection, ["cmd": "list"]) }.value
        XCTAssertEqual(first["ok"] as? Bool, true)

        // This is the dispatch-side switch guard, independently of unlinking.
        enabled = false
        for command in ["list", "focus", "read-text", "send-text", "send-key"] {
            let response = try await Task.detached {
                try Self.exchange(connection, ["cmd": command, "pane": handle, "text": "blocked",
                                               "keys": ["enter"], "token": oldToken])
            }.value
            XCTAssertEqual(response["error"] as? String, "disabled", command)
        }
        XCTAssertEqual(store.selectedWorkspaceID, local.id)
        XCTAssertFalse(store.isWorkspaceRemotelyControlled(target.id))
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.tokenPath))
        let off = try await cli(["--socket", path, "panes", "list"])
        XCTAssertEqual(off.status, 1)
        XCTAssertTrue(off.error.contains("External control"))

        enabled = true
        bridge.start()
        let oldConnection = try await Task.detached { try Self.exchange(connection, ["cmd": "list"]) }.value
        XCTAssertEqual(oldConnection["error"] as? String, "disabled")
        let freshConnection = try await Task.detached { try Self.connect(path) }.value
        defer { close(freshConnection) }
        let staleToken = try await Task.detached {
            try Self.exchange(freshConnection, ["cmd": "read-text", "pane": handle, "token": oldToken])
        }.value
        XCTAssertEqual(staleToken["error"] as? String, "unauthorized")
        let on = try await cli(["--socket", path, "panes", "list"])
        XCTAssertEqual(on.status, 0, on.error)
        XCTAssertEqual(store.selectedWorkspaceID, local.id)
    }

    func testOversizedSocketRequestReturnsExplicitError() async throws {
        let store = WorkspaceStore(activity: PaneActivityStore())
        let bridge = ControlBridge(runDirectory: try directory(), isEnabled: { true })
        bridge.start()
        defer { bridge.stop(); withExtendedLifetime(store) {} }
        let path = bridge.socketPath
        let response = try await Task.detached { () throws -> [String: Any] in
            let fd = try Self.connect(path)
            defer { close(fd) }
            // No newline: the server must reject an oversized in-progress frame.
            let payload = Data(repeating: 0x61, count: (1 << 20) + 1)
            try payload.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                    guard n > 0 else { throw POSIXError(.EIO) }
                    sent += n
                }
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw POSIXError(.EIO) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any])
        }.value
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "request-too-large")
    }

    func testDefaultBridgeRejectsAccessWhenPreferenceIsOff() async throws {
        let store = WorkspaceStore(activity: PaneActivityStore())
        // Preserve the user's defaults; no listener is started through the toggle.
        let old = UserDefaults.standard.object(forKey: "glint.externalControlEnabled")
        UserDefaults.standard.set(false, forKey: "glint.externalControlEnabled")
        defer {
            if let old { UserDefaults.standard.set(old, forKey: "glint.externalControlEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "glint.externalControlEnabled") }
        }
        // The actual gate reads the current store's switch, not CLI metadata.
        // WorkspaceStore initially reads the persisted preference; use a fresh store.
        let disabledStore = WorkspaceStore(activity: PaneActivityStore())
        let bridge = ControlBridge(runDirectory: try directory())
        bridge.start()
        defer { bridge.stop(); withExtendedLifetime(store) {} }
        XCTAssertFalse(disabledStore.externalControlEnabled)
        let result = try await cli(["--socket", bridge.socketPath, "panes", "list"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.error.contains("disabled"))
        withExtendedLifetime(disabledStore) {}
    }

    func testCLIInstallationStateRejectsRepeatInstallAndUninstallsOnlyLink() throws {
        let root = try directory()
        let tool = root.appendingPathComponent("tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let bin = root.appendingPathComponent("bin")
        XCTAssertEqual(CLIInstallation.state(executable: tool, directory: bin), .notInstalled)
        let link = try CLIInstallation.install(executable: tool, directory: bin)
        XCTAssertEqual(CLIInstallation.state(executable: tool, directory: bin), .installed)
        XCTAssertThrowsError(try CLIInstallation.install(executable: tool, directory: bin))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), tool.path)
        try CLIInstallation.uninstall(executable: tool, directory: bin)
        XCTAssertEqual(CLIInstallation.state(executable: tool, directory: bin), .notInstalled)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path))
        XCTAssertThrowsError(try CLIInstallation.uninstall(executable: tool, directory: bin))
        _ = try CLIInstallation.install(executable: tool, directory: bin)
        XCTAssertEqual(CLIInstallation.state(executable: tool, directory: bin), .installed)
    }

    func testCLIInstallationDistinguishesExistingGlintFromDanglingLink() throws {
        let root = try directory()
        let executable = URL(fileURLWithPath: "/bin/sh")
        let other = root.appendingPathComponent("Other/Glint.app/Contents/Helpers/glint")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: other)
        let link = root.appendingPathComponent("glint")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertEqual(CLIInstallation.state(executable: executable, directory: root), .linkedElsewhere)
        XCTAssertThrowsError(try CLIInstallation.install(executable: executable, directory: root))
        XCTAssertThrowsError(try CLIInstallation.uninstall(executable: executable, directory: root))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), other.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        try FileManager.default.removeItem(at: other)
        XCTAssertEqual(CLIInstallation.state(executable: executable, directory: root), .repairable)
        _ = try CLIInstallation.install(executable: executable, directory: root)
        XCTAssertEqual(CLIInstallation.state(executable: executable, directory: root), .installed)
    }

    func testCLIUninstallRefusesReplacedFilesAndForeignLinks() throws {
        let root = try directory()
        let tool = URL(fileURLWithPath: "/bin/sh")
        let link = root.appendingPathComponent("glint")
        try Data("another command".utf8).write(to: link)
        XCTAssertEqual(CLIInstallation.state(executable: tool, directory: root), .conflict)
        XCTAssertThrowsError(try CLIInstallation.uninstall(executable: tool, directory: root))
        XCTAssertEqual(try String(contentsOf: link), "another command")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing/tool")
        XCTAssertEqual(CLIInstallation.state(executable: tool, directory: root), .conflict)
        XCTAssertThrowsError(try CLIInstallation.uninstall(executable: tool, directory: root))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/missing/tool")
    }

    func testCopiedAgentInstructionsChooseMatchingBuildWithoutCredentials() {
        let binary = URL(fileURLWithPath: "/Applications/Glint's App.app/Contents/Helpers/glint")
        let debug = ControlCLIIntegration.agentInstructions(executable: binary, debug: true)
        let release = ControlCLIIntegration.agentInstructions(executable: binary, debug: false)
        XCTAssertTrue(debug.contains("Glint'\\''s App.app"))
        XCTAssertTrue(debug.contains("--debug panes list"))
        XCTAssertTrue(release.contains("pane read PANE"))
        XCTAssertFalse(release.contains("--debug"))
        XCTAssertFalse(debug.contains("control.token"))
    }
}
