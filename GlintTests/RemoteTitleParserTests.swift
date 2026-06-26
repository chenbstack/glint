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
}
