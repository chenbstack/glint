import XCTest
@testable import Glint

final class CodexUsageReaderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-codex-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testReadsQuotaFromRequestedHome() throws {
        let sessions = home.appendingPathComponent("sessions/2026/06/22", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-test.jsonl")
        let line = #"{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":25,"resets_at":1900000000},"secondary":{"used_percent":50,"resets_at":1900100000},"plan_type":"pro"}}}"#
        try line.write(to: rollout, atomically: true, encoding: .utf8)

        let quota = try XCTUnwrap(CodexUsageReader.read(from: home))

        XCTAssertEqual(quota.sessionPercent, 25)
        XCTAssertEqual(quota.weeklyPercent, 50)
        XCTAssertEqual(quota.planType, "pro")
    }

    func testAuthStatusIsPerHomeAndNonfatal() throws {
        XCTAssertEqual(CodexLiveReader.authStatus(from: home), .missing)

        let authURL = home.appendingPathComponent("auth.json")
        try "invalid".write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexLiveReader.authStatus(from: home), .invalid("Invalid auth.json"))

        try #"{"tokens":{"access_token":"token","account_id":"account"}}"#
            .write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexLiveReader.authStatus(from: home), .found)
    }
}
