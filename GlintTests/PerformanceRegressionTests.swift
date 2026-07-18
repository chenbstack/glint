import XCTest
import Combine
import QuartzCore
@testable import Glint

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    private func workspace(archived: Bool) -> Workspace {
        let paneID = PaneID(value: 0)
        let tabID = TabID(value: 0)
        return Workspace(
            id: UUID(), name: "repo", userNamed: false,
            accentHex: "5E5CE6", symbol: "terminal",
            tabs: [WorkspaceTab(id: tabID, name: nil, root: .leaf(paneID), focusedPane: paneID)],
            selectedTabID: tabID, nextTabSeq: 1,
            panes: [paneID: Pane(id: paneID, title: "Terminal")], nextPaneSeq: 1,
            archived: archived,
            source: WorkspaceSource(kind: .localRepo, repoRoot: "/tmp/repo")
        )
    }

    func testGitTimerPolicySkipsArchivedWorkspace() {
        let workspace = workspace(archived: true)

        XCTAssertFalse(WorkspaceStore.shouldTimerPoll(
            workspace, selectedWorkspaceID: workspace.id,
            effectiveGitPath: "/tmp/repo", appIsActive: true
        ))
    }

    func testGitTimerPolicySkipsWhenAppIsInactive() {
        let workspace = workspace(archived: false)

        XCTAssertFalse(WorkspaceStore.shouldTimerPoll(
            workspace, selectedWorkspaceID: workspace.id,
            effectiveGitPath: "/tmp/repo", appIsActive: false
        ))
    }

    func testGitTimerPolicyPollsSelectedActiveWorkspace() {
        let workspace = workspace(archived: false)

        XCTAssertTrue(WorkspaceStore.shouldTimerPoll(
            workspace, selectedWorkspaceID: workspace.id,
            effectiveGitPath: "/tmp/repo", appIsActive: true
        ))
    }

    func testTerminalOfflinePolicyAllowsOnlyIdleShellPromptsPastTimeout() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: true,
            inactiveSince: now.addingTimeInterval(-300),
            now: now,
            timeout: 300,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh"
        ))
    }

    func testTerminalOfflinePolicyKeepsFocusedOrRecentlyUsedTerminalLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: true,
            inactiveSince: nil,
            now: now,
            timeout: 300,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh"
        ))
        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: true,
            inactiveSince: now.addingTimeInterval(-299),
            now: now,
            timeout: 300,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh"
        ))
    }

    func testTerminalOfflinePolicyKeepsBusyAndLongLivedProcessesLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let inactiveSince = now.addingTimeInterval(-600)

        for process in ["ssh", "vim", "claude", "codex", "tmux"] {
            XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
                enabled: true,
                hasLiveSurface: true,
                inactiveSince: inactiveSince,
                now: now,
                timeout: 300,
                needsConfirmQuit: false,
                foregroundProcessName: process
            ), "\(process) must not be taken offline")
        }
        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: true,
            inactiveSince: inactiveSince,
            now: now,
            timeout: 300,
            needsConfirmQuit: true,
            foregroundProcessName: "zsh"
        ), "A shell with unsubmitted input must stay live")
    }

    func testTerminalOfflinePolicyKeepsShellsWithUserOrJobStateLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: true,
            inactiveSince: now.addingTimeInterval(-600),
            now: now,
            timeout: 300,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh",
            hasUserOrJobState: true
        ))
    }

    func testConfirmCloseSurfaceEnumTagsUseGhosttyStringABI() {
        XCTAssertFalse(GhosttyManager.promptDetectionIsReliable(confirmCloseSurfaceTag: nil))
        XCTAssertFalse(GhosttyManager.promptDetectionIsReliable(confirmCloseSurfaceTag: "false"))
        XCTAssertFalse(GhosttyManager.promptDetectionIsReliable(confirmCloseSurfaceTag: "unknown"))
        XCTAssertTrue(GhosttyManager.promptDetectionIsReliable(confirmCloseSurfaceTag: "true"))
        XCTAssertTrue(GhosttyManager.promptDetectionIsReliable(confirmCloseSurfaceTag: "always"))
    }

    func testBackgroundWorkspaceNeverKeepsItsCurrentPaneFocused() {
        XCTAssertTrue(TerminalFocusPolicy.isPaneFocused(
            workspaceIsSelected: true,
            paneIsFocused: true
        ))
        XCTAssertFalse(TerminalFocusPolicy.isPaneFocused(
            workspaceIsSelected: false,
            paneIsFocused: true
        ))
    }

    func testBackgroundWorkspaceFirstResponderDoesNotPauseIdleClock() {
        XCTAssertTrue(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: true,
            workspaceIsSelected: true,
            viewIsFirstResponder: true
        ))
        XCTAssertFalse(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: true,
            workspaceIsSelected: false,
            viewIsFirstResponder: true
        ))
    }

    func testTerminalOfflinePolicyRequiresOptInAndLiveSurface() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let inactiveSince = now.addingTimeInterval(-600)

        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: false,
            hasLiveSurface: true,
            inactiveSince: inactiveSince,
            now: now,
            timeout: 300,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh"
        ))
        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: false,
            inactiveSince: inactiveSince,
            now: now,
            timeout: 300,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh"
        ))
        XCTAssertFalse(TerminalOfflinePolicy.shouldTakeOffline(
            enabled: true,
            hasLiveSurface: true,
            inactiveSince: inactiveSince,
            now: now,
            timeout: 300,
            promptStateDetectionEnabled: false,
            needsConfirmQuit: false,
            foregroundProcessName: "zsh"
        ), "Offlining must stop when Ghostty cannot report prompt state")
    }

    func testCancellingLocalRunnerTerminatesSubprocessPromptly() async {
        let runner = LocalGitRunner(gitPath: "/bin/sleep")
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await runner.run(["2"], cwd: nil, timeout: .poll)
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled subprocess should not run to completion")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testSurfaceFocusGateSuppressesDuplicateUpdates() {
        var gate = SurfaceFocusUpdateGate()

        XCTAssertTrue(gate.shouldApply(true))
        XCTAssertFalse(gate.shouldApply(true))
        XCTAssertTrue(gate.shouldApply(false))
        XCTAssertFalse(gate.shouldApply(false))

        gate.reset()
        XCTAssertTrue(gate.shouldApply(false))
    }

    func testTerminalBackingSkipsIdenticalLayerWrites() {
        let layer = CALayer()
        let background = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        XCTAssertTrue(GhosttyManager.applyTerminalBacking(
            to: layer, transparent: false, opaqueBackgroundColor: background
        ))
        XCTAssertFalse(GhosttyManager.applyTerminalBacking(
            to: layer, transparent: false, opaqueBackgroundColor: background
        ))
        XCTAssertTrue(GhosttyManager.applyTerminalBacking(
            to: layer, transparent: true, opaqueBackgroundColor: background
        ))
        XCTAssertFalse(layer.isOpaque)
    }

    func testPaneActivityDoesNotPublishWorkspaceStore() {
        let activity = PaneActivityStore()
        let store = WorkspaceStore(activity: activity)
        let key = WorkspaceStore.WorkspacePaneKey(workspace: UUID(), pane: PaneID(value: 0))
        var workspacePublishes = 0
        var activityPublishes = 0
        let workspaceCancellable = store.objectWillChange.sink { workspacePublishes += 1 }
        let activityCancellable = activity.objectWillChange.sink { activityPublishes += 1 }

        store.paneProcesses[key] = "zsh"

        XCTAssertEqual(store.paneProcesses[key], "zsh")
        XCTAssertEqual(activityPublishes, 1)
        XCTAssertEqual(workspacePublishes, 0)
        withExtendedLifetime((workspaceCancellable, activityCancellable)) {}
    }
}
