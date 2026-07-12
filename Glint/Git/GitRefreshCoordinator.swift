import Foundation

/// Coalesces rapid git-status refresh requests for one workspace so a single
/// logical change can't spawn more than one `git status` subprocess.
///
/// Two independent push channels both fire for one change: the shell's
/// command-finished signal lands first, and the filesystem watcher's callback
/// follows ~0.5s later (its debounce latency). `WorkspaceStore.gitInFlight`
/// only de-dupes refreshes that overlap in time — and a fast local `git status`
/// (~100ms) finishes well before the trailing FSEvents callback arrives, so
/// one `git commit` spawned two subprocesses. This coordinator closes that gap:
/// once a refresh has been dispatched for a workspace, further refreshes
/// requested within `minInterval` coalesce into ONE trailing refresh at the
/// interval boundary. A sustained storm (build, rebase, checkout) thus
/// refreshes at most once per `minInterval`, never zero — the trailing refresh
/// always runs, so a genuine change can't be dropped while the storm throttles.
///
/// Only the push-based event channels route through here. Pull-based refreshes
/// (workspace/pane switch, popover open, the active-only fallback timer) call
/// `refreshGitStatus` / `refreshGitStatusNow` directly and stay immediate.
final class GitRefreshCoordinator {
    private let minInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.glint.git-refresh")
    /// Last time a refresh for this workspace was actually dispatched (immediate
    /// path, or a trailing fire). The elapsed-since guard is what folds a
    /// trailing FSEvents callback back into the refresh the command-finished
    /// signal already triggered.
    private var lastDispatch: [UUID: Date] = [:]
    /// One in-flight trailing work item per workspace, so a fresher request can
    /// cancel a not-yet-fired trailing refresh and replace it.
    private var pending: [UUID: DispatchWorkItem] = [:]

    init(minInterval: TimeInterval = 1.5) {
        self.minInterval = minInterval
    }

    /// Request a refresh of `id`. `run` runs on the main actor immediately when
    /// at least `minInterval` has elapsed since the last dispatch, otherwise
    /// once at the interval boundary. Repeated requests within the window
    /// coalesce: a fresher request cancels any not-yet-fired trailing refresh
    /// and replaces it, so only the most recent request's `run` survives.
    func request(_ id: UUID, run: @escaping () -> Void) {
        queue.async { [self] in
            pending[id]?.cancel()
            let now = Date()
            let elapsed = lastDispatch[id].map { now.timeIntervalSince($0) } ?? .infinity
            if elapsed >= minInterval {
                lastDispatch[id] = now
                pending[id] = nil
                DispatchQueue.main.async(execute: run)
            } else {
                let delay = minInterval - elapsed
                let item = DispatchWorkItem { [self] in
                    lastDispatch[id] = Date()
                    pending[id] = nil
                    DispatchQueue.main.async(execute: run)
                }
                pending[id] = item
                queue.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }
    }

    /// Drop any not-yet-fired trailing refresh for `id` (e.g. its workspace was
    /// removed). Does not affect a refresh already dispatched to the main queue.
    func cancel(_ id: UUID) {
        queue.async { [self] in
            pending[id]?.cancel()
            pending[id] = nil
        }
    }
}
