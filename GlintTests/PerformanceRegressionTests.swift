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
        // "always" makes needsConfirmQuit unconditionally true — prompt
        // state is unreadable, so the feature must treat it as unreliable.
        XCTAssertFalse(GhosttyManager.promptDetectionIsReliable(confirmCloseSurfaceTag: "always"))
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

    func testDelayedSurfaceReassertRejectsPaneAfterWorkspaceSwitch() {
        XCTAssertTrue(SurfaceReassertionPolicy.shouldReassert(
            containerIsAttached: true,
            expectedSurfaceMatches: true,
            paneIsVisible: true,
            hostClaimMatches: true
        ))
        XCTAssertFalse(SurfaceReassertionPolicy.shouldReassert(
            containerIsAttached: true,
            expectedSurfaceMatches: true,
            paneIsVisible: false,
            hostClaimMatches: true
        ))
    }

    func testDelayedSurfaceReassertRejectsSupersededHost() {
        XCTAssertFalse(SurfaceReassertionPolicy.shouldReassert(
            containerIsAttached: true,
            expectedSurfaceMatches: true,
            paneIsVisible: true,
            hostClaimMatches: false
        ))
    }

    func testOlderSurfaceHostCannotStealFromAttachedNewerHost() {
        XCTAssertFalse(SurfaceHostClaimPolicy.shouldClaim(
            candidateGeneration: 10,
            currentGeneration: 11,
            currentHostIsAttached: true,
            isSameHost: false
        ))
    }

    func testOlderSurfaceHostCanRecoverAfterNewerHostDetaches() {
        XCTAssertTrue(SurfaceHostClaimPolicy.shouldClaim(
            candidateGeneration: 10,
            currentGeneration: 11,
            currentHostIsAttached: false,
            isSameHost: false
        ))
    }

    func testOlderOutgoingHostDefersWhileNewerClaimIsPreCommit() {
        XCTAssertTrue(SurfaceHostClaimPolicy.shouldDeferUntilAfterCommit(
            candidateGeneration: 10,
            currentGeneration: 11,
            currentHostExists: true,
            currentHostIsAttached: false,
            isSameHost: false
        ))

        // Once the incoming host survives the commit and attaches, the stale
        // outgoing host must not steal the surface back.
        XCTAssertFalse(SurfaceHostClaimPolicy.shouldDeferUntilAfterCommit(
            candidateGeneration: 10,
            currentGeneration: 11,
            currentHostExists: true,
            currentHostIsAttached: true,
            isSameHost: false
        ))
        XCTAssertFalse(SurfaceHostClaimPolicy.shouldClaim(
            candidateGeneration: 10,
            currentGeneration: 11,
            currentHostIsAttached: true,
            isSameHost: false
        ))
    }

    func testNewestHostWinsDeterministicOutgoingIncomingOutgoingRace() {
        let outgoingHost = NSView()
        let incomingHost = NSView()
        let surface = NSView()
        outgoingHost.addSubview(surface)

        var currentHost: NSView = outgoingHost
        var currentGeneration: UInt64 = 10
        func claim(_ candidate: NSView, generation: UInt64) {
            guard SurfaceHostClaimPolicy.shouldClaim(
                candidateGeneration: generation,
                currentGeneration: currentGeneration,
                currentHostIsAttached: true,
                isSameHost: currentHost === candidate
            ) else { return }
            surface.removeFromSuperview()
            candidate.addSubview(surface)
            currentHost = candidate
            currentGeneration = generation
        }

        claim(incomingHost, generation: 11)
        claim(outgoingHost, generation: 10) // delayed stale-tree callback

        XCTAssertTrue(surface.superview === incomingHost)
        XCTAssertTrue(currentHost === incomingHost)
        XCTAssertEqual(currentGeneration, 11)
    }

    func testRecordedHostKeepsVetoWhileItStillExpectsTheSurface() {
        // The split-collapse steal-back guard must survive untouched: a live
        // host that still holds this surface is not a stale recording.
        XCTAssertFalse(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: true,
            currentHostIsAttached: true,
            currentHostExpectsThisSurface: true,
            isSameHost: false
        ))
    }

    func testRecycledRecordedHostLosesItsVeto() {
        // SwiftUI reused the recorded container for another pane's surface.
        // It is still alive and attached, but it no longer speaks for this
        // surface, so its newer generation must stop declining the attach.
        XCTAssertTrue(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: true,
            currentHostIsAttached: true,
            currentHostExpectsThisSurface: false,
            isSameHost: false
        ))
    }

    func testDetachedOrMissingRecordedHostIsStale() {
        XCTAssertTrue(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: true,
            currentHostIsAttached: false,
            currentHostExpectsThisSurface: true,
            isSameHost: false
        ))
        XCTAssertTrue(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: false,
            currentHostIsAttached: false,
            currentHostExpectsThisSurface: false,
            isSameHost: false
        ))
    }

    func testSameHostIsNeverTreatedAsStaleRecording() {
        XCTAssertFalse(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: true,
            currentHostIsAttached: true,
            currentHostExpectsThisSurface: false,
            isSameHost: true
        ))
    }

    /// Reproduces the workspace-switch shape from #103: SwiftUI recycles the
    /// split containers in flipped order, so surface A's recording ends up
    /// pointing at the container that now hosts surface B. Without the
    /// post-commit staleness recheck, A's legitimate attach is declined
    /// forever and its pane keeps rendering the outgoing workspace.
    func testSurfaceRecoversFromRecordingPointingAtRecycledContainer() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root

        // Two recycled containers, both live in the window across the switch.
        let older = NSView()
        let newer = NSView()
        root.addSubview(older)
        root.addSubview(newer)
        let generation: [ObjectIdentifier: UInt64] = [
            ObjectIdentifier(older): 10,
            ObjectIdentifier(newer): 11,
        ]

        let surfaceA = NSView()
        let surfaceB = NSView()

        // What each container currently expects, and what each surface has
        // recorded as its host — the pair `attach` keeps in sync.
        var expectedSurface: [ObjectIdentifier: NSView] = [:]
        var recordedHost: [ObjectIdentifier: NSView] = [:]

        func pin(_ surface: NSView, in container: NSView) {
            for child in container.subviews where child !== surface {
                child.removeFromSuperview()
            }
            surface.removeFromSuperview()
            container.addSubview(surface)
            expectedSurface[ObjectIdentifier(container)] = surface
            recordedHost[ObjectIdentifier(surface)] = container
        }

        func attach(_ surface: NSView, to container: NSView) {
            let host = recordedHost[ObjectIdentifier(surface)]
            let claimed = SurfaceHostClaimPolicy.shouldClaim(
                candidateGeneration: generation[ObjectIdentifier(container)]!,
                currentGeneration: host.map { generation[ObjectIdentifier($0)]! } ?? 0,
                currentHostIsAttached: host?.window != nil,
                isSameHost: host === container
            )
            if claimed {
                pin(surface, in: container)
                return
            }
            // Post-commit recovery.
            guard SurfaceHostClaimPolicy.recordedHostIsStale(
                currentHostExists: host != nil,
                currentHostIsAttached: host?.window != nil,
                currentHostExpectsThisSurface:
                    host.flatMap { expectedSurface[ObjectIdentifier($0)] } === surface,
                isSameHost: host === container
            ) else { return }
            pin(surface, in: container)
        }

        // Outgoing workspace: A lives in the newer container.
        attach(surfaceA, to: newer)
        XCTAssertTrue(surfaceA.superview === newer)

        // Incoming workspace reuses that same container for B, and hands A the
        // older one. A's recording still points at `newer`, which is attached
        // and outranks `older` on generation.
        attach(surfaceB, to: newer)
        attach(surfaceA, to: older)

        XCTAssertTrue(surfaceB.superview === newer)
        XCTAssertTrue(surfaceA.superview === older,
                      "surface A must recover its pane instead of staying evicted")
        XCTAssertTrue(recordedHost[ObjectIdentifier(surfaceA)] === older)
    }

    func testSplitLayoutExplicitlyAccountsForBothBranchesAndDivider() {
        let lengths = SplitLayoutPolicy.lengths(
            total: 1_556,
            ratio: 0.5481854514781491,
            minPaneLength: 100
        )

        XCTAssertEqual(lengths.first, 852)
        XCTAssertEqual(lengths.second, 703)
        XCTAssertEqual(lengths.first + SplitLayoutPolicy.dividerLength + lengths.second, 1_556)
    }

    func testSplitHandleCannotMoveBorderlessWindow() {
        XCTAssertFalse(SplitDragHandleView().mouseDownCanMoveWindow)
    }

    func testPaneVisibilityRequiresSelectedWorkspaceAndSelectedTab() {
        let wsID = UUID()
        let onSelectedTab = PaneID(value: 1)
        let onOtherTab = PaneID(value: 2)
        let ws = Workspace(
            id: wsID, name: "repo", userNamed: false,
            accentHex: "5E5CE6", symbol: "terminal",
            tabs: [
                WorkspaceTab(id: TabID(value: 0), name: nil,
                             root: .leaf(onSelectedTab), focusedPane: onSelectedTab),
                WorkspaceTab(id: TabID(value: 1), name: nil,
                             root: .leaf(onOtherTab), focusedPane: onOtherTab),
            ],
            selectedTabID: TabID(value: 0), nextTabSeq: 2,
            panes: [:], nextPaneSeq: 3
        )
        func key(_ pane: PaneID, workspace: UUID = wsID) -> WorkspaceStore.WorkspacePaneKey {
            .init(workspace: workspace, pane: pane)
        }

        XCTAssertTrue(WorkspaceStore.paneIsVisible(
            key(onSelectedTab), selectedWorkspaceID: wsID, in: ws))
        // Same workspace, but the pane lives in a non-selected tab.
        XCTAssertFalse(WorkspaceStore.paneIsVisible(
            key(onOtherTab), selectedWorkspaceID: wsID, in: ws))
        // Selection moved to a different workspace.
        XCTAssertFalse(WorkspaceStore.paneIsVisible(
            key(onSelectedTab), selectedWorkspaceID: UUID(), in: ws))
        // Nothing selected at all (empty sidebar / startup).
        XCTAssertFalse(WorkspaceStore.paneIsVisible(
            key(onSelectedTab), selectedWorkspaceID: nil, in: nil))
    }

    func testBackgroundWorkspaceFirstResponderDoesNotPauseIdleClock() {
        XCTAssertTrue(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: true,
            workspaceIsSelected: true,
            viewIsFirstResponder: true,
            viewIsAttachedToWindow: true
        ))
        XCTAssertFalse(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: true,
            workspaceIsSelected: false,
            viewIsFirstResponder: true,
            viewIsAttachedToWindow: true
        ))
    }

    func testVisiblePaneIsProtectedEvenWithoutKeyboardFocus() {
        // Keyboard focus parked in the sidebar/search must not let the pane
        // the user is looking at be swapped for the offline placeholder.
        XCTAssertTrue(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: true,
            workspaceIsSelected: true,
            viewIsFirstResponder: false,
            viewIsAttachedToWindow: true
        ))
        // Detached views (other workspace/tab) are the release candidates.
        XCTAssertFalse(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: true,
            workspaceIsSelected: true,
            viewIsFirstResponder: false,
            viewIsAttachedToWindow: false
        ))
        // An inactive app protects nothing — wake happens on reactivation.
        XCTAssertFalse(TerminalFocusPolicy.protectsFromIdleOfflining(
            appIsActive: false,
            workspaceIsSelected: true,
            viewIsFirstResponder: false,
            viewIsAttachedToWindow: true
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

    func testAccessibilityTextUsesUTF16Coordinates() {
        let content = "😀a\n界b"

        XCTAssertEqual(AccessibilityText.utf16Count(content), 6)
        XCTAssertEqual(
            AccessibilityText.substring(in: content, range: NSRange(location: 0, length: 2)),
            "😀"
        )
        XCTAssertEqual(
            AccessibilityText.substring(in: content, range: NSRange(location: 2, length: 1)),
            "a"
        )
        XCTAssertEqual(AccessibilityText.lineNumber(in: content, atUTF16Index: 4), 1)
    }

    func testAccessibilitySelectionMapsAgainstExposedText() {
        let content = "short\nselected 😀 text\nend"
        let selectedText = "selected 😀"

        let range = AccessibilityText.uniqueRange(of: selectedText, in: content)

        XCTAssertEqual(range, NSRange(location: 6, length: 11))
        XCTAssertEqual(range.flatMap { AccessibilityText.substring(in: content, range: $0) }, selectedText)
    }

    func testAccessibilitySelectionRejectsMissingOrAmbiguousMapping() {
        XCTAssertNil(AccessibilityText.uniqueRange(of: "padded", in: "trimmed"))
        XCTAssertNil(AccessibilityText.uniqueRange(of: "same", in: "same\nsame"))
    }

    func testAccessibilityCacheRefetchesOnlyAfterExpiry() async throws {
        var fetchCount = 0
        let cache = CachedValue(duration: .milliseconds(20)) {
            fetchCount += 1
            return fetchCount
        }

        XCTAssertEqual(cache.get(), 1)
        XCTAssertEqual(cache.get(), 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(cache.get(), 2)
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
