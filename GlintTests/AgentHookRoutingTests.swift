import XCTest
@testable import Glint

final class AgentHookRoutingTests: XCTestCase {
    func testAttentionRankDoesNotLetThinkingHideCompletedSibling() {
        XCTAssertEqual(
            PaneAgentStatus.bestAttentionRank(in: [.thinking, .justCompleted]),
            PaneAgentStatus.justCompleted.attentionRank
        )
    }

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
        // Grok's hook payload uses camelCase sessionId; also GROK_SESSION_ID env.
        XCTAssertTrue(body.contains("plutil -extract sessionId"))
        XCTAssertTrue(body.contains("GROK_SESSION_ID"))
        // Dual-hook suppression: Claude-compat entry under Grok must no-op.
        XCTAssertTrue(body.contains("[ \"$AGENT\" != \"grok\" ]"))
        // ask_user_question / exit_plan_mode → NeedsReply for agent=grok.
        XCTAssertTrue(body.contains("ask_user_question"))
        XCTAssertTrue(body.contains("exit_plan_mode"))
        XCTAssertTrue(body.contains("NeedsReply"))
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
        reporter.arguments = [script.path, "PermissionRequest", "codex"]
        var environment = ProcessInfo.processInfo.environment
        environment["GLINT_PANE_ID"] = "12345678-1234-1234-1234-123456789ABC:7"
        environment["GLINT_AGENT_SOCK"] = socket.path
        reporter.environment = environment
        let input = Pipe()
        reporter.standardInput = input
        try reporter.run()
        input.fileHandleForWriting.write(
            Data(#"{"session_id":"session-123","turn_id":"turn-123","transcript_path":"/tmp/codex.jsonl","cwd":"/tmp/repo"}"#.utf8)
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
            "hook": "PermissionRequest",
            "agent": "codex",
            "session": "session-123",
            "turn": "turn-123",
            "transcript": "/tmp/codex.jsonl",
        ])
    }

    /// Grok's ask_user_question blocks waiting for the user — the shared
    /// reporter remaps PreToolUse + toolName=ask_user_question → NeedsReply
    /// and accepts camelCase sessionId from Grok's hook payload.
    func testReporterRemapsGrokAskUserQuestionToNeedsReply() throws {
        let decoded = try runReporter(
            hook: "PreToolUse",
            agent: "grok",
            pane: "12345678-1234-1234-1234-123456789ABC:9",
            stdinJSON: #"{"sessionId":"019f6966-b5a8-77f0-89a4-109ba759b539","toolName":"ask_user_question","cwd":"/tmp/repo"}"#,
            extraEnv: nil,
            expectSocketTraffic: true
        )
        XCTAssertEqual(decoded, [
            "pane": "12345678-1234-1234-1234-123456789ABC:9",
            "hook": "NeedsReply",
            "agent": "grok",
            "session": "019f6966-b5a8-77f0-89a4-109ba759b539",
        ])
    }

    /// Plan approval via exit_plan_mode is the same "blocked on user" surface.
    func testReporterRemapsGrokExitPlanModeToNeedsReply() throws {
        let decoded = try runReporter(
            hook: "PreToolUse",
            agent: "grok",
            pane: "12345678-1234-1234-1234-123456789ABC:a",
            stdinJSON: #"{"sessionId":"sess-plan-1","toolName":"exit_plan_mode"}"#,
            extraEnv: nil,
            expectSocketTraffic: true
        )
        XCTAssertEqual(decoded?["hook"] as? String, "NeedsReply")
        XCTAssertEqual(decoded?["agent"] as? String, "grok")
        XCTAssertEqual(decoded?["session"] as? String, "sess-plan-1")
    }

    /// When the payload lacks session fields, GROK_SESSION_ID still captures id.
    func testReporterFallsBackToGrokSessionIdEnv() throws {
        let decoded = try runReporter(
            hook: "UserPromptSubmit",
            agent: "grok",
            pane: "12345678-1234-1234-1234-123456789ABC:b",
            stdinJSON: #"{"cwd":"/tmp/repo"}"#,
            extraEnv: ["GROK_SESSION_ID": "from-env-session-id"],
            expectSocketTraffic: true
        )
        XCTAssertEqual(decoded?["hook"] as? String, "UserPromptSubmit")
        XCTAssertEqual(decoded?["agent"] as? String, "grok")
        XCTAssertEqual(decoded?["session"] as? String, "from-env-session-id")
    }

    /// Claude-compat dual-fire under Grok must not reach Glint — otherwise
    /// agent=claude + PreToolUse overwrites NeedsReply from the Grok entry.
    func testReporterSkipsClaudeEntryWhenGrokSessionIdPresent() throws {
        let decoded = try runReporter(
            hook: "PreToolUse",
            agent: "claude",
            pane: "12345678-1234-1234-1234-123456789ABC:c",
            stdinJSON: #"{"sessionId":"should-not-matter","toolName":"ask_user_question"}"#,
            extraEnv: ["GROK_SESSION_ID": "active-grok-session"],
            expectSocketTraffic: false
        )
        XCTAssertNil(decoded, "Claude-compat report under Grok must be suppressed")
    }

    /// Ordinary Claude sessions (no GROK_SESSION_ID) still report normally.
    func testReporterStillForwardsClaudeWithoutGrokSessionId() throws {
        let decoded = try runReporter(
            hook: "UserPromptSubmit",
            agent: "claude",
            pane: "12345678-1234-1234-1234-123456789ABC:d",
            stdinJSON: #"{"session_id":"claude-sess-1"}"#,
            extraEnv: nil,
            expectSocketTraffic: true
        )
        XCTAssertEqual(decoded, [
            "pane": "12345678-1234-1234-1234-123456789ABC:d",
            "hook": "UserPromptSubmit",
            "agent": "claude",
            "session": "claude-sess-1",
        ])
    }

    /// Shared helper: spin up a Unix-domain listener, run the reporter once,
    /// return the decoded envelope (or nil when nothing was sent).
    @discardableResult
    private func runReporter(
        hook: String,
        agent: String,
        pane: String,
        stdinJSON: String,
        extraEnv: [String: String]?,
        expectSocketTraffic: Bool
    ) throws -> [String: String]? {
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
        reporter.arguments = [script.path, hook, agent]
        var environment = ProcessInfo.processInfo.environment
        environment["GLINT_PANE_ID"] = pane
        environment["GLINT_AGENT_SOCK"] = socket.path
        // Clear any ambient GROK_SESSION_ID from the test runner's env so
        // Claude-path tests don't inherit a real Grok session.
        environment.removeValue(forKey: "GROK_SESSION_ID")
        if let extraEnv {
            for (k, v) in extraEnv { environment[k] = v }
        }
        reporter.environment = environment
        let input = Pipe()
        reporter.standardInput = input
        try reporter.run()
        input.fileHandleForWriting.write(Data(stdinJSON.utf8))
        try input.fileHandleForWriting.close()
        reporter.waitUntilExit()
        XCTAssertEqual(reporter.terminationStatus, 0)

        if expectSocketTraffic {
            let deadline = Date().addingTimeInterval(3)
            while listener.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertFalse(listener.isRunning, "reporter did not connect to the Unix socket")
            let line = listenerOutput.fileHandleForReading.readDataToEndOfFile()
            return AgentBridge.decodeHookLine(line)
        } else {
            // Suppression path: no connect. Don't wait for nc -l to exit —
            // kill after a brief grace period and assert empty output.
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if listener.isRunning { listener.terminate() }
            let line = listenerOutput.fileHandleForReading.readDataToEndOfFile()
            XCTAssertTrue(line.isEmpty, "expected no socket traffic, got: \(String(data: line, encoding: .utf8) ?? "<bin>")")
            return nil
        }
    }

    func testCodexApprovalReviewerComesFromMatchingTurnContext() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-\(UUID().uuidString).jsonl")
        let fixture = """
        {"type":"turn_context","payload":{"turn_id":"turn-user","approvals_reviewer":"user"}}
        {"type":"turn_context","payload":{"turn_id":"turn-auto","approvals_reviewer":"auto_review"}}
        """
        try fixture.write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript) }

        XCTAssertEqual(
            AgentBridge.codexApprovalReviewer(
                transcriptPath: transcript.path,
                turnID: "turn-auto"
            ),
            "auto_review"
        )
        XCTAssertEqual(
            AgentBridge.codexApprovalReviewer(
                transcriptPath: transcript.path,
                turnID: "turn-user"
            ),
            "user"
        )
        XCTAssertNil(
            AgentBridge.codexApprovalReviewer(
                transcriptPath: transcript.path,
                turnID: "turn-missing"
            )
        )
    }

    /// The tail window must drop turn_context lines older than `maxTailBytes`,
    /// including a matching one, so a multi-MB session can't stall routing. A
    /// tiny window keeps the fixture cheap while still exercising the
    /// partial-first-line drop the production 8 MB cap relies on.
    func testCodexApprovalReviewerIgnoresTurnContextBeyondTailWindow() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tail-\(UUID().uuidString).jsonl")
        let decoy = #"{"type":"turn_context","payload":{"turn_id":"turn-x","approvals_reviewer":"user"}}"#
        let live = #"{"type":"turn_context","payload":{"turn_id":"turn-x","approvals_reviewer":"auto_review"}}"#
        // One long newline-free line pushes the decoy out of the window; the
        // read offset lands inside it, so this also covers the
        // drop-up-to-first-newline branch.
        let filler = String(repeating: "x", count: 512)
        let window: UInt64 = 128

        // Decoy sits beyond the window → only the tail `live` line is visible,
        // so we resolve auto_review rather than the head's user.
        try "\(decoy)\n\(filler)\n\(live)\n".write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript) }
        XCTAssertEqual(
            AgentBridge.codexApprovalReviewer(
                transcriptPath: transcript.path,
                turnID: "turn-x",
                maxTailBytes: window
            ),
            "auto_review"
        )

        // With no match in the tail, the head decoy must not be seen — a
        // broken window would return "user" here.
        try "\(decoy)\n\(filler)\n".write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertNil(
            AgentBridge.codexApprovalReviewer(
                transcriptPath: transcript.path,
                turnID: "turn-x",
                maxTailBytes: window
            )
        )
    }

    @MainActor
    func testCodexAutoReviewPermissionRequestDoesNotWaitForUser() {
        XCTAssertEqual(
            WorkspaceStore.permissionRequestStatus(
                kind: .codex,
                approvalsReviewer: "auto_review"
            ),
            .thinking
        )
        // Any reviewer other than auto_review (incl. future/unknown values)
        // still surfaces as needs-permission: a false alert is safe, silently
        // suppressing a real prompt is not.
        XCTAssertEqual(
            WorkspaceStore.permissionRequestStatus(
                kind: .codex,
                approvalsReviewer: "some_future_reviewer"
            ),
            .needsPermission
        )
        XCTAssertEqual(
            WorkspaceStore.permissionRequestStatus(kind: .codex, approvalsReviewer: "user"),
            .needsPermission
        )
        XCTAssertEqual(
            WorkspaceStore.permissionRequestStatus(kind: .codex, approvalsReviewer: nil),
            .needsPermission
        )
        XCTAssertEqual(
            WorkspaceStore.permissionRequestStatus(
                kind: .claude,
                approvalsReviewer: "auto_review"
            ),
            .needsPermission
        )
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
