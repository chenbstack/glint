import CryptoKit
import Foundation

// MARK: - Out-of-band git
//
// Plan B: worktree (and later remote) git work runs as a *managed subprocess*,
// NOT by typing commands into the user's visible Ghostty PTY. The terminal stays
// the user's / agent's interactive surface; everything here captures stdout so
// the native UI can show progress, parse status, and report conflicts as proper
// dialogs instead of leaving a cryptic git error in the scrollback.
//
// `GitRunner` is the seam for Phase 2: `LocalGitRunner` shells out via `Process`
// today; an `SSHGitRunner` can conform later and every high-level `GitService`
// method below keeps working unchanged.

struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
}

enum GitError: Error, LocalizedError {
    case launchFailed(String)
    case commandFailed(args: [String], exitCode: Int32, stderr: String)
    case notARepository(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m):
            return "Couldn't run git: \(m)"
        case .commandFailed(let args, let code, let stderr):
            let cmd = (["git"] + args).joined(separator: " ")
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "`\(cmd)` failed (exit \(code))"
                                  : "`\(cmd)` failed: \(detail)"
        case .notARepository(let path):
            return "Not a git repository: \(path)"
        }
    }
}

/// Where git runs. Local now; an SSH runner can conform later (Phase 2) and the
/// high-level `GitService` methods stay identical — `cwd` just resolves remotely.
protocol GitRunner: Sendable {
    /// Run `git args` with the runner's notion of `cwd`. Never throws on a
    /// non-zero git exit (that's a normal signal, e.g. "branch missing"); only
    /// throws if the process itself couldn't be launched.
    func run(_ args: [String], cwd: String?) async throws -> GitResult
}

/// Runs git as a local subprocess. The app is non-sandboxed, so this is
/// unrestricted. Reads both pipes concurrently so neither pipe's fixed buffer
/// can deadlock on large output, and disables interactive prompts/pagers so a
/// stray credential/pager prompt can never hang a background call.
struct LocalGitRunner: GitRunner {
    var gitPath: String = "/usr/bin/git"

    func run(_ args: [String], cwd: String?) async throws -> GitResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: gitPath)
                proc.arguments = args
                if let cwd, !cwd.isEmpty {
                    proc.currentDirectoryURL =
                        URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
                }
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"   // never block on a credential prompt
                env["GIT_PAGER"] = "cat"            // never invoke a pager
                env["GIT_OPTIONAL_LOCKS"] = "0"     // don't take index.lock just to read status
                proc.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: GitError.launchFailed(error.localizedDescription))
                    return
                }

                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                let q = DispatchQueue(label: "app.glint.git.read", attributes: .concurrent)
                q.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
                q.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }
                group.wait()
                proc.waitUntilExit()

                cont.resume(returning: GitResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

/// POSIX shell single-quote: every byte passes through literally; an embedded
/// `'` is terminated, backslash-escaped, and reopened so the result is exactly
/// one re-parse-safe shell word. Use for any value that will be re-parsed by a
/// shell (a local `sh -c` command line, the remote-command portion of an ssh
/// invocation, anything written into a script). One canonical implementation
/// so all the call sites stay byte-equivalent.
func posixShellQuoted(_ s: String) -> String {
    if !s.contains("'") { return "'\(s)'" }
    return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
}

/// Runs git over SSH against a captured destination, so `GitService`'s
/// high-level methods work unchanged against a REMOTE repo. `cwd` is the
/// remote path; the runner POSIX-quotes it (and every `gitArg`) before
/// handing it to ssh so the remote login shell — which re-parses the entire
/// remote-command portion ssh sends it — sees one literal token per element.
/// A leading `~` in `cwd` is preserved UNQUOTED so the remote shell performs
/// tilde expansion against the user's actual `$HOME` (no local round-trip to
/// resolve `$HOME` first; no cache to poison).
///
/// Reuses a per-target SSH `ControlMaster` so the status poll and the Review
/// window don't each re-authenticate, and forces `BatchMode` so a missing key
/// never hangs a background call (a host needing an interactive password
/// degrades to empty results, same shape as a local non-repo). The remote
/// title/host data that produces `target`/`cwd` is untrusted (anyone who can
/// set the remote `PS1`/`PROMPT_COMMAND` controls it); this runner only ever
/// runs read-only `git`, so the worst a spoofed title can do is query a repo
/// on a host the user already SSHed to.
struct SSHGitRunner: GitRunner {
    let target: String
    let port: Int?
    /// Per-target ControlMaster socket so repeated calls share one authed
    /// connection; `ControlPersist=10m` keeps it alive briefly after the last
    /// call so a Review open right after a status poll reuses it.
    ///
    /// Hashed (not sanitized) on purpose: a naive `[^A-Za-z0-9] → "-"` slug
    /// collapses `deploy.prod.server` / `deploy-prod-server` / `deploy_prod_server`
    /// into the same path, so two distinct destinations would share a mux and
    /// the second ssh would tunnel through the first's connection — i.e. land
    /// on the wrong host. Hashing is also short enough to fit comfortably under
    /// macOS's 104-byte unix socket path limit even for long ssh aliases.
    let controlPath: String

    init(target: String, port: Int?) {
        self.target = target
        self.port = port
        var slug = target
        if let port { slug += ":\(port)" }
        let digest = SHA256.hash(data: Data(slug.utf8))
        let safe = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        self.controlPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-ssh-\(safe).sock").path
    }

    func run(_ args: [String], cwd: String?) async throws -> GitResult {
        let argv = Self.commandArgs(target: target, port: port,
                                    controlPath: controlPath, cwd: cwd, gitArgs: args)
        return try await Self.spawn(argv)
    }

    /// Pure: the full `ssh … git -C <cwd> <args>` argv. Split out so the wire
    /// format is unit-testable without spawning ssh.
    ///
    /// **Every element after `target` is POSIX-quoted on purpose.** `Process`
    /// passes our argv to `/usr/bin/ssh` without a shell, but ssh joins the
    /// remote-command portion with spaces and hands the resulting string to
    /// the REMOTE LOGIN SHELL, which re-parses it. So any unquoted `;` /
    /// `$(…)` / backtick / space in any element (cwd OR gitArg) would execute
    /// arbitrary remote code in the user's authenticated session. Callers may
    /// thread remote-derived data through both, so both layers must quote.
    ///
    /// `cwd` is handled specially: a leading `~` (or `~user`) is kept unquoted
    /// so the remote shell can perform tilde expansion, and the rest of the
    /// path is single-quoted — see `quoteRemoteCwd`.
    static func commandArgs(target: String, port: Int?, controlPath: String,
                            cwd: String?, gitArgs: [String]) -> [String] {
        var a = ["-o", "BatchMode=yes",
                 "-o", "ControlMaster=auto", "-o", "ControlPersist=10m",
                 "-o", "ControlPath=\(controlPath)"]
        if let port { a += ["-p", "\(port)"] }
        a.append(target)
        a.append("git")
        if let cwd, !cwd.isEmpty { a += ["-C", quoteRemoteCwd(cwd)] }
        a += gitArgs.map(posixShellQuoted)
        return a
    }

    /// Quote `cwd` for inclusion as `git -C <quoted>` in the remote command.
    /// Single-quotes everything EXCEPT a leading `~` (or `~user`) segment,
    /// which is left unquoted so the remote login shell performs tilde
    /// expansion. Bash's default `\w` PS1 prints `~/proj` for the user's home
    /// — keeping that working is the whole point of the carve-out.
    ///
    /// Examples (assuming remote `$HOME=/home/deploy`):
    ///   `~/proj`         → `~'/proj'`          → `/home/deploy/proj`
    ///   `~admin/proj`    → `~admin'/proj'`     → admin's `$HOME` + `/proj`
    ///   `~`              → `~`                  → `/home/deploy`
    ///   `/abs/path`      → `'/abs/path'`       → literal
    ///   `/srv/has space` → `'/srv/has space'`  → literal (space safe in quotes)
    ///
    /// The tilde-prefix carve-out is only safe when it has no shell metachars
    /// itself; the title path allowlist guarantees this, but we re-validate
    /// here so the safety doesn't rely on a caller in a different file.
    /// Allowed in the `~user` part: ASCII alnum + `_`/`-`/`.` — covers the
    /// common corp LDAP/AD `admin.user` form that bash's `getpwnam` resolves
    /// fine. Other chars the path allowlist accepts (space, `+`, `,`, `()`,
    /// `=`, `@`, CJK letters, …) are valid POSIX usernames in theory but
    /// either bash won't tilde-expand them or they cross into metachar
    /// territory once the carve-out is unquoted, so we keep the conservative
    /// fallback to fully single-quoting the whole path. Net effect for those:
    /// no tilde expansion — but no Review breakage either, since the path
    /// allowlist was loosened to UNQUOTED rendering, not "must be unquoted."
    static func quoteRemoteCwd(_ cwd: String) -> String {
        guard cwd.hasPrefix("~") else { return posixShellQuoted(cwd) }
        let slash = cwd.firstIndex(of: "/")
        let tildePart = String(cwd[..<(slash ?? cwd.endIndex)])
        let safe = tildePart.allSatisfy {
            $0 == "~" || $0 == "_" || $0 == "-" || $0 == "."
                || ($0 >= "a" && $0 <= "z")
                || ($0 >= "A" && $0 <= "Z")
                || ($0 >= "0" && $0 <= "9")
        }
        guard safe else { return posixShellQuoted(cwd) }
        guard let slash else { return tildePart }
        return tildePart + posixShellQuoted(String(cwd[slash...]))
    }

    /// Spawn `/usr/bin/ssh <args>` and capture stdout/stderr — mirrors
    /// `LocalGitRunner`'s concurrent-read layout so neither fixed pipe buffer
    /// can deadlock on large diff output.
    private static func spawn(_ sshArgs: [String]) async throws -> GitResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = sshArgs
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_PAGER"] = "cat"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                proc.environment = env
                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do { try proc.run() } catch {
                    cont.resume(throwing: GitError.launchFailed(error.localizedDescription))
                    return
                }
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                let q = DispatchQueue(label: "app.glint.git.read", attributes: .concurrent)
                q.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
                q.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }
                group.wait()
                proc.waitUntilExit()
                cont.resume(returning: GitResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

// MARK: - High-level git operations

/// A single entry from `git worktree list --porcelain`.
struct GitWorktree: Hashable {
    var path: String
    var head: String           // commit sha (HEAD)
    var branch: String?        // short branch name, nil if detached/bare
    var isBare: Bool
    var isDetached: Bool
    var isLocked: Bool
}

/// Lightweight working-tree status for the sidebar card / tab popover. Cheap to
/// poll: one `status --porcelain=v2 --branch` plus one `log -1`.
struct GitStatus: Equatable {
    var branch: String?        // nil ⇒ detached HEAD
    var upstream: String?
    var ahead: Int
    var behind: Int
    var dirtyCount: Int        // tracked changes + untracked entries
    var lastCommitSubject: String?
    var lastCommitRelative: String?

    var isDirty: Bool { dirtyCount > 0 }
}

struct GitService {
    var runner: GitRunner = LocalGitRunner()

    /// Run git, throwing `commandFailed` on a non-zero exit unless `allowFailure`
    /// (used for the many "exit code IS the answer" probes like branch-exists).
    @discardableResult
    func git(_ args: [String], cwd: String?, allowFailure: Bool = false) async throws -> GitResult {
        let r = try await runner.run(args, cwd: cwd)
        if !r.ok && !allowFailure {
            throw GitError.commandFailed(args: args, exitCode: r.exitCode, stderr: r.stderr)
        }
        return r
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: discovery

    /// Absolute repo root for `path` (the main worktree's top level), or nil if
    /// `path` isn't inside a git repository.
    func repoRoot(at path: String) async -> String? {
        guard let r = try? await git(["rev-parse", "--show-toplevel"], cwd: path, allowFailure: true),
              r.ok else { return nil }
        let root = trimmed(r.stdout)
        return root.isEmpty ? nil : root
    }

    func isRepository(at path: String) async -> Bool {
        await repoRoot(at: path) != nil
    }

    /// Short current branch name, or nil if detached / not a repo.
    func currentBranch(at path: String) async -> String? {
        guard let r = try? await git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path, allowFailure: true),
              r.ok else { return nil }
        let b = trimmed(r.stdout)
        return (b.isEmpty || b == "HEAD") ? nil : b
    }

    /// True if a local branch `name` already exists (drives the New-Worktree
    /// sheet's live "✓ available / ✗ exists" check).
    func localBranchExists(repo: String, name: String) async -> Bool {
        guard !name.isEmpty,
              let r = try? await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"],
                                     cwd: repo, allowFailure: true)
        else { return false }
        return r.ok
    }

    /// True if `name` is a syntactically valid git branch name. The single seam
    /// that knows git's ref-name rules — defends `addWorktree`/the sheet from
    /// names git itself rejects (spaces, `..`, leading `-`, trailing `.lock`,
    /// control chars) instead of letting them fail deep inside `worktree add`.
    func isValidBranchName(_ name: String, repo: String) async -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        // git refnames can't begin with '-'; rejecting it locally also stops the
        // name from being parsed as an option by check-ref-format below.
        guard !n.isEmpty, !n.hasPrefix("-") else { return false }
        guard let r = try? await git(["check-ref-format", "--branch", n],
                                     cwd: repo, allowFailure: true) else { return false }
        return r.ok
    }

    // MARK: worktrees

    func worktrees(repo: String) async throws -> [GitWorktree] {
        let r = try await git(["worktree", "list", "--porcelain"], cwd: repo)
        return Self.parseWorktrees(r.stdout)
    }

    static func parseWorktrees(_ porcelain: String) -> [GitWorktree] {
        var out: [GitWorktree] = []
        // Records are separated by blank lines; each starts with a `worktree` line.
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?, head = "", branch: String?
            var bare = false, detached = false, locked = false
            for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
                let l = String(line)
                if l.hasPrefix("worktree ") { path = String(l.dropFirst("worktree ".count)) }
                else if l.hasPrefix("HEAD ") { head = String(l.dropFirst("HEAD ".count)) }
                else if l.hasPrefix("branch ") {
                    let ref = String(l.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                }
                else if l == "bare" { bare = true }
                else if l == "detached" { detached = true }
                else if l == "locked" || l.hasPrefix("locked ") { locked = true }
            }
            if let path, !path.isEmpty {
                out.append(GitWorktree(path: path, head: head, branch: branch,
                                       isBare: bare, isDetached: detached, isLocked: locked))
            }
        }
        return out
    }

    /// Create a worktree at `path`. With `newBranch` set, also creates that
    /// branch off `base` (`git worktree add -b <branch> <path> <base>`); without
    /// it, checks out an existing `base` ref into the new worktree.
    @discardableResult
    func addWorktree(repo: String, path: String, newBranch: String?, base: String) async throws -> GitWorktree {
        let expanded = (path as NSString).expandingTildeInPath
        // Make sure the parent exists; `git worktree add` won't mkdir -p.
        try? FileManager.default.createDirectory(
            atPath: (expanded as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        var args = ["worktree", "add"]
        if let newBranch, !newBranch.isEmpty { args += ["-b", newBranch] }
        // `--` ends option parsing: without it a path or base ref beginning with
        // `-` (e.g. `--detach`) would be read by git as an option, not a value.
        args += ["--", expanded, base]
        try await git(args, cwd: repo)

        let list = try await worktrees(repo: repo)
        return list.first { ($0.path as NSString).standardizingPath == (expanded as NSString).standardizingPath }
            ?? GitWorktree(path: expanded, head: "", branch: newBranch,
                           isBare: false, isDetached: false, isLocked: false)
    }

    /// Copy `base`'s uncommitted working-tree state into a freshly created
    /// `worktree`, leaving `base` untouched (the originals stay put). Tracked
    /// edits (staged + unstaged) replay through a `diff HEAD` patch; genuinely
    /// untracked files — gitignored ones excluded — are copied across. The
    /// patch applies onto an identical HEAD by construction, so it can't
    /// conflict; per-file copies are best-effort.
    func carryWorkingTree(from base: String, to worktree: String) async throws {
        let wt = (worktree as NSString).expandingTildeInPath

        // 1) Tracked changes relative to HEAD. `git diff --output=<file>` writes
        //    the patch straight to disk: capturing it as stdout would round-trip
        //    the bytes through the runner's lossy UTF-8 decode (then a re-encode
        //    on write), corrupting any binary hunk or non-UTF-8 text file so
        //    `git apply` silently fails. Letting git own the file keeps it exact.
        let patch = NSTemporaryDirectory() + "glint-carry-\(UUID().uuidString).patch"
        defer { try? FileManager.default.removeItem(atPath: patch) }
        try await git(["diff", "HEAD", "--binary", "--output=\(patch)"], cwd: base)
        // `--output` writes an empty file when there are no tracked changes;
        // skip the apply in that case (and avoid a needless subprocess).
        let attrs = try? FileManager.default.attributesOfItem(atPath: patch)
        let patchSize = (attrs?[.size] as? Int) ?? 0
        if patchSize > 0 {
            try await git(["apply", "--whitespace=nowarn", "--", patch], cwd: wt)
        }

        // 2) Untracked, non-ignored files (build artifacts stay out via
        //    --exclude-standard). Copied verbatim, preserving relative layout.
        let others = try await git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: base)
        let fm = FileManager.default
        for rel in others.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let relPath = String(rel)
            let src = (base as NSString).appendingPathComponent(relPath)
            let dst = (wt as NSString).appendingPathComponent(relPath)
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
    }

    /// Remove a worktree directory (`git worktree remove`). `force` allows
    /// removal even with uncommitted changes — the UI gates this behind an
    /// explicit confirm.
    func removeWorktree(repo: String, path: String, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args += ["--", (path as NSString).expandingTildeInPath]   // `--`: path may start with `-`
        try await git(args, cwd: repo)
    }

    func deleteBranch(repo: String, name: String, force: Bool) async throws {
        try await git(["branch", force ? "-D" : "-d", "--", name], cwd: repo)   // `--`: name may start with `-`
    }

    func prune(repo: String) async throws {
        try await git(["worktree", "prune"], cwd: repo)
    }

    func fetch(repo: String, remote: String = "origin") async throws {
        try await git(["fetch", remote, "--prune"], cwd: repo)
    }

    // MARK: status

    func status(at path: String) async throws -> GitStatus {
        // The status and the HEAD-commit lookup are independent — run them
        // concurrently so each poll costs one round-trip, not two sequential
        // subprocess waits (matters with N workspaces polled every ~5s).
        async let statusR = git(["status", "--porcelain=v2", "--branch"], cwd: path)
        async let logR = git(["log", "-1", "--format=%s%n%cr"], cwd: path, allowFailure: true)
        var s = Self.parseStatus((try await statusR).stdout)
        // Subject + relative date of HEAD; empty repo (no commits) just leaves nil.
        if let log = try? await logR, log.ok {
            let lines = log.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if lines.count >= 1 { s.lastCommitSubject = trimmed(String(lines[0])) }
            if lines.count >= 2 { s.lastCommitRelative = trimmed(String(lines[1])) }
        }
        return s
    }

    static func parseStatus(_ porcelain: String) -> GitStatus {
        var s = GitStatus(branch: nil, upstream: nil, ahead: 0, behind: 0,
                          dirtyCount: 0, lastCommitSubject: nil, lastCommitRelative: nil)
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            if l.hasPrefix("# branch.head ") {
                let h = String(l.dropFirst("# branch.head ".count))
                s.branch = (h == "(detached)") ? nil : h
            } else if l.hasPrefix("# branch.upstream ") {
                s.upstream = String(l.dropFirst("# branch.upstream ".count))
            } else if l.hasPrefix("# branch.ab ") {
                // "# branch.ab +A -B"
                let parts = l.dropFirst("# branch.ab ".count).split(separator: " ")
                for p in parts {
                    if p.hasPrefix("+") { s.ahead = Int(p.dropFirst()) ?? 0 }
                    else if p.hasPrefix("-") { s.behind = Int(p.dropFirst()) ?? 0 }
                }
            } else if !l.hasPrefix("#") {
                // Any non-header line is a changed/untracked/unmerged entry.
                s.dirtyCount += 1
            }
        }
        return s
    }

    // MARK: paths

    /// Default suggested worktree location: `~/glint/worktrees/<repo>/<slug>`.
    /// Discoverable in Finder (not hidden under a dotfile) — see requirements #2.
    static func defaultWorktreeRoot() -> String {
        (("~/glint/worktrees") as NSString).expandingTildeInPath
    }

    static func suggestedWorktreePath(repoRoot: String, branch: String) -> String {
        let repoName = (repoRoot as NSString).lastPathComponent
        let s = slug(branch)
        let withRepo = (defaultWorktreeRoot() as NSString).appendingPathComponent(repoName)
        return (withRepo as NSString).appendingPathComponent(s.isEmpty ? "worktree" : s)
    }

    /// `feature/Fix Theme Catalog` → `fix-theme-catalog`. Last path component,
    /// lowercased, non-alphanumerics collapsed to single dashes.
    static func slug(_ s: String) -> String {
        let last = s.split(separator: "/").last.map(String.init) ?? s
        let lowered = last.lowercased()
        var result = ""
        var prevDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                result.append(ch); prevDash = false
            } else if !prevDash {
                result.append("-"); prevDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
