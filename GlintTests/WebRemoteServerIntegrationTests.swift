import CryptoKit
import Network
import XCTest
@testable import Glint

/// End-to-end tests that drive `WebRemoteServer` over real sockets on the
/// loopback interface. They cover the HTTP asset layer (including the allowlist
/// and HEAD handling) and the WebSocket authentication flow (including the
/// exponential backoff that throttles online token guessing).
///
/// Each test uses a private defaults domain and an available loopback port pair,
/// plus in-memory credentials, leaving running Glint sessions and Keychain alone.
final class WebRemoteServerIntegrationTests: XCTestCase {
    private var server: WebRemoteServer!
    private var testDefaults: UserDefaults!
    private var defaultsName: String!
    private let interfaceAddress = TestInterfaceAddress()
    private var urlSession: URLSession!
    private var readyToken: String?
    private var httpOrigin: String?
    private var webSocketURL: URL?

    override func setUp() async throws {
        try await super.setUp()
        defaultsName = "app.glint.WebRemoteTests.\(UUID().uuidString)"
        testDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        testDefaults.set(Int(try availableHTTPPort()), forKey: "glint.webRemoteHTTPPort")
        interfaceAddress.set(nil)
        server = WebRemoteServer(defaults: testDefaults, interfaceRetryInterval: 0.2) { [interfaceAddress] key in
            key == "test-interface" ? interfaceAddress.get() : WebRemoteListenTarget.bindAddress(for: key)
        }
        urlSession = URLSession(configuration: .ephemeral)
        readyToken = nil
        httpOrigin = nil
        webSocketURL = nil

        let ready = expectation(description: "WebRemoteServer reports .ready")
        server.setStatusHandler { [weak self] status in
            guard case let .ready(urls) = status,
                  let url = urls.first,
                  let token = WebRemoteAccessURL.token(from: url),
                  let components = URLComponents(string: url),
                  let host = components.host,
                  let httpPort = components.port
            else { return }
            self?.readyToken = token
            self?.httpOrigin = "http://\(host):\(httpPort)"
            self?.webSocketURL = URL(string: "ws://\(host):\(httpPort + 1)/control")
            ready.fulfill()
        }
        // Bind to loopback only — never touch a real NIC from tests.
        server.setListenInterface(WebRemoteListenTarget.loopback)
        // Keep the access token in memory. Against the real Keychain this
        // prompts for the login password (the test binary is not the signed
        // identity the item's ACL trusts) and `start()` then times out.
        server.setSecretStorage(WebRemoteEphemeralSecretStorage())
        server.start()
        try await fulfillment(of: [ready], timeout: 10)
        XCTAssertNotNil(readyToken, "Server should expose an access token in its ready URL")
        XCTAssertNotNil(httpOrigin)
        XCTAssertNotNil(webSocketURL)
    }

    override func tearDown() async throws {
        server.setStatusHandler { _ in }
        server.stop()
        // stop() is asynchronous on the server queue; let NWListener cancel.
        try? await Task.sleep(nanoseconds: 400_000_000)
        urlSession.invalidateAndCancel()
        urlSession = nil
        server = nil
        testDefaults.removePersistentDomain(forName: defaultsName)
        testDefaults = nil
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

    func testHTTPServesIOSIMEInputFallback() async throws {
        let (data, http) = try await request("/ime-input.mjs")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Type")?.range(of: "text/javascript"))
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

    /// Once the handshake completes, every inbound frame must authenticate. A
    /// frame too short to hold nonce+tag cannot be a sealed envelope, so it has
    /// to drop — never fall back to plaintext JSON parsing. Without this,
    /// an injected 15-byte `{"type":"list"}` would execute against a session
    /// that is nominally encrypted.
    func testShortPlaintextFrameAfterHandshakeIsRejected() async throws {
        let token = try XCTUnwrap(readyToken)
        let tokenKey = try XCTUnwrap(WebRemoteCrypto.tokenKey(from: token))
        let task = makeWebSocket()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let challenge = try await receiveAuthChallenge(task)
        let proof = WebRemoteCrypto.proof(tokenKey: tokenKey, challenge: challenge)
        try await send(task, ["type": "authenticate", "proof": proof.base64EncodedString()])
        let keys = WebRemoteCrypto.sessionKeys(tokenKey: tokenKey, challenge: challenge)
        let authenticated = try await receiveEncryptedJSON(task, key: keys.s2c)
        XCTAssertEqual(authenticated["type"] as? String, "authenticated")

        // 15 bytes on the wire — below nonce(12) + tag(16), so it can never be
        // a valid sealed frame.
        try await send(task, ["type": "list"])

        do {
            let leaked = try await receiveJSON(task)
            XCTFail("server acted on an unencrypted post-handshake frame: \(leaked)")
        } catch {
            // Expected: the server dropped the connection instead of answering.
        }
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

    func testAuthenticationBackoffSpansSeparateConnectionsFromSameSource() async throws {
        let firstTask = makeWebSocket()
        let secondTask = makeWebSocket()
        defer {
            firstTask.cancel(with: .goingAway, reason: nil)
            secondTask.cancel(with: .goingAway, reason: nil)
        }
        _ = try await receiveAuthChallenge(firstTask)
        _ = try await receiveAuthChallenge(secondTask)

        let firstStart = Date()
        try await send(firstTask, ["type": "authenticate", "proof": wrongProofBase64])
        let firstReply = try await receiveJSON(firstTask)
        XCTAssertEqual(firstReply["code"] as? String, "unauthorized")
        let first = Date().timeIntervalSince(firstStart)

        let secondStart = Date()
        try await send(secondTask, ["type": "authenticate", "proof": wrongProofBase64])
        let secondReply = try await receiveJSON(secondTask)
        XCTAssertEqual(secondReply["code"] as? String, "unauthorized")
        let second = Date().timeIntervalSince(secondStart)

        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThanOrEqual(second, first * 1.4)
        XCTAssertLessThan(second, 3.0)
    }

    func testAuthenticationThrottleSpansConnectionsFromSameSource() {
        var throttle = WebRemoteAuthThrottle(expirySeconds: 60)

        XCTAssertEqual(throttle.recordFailure(for: "127.0.0.1", now: 1_000), 1)
        XCTAssertEqual(
            throttle.recordFailure(for: "127.0.0.1", now: 1_001),
            2,
            "A new connection from the same source must not reset the backoff"
        )
        XCTAssertEqual(throttle.recordFailure(for: "192.0.2.10", now: 1_001), 1)
        XCTAssertEqual(
            throttle.recordFailure(for: "127.0.0.1", now: 1_061),
            1,
            "Idle failure history should expire"
        )
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

    func testClientAdmissionCapsTotalAndUnauthenticatedConnections() {
        XCTAssertTrue(WebRemoteServer.allowsNewClient(total: 0, unauthenticated: 0))
        XCTAssertTrue(
            WebRemoteServer.allowsNewClient(
                total: WebRemoteServer.maxClientConnections - 1,
                unauthenticated: WebRemoteServer.maxUnauthenticatedConnections - 1
            )
        )
        XCTAssertFalse(
            WebRemoteServer.allowsNewClient(
                total: WebRemoteServer.maxClientConnections,
                unauthenticated: 0
            )
        )
        XCTAssertFalse(
            WebRemoteServer.allowsNewClient(
                total: 0,
                unauthenticated: WebRemoteServer.maxUnauthenticatedConnections
            )
        )
    }

    func testAuthSourceKeyIgnoresEphemeralPort() throws {
        let first = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: 12_001))
        )
        let second = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: 12_002))
        )

        XCTAssertEqual(
            WebRemoteServer.authSourceKey(for: first),
            WebRemoteServer.authSourceKey(for: second)
        )
    }

    func testLANListenTargetsRequireActiveAttackWarning() {
        XCTAssertFalse(
            WebRemoteListenTarget.requiresActiveAttackWarning(WebRemoteListenTarget.loopback)
        )
        XCTAssertTrue(
            WebRemoteListenTarget.requiresActiveAttackWarning(WebRemoteListenTarget.any)
        )
        XCTAssertTrue(WebRemoteListenTarget.requiresActiveAttackWarning("en0"))
    }

    func testListenTargetBindAddressResolvesSpecialCases() {
        XCTAssertEqual(WebRemoteListenTarget.bindAddress(for: WebRemoteListenTarget.loopback), "127.0.0.1")
        XCTAssertNil(WebRemoteListenTarget.bindAddress(for: WebRemoteListenTarget.any))
        XCTAssertNil(
            WebRemoteListenTarget.bindAddress(for: "glint-definitely-not-an-interface"),
            "An unknown interface name must not resolve to a bind address"
        )
    }

    func testVanishedSelectedInterfaceWaitsWithoutWildcardBind() async throws {
        let waiting = expectation(description: "vanished interface reports waiting")
        let listening = expectation(description: "missing NIC must not fall back to wildcard")
        listening.isInverted = true
        server.setStatusHandler { status in
            if case .waitingForInterface(name: "glint-definitely-not-an-interface") = status {
                waiting.fulfill()
            }
            if case .ready = status { listening.fulfill() }
            if case .failed = status { XCTFail("A missing NIC should wait for recovery") }
        }
        server.setListenInterface("glint-definitely-not-an-interface")
        server.start()
        await fulfillment(of: [waiting], timeout: 3)
        await fulfillment(of: [listening], timeout: 0.7)
        do {
            _ = try await request("/")
            XCTFail("No HTTP listener should be bound while the selected NIC is missing")
        } catch is URLError { }
    }

    func testUnavailableInterfaceRecoversWhenAddressReturns() async throws {
        try await assertUnavailableInterfaceRecovers(sendPathUpdate: true)
    }

    func testUnavailableInterfaceRecoversWithoutPathUpdate() async throws {
        try await assertUnavailableInterfaceRecovers(sendPathUpdate: false)
    }

    private func assertUnavailableInterfaceRecovers(sendPathUpdate: Bool) async throws {
        let waiting = expectation(description: "selected interface unavailable")
        let recovered = expectation(description: "selected interface recovers automatically")
        server.setStatusHandler { status in
            if case .waitingForInterface = status { waiting.fulfill() }
            if case .failed = status { XCTFail("A temporarily missing address must remain recoverable") }
            if case .ready = status { recovered.fulfill() }
        }
        server.setListenInterface("test-interface")
        server.start()
        await fulfillment(of: [waiting], timeout: 3)
        interfaceAddress.set("127.0.0.1")
        if sendPathUpdate { server.refreshListenAddress() }
        await fulfillment(of: [recovered], timeout: 3)
        let (_, response) = try await request("/")
        XCTAssertEqual(response.statusCode, 200)
        let socket = makeWebSocket()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        _ = try await receiveAuthChallenge(socket)
    }

    func testRunningInterfaceRecoversAfterSustainedAddressLoss() async throws {
        try await startNamedInterface()
        let waiting = expectation(description: "lost address enters waiting")
        let recovered = expectation(description: "running interface recovers")
        server.setStatusHandler { status in
            if case .waitingForInterface = status { waiting.fulfill() }
            if case .ready = status { recovered.fulfill() }
            if case .failed = status { XCTFail("Network loss must not disable recovery") }
        }
        interfaceAddress.set(nil)
        server.refreshListenAddress()
        await fulfillment(of: [waiting], timeout: 3)
        interfaceAddress.set("127.0.0.1")
        await fulfillment(of: [recovered], timeout: 3)
        let (_, response) = try await request("/")
        XCTAssertEqual(response.statusCode, 200)
    }

    func testStopWhileWaitingCancelsRecovery() async throws {
        let waiting = expectation(description: "waiting before stop")
        server.setStatusHandler { if case .waitingForInterface = $0 { waiting.fulfill() } }
        server.setListenInterface("test-interface")
        server.start()
        await fulfillment(of: [waiting], timeout: 3)

        let stopped = expectation(description: "explicitly stopped")
        server.setStatusHandler { if case .stopped = $0 { stopped.fulfill() } }
        server.stop()
        await fulfillment(of: [stopped], timeout: 3)
        let restarted = expectation(description: "stopped server must not recover")
        restarted.isInverted = true
        server.setStatusHandler { _ in restarted.fulfill() }
        interfaceAddress.set("127.0.0.1")
        server.refreshListenAddress()
        await fulfillment(of: [restarted], timeout: 0.8)
    }

    func testSwitchToLoopbackCancelsPendingInterfaceRestart() async throws {
        try await startNamedInterface()
        interfaceAddress.set(nil)
        server.refreshListenAddress()
        try await Task.sleep(nanoseconds: 100_000_000)

        let ready = expectation(description: "new loopback selection ready")
        server.setStatusHandler { if case .ready = $0 { ready.fulfill() } }
        server.setListenInterface(WebRemoteListenTarget.loopback)
        server.start()
        await fulfillment(of: [ready], timeout: 3)
        let restarted = expectation(description: "old path callback must not restart new selection")
        restarted.isInverted = true
        server.setStatusHandler { _ in restarted.fulfill() }
        interfaceAddress.set("127.0.0.1")
        server.refreshListenAddress()
        await fulfillment(of: [restarted], timeout: 0.8)
        let (_, response) = try await request("/")
        XCTAssertEqual(response.statusCode, 200)
    }

    func testPortConflictDoesNotBecomeInterfaceRecovery() async throws {
        interfaceAddress.set("127.0.0.1")
        let conflictingServer = WebRemoteServer(defaults: testDefaults) { [interfaceAddress] key in
            key == "test-interface" ? interfaceAddress.get() : WebRemoteListenTarget.bindAddress(for: key)
        }
        conflictingServer.setSecretStorage(WebRemoteEphemeralSecretStorage())
        defer {
            conflictingServer.setStatusHandler { _ in }
            conflictingServer.stop()
        }
        let conflict = expectation(description: "occupied port remains an explicit conflict")
        conflictingServer.setStatusHandler { status in
            if case .portConflict = status { conflict.fulfill() }
            if case .waitingForInterface = status { XCTFail("A port conflict cannot recover by waiting for the NIC") }
            if case .ready = status { XCTFail("The test server already occupies these ports") }
        }
        conflictingServer.setListenInterface("test-interface")
        conflictingServer.start()
        await fulfillment(of: [conflict], timeout: 3)
    }

    private func startNamedInterface() async throws {
        interfaceAddress.set("127.0.0.1")
        let ready = expectation(description: "named interface ready")
        server.setStatusHandler { if case .ready = $0 { ready.fulfill() } }
        server.setListenInterface("test-interface")
        server.start()
        await fulfillment(of: [ready], timeout: 3)
    }

    func testBriefAddressLossDoesNotRestartHealthyListeners() async throws {
        try await startNamedInterface()

        let restarted = expectation(description: "healthy listener should survive a brief address loss")
        restarted.isInverted = true
        server.setStatusHandler { if case .starting = $0 { restarted.fulfill() } }
        interfaceAddress.set(nil)
        server.refreshListenAddress()
        try await Task.sleep(nanoseconds: 100_000_000)
        interfaceAddress.set("127.0.0.1")
        server.refreshListenAddress()
        await fulfillment(of: [restarted], timeout: 0.8)
        let (_, response) = try await request("/")
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: - Helpers

    /// Reserve both sockets together before choosing the pair. NWListener binds
    /// them after these probes close; no persisted production ports are reused.
    private func availableHTTPPort() throws -> UInt16 {
        for _ in 0..<100 {
            let port = UInt16.random(in: 49152...65533)
            let http = socket(AF_INET, SOCK_STREAM, 0)
            let webSocket = socket(AF_INET, SOCK_STREAM, 0)
            guard http >= 0, webSocket >= 0 else {
                if http >= 0 { close(http) }
                if webSocket >= 0 { close(webSocket) }
                throw POSIXError(.EMFILE)
            }
            defer { close(http); close(webSocket) }
            func bindLoopback(_ fd: Int32, _ port: UInt16) -> Bool {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                return withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
            }
            if bindLoopback(http, port), bindLoopback(webSocket, port + 1) { return port }
        }
        throw POSIXError(.EADDRINUSE)
    }

    private func request(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        let origin = try XCTUnwrap(httpOrigin)
        var req = URLRequest(url: try XCTUnwrap(URL(string: origin + path)))
        req.httpMethod = method
        req.timeoutInterval = 5
        let (data, response) = try await urlSession.data(for: req)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func makeWebSocket() -> URLSessionWebSocketTask {
        let task = urlSession.webSocketTask(with: webSocketURL!)
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

private final class TestInterfaceAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return address
    }

    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        address = value
    }
}
