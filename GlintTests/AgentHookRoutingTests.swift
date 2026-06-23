import XCTest
@testable import Glint

final class AgentHookRoutingTests: XCTestCase {
    func testDirectPaneEnvelopeStillDecodes() throws {
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

    func testSharedCodexEnvelopeDecodesRoutingMetadata() throws {
        let session = Data("019eed23-2baa-7043-be10-c1254064dbee".utf8).base64EncodedString()
        let cwd = Data("/Volumes/Work Space/repo".utf8).base64EncodedString()
        let line = try JSONSerialization.data(withJSONObject: [
            "hook": "UserPromptSubmit",
            "agent": "codex",
            "session_b64": session,
            "cwd_b64": cwd,
        ])

        XCTAssertEqual(AgentBridge.decodeHookLine(line), [
            "hook": "UserPromptSubmit",
            "agent": "codex",
            "session": "019eed23-2baa-7043-be10-c1254064dbee",
            "cwd": "/Volumes/Work Space/repo",
        ])
    }

    func testEnvelopeWithoutPaneOrSessionIsRejected() throws {
        let line = try XCTUnwrap(#"{"hook":"Stop","agent":"codex"}"#.data(using: .utf8))
        XCTAssertNil(AgentBridge.decodeHookLine(line))
    }

    @MainActor
    func testKnownShellDoesNotFallBackToStaleCodexState() {
        XCTAssertNil(WorkspaceStore.codexRoutingCandidateKind(
            foregroundProcessName: "zsh",
            polledProcessName: "codex",
            stateKind: .codex
        ))
    }

    @MainActor
    func testMissingProcessInfoCanUseCurrentCodexState() {
        XCTAssertEqual(WorkspaceStore.codexRoutingCandidateKind(
            foregroundProcessName: nil,
            polledProcessName: nil,
            stateKind: .codex
        ), .codex)
    }

    @MainActor
    func testRecentReturnCanRebindBoundCodexPaneForNewSession() {
        let key = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 0)
        )
        let now = Date()

        let routed = WorkspaceStore.selectCodexRoutingPane(
            codexPanes: [key],
            boundPanes: [key],
            recentPaneReturns: [key: now.addingTimeInterval(-1)],
            cwd: "/tmp",
            now: now,
            cwdForPane: { _ in "/tmp" }
        )

        XCTAssertEqual(routed, key)
    }

    @MainActor
    func testLatestRecentReturnWinsAmongCodexPanes() {
        let older = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 0)
        )
        let latest = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 1)
        )
        let now = Date()

        let routed = WorkspaceStore.selectRecentCodexRoutingPane(
            codexPanes: [older, latest],
            recentPaneReturns: [
                older: now.addingTimeInterval(-2),
                latest: now.addingTimeInterval(-1),
            ],
            now: now
        )

        XCTAssertEqual(routed, latest)
    }

    @MainActor
    func testPreferredRecentReturnWinsForExistingCodexRoute() {
        let routePane = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 0)
        )
        let otherPane = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 1)
        )
        let now = Date()

        let routed = WorkspaceStore.selectRecentCodexRoutingPane(
            codexPanes: [routePane, otherPane],
            recentPaneReturns: [
                routePane: now.addingTimeInterval(-2),
                otherPane: now.addingTimeInterval(-1),
            ],
            now: now,
            preferredPane: routePane
        )

        XCTAssertEqual(routed, routePane)
    }

    @MainActor
    func testRebindingCodexRouteReleasesDisplacedSessionForTargetPane() {
        let pane1 = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 0)
        )
        let pane2 = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 1)
        )
        let now = Date()
        var routes = [
            "sessionA": WorkspaceStore.CodexSessionRoute(
                pane: pane1,
                lastSeen: now.addingTimeInterval(-10)
            ),
            "sessionB": WorkspaceStore.CodexSessionRoute(
                pane: pane2,
                lastSeen: now.addingTimeInterval(-5)
            ),
        ]
        var releasedSessions: [String] = []

        WorkspaceStore.replaceCodexSessionRoute(
            routes: &routes,
            session: "sessionB",
            pane: pane1,
            now: now,
            releaseClaim: { releasedSessions.append($0) }
        )

        XCTAssertNil(routes["sessionA"])
        XCTAssertEqual(routes["sessionB"]?.pane, pane1)
        XCTAssertEqual(routes["sessionB"]?.lastSeen, now)
        XCTAssertEqual(Set(routes.keys), Set(["sessionB"]))
        XCTAssertEqual(releasedSessions, ["sessionA"])
    }

    @MainActor
    func testCwdFallbackDoesNotStealAlreadyBoundCodexPane() {
        let key = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 0)
        )

        let routed = WorkspaceStore.selectCodexRoutingPane(
            codexPanes: [key],
            boundPanes: [key],
            recentPaneReturns: [:],
            cwd: "/tmp",
            now: Date(),
            cwdForPane: { _ in "/tmp" }
        )

        XCTAssertNil(routed)
    }

    @MainActor
    func testCwdFallbackStillRoutesUniqueUnboundCodexPane() {
        let key = WorkspaceStore.WorkspacePaneKey(
            workspace: UUID(),
            pane: PaneID(value: 0)
        )

        let routed = WorkspaceStore.selectCodexRoutingPane(
            codexPanes: [key],
            boundPanes: [],
            recentPaneReturns: [:],
            cwd: "/tmp",
            now: Date(),
            cwdForPane: { _ in "/tmp" }
        )

        XCTAssertEqual(routed, key)
    }

    func testReporterKeepsCodexCommandStableAndDrainsPayload() throws {
        let body = AgentHookInstaller.scriptBody
        XCTAssertTrue(body.contains("plutil -extract session_id"))
        XCTAssertTrue(body.contains("agent-debug.sock"))
        XCTAssertFalse(body.contains(#"${3:-"#))
        XCTAssertFalse(body.contains("CodexPaneShim"))

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

    func testReporterForwardsSharedCodexMetadataOverUnixSocket() throws {
        // Unix-domain socket paths are capped at 104 bytes on Darwin; XCTest's
        // default temporary directory is already too deep.
        let root = URL(fileURLWithPath: "/tmp/gr-\(UUID().uuidString)", isDirectory: true)
        let runDirectory = root.appendingPathComponent(".glint/run", isDirectory: true)
        let socket = runDirectory.appendingPathComponent("agent.sock")
        let script = root.appendingPathComponent("glint-report.sh")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
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
        environment["HOME"] = root.path
        environment.removeValue(forKey: "GLINT_PANE_ID")
        environment.removeValue(forKey: "GLINT_AGENT_SOCK")
        reporter.environment = environment
        let input = Pipe()
        reporter.standardInput = input
        try reporter.run()
        input.fileHandleForWriting.write(
            Data(#"{"session_id":"session-123","cwd":"/Volumes/Work Space/repo"}"#.utf8)
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
            "hook": "UserPromptSubmit",
            "agent": "codex",
            "session": "session-123",
            "cwd": "/Volumes/Work Space/repo",
        ])
    }

    @MainActor
    func testCanonicalizeCwdResolvesDarwinPrivateSymlinks() {
        // Darwin's /tmp -> /private/tmp symlink is the canonical case that
        // broke first-prompt routing when Codex reported one form and the
        // pane's OSC 7 reported the other.
        XCTAssertEqual(
            WorkspaceStore.canonicalizeCwd("/tmp"),
            WorkspaceStore.canonicalizeCwd("/private/tmp")
        )
        XCTAssertEqual(
            WorkspaceStore.canonicalizeCwd("/var"),
            WorkspaceStore.canonicalizeCwd("/private/var")
        )
    }

    @MainActor
    func testCanonicalizeCwdResolvesUserSymlink() throws {
        let root = URL(
            fileURLWithPath: "/tmp/gccwd-\(UUID().uuidString)",
            isDirectory: true
        )
        let real = root.appendingPathComponent("real-dir", isDirectory: true)
        let link = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            WorkspaceStore.canonicalizeCwd(real.path),
            WorkspaceStore.canonicalizeCwd(link.path)
        )
    }

    @MainActor
    func testClaimCodexSessionIsIdempotentForSameProcess() {
        let session = "claim-\(UUID().uuidString)"
        defer { WorkspaceStore.releaseCodexSessionClaim(session) }

        XCTAssertTrue(WorkspaceStore.tryClaimCodexSession(session, now: Date()))
        // Same-process re-claim must succeed (route can be rebuilt after
        // the routing cache evicts our entry but the file persists).
        XCTAssertTrue(WorkspaceStore.tryClaimCodexSession(session, now: Date()))
    }

    @MainActor
    func testReleaseCodexSessionClaimOnlyDropsOurClaim() throws {
        let session = "release-\(UUID().uuidString)"
        XCTAssertTrue(WorkspaceStore.tryClaimCodexSession(session, now: Date()))
        WorkspaceStore.releaseCodexSessionClaim(session)
        // Re-claiming after release must succeed because the file is gone.
        XCTAssertTrue(WorkspaceStore.tryClaimCodexSession(session, now: Date()))
        WorkspaceStore.releaseCodexSessionClaim(session)
    }

    func testReporterLogsDiagnosticWhenSessionIdMissing() throws {
        let root = URL(fileURLWithPath: "/tmp/grm-\(UUID().uuidString)", isDirectory: true)
        let runDirectory = root.appendingPathComponent(".glint/run", isDirectory: true)
        let script = root.appendingPathComponent("glint-report.sh")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try AgentHookInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: "/bin/sh")
        reporter.arguments = [script.path, "PreToolUse", "codex"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment.removeValue(forKey: "GLINT_PANE_ID")
        environment.removeValue(forKey: "GLINT_AGENT_SOCK")
        reporter.environment = environment
        let input = Pipe()
        let stderrPipe = Pipe()
        reporter.standardInput = input
        reporter.standardError = stderrPipe
        try reporter.run()
        // Payload that doesn't carry session_id — would otherwise drop silently
        // and leave the pane frozen with no diagnostic.
        input.fileHandleForWriting.write(Data(#"{"cwd":"/tmp/repo"}"#.utf8))
        try input.fileHandleForWriting.close()
        reporter.waitUntilExit()
        XCTAssertEqual(reporter.terminationStatus, 0)

        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: stderr, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.contains("missing session_id"),
            "expected stderr diagnostic, got: \(text)"
        )
    }

    func testReporterPrefersExplicitSocketWithoutBroadcasting() throws {
        let root = URL(fileURLWithPath: "/tmp/gp-\(UUID().uuidString)", isDirectory: true)
        let runDirectory = root.appendingPathComponent(".glint/run", isDirectory: true)
        let explicitSocket = root.appendingPathComponent("explicit.sock")
        let debugSocket = runDirectory.appendingPathComponent("agent-debug.sock")
        let script = root.appendingPathComponent("glint-report.sh")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try AgentHookInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let explicitOutput = Pipe()
        let explicitListener = Process()
        explicitListener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        explicitListener.arguments = ["-lU", explicitSocket.path]
        explicitListener.standardOutput = explicitOutput
        try explicitListener.run()
        defer { if explicitListener.isRunning { explicitListener.terminate() } }

        let debugListener = Process()
        debugListener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        debugListener.arguments = ["-lU", debugSocket.path]
        try debugListener.run()
        defer { if debugListener.isRunning { debugListener.terminate() } }

        let socketDeadline = Date().addingTimeInterval(1)
        while (!FileManager.default.fileExists(atPath: explicitSocket.path)
               || !FileManager.default.fileExists(atPath: debugSocket.path)),
              Date() < socketDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: explicitSocket.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugSocket.path))

        let reporter = Process()
        reporter.executableURL = URL(fileURLWithPath: "/bin/sh")
        reporter.arguments = [script.path, "UserPromptSubmit", "codex"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["GLINT_PANE_ID"] = "workspace:1"
        environment["GLINT_AGENT_SOCK"] = explicitSocket.path
        reporter.environment = environment
        let input = Pipe()
        reporter.standardInput = input
        try reporter.run()
        input.fileHandleForWriting.write(
            Data(#"{"session_id":"session-explicit","cwd":"/tmp/repo"}"#.utf8)
        )
        try input.fileHandleForWriting.close()
        reporter.waitUntilExit()
        XCTAssertEqual(reporter.terminationStatus, 0)

        let deadline = Date().addingTimeInterval(3)
        while explicitListener.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(explicitListener.isRunning)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(debugListener.isRunning, "reporter unexpectedly broadcast to debug socket")
        let line = explicitOutput.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(AgentBridge.decodeHookLine(line)?["session"], "session-explicit")
    }
}
