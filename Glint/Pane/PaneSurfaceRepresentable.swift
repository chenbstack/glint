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
    /// A recorded host that still expects this surface is NOT stale — the
    /// generation verdict stands there, so the split-collapse steal-back
    /// guard is unaffected.
    static func recordedHostIsStale(currentHostExists: Bool,
                                    currentHostIsAttached: Bool,
                                    currentHostExpectsThisSurface: Bool,
                                    isSameHost: Bool) -> Bool {
        guard !isSameHost else { return false }
        guard currentHostExists else { return true }
        return !currentHostIsAttached || !currentHostExpectsThisSurface
    }
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
    /// updateNSView re-runs ~1/s, and re-grabbing the terminal surface here
    /// races the palette's search field and yanks focus back off it.
    let deferFocus: Bool
    /// Evaluated inside the deferred re-pin, not when SwiftUI builds the view:
    /// workspace/tab selection may change before that callback runs.
    let isPaneVisible: () -> Bool

    func makeNSView(context: Context) -> NoDragContainerView {
        let container = NoDragContainerView()
        container.wantsLayer = true
        Self.updateContainerBacking(container)
        surfaceView.refreshAppearanceBacking()
        attach(surfaceView, to: container)
        return container
    }

    func updateNSView(_ nsView: NoDragContainerView, context: Context) {
        // SwiftUI re-runs this ~1/s (sidebar TimelineView), so it doubles as
        // the live-refresh path for opacity changes: re-stamp the container and
        // surface backing every pass so dragging the opacity slider flips the
        // compositor without a relaunch.
        Self.updateContainerBacking(nsView)
        surfaceView.refreshAppearanceBacking()
        if surfaceView.superview !== nsView {
            attach(surfaceView, to: nsView)
        }
        // Don't yank focus out of a text editor (sidebar search, rename
        // field, …). SwiftUI re-runs updateNSView roughly every second
        // because of the sidebar's per-workspace elapsed-time
        // TimelineView, so any unconditional sync here would steal focus
        // and re-light the terminal cursor ~1s after the user clicks the
        // search box. resignFirstResponder already pushed ghostty into
        // the unfocused state; leave it alone until the responder dance
        // unwinds naturally.
        //
        // `deferFocus` covers the command palette: while it's open, skip
        // the focus sync entirely so this ~1/s pass can't race the
        // palette's search field for first responder.
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
    private enum AttachPass {
        /// SwiftUI's own `makeNSView` / `updateNSView` call.
        case initial
        /// Re-run once the commit made the incoming host's attachment state
        /// readable, resolving the split-collapse ambiguity.
        case postCommitDeferred
        /// Re-run after the commit found the surface's recorded host claim
        /// stale: the recording loses its veto and this container pins.
        case staleRecordingRecovery
    }

    private func attach(_ surface: GhosttySurfaceView,
                        to container: NoDragContainerView,
                        pass: AttachPass = .initial) {
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
                attach(surface, to: container, pass: .postCommitDeferred)
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
                scheduleStaleRecordingRecovery(surface, to: container)
                return
            }
        }

        surface.paneHostView = container
        surface.paneHostGeneration = container.hostGeneration
        container.expectedSurface = surface
        Self.pin(surface, in: container)
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
            Self.pin(surface, in: container)
        }
    }

    /// A declined claim used to be final, so a surface whose recorded host had
    /// been recycled onto another pane stayed stuck on the outgoing
    /// workspace's terminal until relaunch. Re-check after the commit: if the
    /// recording no longer describes a live host that expects this surface, it
    /// has no standing to veto and this container takes over.
    private func scheduleStaleRecordingRecovery(_ surface: GhosttySurfaceView,
                                                to container: NoDragContainerView) {
        DispatchQueue.main.async {
            guard container.window != nil, isPaneVisible() else { return }
            let host = surface.paneHostView
            guard SurfaceHostClaimPolicy.recordedHostIsStale(
                currentHostExists: host != nil,
                currentHostIsAttached: host?.window != nil,
                currentHostExpectsThisSurface:
                    (host as? NoDragContainerView)?.expectedSurface === surface,
                isSameHost: host === container
            ) else { return }
            attach(surface, to: container, pass: .staleRecordingRecovery)
        }
    }

    private static func pin(_ surface: GhosttySurfaceView, in container: NSView) {
        // Evict any stale surface left over from another workspace's pane that
        // happened to use this container. With the workspace `.id()` removed
        // above, SwiftUI re-uses the same hosting NSView across switches, so
        // we have to actively clean up rather than rely on full teardown.
        for child in container.subviews where child !== surface {
            child.removeFromSuperview()
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
