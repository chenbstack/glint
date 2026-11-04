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
    /// Working-tree modification time (stat of `repo/path`), or nil when the
    /// file isn't on disk (deleted) — powers the list's compact "Modified"
    /// column + sort-by-modified; not consumed by git itself.
    var modDate: Date? = nil
    var id: String { path }
}

/// One Review list load, including a recoverable untracked failure and the
/// comparison baseline reused by file selection until the next reload.
struct GitReviewChanges {
    let files: [GitFileChange]
    let untrackedWarning: Bool
    /// Fixed OID/empty tree for working-tree review; original range expression for branch review.
    let baseline: String
}

extension GitService {

    /// Return files changed in `repo` under `scope`, sorted by literal path.
    /// Parameters: repository directory and comparison scope. Returns an empty
    /// list when the tracked comparison succeeds without changes. Untracked
    /// failures are recoverable; use reviewChanges to also display their warning.
    func changedFiles(repo: String, scope: DiffScope) async throws -> [GitFileChange] {
        try await reviewChanges(repo: repo, scope: scope).files
    }

    /// Load files and their comparison baseline; inputs are repository and scope.
    /// Returns partial tracked results if untracked enumeration fails; throws if
    /// the baseline or tracked comparison fails. Raw diagnostics stay in logs.
    func reviewChanges(repo: String, scope: DiffScope) async throws -> GitReviewChanges {
        switch scope {
        case .workingTree:
            let base = try await workingTreeDiffBase(repo: repo)
            // name-status (kind) + numstat (line counts) run concurrently, then
            // untracked files are appended as additions. `ls-files` runs at the
            // .read tier alongside its siblings — a slow SSH monorepo can take
            // tens of seconds to enumerate untracked entries, so the shorter
            // .poll ceiling can incorrectly interrupt an otherwise healthy read.
            async let names = reviewGit(["diff", base, "--no-renames", "--name-status", "-z"], repo: repo)
            async let nums  = reviewGit(["diff", base, "--no-renames", "--numstat", "-z"], repo: repo)
            async let untrk = reviewGit(["ls-files", "--others", "--exclude-standard", "-z"], repo: repo)
            var map = Self.mergeNameNumstat(
                nameStatus: try await names.stdout,
                numstat: try await nums.stdout)
            var untrackedWarning = false
            do {
                let paths = try await untrk.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                let counts = await runner.countUntrackedAdditions(repo: repo, paths: paths)
                for p in paths {
                    map[p] = GitFileChange(path: p, kind: .untracked,
                                          additions: counts[p] ?? 0,
                                          deletions: 0, isBinary: false)
                }
            } catch {
                untrackedWarning = true
                NSLog("Review untracked loading failed: %@", error.localizedDescription)
            }
            return GitReviewChanges(files: withMtime(map.values.sorted { $0.path < $1.path }, repo: repo),
                                    untrackedWarning: untrackedWarning, baseline: base)

        case .branch(let base):
            async let names = reviewGit(["diff", "\(base)...HEAD", "--no-renames", "--name-status", "-z"], repo: repo)
            async let nums  = reviewGit(["diff", "\(base)...HEAD", "--no-renames", "--numstat", "-z"], repo: repo)
            let map = Self.mergeNameNumstat(
                nameStatus: try await names.stdout,
                numstat: try await nums.stdout)
            return GitReviewChanges(files: withMtime(map.values.sorted { $0.path < $1.path }, repo: repo),
                                    untrackedWarning: false, baseline: "\(base)...HEAD")
        }
    }

    /// Stat each LOCAL file's working-tree path for its modification date — one
    /// cheap syscall per file, nil-safe (a deleted/missing file yields nil).
    /// A non-local runner's `repo` belongs to another filesystem, so leave its
    /// dates empty rather than reading an unrelated same-pathed local file.
    private func withMtime(_ files: [GitFileChange], repo: String) -> [GitFileChange] {
        guard runner is LocalGitRunner else { return files }
        let fm = FileManager.default
        let base = repo as NSString
        return files.map { f in
            var g = f
            g.modDate = (try? fm.attributesOfItem(atPath: base.appendingPathComponent(f.path)))?[.modificationDate] as? Date
            return g
        }
    }

    /// Unified-diff text for one file; throws on Git failure or interruption.
    /// Parameters: repository, scope, changed file, whitespace preference and
    /// an optional working-tree baseline from the same Review list load.
    /// Returns complete diff text, including an empty successful diff.
    /// `ignoreWhitespace` adds `--ignore-all-space` (indentation/whitespace-only
    /// changes collapse to context) — a load-time flag, not a render filter.
    ///
    /// If the runner's watchdog killed git (`r.wasSignaled`), the captured
    /// stdout is whatever was drained before SIGTERM — a mid-stream truncation
    /// of the unified diff. Returning that partial text would render a
    /// complete-looking diff with the tail silently missing, so on signal we
    /// drop the bytes and throw rather than render a complete-looking empty diff.
    func fileDiff(repo: String, scope: DiffScope, file: GitFileChange,
                  ignoreWhitespace: Bool = false, baseline: String? = nil) async throws -> String {
        // Huge -U makes git emit the entire file as context (clamped to file
        // length), so "Show All" renders the whole file and "Changes Only"
        // just filters context at render time. One load serves both states.
        var args = ["diff", "--unified=1000000"]
        if ignoreWhitespace { args.append("--ignore-all-space") }
        let result: GitResult
        switch scope {
        case .workingTree:
            if file.kind == .untracked {
                // No HEAD side — diff against /dev/null so the whole file shows
                // as an addition. `--no-index` exits 1 when files differ (normal).
                // Prepend `args` so the toolbar's Show All / Ignore Whitespace
                // toggles apply uniformly — without this, untracked files were
                // silently exempt from the menu state.
                result = try await reviewGit(args + ["--no-index", "--", "/dev/null", file.path],
                                             repo: repo, allowedExitCodes: [0, 1])
            } else {
                let base: String
                if let baseline { base = baseline }
                else { base = try await workingTreeDiffBase(repo: repo) }
                result = try await reviewGit(args + [base, "--", file.path], repo: repo)
            }
        case .branch(let base):
            result = try await reviewGit(args + ["\(base)...HEAD", "--", file.path], repo: repo)
        }
        return result.stdout
    }

    /// Validate a Review read. Parameters: Git argv, repository and permitted
    /// exit codes. Returns complete output; throws for interruption or failure.
    private func reviewGit(_ args: [String], repo: String,
                           allowedExitCodes: [Int32] = [0]) async throws -> GitResult {
        let result = try await git(args, cwd: repo, allowFailure: true, timeout: .read)
        guard !result.wasSignaled, allowedExitCodes.contains(result.exitCode) else {
            throw GitError.commandFailed(args: args, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Resolve the working-tree baseline. Parameter: repository directory.
    /// Returns the resolved HEAD OID or repository-format empty tree for an unborn branch;
    /// throws for invalid repositories, broken refs and other Git failures.
    private func workingTreeDiffBase(repo: String) async throws -> String {
        let headArgs = ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]
        let head = try await reviewGit(headArgs, repo: repo, allowedExitCodes: [0, 1])
        if head.ok { return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard head.stderr.isEmpty else {
            throw GitError.commandFailed(args: headArgs, exitCode: head.exitCode, stderr: head.stderr)
        }
        let branch = try await reviewGit(["symbolic-ref", "--quiet", "HEAD"], repo: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await reviewGit(["show-ref", "--verify", "--quiet", branch],
                                            repo: repo, allowedExitCodes: [0, 1])
        guard existing.exitCode == 1, existing.stderr.isEmpty else {
            throw GitError.commandFailed(args: headArgs, exitCode: head.exitCode, stderr: head.stderr)
        }
        // Hashing the empty tree uses this repository's object format without
        // writing an object or assuming SHA-1's well-known empty-tree hash.
        return try await reviewGit(["hash-object", "-t", "tree", "--", "/dev/null"], repo: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: parsing

    /// Merge literal paths from NUL-delimited Git output. Parameters:
    /// `nameStatus` from `--name-status -z --no-renames` and `numstat` from
    /// `--numstat -z --no-renames`. Returns changes keyed by their actual paths.
    /// Explicitly disabling renames keeps delete/add paths aligned even when
    /// the repository enables rename detection; NUL avoids Git's quoted paths.
    static func mergeNameNumstat(nameStatus: String, numstat: String) -> [String: GitFileChange] {
        var kinds: [String: GitFileChange.Kind] = [:]
        var names = nameStatus.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let code = names.next(), let rawPath = names.next() {
            let path = String(rawPath)
            switch code.first {
            case "A": kinds[path] = .added
            case "D": kinds[path] = .deleted
            case "R": kinds[path] = .renamed
            default:  kinds[path] = .modified
            }
        }
        var out: [String: GitFileChange] = [:]
        for line in numstat.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let a = String(parts[0]); let d = String(parts[1]); let path = String(parts[2])
            let binary = (a == "-" || d == "-")   // numstat marks binary files with "-"
            out[path] = GitFileChange(path: path, kind: kinds[path] ?? .modified,
                                      additions: Int(a) ?? 0, deletions: Int(d) ?? 0, isBinary: binary)
        }
        // Mode-only entries can appear in name-status but not numstat.
        for (path, kind) in kinds where out[path] == nil {
            out[path] = GitFileChange(path: path, kind: kind, additions: 0, deletions: 0, isBinary: false)
        }
        return out
    }
}
