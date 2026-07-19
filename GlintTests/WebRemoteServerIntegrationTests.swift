import CryptoKit
import XCTest
@testable import Glint

/// End-to-end tests that drive `WebRemoteServer.shared` over real sockets on the
/// loopback interface. They cover the HTTP asset layer (including the allowlist
/// and HEAD handling) and the WebSocket authentication flow (including the
/// exponential backoff that throttles online token guessing).
///
/// These tests bind the project's real ports (43871 HTTP / 43872 WS) on
/// 127.0.0.1, so they will conflict with a concurrently running Glint whose web
/// remote is enabled. The server is started fresh in `setUp` and stopped in
/// `tearDown`; test methods run serially within the class.
final class WebRemoteServerIntegrationTests: XCTestCase {
    private static let httpOrigin = "http://127.0.0.1:43871"
    private static let webSocketURL = URL(string: "ws://127.0.0.1:43872/control")!

    private var urlSession: URLSession!
    private var readyToken: String?

    override func setUp() async throws {
        try await super.setUp()
        urlSession = URLSession(configuration: .ephemeral)
        readyToken = nil

        let ready = expectation(description: "WebRemoteServer reports .ready")
        WebRemoteServer.shared.setStatusHandler { [weak self] status in
            guard case let .ready(urls) = status,
                  let url = urls.first,
                  let token = WebRemoteAccessURL.token(from: url)
            else { return }
            self?.readyToken = token
            ready.fulfill()
        }
        // Bind to loopback only — never touch a real NIC from tests.
        WebRemoteServer.shared.setListenInterface(WebRemoteListenTarget.loopback)
        WebRemoteServer.shared.start()
        try await fulfillment(of: [ready], timeout: 10)
        XCTAssertNotNil(readyToken, "Server should expose an access token in its ready URL")
    }

    override func tearDown() async throws {
        WebRemoteServer.shared.stop()
        // stop() is asynchronous on the server queue; let NWListener cancel.
        try? await Task.sleep(nanoseconds: 400_000_000)
        urlSession.invalidateAndCancel()
        urlSession = nil
        try await super.tearDown()
    }

    // MARK: - HTTP layer

    func testHTTPServesIndexHtml() async throws {
        let (data, http) = try await request("/")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Type")?.range(of: "text/html"))
        XCTAssertFalse(data.isEmpty)
    }

    func testHTTPServesAppJavaScript() async throws {
        let (data, http) = try await request("/app.js")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Type")?.range(of: "text/javascript"))
        XCTAssertFalse(data.isEmpty)
    }

    func testHTTPServesVendoredXterm() async throws {
        let (data, http) = try await request("/xterm.mjs")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
    }

    func testHTTPReturns404ForUnknownAsset() async throws {
        let (data, http) = try await request("/favicon.ico")
        XCTAssertEqual(http.statusCode, 404)
        XCTAssertFalse(data.isEmpty, "404 should still carry a short text body")
    }

    func testHTTPHeadOmitsBodyButKeepsContentLength() async throws {
        let (data, http) = try await request("/app.js", method: "HEAD")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(data.isEmpty, "HEAD must not return a body")
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Length"))
    }

    // MARK: - WebSocket authentication (challenge-response + AES-GCM)

    func testWebSocketRejectsWrongProofThenAcceptsCorrectProof() async throws {
        let token = try XCTUnwrap(readyToken)
        let tokenKey = try XCTUnwrap(WebRemoteCrypto.tokenKey(from: token))
        let task = makeWebSocket()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // The server issues a per-connection challenge on connect.
        let challenge = try await receiveAuthChallenge(task)

        // Wrong proof → plaintext `unauthorized` after the backoff window. The
        // token itself never crosses the wire.
        try await send(task, ["type": "authenticate", "proof": wrongProofBase64])
        let bad = try await receiveJSON(task)
        XCTAssertEqual(bad["type"] as? String, "error")
        XCTAssertEqual(bad["code"] as? String, "unauthorized")

        // Correct proof → the first reply is an *encrypted* frame. Decrypting it
        // to `{"type":"authenticated"}` proves the session keys agree.
        let proof = WebRemoteCrypto.proof(tokenKey: tokenKey, challenge: challenge)
        try await send(task, ["type": "authenticate", "proof": proof.base64EncodedString()])
        let keys = WebRemoteCrypto.sessionKeys(tokenKey: tokenKey, challenge: challenge)
        let good = try await receiveEncryptedJSON(task, key: keys.s2c)
        // `sendState` no-ops without a WorkspaceStore, so only `authenticated`
        // arrives — enough to prove the proof was accepted and the frame encrypted.
        XCTAssertEqual(good["type"] as? String, "authenticated")
    }

    func testAuthenticationBackoffGrowsAcrossConsecutiveFailures() async throws {
        let task = makeWebSocket()
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await receiveAuthChallenge(task)

        func timedFailure() async throws -> TimeInterval {
            let start = Date()
            try await send(task, ["type": "authenticate", "proof": wrongProofBase64])
            let reply = try await receiveJSON(task)
            XCTAssertEqual(reply["code"] as? String, "unauthorized")
            return Date().timeIntervalSince(start)
        }

        let first = try await timedFailure()    // ~0.25s
        let second = try await timedFailure()   // ~0.5s

        // Exponential: the second failure must wait materially longer than the
        // first, yet stay far below the 16s cap. Loose thresholds absorb CI
        // scheduler jitter (expected ratio is ~2x).
        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThanOrEqual(second, first * 1.4)
        XCTAssertLessThan(second, 3.0)
    }

    private var wrongProofBase64: String {
        Data(repeating: 0, count: WebRemoteCrypto.challengeLength).base64EncodedString()
    }

    // MARK: - Pure-function behaviour

    func testAuthBackoffCurveIsMonotonicAndCapped() {
        let expected: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8, 16, 16]
        for (count, want) in zip(1 ... 8, expected) {
            XCTAssertEqual(
                WebRemoteServer.authBackoffSeconds(forFailures: count),
                want,
                accuracy: 0.0001,
                "count \(count)"
            )
        }
        // Out-of-range inputs clamp, never grow unbounded.
        XCTAssertEqual(WebRemoteServer.authBackoffSeconds(forFailures: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(WebRemoteServer.authBackoffSeconds(forFailures: 1_000), 16, accuracy: 0.0001)
    }

    func testListenTargetBindAddressResolvesSpecialCases() {
        XCTAssertEqual(WebRemoteListenTarget.bindAddress(for: WebRemoteListenTarget.loopback), "127.0.0.1")
        XCTAssertNil(WebRemoteListenTarget.bindAddress(for: WebRemoteListenTarget.any))
        XCTAssertNil(
            WebRemoteListenTarget.bindAddress(for: "glint-definitely-not-an-interface"),
            "An unknown interface name must not resolve to a bind address"
        )
    }

    func testVanishedSelectedInterfaceFailsLoudly() async throws {
        // A user-chosen NIC that no longer exists must surface `.failed` — never
        // silently fall back to a 0.0.0.0 wildcard bind (that would widen
        // exposure, the opposite of picking a NIC).
        WebRemoteServer.shared.stop()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let failed = expectation(description: "vanished interface reports .failed")
        WebRemoteServer.shared.setStatusHandler { status in
            if case .failed = status { failed.fulfill() }
        }
        WebRemoteServer.shared.setListenInterface("glint-definitely-not-an-interface")
        WebRemoteServer.shared.start()
        try await fulfillment(of: [failed], timeout: 10)
    }

    // MARK: - Helpers

    private func request(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: Self.httpOrigin + path)!)
        req.httpMethod = method
        req.timeoutInterval = 5
        let (data, response) = try await urlSession.data(for: req)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func makeWebSocket() -> URLSessionWebSocketTask {
        let task = urlSession.webSocketTask(with: Self.webSocketURL)
        task.resume()
        return task
    }

    private func send(_ task: URLSessionWebSocketTask, _ object: [String: Any]) async throws {
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}"
        try await task.send(.string(text))
    }

    /// Receive one raw message, bounded by a timeout so a misbehaving server
    /// fails the test instead of hanging it.
    private func receiveMessage(
        _ task: URLSessionWebSocketTask,
        timeoutSeconds: UInt64 = 6
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return result
        }
    }

    private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        switch try await receiveMessage(task) {
        case let .string(text):
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        case let .data(data):
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        @unknown default:
            throw URLError(.badServerResponse)
        }
    }

    /// The server sends the plaintext challenge as soon as the socket opens.
    private func receiveAuthChallenge(_ task: URLSessionWebSocketTask) async throws -> Data {
        switch try await receiveMessage(task) {
        case let .string(text):
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "auth-challenge")
            return try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["challenge"] as? String)))
        case .data:
            throw URLError(.badServerResponse)
        @unknown default:
            throw URLError(.badServerResponse)
        }
    }

    /// Receive one encrypted binary frame, decrypt it under `key`, and decode
    /// the plaintext JSON. Closes the loop on the server's encrypt path.
    private func receiveEncryptedJSON(
        _ task: URLSessionWebSocketTask,
        key: SymmetricKey
    ) async throws -> [String: Any] {
        let data: Data
        switch try await receiveMessage(task) {
        case let .data(value): data = value
        case .string: throw URLError(.badServerResponse)
        @unknown default: throw URLError(.badServerResponse)
        }
        let nonce = data.prefix(WebRemoteCrypto.nonceLength)
        let body = data.subdata(in: WebRemoteCrypto.nonceLength ..< data.count)
        let plaintext = try XCTUnwrap(WebRemoteCrypto.openFrame(nonce: nonce, body: body, key: key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    }
}
