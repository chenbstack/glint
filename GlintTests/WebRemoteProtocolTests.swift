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

    func testSnapshotRestoresGhosttyTerminalStateAfterPaintingGrid() throws {
        let json = Data(#"""
        {
          "columns": 80,
          "rows": 24,
          "cursor": {"row": 5, "column": 7, "visible": false, "style": "bar", "blinking": true},
          "styles": [{
            "id": 0,
            "foreground": "#FFFFFF",
            "background": "#000000",
            "bold": false,
            "faint": false,
            "italic": false,
            "underline": false,
            "blink": false,
            "inverse": false,
            "invisible": false,
            "strikethrough": false,
            "overline": false
          }],
          "row_spans": [{"row": 0, "column": 0, "style_id": 0, "cell_width": 1, "text": "X"}],
          "row_wraps": [false],
          "active_screen": "alternate",
          "modes": [
            {"code": 1, "ansi": false, "on": true},
            {"code": 6, "ansi": false, "on": true},
            {"code": 2004, "ansi": false, "on": true}
          ],
          "scrolling_region": {"top": 2, "bottom": 20, "left": 3, "right": 70},
          "pty_output_seq": 41,
          "pty_stream_safe": true,
          "scrollback_rows": 0,
          "scrollback_row_wraps": [],
          "scrollback_spans": []
        }
        """#.utf8)

        let snapshot = try XCTUnwrap(
            GhosttySurfaceView.webRemoteSnapshot(fromRenderGrid: json, maxLines: 1000)
        )
        XCTAssertEqual(snapshot.outputSequence, 41)
        let text = String(decoding: snapshot.payload, as: UTF8.self)
        let paint = try XCTUnwrap(text.range(of: "X")?.lowerBound)
        let alternate = try XCTUnwrap(text.range(of: "\u{1b}[?1049h")?.lowerBound)
        let applicationCursor = try XCTUnwrap(text.range(of: "\u{1b}[?1h")?.lowerBound)
        let bracketedPaste = try XCTUnwrap(text.range(of: "\u{1b}[?2004h")?.lowerBound)
        let scrollingRegion = try XCTUnwrap(text.range(of: "\u{1b}[3;21r")?.lowerBound)
        let horizontalMargins = try XCTUnwrap(text.range(of: "\u{1b}[4;71s")?.lowerBound)
        let cursor = try XCTUnwrap(text.range(of: "\u{1b}[4;5H")?.lowerBound)

        XCTAssertLessThan(alternate, paint)
        XCTAssertLessThan(paint, applicationCursor)
        XCTAssertLessThan(applicationCursor, bracketedPaste)
        XCTAssertLessThan(bracketedPaste, scrollingRegion)
        XCTAssertLessThan(scrollingRegion, horizontalMargins)
        XCTAssertLessThan(horizontalMargins, cursor)
        XCTAssertTrue(text.hasSuffix("\u{1b}[5 q\u{1b}[?25l"))
    }

    func testSnapshotRejectsUnsafePTYParserBoundary() {
        let json = Data(#"""
        {
          "styles": [],
          "row_spans": [],
          "scrollback_spans": [],
          "scrollback_rows": 0,
          "rows": 24,
          "pty_output_seq": 41,
          "pty_stream_safe": false
        }
        """#.utf8)

        XCTAssertNil(GhosttySurfaceView.webRemoteSnapshot(fromRenderGrid: json, maxLines: 1000))
    }

    func testTerminalOutputBufferCoalescesBytesAndRejectsOverflow() {
        var buffer = WebRemoteOutputBuffer(byteLimit: 4)

        XCTAssertTrue(buffer.append(Data("ab".utf8), sequence: 1))
        XCTAssertTrue(buffer.append(Data("cd".utf8), sequence: 2))
        XCTAssertFalse(buffer.append(Data("e".utf8), sequence: 3))
        XCTAssertEqual(buffer.take(after: 0), Data("abcd".utf8))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTerminalOutputBufferDropsChunksAlreadyIncludedInSnapshot() {
        var buffer = WebRemoteOutputBuffer(byteLimit: 32)

        XCTAssertTrue(buffer.append(Data("before".utf8), sequence: 40))
        XCTAssertTrue(buffer.append(Data("included".utf8), sequence: 41))
        XCTAssertTrue(buffer.append(Data("after".utf8), sequence: 42))

        XCTAssertEqual(buffer.take(after: 41), Data("after".utf8))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTerminalOutputBufferPreservesSequenceBoundariesWhenCoalescingBatches() {
        var ingress = WebRemoteOutputBuffer(byteLimit: 32)
        XCTAssertTrue(ingress.append(Data("included".utf8), sequence: 41))
        XCTAssertTrue(ingress.append(Data("after".utf8), sequence: 42))

        var pendingSelection = WebRemoteOutputBuffer(byteLimit: 32)
        XCTAssertTrue(pendingSelection.append(contentsOf: ingress))

        XCTAssertEqual(pendingSelection.take(after: 41), Data("after".utf8))
    }

    func testOutboundBufferKeepsSnapshotBeforeBufferedTerminalOutput() {
        let snapshot = Data("snapshot".utf8)
        var buffer = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 4)

        buffer.enqueueMessage(snapshot)
        XCTAssertTrue(buffer.enqueueTerminalOutput(Data("ab".utf8), pane: "pane-1"))
        XCTAssertTrue(buffer.enqueueTerminalOutput(Data("cd".utf8), pane: "pane-1"))
        XCTAssertFalse(buffer.enqueueTerminalOutput(Data("e".utf8), pane: "pane-1"))

        guard case let .message(message)? = buffer.next() else {
            return XCTFail("Snapshot message must be sent first")
        }
        XCTAssertEqual(message, snapshot)
        guard case let .terminalOutput(pane, output)? = buffer.next() else {
            return XCTFail("Buffered terminal output must follow the snapshot")
        }
        XCTAssertEqual(pane, "pane-1")
        XCTAssertEqual(output, Data("abcd".utf8))
        XCTAssertNil(buffer.next())
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

    @MainActor
    func testRemoteCloseTargetsRequestedPaneAndRequiresConfirmationForBusyProcess() {
        let workspaceID = UUID()
        let closingPane = PaneID(value: 0)
        let survivingPane = PaneID(value: 1)
        let tab = WorkspaceTab(
            id: TabID(value: 0),
            name: nil,
            root: .split(
                direction: .horizontal,
                ratio: 0.5,
                a: .leaf(closingPane),
                b: .leaf(survivingPane)
            ),
            focusedPane: survivingPane
        )
        let workspace = Workspace(
            id: workspaceID,
            name: "Remote Close",
            userNamed: true,
            accentHex: "5E5CE6",
            symbol: "R",
            tabs: [tab],
            selectedTabID: tab.id,
            nextTabSeq: 1,
            panes: [
                closingPane: Pane(id: closingPane, title: "vim"),
                survivingPane: Pane(id: survivingPane, title: "zsh"),
            ],
            nextPaneSeq: 2
        )
        let store = WorkspaceStore(activity: PaneActivityStore())
        store.workspaces = [workspace]
        store.selectedWorkspaceID = workspaceID
        store.paneProcesses[
            WorkspaceStore.WorkspacePaneKey(workspace: workspaceID, pane: closingPane)
        ] = "vim"
        let handle = "\(workspaceID.uuidString):\(closingPane.value)"

        XCTAssertEqual(
            store.webRemoteCloseTerminal(pane: handle, confirmed: false),
            .confirmationRequired
        )
        XCTAssertNotNil(store.workspaces[0].panes[closingPane])

        XCTAssertEqual(
            store.webRemoteCloseTerminal(pane: handle, confirmed: true),
            .success
        )
        XCTAssertNil(store.workspaces[0].panes[closingPane])
        XCTAssertNotNil(store.workspaces[0].panes[survivingPane])
        XCTAssertEqual(store.workspaces[0].tabs[0].root.leaves, [survivingPane])
        XCTAssertEqual(store.workspaces[0].tabs[0].focusedPane, survivingPane)
    }

    @MainActor
    func testRemoteCloseRejectsWorkspaceLastTerminal() {
        let workspace = Workspace.fresh(name: "Only", accentHex: "5E5CE6", symbol: "O")
        let pane = try! XCTUnwrap(workspace.selectedTab?.focusedPane)
        let store = WorkspaceStore(activity: PaneActivityStore())
        store.workspaces = [workspace]
        store.selectedWorkspaceID = workspace.id

        XCTAssertEqual(
            store.webRemoteCloseTerminal(
                pane: "\(workspace.id.uuidString):\(pane.value)",
                confirmed: true
            ),
            .failure("last-terminal")
        )
        XCTAssertNotNil(store.workspaces[0].panes[pane])
    }

    // MARK: - Challenge-response crypto (must match the JS client byte-for-byte)

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func hexString(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data(Array($0)) }.map { String(format: "%02x", $0) }.joined()
    }

    func testTokenKeyDecodesHexAndRejectsAnythingElse() {
        XCTAssertEqual(
            hexString(WebRemoteCrypto.tokenKey(from: "0011ff") ?? Data()),
            "0011ff"
        )
        // Exactly 64 lowercase hex chars → 32 bytes.
        let full = String(repeating: "ab", count: 32)
        XCTAssertEqual(WebRemoteCrypto.tokenKey(from: full)?.count, 32)
        // Uppercase, wrong length, non-hex, and empty all fail (fail closed).
        XCTAssertNil(WebRemoteCrypto.tokenKey(from: String(repeating: "ABCD", count: 16)))
        XCTAssertNil(WebRemoteCrypto.tokenKey(from: String(repeating: "00", count: 31)))
        XCTAssertNil(WebRemoteCrypto.tokenKey(from: String(repeating: "zz", count: 32)))
        XCTAssertNil(WebRemoteCrypto.tokenKey(from: ""))
    }

    /// Pins the Swift derivation to the exact bytes the JS client (vendored
    /// noble) produces for the same inputs — the wire-compat contract. If this
    /// changes, the browser and the Mac can no longer talk.
    func testCryptoDerivationMatchesClientVector() {
        let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        let challenge = Data((0 ..< 32).map { UInt8($0) })
        let key = try! XCTUnwrap(WebRemoteCrypto.tokenKey(from: token))

        XCTAssertEqual(
            hexString(WebRemoteCrypto.proof(tokenKey: key, challenge: challenge)),
            "4bab2b0021f6ea13cfa4a9b0ca0741d025ccd291c5b98dbf43480e9ba086120b"
        )
        let keys = WebRemoteCrypto.sessionKeys(tokenKey: key, challenge: challenge)
        XCTAssertEqual(hexString(keys.c2s), "e8c4e3f3f90401c6afdbc05ac630f5fb2ab4bea095e695e13551a45015f253c2")
        XCTAssertEqual(hexString(keys.s2c), "0d95713984b1723faefc9da27063fb792860e30b29648123dd1ecafae17df0d3")
    }

    func testProofAndSessionKeysAreDeterministicAndChallengeBound() {
        let key = WebRemoteCrypto.tokenKey(from: String(repeating: "9c", count: 32))!
        let challengeA = Data(repeating: 0x01, count: 32)
        let challengeB = Data(repeating: 0x02, count: 32)

        // Same inputs → same outputs.
        XCTAssertEqual(
            WebRemoteCrypto.proof(tokenKey: key, challenge: challengeA),
            WebRemoteCrypto.proof(tokenKey: key, challenge: challengeA)
        )
        // Different challenge → different proof and different keys (no leakage
        // across connections).
        XCTAssertNotEqual(
            WebRemoteCrypto.proof(tokenKey: key, challenge: challengeA),
            WebRemoteCrypto.proof(tokenKey: key, challenge: challengeB)
        )
        let a = WebRemoteCrypto.sessionKeys(tokenKey: key, challenge: challengeA)
        let b = WebRemoteCrypto.sessionKeys(tokenKey: key, challenge: challengeB)
        XCTAssertNotEqual(hexString(a.c2s), hexString(b.c2s))
        XCTAssertNotEqual(hexString(a.s2c), hexString(b.s2c))
        // Direction keys are themselves distinct.
        XCTAssertNotEqual(hexString(a.c2s), hexString(a.s2c))
    }

    func testConstantTimeEqualsHandlesLengthAndContent() {
        XCTAssertTrue(WebRemoteCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(WebRemoteCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(WebRemoteCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        XCTAssertFalse(WebRemoteCrypto.constantTimeEquals(Data([1, 2, 3]), Data([])))
        XCTAssertTrue(WebRemoteCrypto.constantTimeEquals(Data(), Data()))
    }

    func testNonceCounterRoundTripsAndStaysMonotonic() {
        XCTAssertEqual(WebRemoteCrypto.nonce(for: 0), Data(count: 12))
        XCTAssertEqual(WebRemoteCrypto.counter(fromNonce: WebRemoteCrypto.nonce(for: 0)), 0)
        XCTAssertEqual(WebRemoteCrypto.counter(fromNonce: WebRemoteCrypto.nonce(for: 42)), 42)
        // The low byte advances first (big-endian) and nonces never repeat.
        XCTAssertEqual(WebRemoteCrypto.nonce(for: 1).last, 0x01)
        var seen = Set<Data>()
        for counter in 0 ..< 1_000 {
            let nonce = WebRemoteCrypto.nonce(for: UInt64(counter))
            XCTAssertEqual(nonce.count, 12)
            XCTAssertTrue(seen.insert(nonce).inserted, "nonce reused at counter \(counter)")
        }
        XCTAssertNil(WebRemoteCrypto.counter(fromNonce: Data(count: 8)))
    }

    func testSealAndOpenRoundTripInEachDirection() {
        let key = WebRemoteCrypto.tokenKey(from: String(repeating: "ab", count: 32))!
        let challenge = Data(repeating: 0x07, count: 32)
        let keys = WebRemoteCrypto.sessionKeys(tokenKey: key, challenge: challenge)
        let plaintext = Data("the quick brown fox".utf8)

        for (label, sendKey, recvKey) in [("c2s", keys.c2s, keys.c2s), ("s2c", keys.s2c, keys.s2c)] {
            guard let frame = WebRemoteCrypto.sealFrame(plaintext: plaintext, key: sendKey, counter: 5) else {
                return XCTFail("seal failed for \(label)")
            }
            // Frame = nonce(12) || ciphertext || tag(16).
            XCTAssertEqual(frame.count, 12 + plaintext.count + 16)
            XCTAssertEqual(
                WebRemoteCrypto.counter(fromNonce: frame.prefix(12)),
                5,
                "nonce in frame must encode the counter"
            )
            let body = frame.subdata(in: 12 ..< frame.count)
            XCTAssertEqual(
                WebRemoteCrypto.openFrame(nonce: frame.prefix(12), body: body, key: recvKey),
                plaintext,
                "round-trip failed for \(label)"
            )
        }
    }

    func testOpenRejectsWrongKeyTamperingAndTruncation() {
        let key = WebRemoteCrypto.tokenKey(from: String(repeating: "ab", count: 32))!
        let otherKey = WebRemoteCrypto.tokenKey(from: String(repeating: "cd", count: 32))!
        let challenge = Data(repeating: 0x07, count: 32)
        let keys = WebRemoteCrypto.sessionKeys(tokenKey: key, challenge: challenge)
        let other = WebRemoteCrypto.sessionKeys(tokenKey: otherKey, challenge: challenge)
        let plaintext = Data("secret".utf8)

        let frame = WebRemoteCrypto.sealFrame(plaintext: plaintext, key: keys.s2c, counter: 0)!
        let nonce = frame.prefix(12)
        let body = frame.subdata(in: 12 ..< frame.count)

        // Wrong key (e.g. wrong token) → auth tag mismatch.
        XCTAssertNil(WebRemoteCrypto.openFrame(nonce: nonce, body: body, key: other.s2c))
        // Tamper one ciphertext byte → rejected.
        var tampered = body
        tampered[0] ^= 0xff
        XCTAssertNil(WebRemoteCrypto.openFrame(nonce: nonce, body: tampered, key: keys.s2c))
        // Truncated frame → rejected.
        XCTAssertNil(WebRemoteCrypto.openFrame(nonce: nonce, body: body.prefix(10), key: keys.s2c))
        // Wrong-length nonce → rejected.
        XCTAssertNil(WebRemoteCrypto.openFrame(nonce: Data(count: 8), body: body, key: keys.s2c))
    }

    func testCryptoAssetIsRegisteredForTheClient() {
        XCTAssertEqual(
            WebRemoteAssets.asset(for: "/crypto.mjs")?.contentType,
            "text/javascript; charset=utf-8"
        )
        XCTAssertNil(WebRemoteAssets.asset(for: "/crypto.js"))
    }
}
