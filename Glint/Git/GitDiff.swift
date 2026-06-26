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
            async let names = git(["diff", "HEAD", "--name-status"], cwd: repo, allowFailure: true)
            async let nums  = git(["diff", "HEAD", "--numstat"], cwd: repo, allowFailure: true)
            async let untrk = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: repo, allowFailure: true)
            var map = Self.mergeNameNumstat(
                nameStatus: (try? await names)?.stdout ?? "",
                numstat: (try? await nums)?.stdout ?? "")
            if let u = try? await untrk, u.ok {
                for path in u.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
                    let p = String(path)
                    map[p] = GitFileChange(path: p, kind: .untracked,
                                           additions: Self.lineCount(repo: repo, relPath: p),
                                           deletions: 0, isBinary: false)
                }
            }
            return map.values.sorted { $0.path < $1.path }

        case .branch(let base):
            async let names = git(["diff", "\(base)...HEAD", "--name-status"], cwd: repo, allowFailure: true)
            async let nums  = git(["diff", "\(base)...HEAD", "--numstat"], cwd: repo, allowFailure: true)
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
                let r = try? await git(["diff", "--no-index", "--", "/dev/null", file.path],
                                       cwd: repo, allowFailure: true)
                return r?.stdout ?? ""
            }
            let r = try? await git(args + ["HEAD", "--", file.path],
                                   cwd: repo, allowFailure: true)
            return r?.stdout ?? ""
        case .branch(let base):
            let r = try? await git(args + ["\(base)...HEAD", "--", file.path],
                                   cwd: repo, allowFailure: true)
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

    /// Best-effort newline count of an untracked file. Skips reading anything
    /// over 512 KB or non-UTF8 (binary) so a huge/binary untracked file can't
    /// stall or balloon the file list.
    private static func lineCount(repo: String, relPath: String) -> Int {
        let full = (repo as NSString).appendingPathComponent(relPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
              let size = attrs[.size] as? Int, size <= 512 * 1024,
              let text = try? String(contentsOfFile: full, encoding: .utf8) else { return 0 }
        if text.isEmpty { return 0 }
        return text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + (text.hasSuffix("\n") ? 0 : 1)
    }
}
