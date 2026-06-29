import Foundation

// Diff data for the Review window. Two scopes, both resolved by `git diff` run
// in the workspace's worktree/repo dir (Plan B: out-of-band subprocess, never
// the visible PTY):
//   • workingTree — staged + unstaged + untracked vs HEAD (what you're about to
//     commit; mirrors the popover's "N changed files").
//   • branch(base) — everything `base...HEAD` introduced (PR-style review of an
//     isolated worktree branch).

enum DiffScope: Equatable, Hashable {
    case workingTree
    case branch(base: String)
}

struct GitFileChange: Identifiable, Equatable {
    enum Kind: String { case added, modified, deleted, untracked, renamed }
    var path: String
    var kind: Kind
    var additions: Int
    var deletions: Int
    var isBinary: Bool
    var id: String { path }
}

extension GitService {

    /// Files changed under `scope`, sorted by path. Never throws — a non-repo or
    /// bad base just yields an empty list (the UI shows "no changes").
    func changedFiles(repo: String, scope: DiffScope) async -> [GitFileChange] {
        switch scope {
        case .workingTree:
            // name-status (kind) + numstat (line counts) run concurrently, then
            // untracked files are appended as additions.
            async let names = git(["diff", "HEAD", "--name-status"], cwd: repo, allowFailure: true, timeout: Self.readTimeout)
            async let nums  = git(["diff", "HEAD", "--numstat"], cwd: repo, allowFailure: true, timeout: Self.readTimeout)
            async let untrk = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: repo, allowFailure: true)
            var map = Self.mergeNameNumstat(
                nameStatus: (try? await names)?.stdout ?? "",
                numstat: (try? await nums)?.stdout ?? "")
            if let u = try? await untrk, u.ok {
                let paths = u.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                let counts = await countUntracked(repo: repo, paths: paths)
                for p in paths {
                    map[p] = GitFileChange(path: p, kind: .untracked,
                                           additions: counts[p] ?? 0,
                                           deletions: 0, isBinary: false)
                }
            }
            return map.values.sorted { $0.path < $1.path }

        case .branch(let base):
            async let names = git(["diff", "\(base)...HEAD", "--name-status"], cwd: repo, allowFailure: true, timeout: Self.readTimeout)
            async let nums  = git(["diff", "\(base)...HEAD", "--numstat"], cwd: repo, allowFailure: true, timeout: Self.readTimeout)
            let map = Self.mergeNameNumstat(
                nameStatus: (try? await names)?.stdout ?? "",
                numstat: (try? await nums)?.stdout ?? "")
            return map.values.sorted { $0.path < $1.path }
        }
    }

    /// Unified-diff text for one file under `scope` (empty string on failure).
    /// `ignoreWhitespace` adds `--ignore-all-space` (indentation/whitespace-only
    /// changes collapse to context) — a load-time flag, not a render filter.
    func fileDiff(repo: String, scope: DiffScope, file: GitFileChange,
                  ignoreWhitespace: Bool = false) async -> String {
        // Huge -U makes git emit the entire file as context (clamped to file
        // length), so "Show All" renders the whole file and "Changes Only"
        // just filters context at render time. One load serves both states.
        var args = ["diff", "--unified=1000000"]
        if ignoreWhitespace { args.append("--ignore-all-space") }
        switch scope {
        case .workingTree:
            if file.kind == .untracked {
                // No HEAD side — diff against /dev/null so the whole file shows
                // as an addition. `--no-index` exits 1 when files differ (normal).
                // Prepend `args` so the toolbar's Show All / Ignore Whitespace
                // toggles apply uniformly — without this, untracked files were
                // silently exempt from the menu state.
                let r = try? await git(args + ["--no-index", "--", "/dev/null", file.path],
                                       cwd: repo, allowFailure: true, timeout: Self.readTimeout)
                return r?.stdout ?? ""
            }
            let r = try? await git(args + ["HEAD", "--", file.path],
                                   cwd: repo, allowFailure: true, timeout: Self.readTimeout)
            return r?.stdout ?? ""
        case .branch(let base):
            let r = try? await git(args + ["\(base)...HEAD", "--", file.path],
                                   cwd: repo, allowFailure: true, timeout: Self.readTimeout)
            return r?.stdout ?? ""
        }
    }

    // MARK: parsing

    /// Merge `--name-status` (kind per path) with `--numstat` (line counts). No
    /// `-M`: a rename appears as a delete + add pair, which both commands agree
    /// on, so keying by path is consistent.
    static func mergeNameNumstat(nameStatus: String, numstat: String) -> [String: GitFileChange] {
        var kinds: [String: GitFileChange.Kind] = [:]
        for line in nameStatus.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            let code = String(parts[0]); let path = String(parts[parts.count - 1])
            switch code.first {
            case "A": kinds[path] = .added
            case "D": kinds[path] = .deleted
            case "R": kinds[path] = .renamed
            default:  kinds[path] = .modified
            }
        }
        var out: [String: GitFileChange] = [:]
        for line in numstat.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let a = String(parts[0]); let d = String(parts[1]); let path = String(parts[2])
            let binary = (a == "-" || d == "-")   // numstat marks binary files with "-"
            out[path] = GitFileChange(path: path, kind: kinds[path] ?? .modified,
                                      additions: Int(a) ?? 0, deletions: Int(d) ?? 0, isBinary: binary)
        }
        // Mode-only / rename entries can appear in name-status but not numstat.
        for (path, kind) in kinds where out[path] == nil {
            out[path] = GitFileChange(path: path, kind: kind, additions: 0, deletions: 0, isBinary: false)
        }
        return out
    }

    /// Per-untracked-file add counts, branched on the runner. LOCAL reads the
    /// bytes directly — N untracked files used to mean N `git diff --no-index`
    /// subprocess spawns (bounded to 4 wide), and the file list blocked on
    /// every one before it could render. REMOTE can't `FileManager`-read the
    /// path (it lives on the far host), so it keeps the bounded git spawn.
    /// Both go through `boundedMap` so a repo with many untracked files can't
    /// fan out N-wide: local byte-reads don't pin dispatch threads, but an
    /// unbounded fan-out would still pile up N full-file buffers (and file
    /// handles) at once — the memory cliff the remote bound exists to avoid.
    private func countUntracked(repo: String, paths: [String]) async -> [String: Int] {
        if !runner.isRemote {
            // No Process, no thread pinning — bytes read in the cooperative
            // pool. Wider than remote (each task holds a file buffer, not 3
            // threads), but still bounded to cap peak memory.
            return await boundedMap(paths: paths, maxConcurrent: 8) {
                Self.untrackedAddCountLocal(repo: repo, relPath: $0)
            }
        }
        // Remote: each git spawn pins 3 dispatch threads (process + 2 pipe
        // readers), so a tighter bound than local.
        return await boundedMap(paths: paths, maxConcurrent: 4) {
            await self.untrackedAddCountRemote(repo: repo, relPath: $0)
        }
    }

    /// Map `body` over `paths` with concurrency capped at `maxConcurrent`,
    /// refilling one slot as each finishes (so the whole list completes in
    /// ceil(N/maxConcurrent) rounds, never an N-wide fan-out). Shared by the
    /// local byte-count and the remote git-spawn paths.
    private func boundedMap(paths: [String], maxConcurrent: Int,
                            _ body: @Sendable @escaping (String) async -> Int) async -> [String: Int] {
        var iter = paths.makeIterator()
        return await withTaskGroup(of: (String, Int).self) { group in
            for _ in 0..<min(maxConcurrent, paths.count) {
                guard let p = iter.next() else { break }
                group.addTask { (p, await body(p)) }
            }
            var dict: [String: Int] = [:]
            for await (p, n) in group {
                dict[p] = n
                if let next = iter.next() {
                    group.addTask { (next, await body(next)) }
                }
            }
            return dict
        }
    }

    /// Don't load an untracked file larger than this into RAM just to badge its
    /// +N — degrade to 0 (same as a binary file). × the local TaskGroup's
    /// concurrency (8) is the worst-case peak, so a stray multi-MB build
    /// artifact can't OOM the app the way an unbounded whole-file read could.
    private static let maxLocalCountBytes = 20_000_000

    /// Local-only: count an untracked file's added lines from its bytes — exact
    /// for the badge. Each `\n` ends an added line, plus one for trailing
    /// content with no newline; a NUL byte marks it binary (git's heuristic) →
    /// 0, an oversized file → 0 (see `maxLocalCountBytes`), and a bad UTF-8
    /// decode → 0 too — all matching `git diff --numstat`'s `-`. Static/pure so
    /// it's trivially Sendable into the TaskGroup.
    private static func untrackedAddCountLocal(repo: String, relPath: String) -> Int {
        let abs = (repo as NSString).appendingPathComponent(relPath)
        guard let data = FileManager.default.contents(atPath: abs), !data.isEmpty,
              data.count <= maxLocalCountBytes,
              !data.contains(0),
              let s = String(data: data, encoding: .utf8) else { return 0 }
        let newlines = s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return newlines + (s.hasSuffix("\n") ? 0 : 1)
    }

    /// `+N` line count for an untracked file in a REMOTE repo (SSH Review): the
    /// path only resolves on the far host, so we ask git (running there) via
    /// `git diff --no-index --numstat /dev/null <path>` instead of reading a
    /// same-pathed LOCAL file. Returns 0 for binary (numstat prints `-`) and on
    /// any error — the list degrades to a missing badge, never a wrong one.
    private func untrackedAddCountRemote(repo: String, relPath: String) async -> Int {
        guard let r = try? await git(["diff", "--no-index", "--numstat", "/dev/null", relPath],
                                     cwd: repo, allowFailure: true) else { return 0 }
        let parts = r.stdout.split(separator: "\n").first?.split(separator: "\t", maxSplits: 2)
        if let parts, parts.count == 3, let n = Int(parts[0]) { return n }
        return 0
    }
}
