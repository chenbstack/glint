import AppKit
import CryptoKit
import XCTest
@testable import Glint

final class WebRemoteProtocolTests: XCTestCase {
    @MainActor
    func testWebRemoteWakeSnapshotsPendingHistoryAtBrowserSize() throws {
        let paneKey = "\(UUID().uuidString):0"
        let archiveID = ScrollbackArchive.fileID(forPaneKey: paneKey)
        let support = try XCTUnwrap(SupportDir.url)
        let archiveDir = support.appendingPathComponent("scrollback", isDirectory: true)
        let archive = archiveDir.appendingPathComponent("\(archiveID).ansi")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archive) }

        let sentinel = "WEB_REMOTE_OFFLINE_HISTORY_SENTINEL"
        let history = String(repeating: "W", count: 180) + sentinel
        let historyData = Data(history.utf8)
        try historyData.write(to: archive, options: [.atomic])
        XCTAssertEqual(ScrollbackArchive.read(id: archiveID), historyData)

        let defaults = UserDefaults.standard
        let key = "glint.restoreTerminalScrollback"
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let view = GhosttySurfaceView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 120),
            paneKey: paneKey
        )
        var receivedSnapshot: WebRemoteTerminalSnapshot?
        view.webRemoteSnapshot(size: WebRemoteTerminalSize(columns: 240, rows: 40)) {
            receivedSnapshot = $0
        }
        let deadline = Date().addingTimeInterval(1)
        while receivedSnapshot == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        let snapshot = try XCTUnwrap(receivedSnapshot)
        XCTAssertTrue(String(decoding: snapshot.payload, as: UTF8.self).contains(sentinel))
    }

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
        let differentSuffix = token.last == "0" ? "1" : "0"
        XCTAssertFalse(WebRemoteAccessToken.matches(String(token.dropLast()) + differentSuffix, expected: token))
    }

    func testAccessKeyPersistsUntilExplicitReset() {
        let suite = "WebRemoteAccessKeyStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WebRemoteEphemeralSecretStorage()

        let first = WebRemoteAccessKeyStore.loadOrCreate(storage: storage, legacyDefaults: defaults)
        XCTAssertEqual(
            WebRemoteAccessKeyStore.loadOrCreate(storage: storage, legacyDefaults: defaults),
            first
        )

        let reset = WebRemoteAccessKeyStore.reset(storage: storage, legacyDefaults: defaults)
        XCTAssertNotEqual(reset, first)
        XCTAssertEqual(
            WebRemoteAccessKeyStore.loadOrCreate(storage: storage, legacyDefaults: defaults),
            reset
        )
    }

    /// The token must never be written to the preferences plist — that file is
    /// world-readable to any process running as this user, and the token is a
    /// live shell.
    func testAccessKeyIsNeverWrittenToPlaintextDefaults() {
        let suite = "WebRemoteAccessKeyPlaintextTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WebRemoteEphemeralSecretStorage()

        let created = WebRemoteAccessKeyStore.loadOrCreate(storage: storage, legacyDefaults: defaults)
        XCTAssertEqual(storage.secret(for: WebRemoteAccessKeyStore.account), created)
        XCTAssertNil(defaults.string(forKey: "glint.webRemoteAccessKey"))

        WebRemoteAccessKeyStore.reset(storage: storage, legacyDefaults: defaults)
        XCTAssertNil(defaults.string(forKey: "glint.webRemoteAccessKey"))
    }

    /// Existing installs keep their paired browsers working: the cleartext key
    /// is adopted into secure storage, and the cleartext copy is erased.
    func testAccessKeyMigratesOutOfLegacyDefaultsAndScrubsThem() {
        let suite = "WebRemoteAccessKeyMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WebRemoteEphemeralSecretStorage()

        let legacy = WebRemoteAccessToken.generate()
        defaults.set(legacy, forKey: "glint.webRemoteAccessKey")

        let loaded = WebRemoteAccessKeyStore.loadOrCreate(storage: storage, legacyDefaults: defaults)
        XCTAssertEqual(loaded, legacy, "migration must preserve the key, not regenerate it")
        XCTAssertEqual(storage.secret(for: WebRemoteAccessKeyStore.account), legacy)
        XCTAssertNil(defaults.string(forKey: "glint.webRemoteAccessKey"))
    }

    /// A malformed leftover must not be adopted — it would be an unusable key.
    func testAccessKeyIgnoresInvalidLegacyValue() {
        let suite = "WebRemoteAccessKeyInvalidLegacyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WebRemoteEphemeralSecretStorage()

        defaults.set("not-a-valid-token", forKey: "glint.webRemoteAccessKey")
        let loaded = WebRemoteAccessKeyStore.loadOrCreate(storage: storage, legacyDefaults: defaults)

        XCTAssertEqual(loaded.count, 64)
        XCTAssertNotEqual(loaded, "not-a-valid-token")
        XCTAssertNil(defaults.string(forKey: "glint.webRemoteAccessKey"))
    }

    func testWebRemotePortPersistsUntilExplicitReset() {
        let suite = "WebRemotePortStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = WebRemotePortStore.loadOrCreate(defaults: defaults)
        XCTAssertEqual(initial.http, 43871)
        XCTAssertEqual(initial.webSocket, 43872)
        XCTAssertEqual(WebRemotePortStore.loadOrCreate(defaults: defaults), initial)

        let reset = WebRemotePortStore.reset(defaults: defaults, randomPort: { 52000 })
        XCTAssertEqual(reset.http, 52000)
        XCTAssertEqual(reset.webSocket, 52001)
        XCTAssertNotEqual(reset, initial)
        XCTAssertEqual(WebRemotePortStore.loadOrCreate(defaults: defaults), reset)
    }

    func testEveryAppIconPresetProvidesAWebRemotePNG() throws {
        for preset in AppIconPreset.allCases {
            let value = try XCTUnwrap(WebRemoteBrandIcon.dataURL(for: preset), preset.rawValue)
            XCTAssertTrue(value.hasPrefix("data:image/png;base64,"), preset.rawValue)
            let encoded = String(value.dropFirst("data:image/png;base64,".count))
            let png = try XCTUnwrap(Data(base64Encoded: encoded), preset.rawValue)
            XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], preset.rawValue)
        }
    }

    func testAccessKeyCanBeCopiedSeparatelyFromSessionURL() {
        let value = "http://192.168.1.20:43871/#token=abc123"

        XCTAssertEqual(WebRemoteAccessURL.token(from: value), "abc123")
        XCTAssertNil(WebRemoteAccessURL.token(from: "http://192.168.1.20:43871/"))
    }

    func testRedactedURLStripsTokenFragmentForSafeCopying() {
        XCTAssertEqual(
            WebRemoteAccessURL.redacted(from: "http://192.168.1.20:43871/#token=abc123"),
            "http://192.168.1.20:43871/"
        )
        // A URL without a token fragment is returned unchanged.
        XCTAssertEqual(
            WebRemoteAccessURL.redacted(from: "http://192.168.1.20:43871/"),
            "http://192.168.1.20:43871/"
        )
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
        XCTAssertEqual(WebRemoteAssets.asset(for: "/ime-input.mjs")?.resource, "ime-input")
        XCTAssertEqual(WebRemoteAssets.asset(for: "/symbols-nerd-font-mono.ttf")?.contentType, "font/ttf")
        XCTAssertNil(WebRemoteAssets.asset(for: "/../state.json"))
        XCTAssertNil(WebRemoteAssets.asset(for: "/favicon.ico"))
    }

    func testBundledAssetsSupportTwoFingerTerminalScrolling() throws {
        let scriptURL = try XCTUnwrap(
            Bundle.main.url(forResource: "web-remote", withExtension: "js")
        )
        let styleURL = try XCTUnwrap(
            Bundle.main.url(forResource: "web-remote", withExtension: "css")
        )
        let inputURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ime-input", withExtension: "mjs")
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let style = try String(contentsOf: styleURL, encoding: .utf8)
        let input = try String(contentsOf: inputURL, encoding: .utf8)

        XCTAssertTrue(script.contains("installTwoFingerTerminalScrolling"))
        XCTAssertTrue(input.contains("\"touchstart\""))
        XCTAssertTrue(input.contains("\"touchmove\""))
        XCTAssertTrue(input.contains("terminal.scrollLines"))
        XCTAssertTrue(input.contains("terminal.buffer.active.baseY > 0"))
        XCTAssertTrue(input.contains("terminal.modes?.mouseTrackingMode === \"none\""))
        XCTAssertTrue(input.contains("new WheelEventLike(\"wheel\""))
        XCTAssertTrue(input.contains(".xterm-screen"))
        XCTAssertTrue(input.contains("passive: false"))
        XCTAssertTrue(style.contains("touch-action: manipulation"))
    }

    func testBundledClientCanDisableTerminalAutoFocus() throws {
        let scriptURL = try XCTUnwrap(
            Bundle.main.url(forResource: "web-remote", withExtension: "js")
        )
        let htmlURL = try XCTUnwrap(
            Bundle.main.url(forResource: "web-remote-index", withExtension: "html")
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)

        XCTAssertTrue(html.contains("id=\"auto-focus-terminal\""))
        XCTAssertTrue(script.contains("glint-auto-focus-terminal"))
        XCTAssertTrue(script.contains("(hover: none) and (pointer: coarse)"))
        XCTAssertTrue(script.contains("if (autoFocusTerminal) terminal.focus()"))
    }

    func testBundledClientRecoversStaleWebSocketConnections() throws {
        let scriptURL = try XCTUnwrap(
            Bundle.main.url(forResource: "web-remote", withExtension: "js")
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("const serverSilenceTimeout = heartbeatInterval * 4"))
        XCTAssertTrue(script.contains("Date.now() - lastServerMessageAt >= serverSilenceTimeout"))
        XCTAssertTrue(script.contains("window.addEventListener(\"online\", connect)"))
        XCTAssertTrue(script.contains("window.addEventListener(\"pageshow\", reconnectIfStale)"))
        XCTAssertTrue(script.contains("document.addEventListener(\"visibilitychange\""))

        let messageHandlerStart = try XCTUnwrap(
            script.range(of: "socket.addEventListener(\"message\", event => {")
        )
        let closeHandlerStart = try XCTUnwrap(
            script.range(
                of: "socket.addEventListener(\"close\", () => {",
                range: messageHandlerStart.upperBound ..< script.endIndex
            )
        )
        let messageHandler = script[messageHandlerStart.lowerBound ..< closeHandlerStart.lowerBound]
        let identityGuard = try XCTUnwrap(
            messageHandler.range(of: "if (socket !== currentSocket) return")
        )
        let timestampUpdate = try XCTUnwrap(
            messageHandler.range(of: "lastServerMessageAt = Date.now()")
        )
        XCTAssertLessThan(identityGuard.lowerBound, timestampUpdate.lowerBound)
    }

    func testSelectingNewPaneSupersedesPendingSelection() {
        XCTAssertEqual(
            WebRemoteServer.panesToReconcileWhenSelecting(
                subscribedPane: nil,
                pendingPane: "pane-a",
                nextPane: "pane-b"
            ),
            Set(["pane-a"])
        )
    }

    func testRepeatedPaneSelectionOnlyAcceptsLatestGeneration() {
        XCTAssertFalse(
            WebRemoteServer.isCurrentPaneSelection(
                pendingPane: "pane-a",
                pendingGeneration: 3,
                pane: "pane-a",
                generation: 1
            )
        )
        XCTAssertTrue(
            WebRemoteServer.isCurrentPaneSelection(
                pendingPane: "pane-a",
                pendingGeneration: 3,
                pane: "pane-a",
                generation: 3
            )
        )
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

    func testWebRemoteFilesListsAndReadsOnlyWorkspaceText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello\n".utf8).write(to: folder.appendingPathComponent("main.swift"))
        let entries = try WebRemoteFiles.list(root: root.path, path: "src").get()
        XCTAssertEqual(entries.first?["name"] as? String, "main.swift")
        XCTAssertEqual(entries.first?["kind"] as? String, "file")
        XCTAssertEqual(try WebRemoteFiles.read(root: root.path, path: "src/main.swift").get(), "hello\n")
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "../outside").get())
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "/etc/passwd").get())
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "src/../main.swift").get())
    }

    func testWebRemoteFilesRejectLinksBinaryAndOversize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc")
        )
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "outside/passwd").get())
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: WebRemoteFiles.maxPreviewBytes + 1)
            .write(to: root.appendingPathComponent("large"))
        if case .failure(.notText) = WebRemoteFiles.read(root: root.path, path: "binary") {
        } else { XCTFail("Binary content must be rejected") }
        if case .failure(.tooLarge) = WebRemoteFiles.read(root: root.path, path: "large") {
        } else { XCTFail("Large content must be rejected") }
    }

    func testFileDirectoryStaysAnchoredWhenRootIsReplaced() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside.txt"))
        let directory = try WebRemoteFiles.Directory(root: root.path)
        try fm.moveItem(at: root, to: base.appendingPathComponent("moved"))
        try fm.createSymbolicLink(at: root, withDestinationURL: outside)
        for _ in 0..<2 {
            XCTAssertEqual(try directory.list(path: "").compactMap { $0["name"] as? String }, ["inside.txt"])
        }
        XCTAssertEqual(try directory.read(path: "inside.txt", limit: 128, tooLarge: .tooLarge), Data("inside".utf8))
        XCTAssertThrowsError(try directory.read(path: "outside.txt", limit: 128, tooLarge: .tooLarge))
    }

    func testFileReadsAndListingsCannotFollowConcurrentSymlinkSwaps() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let item = root.appendingPathComponent("item")
        let alternate = root.appendingPathComponent("alternate")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: item, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("inside".utf8).write(to: item.appendingPathComponent("test.txt"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("test.txt"))
        try Data().write(to: outside.appendingPathComponent("outside-only.txt"))
        try fm.createSymbolicLink(at: alternate, withDestinationURL: outside)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for _ in 0..<4000 {
                _ = renameatx_np(AT_FDCWD, item.path, AT_FDCWD, alternate.path, UInt32(RENAME_SWAP))
            }
        }
        defer { group.wait() }
        for _ in 0..<500 {
            if case let .success(text) = WebRemoteFiles.read(root: root.path, path: "item/test.txt") {
                XCTAssertEqual(text, "inside")
            }
            if case let .success(entries) = WebRemoteFiles.list(root: root.path, path: "item") {
                XCTAssertFalse(entries.contains { $0["name"] as? String == "outside-only.txt" })
            }
        }
    }

    func testFileReadersRejectLeafLinksAndSpecialFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("text"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("text"))
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "link.png").get())
        XCTAssertThrowsError(try WebRemoteFiles.readImage(root: root.path, path: "link.png").get())
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "pipe").get())
        XCTAssertThrowsError(try WebRemoteFiles.read(root: root.path, path: "").get())
    }

    func testFileRequestsRejectChangedRootsAndRequireCorrelation() throws {
        var payload: [String: Any] = [
            "type": "readFile", "workspace": UUID().uuidString, "pane": "pane",
            "root": "/project-A", "path": "README.md", "request": "17",
        ]
        let request = try XCTUnwrap(WebRemoteFileRequest(payload))
        XCTAssertEqual(try request.validatedRoot(current: "/project-A").get(), "/project-A")
        XCTAssertThrowsError(try request.validatedRoot(current: "/project-B").get()) {
            XCTAssertEqual($0 as? WebRemoteFiles.ErrorCode, .rootChanged)
        }
        XCTAssertThrowsError(try request.validatedRoot(current: nil).get())
        XCTAssertEqual(request.error(.rootChanged)["request"] as? String, "17")
        payload.removeValue(forKey: "request")
        XCTAssertNil(WebRemoteFileRequest(payload))
        payload["request"] = "18"
        payload["root"] = ""
        XCTAssertNil(WebRemoteFileRequest(payload), "Reads may not discover/rebase the root")
        payload["type"] = "listFiles"
        XCTAssertNil(WebRemoteFileRequest(payload), "Subdirectory listings must bind a root too")
        payload["path"] = ""
        let discovery = try XCTUnwrap(WebRemoteFileRequest(payload))
        XCTAssertEqual(try discovery.validatedRoot(current: "/project-B").get(), "/project-B")
    }

    @MainActor
    func testWebRemoteFileRootRejectsSSHWithoutRemoteTitleMetadata() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        var workspace = Workspace.fresh(name: "SSH", accentHex: "5E5CE6", symbol: "S")
        let pane = try XCTUnwrap(workspace.selectedTab?.focusedPane)
        workspace.panes[pane]?.workingDirectory = project.path
        // Both ssh host and ssh host command may have no remote cwd/title.
        XCTAssertNil(workspace.panes[pane]?.remoteTarget)
        let store = WorkspaceStore(activity: PaneActivityStore())
        store.workspaces = [workspace]
        let key = WorkspaceStore.WorkspacePaneKey(workspace: workspace.id, pane: pane)
        let handle = "\(workspace.id.uuidString):\(pane.value)"
        store.paneProcesses[key] = "ssh"
        XCTAssertNil(store.webRemoteFileRoot(workspace: workspace.id, pane: handle))
        store.paneProcesses[key] = "zsh"
        XCTAssertEqual(store.webRemoteFileRoot(workspace: workspace.id, pane: handle), project.path)
    }

    func testWebRemoteImagePreviewUsesWorkspacePathAndReturnsPNG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.setColor(.red, atX: 0, y: 0)
        let source = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try source.write(to: root.appendingPathComponent("photo.PNG"))

        XCTAssertTrue(WebRemoteFiles.isImage("photo.PNG"))
        XCTAssertFalse(WebRemoteFiles.isImage("page.html"))
        XCTAssertTrue(WebRemoteFiles.isHTML("page.HTM"))
        let preview = try WebRemoteFiles.readImage(root: root.path, path: "photo.PNG").get()
        XCTAssertEqual(Array(preview.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertThrowsError(try WebRemoteFiles.readImage(root: root.path, path: "../photo.PNG").get())
    }

    @MainActor
    func testWebRemoteFileRootUsesRequestedTerminalCwd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var workspace = Workspace.fresh(name: "Files", accentHex: "5E5CE6", symbol: "F")
        let first = try XCTUnwrap(workspace.selectedTab?.focusedPane)
        workspace.panes[first]?.workingDirectory = project.path
        workspace.source.repoRoot = project.path
        let second = PaneID(value: 1)
        workspace.panes[second] = Pane(id: second, title: "zsh", workingDirectory: other.path)
        workspace.tabs.append(WorkspaceTab(
            id: TabID(value: 1), name: nil, root: .leaf(second), focusedPane: second
        ))
        let store = WorkspaceStore(activity: PaneActivityStore())
        store.workspaces = [workspace]

        XCTAssertEqual(store.webRemoteFileRoot(
            workspace: workspace.id, pane: "\(workspace.id.uuidString):1"
        ), other.path)
        XCTAssertNil(store.webRemoteFileRoot(workspace: UUID(), pane: "\(workspace.id.uuidString):1"))
        XCTAssertNil(store.webRemoteFileRoot(workspace: workspace.id, pane: "\(workspace.id.uuidString):2"))
        store.workspaces[0].panes[second]?.remoteTarget = "example.com"
        XCTAssertNil(store.webRemoteFileRoot(
            workspace: workspace.id, pane: "\(workspace.id.uuidString):1"
        ))
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
        XCTAssertNil(WebRemoteCrypto.tokenKey(from: "0011ff"))
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
