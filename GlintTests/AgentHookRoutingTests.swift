import XCTest
@testable import Glint

final class AgentHookRoutingTests: XCTestCase {
    func testDirectPaneEnvelopeDecodes() throws {
        let line = try XCTUnwrap(
            #"{"pane":"12345678-1234-1234-1234-123456789ABC:7","hook":"Stop","agent":"claude"}"#
                .data(using: .utf8)
        )

        XCTAssertEqual(AgentBridge.decodeHookLine(line), [
            "pane": "12345678-1234-1234-1234-123456789ABC:7",
            "hook": "Stop",
            "agent": "claude",
        ])
    }

    func testEnvelopeWithSessionB64DecodesSession() throws {
        let session = Data("019eed23-2baa-7043-be10-c1254064dbee".utf8).base64EncodedString()
        let line = try JSONSerialization.data(withJSONObject: [
            "pane": "12345678-1234-1234-1234-123456789ABC:7",
            "hook": "UserPromptSubmit",
            "agent": "codex",
            "session_b64": session,
        ])

        XCTAssertEqual(AgentBridge.decodeHookLine(line), [
            "pane": "12345678-1234-1234-1234-123456789ABC:7",
            "hook": "UserPromptSubmit",
            "agent": "codex",
            "session": "019eed23-2baa-7043-be10-c1254064dbee",
        ])
    }

    func testEnvelopeWithoutPaneIsRejected() throws {
        let line = try XCTUnwrap(#"{"hook":"Stop","agent":"codex"}"#.data(using: .utf8))
        XCTAssertNil(AgentBridge.decodeHookLine(line))
    }

    func testReporterScriptParses() throws {
        let body = AgentHookInstaller.scriptBody
        XCTAssertTrue(body.contains("plutil -extract session_id"))
        XCTAssertFalse(body.contains("agent-debug.sock"),
                       "broadcast fallback should be gone after the direct-route revert")
        XCTAssertFalse(body.contains("cwd_b64"),
                       "cwd metadata is no longer needed once routing is pane-based")

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-reporter-\(UUID().uuidString)")
        try body.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", temp.path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }

    /// End-to-end: the reporter inherits PANE+SOCK from env (the only path
    /// supported now that codex and claude share the direct route) and emits
    /// a pane-addressed envelope carrying the extracted session_id.
    func testReporterForwardsPaneAddressedEnvelopeOverUnixSocket() throws {
        // Unix-domain socket paths are capped at 104 bytes on Darwin; XCTest's
        // default temporary directory is already too deep.
        let root = URL(fileURLWithPath: "/tmp/gr-\(UUID().uuidString)", isDirectory: true)
        let socket = root.appendingPathComponent("agent.sock")
        let script = root.appendingPathComponent("glint-report.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AgentHookInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let listenerOutput = Pipe()
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-lU", socket.path]
        listener.standardOutput = listenerOutput
        try listener.run()
        defer { if listener.isRunning { listener.terminate() } }
        let socketDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: socket.path), Date() < socketDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))

        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: "/bin/sh")
        reporter.arguments = [script.path, "UserPromptSubmit", "codex"]
        var environment = ProcessInfo.processInfo.environment
        environment["GLINT_PANE_ID"] = "12345678-1234-1234-1234-123456789ABC:7"
        environment["GLINT_AGENT_SOCK"] = socket.path
        reporter.environment = environment
        let input = Pipe()
        reporter.standardInput = input
        try reporter.run()
        input.fileHandleForWriting.write(
            Data(#"{"session_id":"session-123","cwd":"/tmp/repo"}"#.utf8)
        )
        try input.fileHandleForWriting.close()
        reporter.waitUntilExit()
        XCTAssertEqual(reporter.terminationStatus, 0)

        let deadline = Date().addingTimeInterval(3)
        while listener.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(listener.isRunning, "reporter did not connect to the Unix socket")
        let line = listenerOutput.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(AgentBridge.decodeHookLine(line), [
            "pane": "12345678-1234-1234-1234-123456789ABC:7",
            "hook": "UserPromptSubmit",
            "agent": "codex",
            "session": "session-123",
        ])
    }

    /// Without PANE/SOCK the reporter must still exit 0 and drain stdin —
    /// blocking the agent on a missing bridge would freeze the CLI.
    func testReporterExitsCleanlyWhenPaneEnvIsMissing() throws {
        let root = URL(fileURLWithPath: "/tmp/grm-\(UUID().uuidString)", isDirectory: true)
        let script = root.appendingPathComponent("glint-report.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AgentHookInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: "/bin/sh")
        reporter.arguments = [script.path, "PreToolUse", "codex"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GLINT_PANE_ID")
        environment.removeValue(forKey: "GLINT_AGENT_SOCK")
        reporter.environment = environment
        let input = Pipe()
        reporter.standardInput = input
        try reporter.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s"}"#.utf8))
        try input.fileHandleForWriting.close()
        reporter.waitUntilExit()
        XCTAssertEqual(reporter.terminationStatus, 0)
    }
}
