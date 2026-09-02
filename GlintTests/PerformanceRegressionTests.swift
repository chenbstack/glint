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

    func testDetachedOrMissingRecordedHostIsNotStaleForRecovery() {
        // A detached or missing host has no standing to veto in `shouldClaim`
        // (both pass the claim directly), so the recovery pass must not
        // adjudicate it stale — worse, "detached" is indistinguishable from
        // "brand-new host mid-commit, not in the window yet", and force-pinning
        // across that gap is exactly the steal-back #96's generation guard
        // exists to prevent.
        XCTAssertFalse(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: true,
            currentHostIsAttached: false,
            currentHostExpectsThisSurface: true,
            isSameHost: false
        ))
        XCTAssertFalse(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: false,
            currentHostIsAttached: false,
            currentHostExpectsThisSurface: false,
            isSameHost: false
        ))
    }

    func testInvisiblePaneCannotAttachThroughSynchronousPath() {
        // The outgoing tree's final updateNSView runs after the incoming tree
        // claimed the recycled containers; its pane is no longer visible, so
        // the synchronous attach must refuse — every async pass already did.
        XCTAssertTrue(SurfaceAttachGate.allowsAttach(paneIsVisible: true))
        XCTAssertFalse(SurfaceAttachGate.allowsAttach(paneIsVisible: false))
    }

    func testRecordingInvalidationOnlyDropsTheNamedContainer() {
        let container = PaneSurfaceRepresentable.NoDragContainerView()
        let other = PaneSurfaceRepresentable.NoDragContainerView()
        let released = GhosttySurfaceView(frame: .zero)
        let bystander = GhosttySurfaceView(frame: .zero)
        released.paneHostView = container
        bystander.paneHostView = other

        PaneSurfaceRepresentable.invalidateStaleRecording(of: released, hostedBy: container)

        XCTAssertNil(released.paneHostView)
        XCTAssertTrue(bystander.paneHostView === other)
    }

    func testSameHostIsNeverTreatedAsStaleRecording() {
        XCTAssertFalse(SurfaceHostClaimPolicy.recordedHostIsStale(
            currentHostExists: true,
            currentHostIsAttached: true,
            currentHostExpectsThisSurface: false,
            isSameHost: true
        ))
    }

    /// Real-path stage for the host-claim sequences: a borderless window
    /// with two recycled containers whose creation order drives their
    /// generations, driven through the production `performAttach` — no
    /// test-side arbiter to drift from the real one.
    @MainActor
    private final class PaneHostStage {
        let window: NSWindow
        let older: PaneSurfaceRepresentable.NoDragContainerView
        let newer: PaneSurfaceRepresentable.NoDragContainerView

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            let root = NSView(frame: window.contentLayoutRect)
            window.contentView = root
            // Creation order drives `hostGeneration`: older < newer.
            older = .init()
            newer = .init()
            root.addSubview(older)
            root.addSubview(newer)
        }

        func attach(_ surface: GhosttySurfaceView,
                    to container: PaneSurfaceRepresentable.NoDragContainerView,
                    visible: Bool) {
            PaneSurfaceRepresentable.performAttach(
                surface, to: container, isPaneVisible: { visible })
        }
    }

    /// Enough main-queue turns to outrun the backstop budget by construction.
    /// Derived rather than hard-coded: a literal would quietly stop clearing
    /// the budget — and stop testing what these cases claim to test — the day
    /// `recoveryRetryBudget` grows.
    private var pastBackstopBudget: Int {
        PaneSurfaceRepresentable.recoveryRetryBudget + 4
    }

    /// Pumps the main queue for `turns` DispatchQueue.main.async rounds. The
    /// awaited fulfillment guarantees every earlier main-queue block has run
    /// (FIFO), so N turns = N async generations.
    private func drainMainQueue(turns: Int) async {
        for _ in 0..<turns {
            let drained = XCTestExpectation(description: "main queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 5)
        }
    }

    /// Reproduces the workspace-switch steal-back shape: the incoming tree
    /// claims a recycled container, then the OUTGOING tree's final
    /// updateNSView runs and — its pane no longer visible — must not be able
    /// to re-pin the old workspace's surface into that container. The
    /// hand-off has already cleared the outgoing surface's recording, so its
    /// late attach looks like a first mount (host nil): only the visibility
    /// gate stops it. This is exactly why the gate must not be narrowed to
    /// re-claims (host != nil).
    func testOutgoingRepresentableCannotStealRecycledContainerAfterSwitch() {
        let stage = PaneHostStage()
        let surfaceOld = GhosttySurfaceView(frame: .zero)
        let surfaceNew = GhosttySurfaceView(frame: .zero)

        // Outgoing workspace: its pane's surface lives in the container.
        stage.attach(surfaceOld, to: stage.older, visible: true)
        XCTAssertTrue(surfaceOld.superview === stage.older)

        // Switch: the incoming surface claims the same recycled container
        // first (#93 documented that the outgoing tree is evaluated last)…
        stage.attach(surfaceNew, to: stage.older, visible: true)
        // …then the outgoing tree's final update arrives, pane invisible —
        // once with the hand-off-cleared (nil) recording…
        stage.attach(surfaceOld, to: stage.older, visible: false)
        // …and once with a recording that still names the container, in case
        // any path ever skips the hand-off clearing.
        surfaceOld.paneHostView = stage.older
        stage.attach(surfaceOld, to: stage.older, visible: false)

        XCTAssertTrue(surfaceNew.superview === stage.older,
                      "the outgoing surface must not steal the recycled container back")
        XCTAssertTrue(surfaceNew.paneHostView === stage.older)
        XCTAssertTrue(stage.older.expectedSurface === surfaceNew)
        XCTAssertFalse(surfaceOld.superview === stage.older)
    }

    /// Reproduces the ordering confirmed against v0.1.28-beta.2 (defect: the
    /// recovery sampled once, too early, and never retried): surface A's
    /// attach is declined while its recorded host still expects it; the host
    /// is reclaimed by another pane's surface only afterwards. The
    /// invalidation event — not runloop polling — must re-drive A's pending
    /// claim through full arbitration. No main-queue turn passes in this
    /// test, so a fixed retry budget could not have helped.
    func testEventDrivenRecoveryTakesOverOnInvalidationWithoutRunloopTurns() {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let surfaceB = GhosttySurfaceView(frame: .zero)

        // Outgoing workspace: A lives in the newer container.
        stage.attach(surfaceA, to: stage.newer, visible: true)
        XCTAssertTrue(surfaceA.superview === stage.newer)

        // Incoming: A's pane is handed the older container and declined
        // (newer is attached, newer-generation, still expecting A).
        stage.attach(surfaceA, to: stage.older, visible: true)
        XCTAssertTrue(surfaceA.superview === stage.newer,
                      "declined attach must not move the surface")
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older,
                      "the declined claim must arm the event-driven recovery")

        // The other pane's surface reclaims `newer` one commit later: the
        // hand-off invalidates A's recording, which re-drives A's pending
        // claim synchronously.
        stage.attach(surfaceB, to: stage.newer, visible: true)

        XCTAssertTrue(surfaceA.superview === stage.older,
                      "the invalidation event must re-drive the declined claim")
        XCTAssertTrue(surfaceB.superview === stage.newer)
        XCTAssertTrue(surfaceA.paneHostView === stage.older)
        XCTAssertNil(surfaceA.pendingRecoveryHost)
    }

    /// The backstop budget must not gate correctness: with the recorded host
    /// still vetoing, the backstop exhausts itself and gives up — but the
    /// pending claim stays armed, so an invalidation arriving arbitrarily
    /// later still takes over. (A reclaim pushed past the budget was the
    /// second confirmed counter-example: a fixed budget only shrinks the
    /// race window.)
    func testPendingRecoverySurvivesBackstopExhaustion() async {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let surfaceB = GhosttySurfaceView(frame: .zero)

        stage.attach(surfaceA, to: stage.newer, visible: true)
        stage.attach(surfaceA, to: stage.older, visible: true) // declined

        // Drain well past the backstop budget; the host keeps vetoing the
        // whole time, as a rightful owner would.
        await drainMainQueue(turns: pastBackstopBudget)

        XCTAssertTrue(surfaceA.superview === stage.newer,
                      "a rightful owner must outlive the backstop budget")
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older,
                      "budget exhaustion must not disarm the pending recovery")

        // The host is finally reclaimed — much later than any budget.
        stage.attach(surfaceB, to: stage.newer, visible: true)

        XCTAssertTrue(surfaceA.superview === stage.older,
                      "the late invalidation must still re-drive the claim")
        XCTAssertTrue(surfaceB.superview === stage.newer)
    }

    /// The last eventless path: a host that simply DEALLOCATES (dismantled
    /// without an ownership hand-off) nils the surface's weak paneHostView
    /// silently — no invalidation fires. A pending recovery that already
    /// outlived its backstop budget would strand the surface forever; the
    /// container's deinit must hand the claim one last event via the
    /// generation token (identity is unverifiable in deinit — the weak
    /// reference is already nil by then).
    func testPendingRecoverySurvivesHostDeallocationAfterBackstopExhaustion() async {
        // Standalone stage: `newer` must be fully releasable, which the
        // shared PaneHostStage's stored properties prevent.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        let older = PaneSurfaceRepresentable.NoDragContainerView()
        var newer: PaneSurfaceRepresentable.NoDragContainerView? =
            .init() // created second: the newer generation
        root.addSubview(older)
        root.addSubview(newer!)
        let surfaceA = GhosttySurfaceView(frame: .zero)

        func attach(_ surface: GhosttySurfaceView,
                    to container: PaneSurfaceRepresentable.NoDragContainerView,
                    visible: Bool) {
            PaneSurfaceRepresentable.performAttach(
                surface, to: container, isPaneVisible: { visible })
        }

        attach(surfaceA, to: newer!, visible: true)
        attach(surfaceA, to: older, visible: true) // declined, pending armed
        await drainMainQueue(turns: pastBackstopBudget) // backstop exhausted

        XCTAssertTrue(surfaceA.pendingRecoveryHost === older,
                      "precondition: the pending recovery is still armed")

        // The host is dismantled outright — not reclaimed by another
        // surface. Releasing the last strong references runs deinit, which
        // queues the generation-token follow-up.
        newer?.removeFromSuperview()
        newer = nil
        await drainMainQueue(turns: 2)

        XCTAssertTrue(surfaceA.superview === older,
                      "the deallocation token must re-drive the pending claim")
        XCTAssertTrue(surfaceA.paneHostView === older)
        XCTAssertNil(surfaceA.pendingRecoveryHost)
    }

    /// P1 from the #109 review: the invalidation re-drive must never pin the
    /// surface into a candidate that has not mounted. A candidate still
    /// mid-commit claims when its own representable mounts (the recording is
    /// nil by then, so `shouldClaim` passes); pinning early would strand the
    /// surface in a window-less container whose reassert bails on
    /// `containerIsAttached`.
    func testUnmountedCandidateRecoversWhenItEntersWindow() {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let surfaceB = GhosttySurfaceView(frame: .zero)
        let outgoingSurface = GhosttySurfaceView(frame: .zero)

        // The candidate is a recycled container that still renders the
        // outgoing workspace's surface, then leaves the window mid-commit.
        stage.attach(outgoingSurface, to: stage.older, visible: true)
        stage.older.removeFromSuperview()

        stage.attach(surfaceA, to: stage.newer, visible: true)
        // A's claim for the unmounted candidate is declined (newer vetoes)
        // and arms the pending recovery.
        stage.attach(surfaceA, to: stage.older, visible: true)
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older)

        // The veto dissolves — but the candidate is still unmounted: no pin.
        stage.attach(surfaceB, to: stage.newer, visible: true)

        XCTAssertTrue(surfaceA.superview == nil,
                      "the surface must not ride a window-less candidate")
        XCTAssertTrue(surfaceA.paneHostView == nil)
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older,
                      "the pending claim stays armed for the candidate's own mount")

        // The candidate's commit lands. Entering the window must itself
        // re-drive the armed claim; SwiftUI is not required to issue another
        // updateNSView after mounting an already-created representable.
        stage.window.contentView?.addSubview(stage.older)

        XCTAssertTrue(surfaceA.superview === stage.older)
        XCTAssertTrue(surfaceA.paneHostView === stage.older)
        XCTAssertFalse(outgoingSurface.superview === stage.older,
                       "the recycled container must not keep showing the outgoing workspace")
    }

    /// A candidate armed for A can be recycled onto visible surface B before
    /// it mounts. The successful claim must retire A's pending recovery so the
    /// mount callback cannot revive A and evict B from its new container.
    func testReusedCandidateDoesNotRecoverPreviousPendingSurfaceOnMount() {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let surfaceB = GhosttySurfaceView(frame: .zero)
        let replacement = GhosttySurfaceView(frame: .zero)

        stage.older.removeFromSuperview()
        stage.attach(surfaceA, to: stage.newer, visible: true)
        stage.attach(surfaceA, to: stage.older, visible: true) // declined, pending armed

        // A's owner is reclaimed while its candidate is still window-less.
        stage.attach(replacement, to: stage.newer, visible: true)
        XCTAssertNil(surfaceA.paneHostView)
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older)

        // SwiftUI reuses the detached candidate for B before mounting it.
        stage.attach(surfaceB, to: stage.older, visible: true)
        XCTAssertTrue(surfaceB.superview === stage.older)
        XCTAssertTrue(stage.older.expectedSurface === surfaceB)

        stage.window.contentView?.addSubview(stage.older)

        XCTAssertTrue(surfaceB.superview === stage.older,
                      "mount must not revive the previous pending surface")
        XCTAssertTrue(surfaceB.paneHostView === stage.older)
        XCTAssertTrue(stage.older.expectedSurface === surfaceB)
        XCTAssertNil(surfaceA.pendingRecoveryHost)
    }

    /// In a 3/4-pane switch, two surfaces can both have their claim for the
    /// same window-less candidate declined before either owner is reclaimed.
    /// Arming B must retire A's candidate link; otherwise A's later
    /// invalidation can evict B after B has mounted and claimed the container.
    func testRejectedClaimDisarmsPreviousSurfacePendingOnSameCandidate() {
        let stage = PaneHostStage()
        let hostB = PaneSurfaceRepresentable.NoDragContainerView()
        stage.window.contentView?.addSubview(hostB)
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let surfaceB = GhosttySurfaceView(frame: .zero)
        let replacementA = GhosttySurfaceView(frame: .zero)
        let replacementB = GhosttySurfaceView(frame: .zero)

        stage.older.removeFromSuperview()
        stage.attach(surfaceA, to: stage.newer, visible: true)
        stage.attach(surfaceB, to: hostB, visible: true)

        stage.attach(surfaceA, to: stage.older, visible: true) // declined
        stage.attach(surfaceB, to: stage.older, visible: true) // declined, replaces A

        XCTAssertNil(surfaceA.pendingRecoveryHost,
                     "a candidate can have only one pending surface")
        XCTAssertTrue(surfaceB.pendingRecoveryHost === stage.older)
        XCTAssertTrue(stage.older.pendingRecoverySurface === surfaceB)

        // B's owner is reclaimed while the candidate is still window-less;
        // mounting the candidate then lets B take it over.
        stage.attach(replacementB, to: hostB, visible: true)
        stage.window.contentView?.addSubview(stage.older)
        XCTAssertTrue(surfaceB.superview === stage.older)

        // A's old owner is reclaimed later. A's superseded pending claim must
        // not reattach and drive B out of the candidate.
        stage.attach(replacementA, to: stage.newer, visible: true)

        XCTAssertTrue(surfaceB.superview === stage.older,
                      "A's stale recovery must not evict B")
        XCTAssertTrue(surfaceB.paneHostView === stage.older)
        XCTAssertTrue(stage.older.expectedSurface === surfaceB)
        XCTAssertFalse(surfaceA.superview === stage.older)
    }

    /// Mount is an event, not permission to bypass arbitration. If the live
    /// recorded host still expects the surface, entering the window must
    /// re-run `.initial`, lose the generation verdict, and stay pending.
    func testMountedCandidateDoesNotStealFromLiveHost() async {
        let stage = PaneHostStage()
        let surface = GhosttySurfaceView(frame: .zero)

        stage.attach(surface, to: stage.newer, visible: true)
        stage.older.removeFromSuperview()
        stage.attach(surface, to: stage.older, visible: true) // declined

        stage.window.contentView?.addSubview(stage.older)
        await drainMainQueue(turns: pastBackstopBudget)

        XCTAssertTrue(surface.superview === stage.newer)
        XCTAssertTrue(surface.paneHostView === stage.newer)
        XCTAssertNil(stage.older.expectedSurface)
        XCTAssertTrue(surface.pendingRecoveryHost === stage.older,
                      "mount must keep waiting while the rightful host still vetoes")

        // Leave no pending backstop state for later tests.
        stage.attach(surface, to: stage.older, visible: false)
        XCTAssertNil(surface.pendingRecoveryHost)
        XCTAssertNil(stage.older.pendingRecoverySurface)
    }

    /// P1 from the #109 review: a backstop chain queued for an OLD pending
    /// claim must die once that claim is satisfied and cleared — otherwise,
    /// when the new host is later detached mid-commit, the stale chain would
    /// re-claim the old candidate as if the surface still wanted it. The
    /// epoch token invalidates the chain at its next turn.
    func testStaleBackstopChainDiesAfterPendingIsCleared() async {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let newest = PaneSurfaceRepresentable.NoDragContainerView()
        stage.window.contentView?.addSubview(newest) // created last: newest gen

        stage.attach(surfaceA, to: stage.newer, visible: true)
        // Declined for `older` — a backstop chain is queued for that claim.
        stage.attach(surfaceA, to: stage.older, visible: true)
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older)

        // The surface is claimed by an even newer container instead; the
        // pending state clears and the epoch bumps.
        stage.attach(surfaceA, to: newest, visible: true)
        XCTAssertNil(surfaceA.pendingRecoveryHost)

        // The new host is momentarily detached mid-commit — exactly when a
        // stale chain, if it still ran, would re-claim `older`.
        newest.removeFromSuperview()
        await drainMainQueue(turns: pastBackstopBudget)

        XCTAssertTrue(surfaceA.superview === newest,
                      "a stale backstop chain must not re-claim the old candidate")
        XCTAssertTrue(surfaceA.paneHostView === newest)
        XCTAssertNil(stage.older.expectedSurface)
    }

    /// Reproduces the pre-commit steal-back counter-example (defect: the
    /// recovery re-entered arbitration with the deferral skipped): the newer
    /// host is temporarily window-less mid-commit while an older candidate
    /// wants the surface. The re-entry must go through the full `.initial`
    /// pass so `shouldDeferUntilAfterCommit` still grants the newer host its
    /// one-commit grace; once it re-attaches, the older candidate's claim is
    /// declined and the backstop exhausts without ever moving the surface.
    func testPreCommitDetachedHostIsNotStolenByRecovery() async {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)

        stage.attach(surfaceA, to: stage.newer, visible: true)

        // Mid-commit: the newer host is momentarily out of the window but
        // still alive and expecting A.
        stage.newer.removeFromSuperview()
        // The older candidate's attach defers (host exists, detached,
        // older generation) instead of claiming…
        stage.attach(surfaceA, to: stage.older, visible: true)
        // …and the commit lands: the newer host survives and re-attaches.
        stage.window.contentView?.addSubview(stage.newer)

        await drainMainQueue(turns: pastBackstopBudget)

        XCTAssertTrue(surfaceA.superview === stage.newer,
                      "the surface must never be stolen from a pre-commit host")
        XCTAssertTrue(surfaceA.paneHostView === stage.newer)
        XCTAssertNil(stage.older.expectedSurface)
    }

    /// The backstop's detached-host re-entry is the exact spot the previous
    /// fix regressed: re-entering with a deferral-skipping pass let the
    /// older container claim while the newer host was merely window-less
    /// mid-commit (#96's steal-back). The re-entry must go through the full
    /// `.initial` pass so `shouldDeferUntilAfterCommit` grants the newer
    /// host its one-commit grace. The queue surgery below orders the turns
    /// deterministically: the backstop samples while the host is detached,
    /// the host re-attaches (the commit landed), and only then does the
    /// deferred pass run.
    func testBackstopReentryKeepsDeferralForDetachedHost() async {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)

        stage.attach(surfaceA, to: stage.newer, visible: true)
        // Decline while the host still vetoes — the backstop's first sample
        // is now queued…
        stage.attach(surfaceA, to: stage.older, visible: true)
        // …then detach the host, and queue the re-attach BEHIND that sample.
        // The `.initial` re-entry appends its deferred pass after the
        // re-attach, so the pass observes the host attached again.
        stage.newer.removeFromSuperview()
        DispatchQueue.main.async { [weak stage] in
            guard let stage else { return }
            stage.window.contentView?.addSubview(stage.newer)
        }
        await drainMainQueue(turns: pastBackstopBudget + 2)

        XCTAssertTrue(surfaceA.superview === stage.newer,
                      "a deferral-skipping re-entry steals from a pre-commit host")
        XCTAssertTrue(surfaceA.paneHostView === stage.newer)
        XCTAssertNil(stage.older.expectedSurface)
    }

    /// A successful claim — from any pass — must clear the pending recovery,
    /// otherwise a stale candidate container could be re-driven by a later,
    /// unrelated invalidation.
    func testClaimClearsPendingRecovery() {
        let stage = PaneHostStage()
        let surfaceA = GhosttySurfaceView(frame: .zero)
        let newest = PaneSurfaceRepresentable.NoDragContainerView()
        stage.window.contentView?.addSubview(newest) // created last: newest generation

        stage.attach(surfaceA, to: stage.newer, visible: true)
        stage.attach(surfaceA, to: stage.older, visible: true) // declined, pending armed
        XCTAssertTrue(surfaceA.pendingRecoveryHost === stage.older)

        stage.attach(surfaceA, to: newest, visible: true) // newer generation: claims

        XCTAssertTrue(surfaceA.superview === newest)
        XCTAssertNil(surfaceA.pendingRecoveryHost)
        XCTAssertNil(surfaceA.pendingRecoveryVisibility)
        XCTAssertNil(stage.older.pendingRecoverySurface)
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
