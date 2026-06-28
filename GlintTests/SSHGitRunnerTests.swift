import XCTest
@testable import Glint

/// `SSHGitRunner` runs git over a captured ssh destination. The runner itself
/// shells out to `/usr/bin/ssh`, so it's covered manually — but the exact argv
/// it assembles (transport, ControlMaster, `-C <remote-path>`, port) is pure
/// and worth pinning: a wrong flag here means Review silently misses or hangs.
final class SSHGitRunnerTests: XCTestCase {

    func testBasicArgv() {
        // Production `cwd` reaches commandArgs already `~`-expanded by
        // `resolveRemoteCwd` (so the remote login shell sees a literal absolute
        // path, not a metachar that needs re-expansion). The unit test reflects
        // that: a normal absolute path lands single-quoted, with the rest of
        // the argv untouched.
        let a = SSHGitRunner.commandArgs(target: "deploy@prod-server", port: nil,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "/home/deploy/code/api", gitArgs: ["status"])
        XCTAssertEqual(a, [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=10m",
            "-o", "ControlPath=/tmp/x.sock",
            "deploy@prod-server",
            "git", "-C", "'/home/deploy/code/api'", "status"
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
        // Immediately after `git` come the git args, with no `-C` injected.
        XCTAssertEqual(a[gitIndex + 1], "status")
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
        let q = SSHGitRunner.shellQuote("a'b")
        XCTAssertEqual(q, "'a'\\''b'")
    }
}
