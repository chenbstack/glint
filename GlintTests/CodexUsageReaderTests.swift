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
        let line = #"{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1900000000},"secondary":{"used_percent":50,"window_minutes":10080,"resets_at":1900100000},"plan_type":"pro"}}}"#
        try line.write(to: rollout, atomically: true, encoding: .utf8)

        let quota = try XCTUnwrap(CodexUsageReader.read(from: home))

        XCTAssertEqual(quota.sessionPercent, 25)
        XCTAssertEqual(quota.weeklyPercent, 50)
        XCTAssertEqual(quota.primaryWindowMinutes, 300)
        XCTAssertEqual(quota.secondaryWindowMinutes, 10_080)
        XCTAssertEqual(quota.primaryWindowLabel, "5h")
        XCTAssertEqual(quota.secondaryWindowLabel, "7d")
        XCTAssertEqual(quota.planType, "pro")
    }

    func testIgnoresNewerModelSpecificQuotaWhenReadingGeneralQuota() throws {
        let sessions = home.appendingPathComponent("sessions/2026/07/13", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let general = sessions.appendingPathComponent("rollout-general.jsonl")
        let generalLine = #"{"type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":8,"window_minutes":10080,"resets_at":1900000000},"secondary":null,"plan_type":"prolite"}}}"#
        try generalLine.write(to: general, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: general.path
        )

        let spark = sessions.appendingPathComponent("rollout-spark.jsonl")
        let sparkLine = #"{"type":"event_msg","payload":{"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0,"window_minutes":10080,"resets_at":1900100000},"secondary":null,"plan_type":"prolite"}}}"#
        try sparkLine.write(to: spark, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: spark.path
        )

        let quota = try XCTUnwrap(CodexUsageReader.read(from: home))

        XCTAssertEqual(quota.sessionPercent, 8)
    }

    func testDecodesLiveSingleWeeklyWindow() throws {
        let payload = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":8,"limit_window_seconds":604800,"reset_after_seconds":575254,"reset_at":1900000000},"secondary_window":null}}"#
        let data = try XCTUnwrap(payload.data(using: .utf8))

        let quota = try XCTUnwrap(CodexLiveReader.decode(data))

        XCTAssertEqual(quota.sessionPercent, 8)
        XCTAssertNil(quota.weeklyPercent)
        XCTAssertEqual(quota.primaryWindowMinutes, 10_080)
        XCTAssertNil(quota.secondaryWindowMinutes)
        XCTAssertEqual(quota.primaryWindowLabel, "7d")
    }

    func testAuthStatusIsPerHomeAndNonfatal() throws {
        XCTAssertEqual(CodexLiveReader.authStatus(from: home), .missing)

        let authURL = home.appendingPathComponent("auth.json")
        try "invalid".write(to: authURL, atomically: true, encoding: .utf8)
        guard case .invalid(let message) = CodexLiveReader.authStatus(from: home) else {
            return XCTFail("Invalid auth.json should report an invalid auth status")
        }
        XCTAssertFalse(message.isEmpty)

        try #"{"tokens":{"access_token":"token","account_id":"account"}}"#
            .write(to: authURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexLiveReader.authStatus(from: home), .found)
    }

    func testSidebarUsesQuotaFromLaterAvailableHome() {
        let unavailable = CodexHome(label: "API", path: "~/api/.codex")
        let subscription = CodexHome(label: "Subscription", path: "~/subscription/.codex")
        let quota = AgentQuota(
            sessionPercent: 27,
            weeklyPercent: 40,
            sessionResetsAt: nil,
            weeklyResetsAt: nil,
            planType: "plus",
            primaryWindowMinutes: 300,
            secondaryWindowMinutes: 10_080
        )
        let statuses = [
            CodexHomeStatus(
                home: unavailable,
                resolvedURL: unavailable.resolvedURL,
                hookStatus: .notInstalled,
                authStatus: .found,
                quotaStatus: .unavailable("Quota unavailable")
            ),
            CodexHomeStatus(
                home: subscription,
                resolvedURL: subscription.resolvedURL,
                hookStatus: .installed,
                authStatus: .found,
                quotaStatus: .available(quota)
            ),
        ]

        let items = CodexQuotaPresentation.sidebarItems(from: statuses, fallback: nil)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Subscription")
        XCTAssertEqual(items[0].quota, quota)
    }

    func testSidebarHidesFallbackWhenEveryHomeIsDisabled() {
        let cached = AgentQuota(
            sessionPercent: 27,
            weeklyPercent: 40,
            sessionResetsAt: nil,
            weeklyResetsAt: nil,
            planType: "plus"
        )

        let items = CodexQuotaPresentation.sidebarItems(
            from: [],
            fallback: cached,
            hasEnabledHomes: false
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testOlderRefreshIsRejectedAfterNewRefreshBegins() {
        var coordinator = CodexRefreshCoordinator()
        let older = coordinator.begin()
        let newer = coordinator.begin()

        XCTAssertFalse(coordinator.accepts(older))
        XCTAssertTrue(coordinator.accepts(newer))

        coordinator.invalidate()
        XCTAssertFalse(coordinator.accepts(newer))
    }

    func testDisabledHomeStatusDoesNotRemainLoading() {
        guard case .unavailable(let message) = CodexQuotaStatus.placeholder(isHomeEnabled: false, isUsageEnabled: true) else {
            return XCTFail("Disabled Codex home should not remain loading")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(
            CodexQuotaStatus.placeholder(isHomeEnabled: true, isUsageEnabled: true),
            .loading
        )
    }
}
