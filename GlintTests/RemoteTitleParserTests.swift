import XCTest
@testable import Glint

/// `GhosttySurfaceView.parseRemoteTitle` is the one piece of real logic behind
/// Review-over-SSH's remote-cwd capture: it mines `user@host:path` out of the
/// terminal title the remote shell prints at each prompt (bash default
/// `\u@\h:\w`). Titles that carry no cwd must return nil so Review degrades
/// gracefully instead of guessing. The surface/ghostty plumbing that delivers
/// the title is covered manually; these tests lock the parser.
final class RemoteTitleParserTests: XCTestCase {

    func testBashDefaultTitle() {
        let r = GhosttySurfaceView.parseRemoteTitle("deploy@prod-server:~/code/api")
        XCTAssertEqual(r?.user, "deploy")
        XCTAssertEqual(r?.host, "prod-server")
        XCTAssertEqual(r?.path, "~/code/api")
    }

    func testAbsolutePath() {
        let r = GhosttySurfaceView.parseRemoteTitle("root@1.2.3.4:/etc/nginx")
        XCTAssertEqual(r?.user, "root")
        XCTAssertEqual(r?.host, "1.2.3.4")
        XCTAssertEqual(r?.path, "/etc/nginx")
    }

    func testFQDNHost() {
        let r = GhosttySurfaceView.parseRemoteTitle("ci@build.example.com:/srv/app")
        XCTAssertEqual(r?.host, "build.example.com")
        XCTAssertEqual(r?.path, "/srv/app")
    }

    func testTrimsSurroundingWhitespace() {
        let r = GhosttySurfaceView.parseRemoteTitle("  deploy@prod-server:~/x  ")
        XCTAssertEqual(r?.user, "deploy")
        XCTAssertEqual(r?.path, "~/x")
    }

    func testNoAtSignReturnsNil() {
        // A local window title with a colon but no `user@host` must not parse.
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("My Mac — zsh"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("~/code/api"))
    }

    func testNoColonReturnsNil() {
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("deploy@prod-server"))
    }

    func testEmptyPathReturnsNil() {
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("deploy@prod-server:"))
    }

    func testUserWithSpaceReturnsNil() {
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("a b@host:/x"))
    }

    func testHostWithInvalidCharsReturnsNil() {
        // host must be letter/digit/.-/_ — a space in the host segment is not
        // a real hostname, so reject rather than mis-parse.
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@ho st:/x"))
    }

    /// Path is restricted to a metachar-free allowlist as belt-and-suspenders
    /// for the single-quoting at the SSH-runner layer: a malicious remote `PS1`
    /// could set the title to anything, but the obvious-injection set must
    /// never reach the wire. Spaces, `@`, `()`, `+`, `=`, `,` are NOT
    /// metachars (they're literal inside POSIX single quotes) and parse — see
    /// the `Allows…` tests below for the legitimate uses they cover.
    func testPathRejectsShellMetacharacters() {
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x;rm -rf ~"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x$(whoami)"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x`id`"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x&y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x|y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x\"y\""))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x>y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x<y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x*y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x?y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x[y]"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x\\y"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/x'y'"))
    }

    /// Confirm legitimate POSIX paths still parse — leading `~`, absolute,
    /// nested, dotfiles, hyphens, underscores, digits. Otherwise the
    /// allowlist would over-reject and silently kill Review on normal hosts.
    func testPathAllowsTypicalPosixPaths() {
        XCTAssertNotNil(GhosttySurfaceView.parseRemoteTitle("u@host:~/.config/nvim"))
        XCTAssertNotNil(GhosttySurfaceView.parseRemoteTitle("u@host:/var/log/nginx-2026.log"))
        XCTAssertNotNil(GhosttySurfaceView.parseRemoteTitle("u@host:/srv/app_v2/dist"))
    }

    /// `@` appears in real-world paths (npm scopes like `node_modules/@types`,
    /// git refs, email-named directories) and is shell-safe (not a metachar).
    /// The previous allowlist over-rejected this; loosen to accept.
    func testPathAllowsAtSign() {
        let r = GhosttySurfaceView.parseRemoteTitle("u@host:/srv/app/node_modules/@types/node")
        XCTAssertEqual(r?.path, "/srv/app/node_modules/@types/node")
    }

    /// Spaces inside a path are legitimate (Documents folder, "My Project"),
    /// and SSHGitRunner's single-quoting handles them safely. The previous
    /// allowlist over-rejected; titles like `~/My Code` now parse.
    func testPathAllowsSpace() {
        let r = GhosttySurfaceView.parseRemoteTitle("u@host:~/My Code/api")
        XCTAssertEqual(r?.path, "~/My Code/api")
    }

    /// CJK and other Unicode characters in the path must parse — CLAUDE.md
    /// mandates i18n / zh-Hans support, and remote users routinely cd into
    /// directories with non-ASCII names. `Character.isLetter` is Unicode-wide
    /// so the allowlist accepts these by design.
    func testPathAllowsCJK() {
        let r = GhosttySurfaceView.parseRemoteTitle("u@host:~/项目/网站")
        XCTAssertEqual(r?.path, "~/项目/网站")
    }

    /// `..` traversal in the path is rejected even when every character is
    /// otherwise allowlist-clean. The path drives the breadcrumb / Review
    /// window header, and a `..`-laced title would let a malicious remote
    /// misrepresent where Review is operating.
    func testPathRejectsDotDotTraversal() {
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:/srv/app/../etc"))
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@host:~/../root"))
    }

    /// Host is ASCII-only (RFC 1123). A non-ASCII host name is never a real
    /// DNS-resolvable hostname and indicates a malformed title — fail closed
    /// rather than mis-route the ssh.
    func testHostRejectsNonAscii() {
        XCTAssertNil(GhosttySurfaceView.parseRemoteTitle("u@主机:/x"))
    }

    /// IPv6 literal hosts come wrapped in `[…]` so the inner `:` separators
    /// don't get confused with the host/path delimiter. The parser consumes
    /// up to the matching `]` first, otherwise it splits at the first inner
    /// `:` and the host comes out as `[` (which fails the allowlist).
    func testIPv6BracketedHost() {
        let r = GhosttySurfaceView.parseRemoteTitle("deploy@[::1]:/srv/app")
        XCTAssertEqual(r?.user, "deploy")
        XCTAssertEqual(r?.host, "::1")
        XCTAssertEqual(r?.path, "/srv/app")
    }

    func testIPv6FullLiteral() {
        let r = GhosttySurfaceView.parseRemoteTitle("ci@[fe80::1ff:fe23:4567:890a]:~/build")
        XCTAssertEqual(r?.host, "fe80::1ff:fe23:4567:890a")
        XCTAssertEqual(r?.path, "~/build")
    }
}
