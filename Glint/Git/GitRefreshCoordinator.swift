import Foundation

/// Coalesces rapid git-status refresh requests for one workspace so a single
/// logical change can't spawn more than one `git status` subprocess.
///
/// Two independent push channels both fire for one change: the shell's
/// command-finished signal lands first, and the filesystem watcher's callback
/// follows ~0.5s later (its debounce latency). The store's in-flight gate only
/// de-dupes refreshes that overlap in time — and a fast local `git status`
/// (~100ms) finishes well before the trailing FSEvents callback arrives, so
/// one `git commit` spawned two subprocesses. This coordinator closes that gap:
/// once a refresh has been dispatched for a workspace, further refreshes
/// requested within `minInterval` coalesce into ONE trailing refresh at the
/// interval boundary. A second coalesced request indicates a sustained storm
/// (build, rebase, checkout), so the trailing refresh backs off to four times
/// the base interval. The trailing refresh still always runs, so a genuine
/// change can't be dropped while the storm throttles.
///
/// Only the push-based event channels route through here. Pull-based refreshes
/// (workspace/pane switch, popover open, the active-only fallback timer) call
/// `refreshGitStatus` / `refreshGitStatusNow` directly and stay immediate.
final class GitRefreshCoordinator {
    private let minInterval: TimeInterval
    private let stormInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.glint.git-refresh")
    private static let stormThreshold = 2
    /// Last time a refresh for this workspace was actually dispatched (immediate
    /// path, or a trailing fire). The elapsed-since guard is what folds a
    /// trailing FSEvents callback back into the refresh the command-finished
    /// signal already triggered.
    private var lastDispatch: [UUID: Date] = [:]
    /// One in-flight trailing work item per workspace, so a fresher request can
    /// cancel a not-yet-fired trailing refresh and replace it.
    private var pending: [UUID: DispatchWorkItem] = [:]
    /// Requests coalesced since the last actual dispatch. A normal shell
    /// command produces one watcher follow-up; several follow-ups in the same
    /// window mean filesystem churn rather than one logical command.
    private var coalescedRequestCount: [UUID: Int] = [:]

    init(minInterval: TimeInterval = 1.5) {
        self.minInterval = minInterval
        self.stormInterval = minInterval * 4
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
            let currentCount = coalescedRequestCount[id] ?? 0
            let currentInterval = currentCount >= Self.stormThreshold
                ? stormInterval : minInterval
            if elapsed >= currentInterval {
                lastDispatch[id] = now
                pending[id] = nil
                coalescedRequestCount[id] = 0
                DispatchQueue.main.async(execute: run)
            } else {
                let nextCount = currentCount + 1
                coalescedRequestCount[id] = nextCount
                let targetInterval = nextCount >= Self.stormThreshold
                    ? stormInterval : minInterval
                let delay = targetInterval - elapsed
                let item = DispatchWorkItem { [self] in
                    lastDispatch[id] = Date()
                    pending[id] = nil
                    coalescedRequestCount[id] = 0
                    DispatchQueue.main.async(execute: run)
                }
                pending[id] = item
                queue.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }
    }

    /// Drop any not-yet-fired trailing refresh and throttle history for `id`
    /// (e.g. its workspace was archived or removed). Does not affect a refresh
    /// already dispatched to the main queue.
    func cancel(_ id: UUID) {
        queue.async { [self] in
            pending[id]?.cancel()
            pending[id] = nil
            lastDispatch[id] = nil
            coalescedRequestCount[id] = nil
        }
    }
}

/// Serializes the actual async git-status work for each workspace without
/// dropping invalidations that arrive while a refresh is suspended. The first
/// request starts work; later requests set one coalesced rerun bit. Finishing
/// the active refresh consumes that bit so the caller can immediately start a
/// fresh snapshot.
struct GitRefreshInFlightGate {
    private var running: Set<UUID> = []
    private var rerunRequested: Set<UUID> = []

    /// True when the caller should start work now. False means a refresh is
    /// already running and exactly one follow-up has been remembered.
    mutating func begin(_ id: UUID) -> Bool {
        guard !running.contains(id) else {
            rerunRequested.insert(id)
            return false
        }
        running.insert(id)
        return true
    }

    /// Finish the active refresh. Returns true when at least one request
    /// arrived while it was running and the caller must launch a fresh pass.
    mutating func finish(_ id: UUID) -> Bool {
        running.remove(id)
        return rerunRequested.remove(id) != nil
    }
}
