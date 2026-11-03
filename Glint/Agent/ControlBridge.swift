import Foundation
import Darwin
import Security

/// Inbound control channel — the reverse of `AgentBridge`. Where the agent
/// socket only *receives* hook events to drive sidebar state, this one
/// *receives commands* and drives panes: focus a pane, inject text/keys,
/// list panes, read terminal text. It speaks line-delimited JSON, one request → one response
/// (vs. `agent.sock`'s fire-and-forget).
///
///     >> {"cmd":"focus","pane":"<uuid>:<seq>"}            << {"ok":true}
///     >> {"cmd":"send-text","pane":"…","text":"yes","enter":true,"token":"…"}
///     >> {"cmd":"send-key","pane":"…","keys":["down","enter"],"token":"…"}
///     >> {"cmd":"read-text","pane":"…","scrollback":true,"maxLines":1000,"token":"…"}
///     >> {"cmd":"list"}   << {"ok":true,"panes":[{"pane":…,"title":…,"cwd":…,"agent":…}]}
///
/// Auth is **stateless**: each command carries an optional `token`; the
/// server validates per-line. Terminal read/write commands (`read-text`, `send-*`) require a
/// matching token; `focus`/`list` are allowed without one. The token is
/// regenerated every launch into a 0600 file under `~/.glint/run/` — being
/// able to read it ≈ already being able to read the user's private files.
/// See docs/external-pane-control.md §4.4.
final class ControlBridge {
    static let shared = ControlBridge()

    private(set) var socketPath: String = ""
    private(set) var tokenPath: String = ""
    private var token: String = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "glint.control.bridge", qos: .utility)
    /// Whether the listener is currently bound. Guards double-start and makes
    /// stop() a no-op when already off. Mutated only on the main thread (from
    /// the externalControlEnabled toggle / app launch).
    private(set) var isRunning = false

    private let runDirectory: URL
    private let isEnabled: @MainActor () -> Bool
    private var sessionID = UUID()

    init(runDirectory: URL? = nil,
         isEnabled: @escaping @MainActor () -> Bool = { WorkspaceStore.current?.externalControlEnabled ?? false }) {
        self.runDirectory = runDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".glint/run", isDirectory: true)
        self.isEnabled = isEnabled
    }

    /// Canonical socket + token paths. Debug builds use separate filenames so
    /// a dev Glint and a prod Glint don't collide on the same path.
    private func socketPaths() -> (socket: String, token: String) {
        let runDir = runDirectory
        #if DEBUG
        return (runDir.appendingPathComponent("control-debug.sock").path,
                runDir.appendingPathComponent("control-debug.token").path)
        #else
        return (runDir.appendingPathComponent("control.sock").path,
                runDir.appendingPathComponent("control.token").path)
        #endif
    }

    /// Bind + listen on `~/.glint/run/control.sock` (Debug: `control-debug.sock`).
    /// Same 0700-parent / 0600-socket discipline as `AgentBridge` — see its
    /// `start()` for the rationale on why a private parent dir matters here.
    func start() {
        guard !isRunning else { return }
        let runDir = runDirectory
        do {
            try FileManager.default.createDirectory(
                at: runDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("[glint] control run dir create failed: \(error)")
            return
        }
        chmod(runDir.path, 0o700)

        let (path, tokPath) = socketPaths()
        socketPath = path
        tokenPath = tokPath

        // Fresh token every launch; the old one dies with the process.
        token = Self.generateToken()
        writeToken(to: tokPath)

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[glint] control socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let dstPtr = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = strlcpy(dstPtr, src, dst.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, addrLen)
            }
        }
        guard bindRC == 0 else {
            NSLog("[glint] control bind(\(path)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("[glint] control listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let sessionID = UUID()
        self.sessionID = sessionID
        src.setEventHandler { [weak self] in self?.acceptOne(listenFD: fd, sessionID: sessionID) }
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src
        isRunning = true
        NSLog("[glint] control bridge listening on \(path)")
    }

    /// Stop listening and remove the socket + token so the
    /// externalControlEnabled toggle can revoke access live — no app restart.
    /// Safe when already stopped. Previously accepted connections can only
    /// receive disabled errors, including after a subsequent restart.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        // The cancel handler closes the captured listener after queued accept
        // handlers finish, so a restart cannot reuse its fd underneath them.
        listenFD = -1
        token = ""
        if !socketPath.isEmpty { unlink(socketPath) }
        // Drop the token too — a fresh one is minted on the next start(), so a
        // stale on-disk token can't authorize anything while we're off.
        if !tokenPath.isEmpty { unlink(tokenPath) }
        NSLog("[glint] control bridge stopped")
    }

    /// Remove any socket/token left from a previous run while we stay disabled,
    /// so "off" leaves nothing on disk. A clean stop() already does this; this
    /// covers a crash / force-quit where stop() never ran. No-op if running.
    func reapStale() {
        guard !isRunning else { return }
        let (sock, tok) = socketPaths()
        unlink(sock)
        unlink(tok)
    }

    // MARK: token

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func writeToken(to path: String) {
        unlink(path)
        FileManager.default.createFile(
            atPath: path,
            contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        chmod(path, 0o600)
    }

    /// Constant-time compare — no early return on first mismatch.
    private func tokenMatches(_ provided: String?) -> Bool {
        guard let provided else { return false }
        let a = Array(provided.utf8)
        let b = Array(token.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    // MARK: accept / serve

    private func acceptOne(listenFD: Int32, sessionID: UUID) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(fd: client, sessionID: sessionID) }
    }

    /// Runs off the accept queue. Each request line is parsed here, dispatched
    /// onto the main queue (where the store + surfaces live), and the response
    /// line written straight back on this connection.
    private func serve(fd: Int32, sessionID: UUID) {
        defer { close(fd) }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = tmp.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n <= 0 { break }
            buf.append(tmp, count: n)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                var resp = line.count > (1 << 20)
                    ? Self.errorResponse("request-too-large") : handle(line: line, sessionID: sessionID)
                resp.append(0x0A)
                let sent = resp.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { return false }
                        offset += written
                    }
                    return true
                }
                if !sent { return }
            }
            if buf.count > (1 << 20) {
                var response = Self.errorResponse("request-too-large")
                response.append(0x0A)
                response.withUnsafeBytes { raw in
                    _ = Darwin.write(fd, raw.baseAddress, raw.count)
                }
                return
            }
        }
    }

    private func handle(line: Data, sessionID: UUID) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return Self.errorResponse("bad-request")
        }

        var response = Self.errorResponse("unknown-cmd")
        var readGrid: (pane: String, data: Data, scrollback: Bool, maxLines: Int)?
        DispatchQueue.main.sync {
            guard let store = WorkspaceStore.current else {
                response = Self.errorResponse("bad-request")
                return
            }
            // Check on the main queue alongside start/stop: disabling access
            // also revokes commands on already accepted connections.
            guard self.isEnabled(), self.isRunning, self.sessionID == sessionID else {
                response = Self.errorResponse("disabled"); return
            }
            if Self.requiresToken(for: cmd) && !self.tokenMatches(obj["token"] as? String) {
                response = Self.errorResponse("unauthorized"); return
            }
            switch cmd {
            case "list":
                response = Self.okResponse(["panes": store.controlListPanes()])

            case "focus":
                guard let pane = obj["pane"] as? String else {
                    response = Self.errorResponse("bad-request"); return
                }
                response = store.controlFocus(pane: pane).map(Self.errorResponse) ?? Self.okResponse([:])

            case "read-text":
                guard let pane = obj["pane"] as? String,
                      obj["scrollback"] == nil || obj["scrollback"] is Bool,
                      let maxLines = Self.readTextMaxLines(obj["maxLines"]) else {
                    response = Self.errorResponse("bad-request"); return
                }
                switch store.controlReadGrid(pane: pane,
                                             scrollback: obj["scrollback"] as? Bool ?? false,
                                             maxLines: maxLines) {
                case let .success(grid):
                    readGrid = (pane, grid, obj["scrollback"] as? Bool ?? false, maxLines)
                case let .failure(error): response = Self.errorResponse(error)
                }

            case "send-text":
                guard let pane = obj["pane"] as? String, let text = obj["text"] as? String else {
                    response = Self.errorResponse("bad-request"); return
                }
                let enter = (obj["enter"] as? Bool) ?? false
                response = store.controlSendText(pane: pane, text: text, enter: enter)
                    .map(Self.errorResponse) ?? Self.okResponse([:])

            case "send-key":
                guard let pane = obj["pane"] as? String else {
                    response = Self.errorResponse("bad-request"); return
                }
                let keys: [String]
                if let arr = obj["keys"] as? [String] { keys = arr }
                else if let k = obj["key"] as? String { keys = [k] }
                else { response = Self.errorResponse("bad-request"); return }
                response = store.controlSendKeys(pane: pane, keys: keys)
                    .map(Self.errorResponse) ?? Self.okResponse([:])

            default:
                response = Self.errorResponse("unknown-cmd")
            }
        }
        // The main queue owns Ghostty; decoding, span assembly and response JSON
        // belong to this connection's serve thread, especially for large history.
        if let readGrid {
            guard let text = GhosttySurfaceView.controlText(fromRenderGrid: readGrid.data,
                scrollback: readGrid.scrollback, maxLines: readGrid.maxLines) else {
                return Self.errorResponse("pane-not-ready")
            }
            return Self.okResponse(["pane": readGrid.pane, "text": text])
        }
        return response
    }

    static func requiresToken(for command: String) -> Bool {
        command == "send-text" || command == "send-key" || command == "read-text"
    }

    static func readTextMaxLines(_ value: Any?) -> Int? {
        guard let value else { return 1000 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              (1...10_000).contains(number.doubleValue) else { return nil }
        return number.intValue
    }

    // MARK: responses

    private static func okResponse(_ extra: [String: Any]) -> Data {
        var dict: [String: Any] = ["ok": true]
        for (k, v) in extra { dict[k] = v }
        return serialize(dict)
    }

    private static func errorResponse(_ code: String) -> Data {
        serialize(["ok": false, "error": code])
    }

    private static func serialize(_ dict: [String: Any]) -> Data {
        SafeJSON.data(dict)
            ?? Data(#"{"ok":false,"error":"bad-request"}"#.utf8)
    }
}

/// Discovery and installation live in the app; terminal access always goes
/// through ControlBridge, including commands launched by the bundled CLI.
enum ControlCLIIntegration {
    static var executableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/glint")
    }

    private static var installationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    static var installationState: CLIInstallation.State {
        CLIInstallation.state(executable: executableURL, directory: installationDirectory)
    }

    static func install() throws -> URL {
        try CLIInstallation.install(executable: executableURL, directory: installationDirectory)
    }

    static func uninstall() throws {
        try CLIInstallation.uninstall(executable: executableURL, directory: installationDirectory)
    }

    static var agentInstructions: String {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return agentInstructions(executable: executableURL, debug: debug)
    }

    static func agentInstructions(executable: URL, debug: Bool) -> String {
        let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            + (debug ? " --debug" : "")
        return String(localized: "Use the following Glint CLI to control terminals on this Mac. Start with --help and panes list to identify the target pane, then read its contents before sending input. Replace PANE with the full handle from the list.")
            + "\n\n```sh\n"
            + "\(command) --help\n"
            + "\(command) panes list\n"
            + "\(command) pane read PANE --scrollback --max-lines 1000\n"
            + "\(command) pane send PANE --text 'pwd' --enter\n"
            + "\(command) pane key PANE down enter\n"
            + "```\n\n"
            + String(localized: "After input, read the terminal again to verify the result. Ordinary reads and input preserve local workspace selection. Use pane focus PANE only when explicitly asked to switch local focus. External control must be enabled in Glint Settings; if access is unavailable, report that instead of bypassing the switch. The CLI reads its token locally; never print or copy the token.")
    }
}
