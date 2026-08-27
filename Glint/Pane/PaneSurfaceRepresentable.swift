import SwiftUI
import AppKit

enum SurfaceReassertionPolicy {
    static func shouldReassert(containerIsAttached: Bool,
                               expectedSurfaceMatches: Bool,
                               paneIsVisible: Bool,
                               hostClaimMatches: Bool) -> Bool {
        containerIsAttached && expectedSurfaceMatches && paneIsVisible && hostClaimMatches
    }
}

enum SurfaceHostClaimPolicy {
    static func shouldClaim(candidateGeneration: UInt64,
                            currentGeneration: UInt64,
                            currentHostIsAttached: Bool,
                            isSameHost: Bool) -> Bool {
        isSameHost || !currentHostIsAttached || candidateGeneration >= currentGeneration
    }

    static func shouldDeferUntilAfterCommit(candidateGeneration: UInt64,
                                            currentGeneration: UInt64,
                                            currentHostExists: Bool,
                                            currentHostIsAttached: Bool,
                                            isSameHost: Bool) -> Bool {
        !isSameHost &&
            currentHostExists &&
            !currentHostIsAttached &&
            candidateGeneration < currentGeneration
    }

    /// Whether the surface's recorded host claim has gone stale and must stop
    /// vetoing a live container's attach.
    ///
    /// `shouldClaim` assumes the recorded host is still the surface's rightful
    /// owner. That stops being true when SwiftUI recycles containers across a
    /// workspace switch: the recording is never cleared when a surface is
    /// evicted from a container, so it can point at a container that is still
    /// alive and attached but now hosts a *different* surface. Its newer
    /// generation would otherwise decline the one legitimate attach forever,
    /// leaving the pane showing the outgoing workspace's terminal.
    ///
    /// Only a host that is alive, attached, and no longer speaks for this
    /// surface is adjudicated stale. A detached or missing host is NOT stale:
    /// `shouldClaim` passes those anyway (it never inspects generations for a
    /// detached host), and "detached" is indistinguishable from "brand-new
    /// host mid-commit, not in the window yet" — the ambiguity
    /// `shouldDeferUntilAfterCommit` exists to resolve. Acting on it from a
    /// recovery pass would skip that deferral and steal the surface from a
    /// host that is about to attach, which is #96's steal-back.
    ///
    /// A recorded host that still expects this surface is NOT stale — the
    /// generation verdict stands there, so the split-collapse steal-back
    /// guard is unaffected.
    static func recordedHostIsStale(currentHostExists: Bool,
                                    currentHostIsAttached: Bool,
                                    currentHostExpectsThisSurface: Bool,
                                    isSameHost: Bool) -> Bool {
        !isSameHost && currentHostExists && currentHostIsAttached && !currentHostExpectsThisSurface
    }
}

/// Gate for the synchronous attach path. The deferred, reassert, and recovery
/// paths all re-check pane visibility before running; the make/update path
/// must not be the exception.
enum SurfaceAttachGate {
    /// A representable whose pane is no longer in the selected workspace's
    /// selected tab must not attach — its tree is on the way out. SwiftUI
    /// evaluates the outgoing tree's representables once more before
    /// dismantling them, and that final update would otherwise re-pin the
    /// outgoing workspace's surface into a recycled container — either via
    /// `shouldClaim`'s `isSameHost` shortcut (the stale recording still names
    /// that container) or via a nil recording just cleared by the ownership
    /// hand-off — leaving the live pane on the wrong workspace's terminal
    /// with no later `updateNSView` pass left to correct it.
    ///
    /// Unconditional by design: a first mount is never blocked here, because
    /// only the selected tab's tree is ever in the hierarchy (`ContentView`
    /// renders `currentRoot` alone) and the store's selection is updated
    /// before the tree re-renders — a mounted representable's pane is visible
    /// at mount time by construction. Narrowing the gate to re-claims only
    /// (host != nil) would reopen the hand-off-cleared variant of the steal.
    static func allowsAttach(paneIsVisible: Bool) -> Bool { paneIsVisible }
}

/// Hosts a stable, store-owned `GhosttySurfaceView` inside a fresh container
/// NSView. SwiftUI may rebuild the container any time the split tree reshapes;
/// the surface itself outlives that and just re-parents.
struct PaneSurfaceRepresentable: NSViewRepresentable {
    let surfaceView: GhosttySurfaceView
    /// Plain value, not a Binding: focus only flows store → AppKit here.
    /// The reverse direction (clicks) goes through store.focus(_:), so a
    /// writable binding would just be a lie about the data flow.
    let focused: Bool
    /// True while an in-window overlay (the command palette) is managing the
    /// window's first responder. When set, this view must NOT touch focus:
    /// updateNSView re-runs on store mutations, and re-grabbing the terminal
    /// surface here races the palette's search field and yanks focus back off
    /// it.
    let deferFocus: Bool
    /// Evaluated inside the deferred re-pin, not when SwiftUI builds the view:
    /// workspace/tab selection may change before that callback runs.
    let isPaneVisible: () -> Bool

    func makeNSView(context: Context) -> NoDragContainerView {
        let container = NoDragContainerView()
        container.wantsLayer = true
        Self.updateContainerBacking(container)
        surfaceView.refreshAppearanceBacking()
        Self.performAttach(surfaceView, to: container, isPaneVisible: isPaneVisible)
        return container
    }

    func updateNSView(_ nsView: NoDragContainerView, context: Context) {
        // This pass re-runs whenever the parent view re-evaluates — store
        // mutations only. The sidebar's per-second TimelineView redraws its
        // own subtree and never invalidates the pane tree's representables,
        // so a skipped attach here stays skipped until the next store
        // mutation; the attach path below must settle ownership on its own.
        // The pass doubles as the live-refresh path for opacity changes:
        // re-stamp the container and surface backing so dragging the opacity
        // slider flips the compositor without a relaunch.
        Self.updateContainerBacking(nsView)
        surfaceView.refreshAppearanceBacking()
        if surfaceView.superview !== nsView {
            Self.performAttach(surfaceView, to: nsView, isPaneVisible: isPaneVisible)
        }
        // Don't yank focus out of a text editor (sidebar search, rename
        // field, …). An unconditional sync here would steal focus and
        // re-light the terminal cursor right after the user clicks the
        // search box. resignFirstResponder already pushed ghostty into
        // the unfocused state; leave it alone until the responder dance
        // unwinds naturally.
        //
        // `deferFocus` covers the command palette: while it's open, skip
        // the focus sync entirely so this pass can't race the palette's
        // search field for first responder.
        guard !deferFocus else { return }
        let textEditorActive = surfaceView.window?.firstResponder is NSText
        if !textEditorActive {
            surfaceView.setGhosttyFocus(focused)
        }
        if focused, !textEditorActive, surfaceView.window?.firstResponder !== surfaceView {
            DispatchQueue.main.async {
                // Re-check on the runloop: a text field (command palette,
                // search box) may have claimed focus between this update and
                // the dispatch. Stealing it back here is the very bug.
                guard !(surfaceView.window?.firstResponder is NSText) else { return }
                surfaceView.window?.makeFirstResponder(surfaceView)
            }
        } else if !focused, surfaceView.window?.firstResponder === surfaceView {
            DispatchQueue.main.async {
                surfaceView.window?.makeFirstResponder(nil)
            }
        }
    }

    /// Container subclass that disables borderless-window drag in the pane
    /// area. Without this, any whitespace not covered by the ghostty surface
    /// (e.g. during a resize) would let the user drag the window.
    ///
    /// Also snaps its own frame to backing-store pixels — SwiftUI's layout
    /// regularly hands us fractional origins (e.g. y=52.5 after the 52pt
    /// toolbar on an odd-height window). Ghostty's CAMetalLayer then lives
    /// at a fractional screen position, Core Animation resamples it to the
    /// pixel grid, and during fast scrollback (`cat` of a big file) each
    /// row falls on a slightly different sub-pixel offset — the eye reads
    /// the result as a 1px "fault line" tearing through the rows.
    final class NoDragContainerView: NSView {
        /// Creation order is the tie-breaker while an outgoing and incoming
        /// split-tree host coexist. New tree containers must win even if an
        /// old representable receives a late update.
        let hostGeneration = mach_absolute_time()

        /// The surface this container most recently claimed via `attach`.
        /// Paired with the surface-side host claim for the post-commit recheck.
        weak var expectedSurface: GhosttySurfaceView?

        deinit {
            // A host dismantled without an ownership hand-off nils the
            // surface's weak paneHostView silently — no invalidation event
            // ever fires, so a pending recovery that already outlived its
            // backstop budget would strand the surface forever. Hand it one
            // last event. Identity cannot be re-checked via
            // `surface.paneHostView === self` (a weak reference is already
            // nil by the time deinit runs); the generation token proves the
            // recording still describes this container's tenure. All state
            // checks happen on the main queue, where the recording may since
            // have moved on.
            // Nothing armed means nothing to re-drive, and nothing can arm
            // it later either: arming requires a decline, a decline requires a
            // live vetoing host, and such a host would make
            // `recoverPendingClaim` bail on its `paneHostView == nil` guard.
            // So the early-out costs no coverage and spares the main queue a
            // block per container teardown — one per pane on every reshape.
            guard let surface = expectedSurface,
                  surface.pendingRecoveryHost != nil else { return }
            let generation = hostGeneration
            DispatchQueue.main.async {
                PaneSurfaceRepresentable.recoverPendingClaim(
                    for: surface, afterHostDeinit: generation)
            }
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(snappedOrigin(newOrigin))
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(snappedSize(newSize))
        }

        private func snappedOrigin(_ p: NSPoint) -> NSPoint {
            guard window != nil else { return p }
            return backingAlignedRect(
                NSRect(origin: p, size: frame.size),
                options: [.alignAllEdgesNearest]
            ).origin
        }

        private func snappedSize(_ s: NSSize) -> NSSize {
            guard window != nil else { return s }
            return backingAlignedRect(
                NSRect(origin: frame.origin, size: s),
                options: [.alignAllEdgesNearest]
            ).size
        }
    }

    /// Mirror the surface's opaque/clear backing onto the hosting container.
    /// The container's own layer would otherwise paint an opaque fill behind
    /// the surface and block the desktop even when the surface itself is clear.
    /// Shares the single implementation in `GhosttyManager` so it can't drift
    /// from the surface view's own backing.
    private static func updateContainerBacking(_ container: NoDragContainerView) {
        GhosttyManager.shared.applyTerminalBacking(to: container.layer)
    }

    /// Which attach attempt this is. The passes differ only in which guard
    /// they are allowed to skip.
    enum AttachPass {
        /// SwiftUI's own `makeNSView` / `updateNSView` call, and every
        /// recovery re-entry: full arbitration, deferral included.
        case initial
        /// Re-run once the commit made the incoming host's attachment state
        /// readable, resolving the split-collapse ambiguity. Skips only the
        /// deferral itself — the claim verdict still applies.
        case postCommitDeferred
        /// Re-run after the recovery proved the recorded host no longer
        /// speaks for this surface (attached, expecting another). The only
        /// pass allowed to skip the generation claim: a recording that
        /// demonstrably describes someone else's container has no standing
        /// to veto on generation. A detached or missing host never reaches
        /// this pass — it re-enters `.initial` so the deferral still
        /// protects a pre-commit host.
        case staleRecordingRecovery
    }

    /// The attach arbitration, on the type rather than the instance so the
    /// event-driven recovery (and the regression tests) can re-drive it with
    /// a real surface and container instead of a test-side re-implementation.
    static func performAttach(_ surface: GhosttySurfaceView,
                              to container: NoDragContainerView,
                              isPaneVisible: @escaping () -> Bool,
                              pass: AttachPass = .initial) {
        // The impostor gate: the outgoing tree's final update runs after the
        // incoming tree has already claimed the recycled containers. Without
        // this check that stale update re-pins the outgoing workspace's
        // surface — via isSameHost or via a recording the hand-off just
        // cleared. A gate-blocked attach disarms any pending recovery: the
        // pane is not the one on screen anymore.
        guard SurfaceAttachGate.allowsAttach(paneIsVisible: isPaneVisible()) else {
            disarmPendingRecovery(surface)
            return
        }
        let currentHost = surface.paneHostView
        if pass == .initial,
           SurfaceHostClaimPolicy.shouldDeferUntilAfterCommit(
               candidateGeneration: container.hostGeneration,
               currentGeneration: surface.paneHostGeneration,
               currentHostExists: currentHost != nil,
               currentHostIsAttached: currentHost?.window != nil,
               isSameHost: currentHost === container
           ) {
            // During a split collapse the incoming host can claim the surface
            // just before SwiftUI gives the outgoing tree one last update.
            // The incoming container is not in the window yet, so the old host
            // would otherwise mistake it for abandoned and steal the surface
            // back. Resolve that ambiguity after the current commit: the new
            // host will be attached if it survived, or still detached if the
            // older host genuinely needs to recover it.
            DispatchQueue.main.async {
                guard container.window != nil, isPaneVisible() else { return }
                performAttach(surface, to: container,
                              isPaneVisible: isPaneVisible, pass: .postCommitDeferred)
            }
            return
        }
        if pass != .staleRecordingRecovery {
            let shouldClaim = SurfaceHostClaimPolicy.shouldClaim(
                candidateGeneration: container.hostGeneration,
                currentGeneration: surface.paneHostGeneration,
                currentHostIsAttached: currentHost?.window != nil,
                isSameHost: currentHost === container
            )
            guard shouldClaim else {
                // Arm the event-driven recovery: the recording's veto may
                // dissolve long after this pass (the host gets reclaimed by
                // another pane's surface), and with no incidental
                // updateNSView pass left, only the invalidation event can
                // re-drive this attach. The bounded backstop below only
                // covers the paths no event fires for (e.g. the host
                // deallocations and the weak reference nils silently).
                armPendingRecovery(surface, host: container, visible: isPaneVisible)
                scheduleRecoveryBackstop(surface, to: container,
                                         isPaneVisible: isPaneVisible,
                                         epoch: surface.pendingRecoveryEpoch)
                return
            }
        }

        disarmPendingRecovery(surface)
        surface.paneHostView = container
        surface.paneHostGeneration = container.hostGeneration
        // Ownership hand-off: the moment this container stops speaking for the
        // surface it held, that surface's recording of this container loses
        // all standing. Clearing it here (and in `pin`'s eviction below) means
        // a recycled container can never veto its previous surface's next
        // legitimate attach — the decline-forever state from #103 is dead at
        // birth instead of only detectable after the fact.
        let previousSurface = container.expectedSurface
        container.expectedSurface = surface
        if let previousSurface, previousSurface !== surface {
            invalidateStaleRecording(of: previousSurface, hostedBy: container)
        }
        pin(surface, in: container)
        // When the split tree reshapes (workspace switch, pane close), SwiftUI
        // evaluates the OUTGOING tree's representables once more before
        // dismantling them, and that stale update can run *after* this attach —
        // re-parenting the surface into a container that's torn down moments
        // later, leaving the live pane blank. Containers that survive the
        // commit re-assert their claim right after it; dismantled ones are out
        // of the window by then and bail. A recycled container can still be in
        // the window after a workspace/tab switch, so also verify that this
        // surface's pane is the one currently visible.
        DispatchQueue.main.async {
            guard SurfaceReassertionPolicy.shouldReassert(
                containerIsAttached: container.window != nil,
                expectedSurfaceMatches: container.expectedSurface === surface,
                paneIsVisible: isPaneVisible(),
                hostClaimMatches: surface.paneHostView === container &&
                    surface.paneHostGeneration == container.hostGeneration
            ) else { return }
            pin(surface, in: container)
        }
    }

    /// Opportunistic backstop for the event-driven recovery — NOT the
    /// correctness mechanism. Each turn re-samples the recorded host's fate:
    ///
    /// - Still attached and still expecting this surface → the veto is live;
    ///   sample again next turn, up to `recoveryRetryBudget`. Giving up does
    ///   NOT disarm the pending recovery: `invalidateStaleRecording` fires
    ///   whenever the host is finally reclaimed, however late, and re-drives
    ///   the full arbitration (a fixed budget can only shrink the race
    ///   window, never close the state machine — the invalidation event
    ///   closes it).
    /// - Gone or detached → full `.initial` re-entry, deferral included, so a
    ///   pre-commit host keeps its #96 protection. This is the one path no
    ///   invalidation event covers: a deallocated host nils the weak
    ///   reference silently.
    /// - Attached and expecting another surface → provably stale; the
    ///   `.staleRecordingRecovery` pass may skip the generation claim.
    ///
    /// The `epoch` token invalidates chains that outlived their intent: every
    /// arm, disarm, or re-arm bumps `pendingRecoveryEpoch`, so a backstop
    /// queued for an older pending claim dies on its next turn instead of
    /// acting for a candidate nobody asked for anymore (e.g. after a
    /// successful claim cleared the pending state, or a newer decline
    /// re-armed it for a different container).
    private static func scheduleRecoveryBackstop(
        _ surface: GhosttySurfaceView,
        to container: NoDragContainerView,
        isPaneVisible: @escaping () -> Bool,
        epoch: UInt,
        remainingRetries: Int = recoveryRetryBudget
    ) {
        DispatchQueue.main.async {
            guard surface.pendingRecoveryEpoch == epoch,
                  container.window != nil,
                  SurfaceAttachGate.allowsAttach(paneIsVisible: isPaneVisible()) else {
                return
            }
            let host = surface.paneHostView
            let hostStillVetoes =
                host !== container &&
                host?.window != nil &&
                (host as? NoDragContainerView)?.expectedSurface === surface
            if hostStillVetoes {
                guard remainingRetries > 0 else { return }
                scheduleRecoveryBackstop(surface, to: container,
                                         isPaneVisible: isPaneVisible,
                                         epoch: epoch,
                                         remainingRetries: remainingRetries - 1)
                return
            }
            if host == nil || host?.window == nil {
                performAttach(surface, to: container,
                              isPaneVisible: isPaneVisible, pass: .initial)
            } else if SurfaceHostClaimPolicy.recordedHostIsStale(
                currentHostExists: host != nil,
                currentHostIsAttached: host?.window != nil,
                currentHostExpectsThisSurface:
                    (host as? NoDragContainerView)?.expectedSurface === surface,
                isSameHost: host === container
            ) {
                performAttach(surface, to: container,
                              isPaneVisible: isPaneVisible, pass: .staleRecordingRecovery)
            }
        }
    }

    /// Arms the event-driven recovery for a declined claim, bumping the epoch
    /// so any backstop chain queued for an earlier pending claim dies.
    ///
    /// One slot per surface, deliberately: a later decline overwrites an
    /// earlier candidate rather than queueing beside it. A surface has exactly
    /// one live representable, so only its most recent declined container can
    /// still be the pane's real host — and a candidate that has since been
    /// recycled onto another pane would, if re-driven, drag this surface into
    /// someone else's container. (The visibility gate is the second line of
    /// defence there: a re-drive for a pane that is no longer on screen is
    /// refused outright.)
    private static func armPendingRecovery(_ surface: GhosttySurfaceView,
                                           host: NoDragContainerView,
                                           visible: @escaping () -> Bool) {
        surface.pendingRecoveryHost = host
        surface.pendingRecoveryVisibility = visible
        surface.pendingRecoveryEpoch += 1
    }

    /// Clears the pending recovery (successful claim, or a gate-blocked
    /// impostor), likewise bumping the epoch to kill in-flight backstop
    /// chains that still speak for the cleared claim.
    private static func disarmPendingRecovery(_ surface: GhosttySurfaceView) {
        guard surface.pendingRecoveryHost != nil ||
              surface.pendingRecoveryVisibility != nil else { return }
        surface.pendingRecoveryHost = nil
        surface.pendingRecoveryVisibility = nil
        surface.pendingRecoveryEpoch += 1
    }

    /// How many extra runloop turns the backstop may spend re-sampling the
    /// recorded host's fate. Small on purpose: correctness comes from the
    /// invalidation event, not from polling. Internal rather than private so
    /// the regression tests can drain *past* it by construction instead of
    /// hard-coding a number that silently stops clearing the budget if this
    /// one ever grows.
    static let recoveryRetryBudget = 8

    /// Deallocation follow-up for a host that died without an ownership
    /// hand-off — the last eventless path. The weak paneHostView nils
    /// silently on dealloc, so a pending recovery whose backstop budget
    /// already ran out would never be re-driven. Verified on the main queue:
    /// the recording must still describe the dead host's tenure (nil host +
    /// matching generation token — identity is unverifiable by then), and
    /// the pending candidate must still be attached and its pane visible;
    /// then the claim re-enters the FULL `.initial` arbitration, deferral
    /// included.
    static func recoverPendingClaim(for surface: GhosttySurfaceView,
                                    afterHostDeinit generation: UInt64) {
        guard surface.paneHostView == nil,
              surface.paneHostGeneration == generation,
              let candidate = surface.pendingRecoveryHost as? NoDragContainerView,
              candidate.window != nil,
              let visible = surface.pendingRecoveryVisibility else { return }
        performAttach(surface, to: candidate, isPaneVisible: visible, pass: .initial)
    }

    /// Drop a surface's host recording once the container it names stops
    /// hosting it — the container was reclaimed by another pane's surface, or
    /// evicted this one. Surviving recordings are vetoes: they still name an
    /// attached container whose generation outranks the next candidate, which
    /// is how a workspace switch could leave a pane on the outgoing
    /// workspace's terminal forever. Clearing the recording also re-drives
    /// the surface's pending recovery, if it has one — this invalidation is
    /// the event that dissolves the veto.
    static func invalidateStaleRecording(of surface: GhosttySurfaceView,
                                         hostedBy container: NSView) {
        guard surface.paneHostView === container else { return }
        // Only the identity is dropped; `paneHostGeneration` deliberately
        // keeps naming this container's tenure. It is the token
        // `recoverPendingClaim` matches on after the container deallocates —
        // by then the weak reference is nil and the generation is the only
        // remaining proof of whose recording this was. Nothing else reads it
        // while the host is nil (`shouldClaim` and
        // `shouldDeferUntilAfterCommit` both short-circuit on a missing host).
        surface.paneHostView = nil
        // Never pin into a candidate that has not mounted: the surface would
        // ride a window-less container whose reassert bails on
        // `containerIsAttached`, leaving the pane blank until the next store
        // mutation. A candidate still mid-commit gets its claim when its own
        // representable mounts (host is nil now, so `shouldClaim` passes);
        // the pending state stays armed for the events that follow.
        guard let candidate = surface.pendingRecoveryHost as? NoDragContainerView,
              candidate.window != nil,
              let visible = surface.pendingRecoveryVisibility else { return }
        performAttach(surface, to: candidate, isPaneVisible: visible, pass: .initial)
    }

    private static func pin(_ surface: GhosttySurfaceView, in container: NSView) {
        // Evict any stale surface left over from another workspace's pane that
        // happened to use this container. With the workspace `.id()` removed
        // above, SwiftUI re-uses the same hosting NSView across switches, so
        // we have to actively clean up rather than rely on full teardown.
        // `subviews` is a value copy, so the re-entrant attach an
        // invalidation can trigger below is free to reshape the view tree
        // mid-loop. That recursion terminates: the nested `performAttach`
        // disarms the evicted surface's pending recovery before it claims, so
        // a second invalidation of the same surface finds nothing to re-drive.
        for child in container.subviews where child !== surface {
            child.removeFromSuperview()
            if let evicted = child as? GhosttySurfaceView {
                invalidateStaleRecording(of: evicted, hostedBy: container)
            }
        }
        guard surface.superview !== container else { return }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Adding a subview to a container whose size is UNCHANGED does not
        // trigger a layout pass, so the pin constraints just activated stay
        // unresolved and the surface keeps its stale (often zero) frame —
        // when SwiftUI hands us a recycled container already at its final
        // size, nothing else resizes the surface to fill it. Resolve the
        // constraints synchronously now so the surface always matches its
        // container, size change or not.
        container.layoutSubtreeIfNeeded()
    }
}
