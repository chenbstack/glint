import Foundation
import Darwin

/// Listens on a per-user Unix domain socket. CLI agents (Claude Code,
/// Codex, …) post one JSON line per hook event:
///
///     {"pane":"<workspace-uuid>:<pane-seq>","hook":"UserPromptSubmit"}
///
/// An optional `session_b64` field carries the agent's session id (base64-
/// wrapped to keep the line a clean JSON string) so restore-on-launch can
/// `--resume <id>` instead of `--continue` (#45).
///
/// The bridge parses, posts `.glintAgentEvent` on the main queue, and
/// `WorkspaceStore` translates it into pane state.
final class AgentBridge {
    static let shared = AgentBridge()

    private(set) var socketPath: String = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "glint.agent.bridge", qos: .utility)

    private init() {}

    /// Bind + listen. Path is short on purpose (sun_path is 104 chars on Darwin).
    ///
    /// The socket lives under `~/.glint/run/` (0700) rather than `/tmp`:
    /// a world-writable /tmp lets any local user pre-create ("squat") our
    /// predictable path, and the chmod-after-bind below would otherwise be
    /// a small race window in a world-readable directory. A 0700 parent
    /// closes both holes — nobody else can reach the socket at all.
    ///
    /// Debug builds use a separate socket filename so a running dev Glint
    /// and a running production Glint don't fight over the same path.
    /// Without this split, whichever process started last `unlink()`s the
    /// other's bound entry and steals every incoming hook event — the other
    /// Glint's sidebar would freeze on whatever status the pane was in when
    /// the steal happened (e.g. "thinking" with no Stop to clear it).
    /// The path is baked into each pane's `$GLINT_AGENT_SOCK` at creation,
    /// so panes consistently report back to the Glint that launched them.
    func start() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runDir = home
            .appendingPathComponent(".glint", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        do {
            // 0700 applies to every directory this call creates (including
            // ~/.glint if it doesn't exist yet); pre-existing dirs keep
            // their mode, so re-assert it on `run` below.
            try FileManager.default.createDirectory(
                at: runDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("[glint] agent run dir create failed: \(error)")
            return
        }
        chmod(runDir.path, 0o700)

        #if DEBUG
        let path = runDir.appendingPathComponent("agent-debug.sock").path
        #else
        let path = runDir.appendingPathComponent("agent.sock").path
        #endif
        socketPath = path

        // Reap any stale socket from a previous run.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[glint] agent socket() failed: \(String(cString: strerror(errno)))")
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
            NSLog("[glint] agent bind(\(path)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("[glint] agent listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
        NSLog("[glint] agent bridge listening on \(path)")
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        // The reporter script holds its connection open for up to a second
        // (`nc -w 1`), and a wedged client could hold it forever. Serve each
        // connection on the concurrent global pool — never on the serial
        // accept queue, where one slow client would stall every other hook
        // event — and bound each blocking read() so a silent peer can't pin
        // a pool thread indefinitely.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(fd: client) }
    }

    /// Runs off the accept queue; touches no bridge state. Parsed events
    /// are forwarded to the main queue in `handle(line:)`, so concurrent
    /// connections stay safe.
    private func serve(fd: Int32) {
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
                handle(line: line)
            }
            // Sanity cap so a hostile/buggy client can't OOM us.
            if buf.count > (1 << 20) { break }
        }
    }

    private struct HookEnvelope: Decodable {
        let pane: String
        let hook: String
        let agent: String?
        let sessionB64: String?

        private enum CodingKeys: String, CodingKey {
            case pane, hook, agent
            case sessionB64 = "session_b64"
        }
    }

    static func decodeHookLine(_ line: Data) -> [String: String]? {
        guard let env = try? JSONDecoder().decode(HookEnvelope.self, from: line),
              !env.pane.isEmpty else {
            return nil
        }
        var result = ["pane": env.pane, "hook": env.hook]
        if let agent = env.agent, !agent.isEmpty { result["agent"] = agent }
        if let encoded = env.sessionB64,
           let data = Data(base64Encoded: encoded),
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            result["session"] = value
        }
        return result
    }

    private func handle(line: Data) {
        guard let decoded = Self.decodeHookLine(line) else {
            NSLog("[glint] agent: malformed hook line (\(line.count) bytes)")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .glintAgentEvent,
                object: nil,
                userInfo: decoded
            )
        }
    }
}

extension Notification.Name {
    static let glintAgentEvent = Notification.Name("glint.agent.event")
    /// Posted by GhosttySurfaceView when the user hits plain Esc in a
    /// pane. userInfo: ["pane": "<workspaceUUID>:<paneID>"]. Used to
    /// optimistically clear a busy agent status — no CLI agent emits a
    /// hook on user interrupt.
    static let glintPaneEscPressed = Notification.Name("glint.pane.escPressed")
    /// Posted by GhosttySurfaceView when the user presses plain Return in a
    /// pane. If that pane is currently waiting for an agent permission choice,
    /// the keypress means the user submitted a decision; Codex does not emit a
    /// dedicated "approved" hook, so the store can clear the red waiting state
    /// optimistically until the next hook confirms the outcome.
    static let glintPaneReturnPressed = Notification.Name("glint.pane.returnPressed")
}
