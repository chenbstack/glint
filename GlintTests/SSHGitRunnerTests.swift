import XCTest
@testable import Glint

/// `SSHGitRunner` runs git over a captured ssh destination. The runner itself
/// shells out to `/usr/bin/ssh`, so it's covered manually — but the exact argv
/// it assembles (transport, ControlMaster, `-C <remote-path>`, port) is pure
/// and worth pinning: a wrong flag here means Review silently misses or hangs.
final class SSHGitRunnerTests: XCTestCase {

    func testBasicArgv() {
        // Absolute cwd lands single-quoted; a non-flag gitArg ("status") is
        // also quoted because the remote login shell re-parses every token.
        let a = SSHGitRunner.commandArgs(target: "deploy@prod-server", port: nil,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "/home/deploy/code/api", gitArgs: ["status"])
        XCTAssertEqual(a, [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=10m",
            "-o", "ControlPath=/tmp/x.sock",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
            "deploy@prod-server",
            "git", "-C", "'/home/deploy/code/api'", "'status'"
        ])
    }

    func testPortInserted() {
        let a = SSHGitRunner.commandArgs(target: "host", port: 2222,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "/srv/app", gitArgs: ["rev-parse", "--show-toplevel"])
        let portIndex = a.firstIndex(of: "-p")
        XCTAssertNotNil(portIndex)
        XCTAssertEqual(a[portIndex! + 1], "2222")
        // cwd present → `-C` lands right after `git`, single-quoted.
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 1], "-C")
        XCTAssertEqual(a[gitIndex + 2], "'/srv/app'")
    }

    func testNilCwdOmitsCFlag() {
        let a = SSHGitRunner.commandArgs(target: "host", port: nil,
                                         controlPath: "/tmp/x.sock",
                                         cwd: nil, gitArgs: ["status"])
        let gitIndex = a.firstIndex(of: "git")!
        // Immediately after `git` come the git args (quoted), with no `-C` injected.
        XCTAssertEqual(a[gitIndex + 1], "'status'")
        XCTAssertFalse(a.contains("-C"))
    }

    func testAlwaysForcesBatchMode() {
        // BatchMode=yes must always be present so a missing key never hangs a
        // background Review/status call.
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/x", cwd: nil, gitArgs: [])
        let idx = a.firstIndex(of: "BatchMode=yes")
        XCTAssertNotNil(idx)
        XCTAssertEqual(a[idx! - 1], "-o")
    }

    /// ssh joins our remote-command args with spaces and hands them to the
    /// REMOTE LOGIN SHELL, which re-parses the whole string — so cwd must be
    /// single-quoted at the argv layer to neutralize `;` / `$(…)` / backtick /
    /// space. The cwd ultimately comes from a remote terminal title that
    /// anyone with PS1 access controls, so this is a real injection sink.
    func testCwdShellQuotedForInjection() {
        let a = SSHGitRunner.commandArgs(target: "host", port: nil,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "/srv/app; rm -rf ~",
                                         gitArgs: ["status"])
        let gitIndex = a.firstIndex(of: "git")!
        // The malicious payload is fully contained in one shell-quoted token,
        // so the remote shell sees one literal cwd arg — not two commands.
        XCTAssertEqual(a[gitIndex + 1], "-C")
        XCTAssertEqual(a[gitIndex + 2], "'/srv/app; rm -rf ~'")
    }

    /// A `'` inside cwd must be closed-escaped-reopened (`'\''`) so the wrapper
    /// single-quote isn't terminated mid-payload. POSIX-portable construction.
    func testShellQuoteEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(posixShellQuoted("a'b"), "'a'\\''b'")
    }

    /// A leading `~` (or `~user`) MUST stay unquoted so the remote login shell
    /// performs tilde expansion against the user's actual `$HOME` — otherwise
    /// `~/proj` would land at a literal directory called `~`. Everything after
    /// the tilde segment is single-quoted so spaces/metachars are still safe.
    func testCommandArgsPreservesLeadingTildeUnquoted() {
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "~/code/api", gitArgs: ["status"])
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 1], "-C")
        XCTAssertEqual(a[gitIndex + 2], "~'/code/api'")
    }

    /// `~admin/proj` must expand to admin's home (not the login user's), so the
    /// whole `~admin` prefix stays unquoted as one shell tilde-prefix word.
    func testTildeUserPreserved() {
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/x", cwd: "~admin/proj", gitArgs: [])
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 2], "~admin'/proj'")
    }

    /// Bare `~` (no slash) means `$HOME` — keep it unquoted with nothing
    /// appended; quoting it would yield a literal directory `~`.
    func testBareTildeUnquoted() {
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/x", cwd: "~", gitArgs: [])
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 2], "~")
    }

    /// gitArgs themselves are re-parsed by the remote shell, so every one
    /// (flags included) must round-trip as a single token. A revision spec
    /// like `main^{commit}` contains shell metachars that would otherwise
    /// blow up — must be quoted at the wire layer.
    func testGitArgsAreShellQuoted() {
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/x", cwd: nil,
                                         gitArgs: ["log", "--format=%H %s", "main^{commit}"])
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(Array(a[(gitIndex + 1)...]),
                       ["'log'", "'--format=%H %s'", "'main^{commit}'"])
    }

    /// Belt-and-suspenders: if a `~`-prefix segment ever DID contain a shell
    /// metachar (the title allowlist should keep this from happening, but
    /// `quoteRemoteCwd` re-validates so the safety doesn't depend on a caller),
    /// fall back to fully single-quoting the whole path — losing tilde
    /// expansion but never letting a metachar reach the remote shell.
    func testTildeWithMetacharsFallsBackToFullQuote() {
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/x",
                                         cwd: "~bad;rm/proj", gitArgs: [])
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 2], "'~bad;rm/proj'")
    }

    /// Dotted corp usernames (LDAP/AD `admin.user`) are the most common
    /// `~user`-form Review hits in the wild. Must stay UNQUOTED so the remote
    /// shell tilde-expands them; previously `.` wasn't in the carve-out
    /// allowlist, so the path silently fell through to literal quoting and
    /// every dotted-user Review showed "Not a git repository".
    func testTildeDottedUsernamePreserved() {
        let a = SSHGitRunner.commandArgs(target: "h", port: nil,
                                         controlPath: "/x",
                                         cwd: "~admin.user/proj", gitArgs: [])
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 2], "~admin.user'/proj'")
    }
}
