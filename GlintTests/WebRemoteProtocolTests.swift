import XCTest
@testable import Glint

final class WebRemoteProtocolTests: XCTestCase {
    func testTerminalSizeAcceptsBrowserGridWithinSafeBounds() {
        XCTAssertEqual(
            WebRemoteTerminalSize.parse(["columns": 132, "rows": 43]),
            WebRemoteTerminalSize(columns: 132, rows: 43)
        )
    }

    func testTerminalSizeRejectsMissingFractionalAndExtremeValues() {
        XCTAssertNil(WebRemoteTerminalSize.parse(["columns": 132]))
        XCTAssertNil(WebRemoteTerminalSize.parse(["columns": 132.5, "rows": 43]))
        XCTAssertNil(WebRemoteTerminalSize.parse(["columns": 19, "rows": 43]))
        XCTAssertNil(WebRemoteTerminalSize.parse(["columns": 132, "rows": 201]))
    }

    func testSnapshotUsesTerminalNewlinesBetweenLogicalRows() {
        let payload = String(
            decoding: WebRemoteSnapshotPayload.make(ansi: "first\nsecond"),
            as: UTF8.self
        )

        XCTAssertTrue(payload.hasSuffix("first\r\nsecond"))
    }

    func testAccessTokenIsRandomHexAndConstantTimeMatcherChecksWholeValue() {
        let token = WebRemoteAccessToken.generate()

        XCTAssertEqual(token.count, 64)
        XCTAssertNotNil(UInt64(token.prefix(16), radix: 16))
        XCTAssertTrue(WebRemoteAccessToken.matches(token, expected: token))
        XCTAssertFalse(WebRemoteAccessToken.matches(nil, expected: token))
        XCTAssertFalse(WebRemoteAccessToken.matches(token + "0", expected: token))
        XCTAssertFalse(WebRemoteAccessToken.matches(String(token.dropLast()) + "0", expected: token))
    }

    func testAccessKeyPersistsUntilExplicitReset() {
        let suite = "WebRemoteAccessKeyStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = WebRemoteAccessKeyStore.loadOrCreate(defaults: defaults)
        XCTAssertEqual(WebRemoteAccessKeyStore.loadOrCreate(defaults: defaults), first)

        let reset = WebRemoteAccessKeyStore.reset(defaults: defaults)
        XCTAssertNotEqual(reset, first)
        XCTAssertEqual(WebRemoteAccessKeyStore.loadOrCreate(defaults: defaults), reset)
    }

    func testAccessKeyCanBeCopiedSeparatelyFromSessionURL() {
        let value = "http://192.168.1.20:43871/#token=abc123"

        XCTAssertEqual(WebRemoteAccessURL.token(from: value), "abc123")
        XCTAssertNil(WebRemoteAccessURL.token(from: "http://192.168.1.20:43871/"))
    }

    func testHTTPRequestParsesGetAndStripsQuery() {
        let data = Data("GET /app.js?v=1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

        XCTAssertEqual(
            WebRemoteHTTPRequest.parse(data),
            WebRemoteHTTPRequest(method: .get, path: "/app.js")
        )
    }

    func testHTTPRequestRejectsUnsupportedMethodAndMalformedTarget() {
        XCTAssertNil(WebRemoteHTTPRequest.parse(Data("POST / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(WebRemoteHTTPRequest.parse(Data("GET relative HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(WebRemoteHTTPRequest.parse(Data("not-http".utf8)))
    }

    func testAssetsOnlyExposeBundledAllowlist() {
        XCTAssertEqual(WebRemoteAssets.asset(for: "/")?.resource, "web-remote-index")
        XCTAssertEqual(WebRemoteAssets.asset(for: "/xterm.mjs")?.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(WebRemoteAssets.asset(for: "/symbols-nerd-font-mono.ttf")?.contentType, "font/ttf")
        XCTAssertNil(WebRemoteAssets.asset(for: "/../state.json"))
        XCTAssertNil(WebRemoteAssets.asset(for: "/favicon.ico"))
    }

    func testHeadResponseKeepsContentLengthWithoutBody() {
        let body = Data("hello".utf8)
        let response = WebRemoteHTTPResponse.make(
            status: 200,
            reason: "OK",
            contentType: "text/plain",
            body: body,
            includeBody: false
        )
        let text = String(decoding: response, as: UTF8.self)

        XCTAssertTrue(text.contains("Content-Length: 5\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(text.hasSuffix("hello"))
    }

    func testProjectPathOnlyAcceptsExistingDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-web-remote-tests-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(WebRemoteProjectPath.resolveExistingDirectory(root.path), root.path)
        XCTAssertNil(WebRemoteProjectPath.resolveExistingDirectory(file.path))
        XCTAssertNil(WebRemoteProjectPath.resolveExistingDirectory(root.appendingPathComponent("missing").path))
        XCTAssertNil(WebRemoteProjectPath.resolveExistingDirectory("relative/path"))
    }
}
