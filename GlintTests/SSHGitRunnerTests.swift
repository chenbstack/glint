import XCTest
@testable import Glint

/// `SSHGitRunner` runs git over a captured ssh destination. The runner itself
/// shells out to `/usr/bin/ssh`, so it's covered manually — but the exact argv
/// it assembles (transport, ControlMaster, `-C <remote-path>`, port) is pure
/// and worth pinning: a wrong flag here means Review silently misses or hangs.
final class SSHGitRunnerTests: XCTestCase {

    func testBasicArgv() {
        let a = SSHGitRunner.commandArgs(target: "deploy@prod-server", port: nil,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "~/code/api", gitArgs: ["status"])
        XCTAssertEqual(a, [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=10m",
            "-o", "ControlPath=/tmp/x.sock",
            "deploy@prod-server",
            "git", "-C", "~/code/api", "status"
        ])
    }

    func testPortInserted() {
        let a = SSHGitRunner.commandArgs(target: "host", port: 2222,
                                         controlPath: "/tmp/x.sock",
                                         cwd: "/srv/app", gitArgs: ["rev-parse", "--show-toplevel"])
        let portIndex = a.firstIndex(of: "-p")
        XCTAssertNotNil(portIndex)
        XCTAssertEqual(a[portIndex! + 1], "2222")
        // cwd present → `-C` lands right after `git`.
        let gitIndex = a.firstIndex(of: "git")!
        XCTAssertEqual(a[gitIndex + 1], "-C")
        XCTAssertEqual(a[gitIndex + 2], "/srv/app")
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
}
