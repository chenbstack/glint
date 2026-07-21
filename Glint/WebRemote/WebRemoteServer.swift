import CryptoKit
import Foundation
import Network
import os

private let webRemoteLogger = Logger(subsystem: "app.glint", category: "WebRemote")

enum WebRemoteStatus: Equatable {
    case stopped
    case starting
    case ready(urls: [String])
    case portConflict(port: UInt16)
    case failed(message: String)
}

struct WebRemoteOutputBuffer {
    private struct Boundary {
        let sequence: UInt64
        let endOffset: Int
    }

    let byteLimit: Int
    private(set) var data = Data()
    private var boundaries: [Boundary] = []

    var isEmpty: Bool { data.isEmpty }

    init(byteLimit: Int) {
        precondition(byteLimit >= 0)
        self.byteLimit = byteLimit
    }

    mutating func append(_ chunk: Data, sequence: UInt64) -> Bool {
        guard chunk.count <= byteLimit - data.count else { return false }
        data.append(chunk)
        boundaries.append(Boundary(sequence: sequence, endOffset: data.count))
        return true
    }

    mutating func append(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        sequence: UInt64
    ) -> Bool {
        guard count <= byteLimit - data.count else { return false }
        data.append(bytes, count: count)
        boundaries.append(Boundary(sequence: sequence, endOffset: data.count))
        return true
    }

    mutating func append(contentsOf buffer: WebRemoteOutputBuffer) -> Bool {
        guard buffer.data.count <= byteLimit - data.count else { return false }
        let baseOffset = data.count
        data.append(buffer.data)
        boundaries.append(contentsOf: buffer.boundaries.map {
            Boundary(sequence: $0.sequence, endOffset: baseOffset + $0.endOffset)
        })
        return true
    }

    mutating func take(after sequence: UInt64? = nil) -> Data {
        let startOffset: Int
        if let sequence,
           let index = boundaries.firstIndex(where: { $0.sequence > sequence }) {
            startOffset = index == boundaries.startIndex ? 0 : boundaries[index - 1].endOffset
        } else if sequence == nil {
            startOffset = 0
        } else {
            startOffset = data.endIndex
        }
        let result = data.subdata(in: startOffset ..< data.endIndex)
        data.removeAll(keepingCapacity: true)
        boundaries.removeAll(keepingCapacity: true)
        return result
    }
}

struct WebRemoteOutboundBuffer {
    enum Item {
        case message(Data)
        case terminalOutput(pane: String, data: Data)
    }

    let maxQueuedOutputBytes: Int
    private var items: [Item] = []
    private var queuedOutputBytes = 0

    init(maxQueuedOutputBytes: Int) {
        precondition(maxQueuedOutputBytes >= 0)
        self.maxQueuedOutputBytes = maxQueuedOutputBytes
    }

    mutating func enqueueMessage(_ data: Data) {
        items.append(.message(data))
    }

    mutating func enqueueTerminalOutput(_ data: Data, pane: String) -> Bool {
        guard data.count <= maxQueuedOutputBytes - queuedOutputBytes else { return false }
        if let last = items.last,
           case let .terminalOutput(existingPane, existingData) = last,
           existingPane == pane {
            var combined = existingData
            combined.append(data)
            items[items.index(before: items.endIndex)] = .terminalOutput(
                pane: pane,
                data: combined
            )
        } else {
            items.append(.terminalOutput(pane: pane, data: data))
        }
        queuedOutputBytes += data.count
        return true
    }

    mutating func next() -> Item? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if case let .terminalOutput(_, data) = item {
            queuedOutputBytes -= data.count
        }
        return item
    }

    mutating func removeAll() {
        items.removeAll()
        queuedOutputBytes = 0
    }
}

final class WebRemoteServer: @unchecked Sendable {
    static let shared = WebRemoteServer()

    private static let maxIngressOutputBytes = 256 * 1024
    private static let maxSelectionOutputBytes = 512 * 1024
    private static let authFailureCountCap = 7

    /// Delay before answering a failed `authenticate`, growing exponentially
    /// with the per-connection failure count to throttle online token guessing.
    /// 0.25s → 0.5s → 1s → … → 16s (capped at the 7th failure). Honest clients
    /// almost never fail auth, so this only bites brute-forcers.
    static func authBackoffSeconds(forFailures count: Int) -> TimeInterval {
        let safe = min(max(count, 1), authFailureCountCap)
        let multiplier = pow(2.0, Double(safe - 1))
        return min(0.25 * multiplier, 16)
    }

    private enum ListenerKind: Hashable {
        case http
        case webSocket
    }

    private let queue = DispatchQueue(label: "app.glint.web-remote", qos: .utility)
    private let subscriptionLock = NSLock()
    private var subscribedPanes = Set<String>()
    private var pendingTerminalOutput: [String: WebRemoteOutputBuffer] = [:]
    private var overflowedTerminalOutput = Set<String>()
    private var terminalOutputDrainScheduled = false
    private var httpListener: NWListener?
    private var webSocketListener: NWListener?
    private var clients: [UUID: WebRemoteClientConnection] = [:]
    private var readyListeners = Set<ListenerKind>()
    private var runID: UUID?
    private var token = ""
    /// Raw 32-byte key material decoded from `token`; empty until the server
    /// starts with a valid token. Drives the challenge-response handshake.
    private var tokenKey = Data()
    private var ports = WebRemotePortStore.loadOrCreate()
    private var listenInterface = WebRemoteListenTarget.loopback
    private var lastBoundAddress: String?
    private var pathMonitor: NWPathMonitor?
    private var pathRestartScheduled = false
    private var terminalSizeRevision: UInt64 = 0
    private var assetCache: [String: Data] = [:]
    private var statusHandler: ((WebRemoteStatus) -> Void)?

    private init() {}

    func setStatusHandler(_ handler: @escaping (WebRemoteStatus) -> Void) {
        queue.async { [weak self] in
            self?.statusHandler = handler
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(emitStatus: true)
        }
    }

    func resetCredentials() {
        queue.async { [weak self] in
            self?.resetCredentialsLocked()
        }
    }

    /// Stage a new bind target. Takes effect on the next `start()`; the store
    /// calls `start()` right after when the server is enabled, which
    /// stop→start rebinds.
    func setListenInterface(_ key: String) {
        queue.async { [weak self] in
            self?.listenInterface = key
        }
    }

    func refreshAppearance() {
        queue.async { [weak self] in
            guard let self else { return }
            clients.values
                .filter(\.authenticated)
                .forEach { self.sendState(to: $0.id) }
        }
    }

    func forwardTerminalOutput(
        pane: String,
        bytes: UnsafePointer<UInt8>?,
        count: UInt,
        sequence: UInt64
    ) {
        guard let bytes, count > 0, let byteCount = Int(exactly: count) else { return }
        var shouldScheduleDrain = false
        subscriptionLock.lock()
        let interested = subscribedPanes.contains(pane)
        if interested {
            if !overflowedTerminalOutput.contains(pane) {
                var buffer = pendingTerminalOutput[pane]
                    ?? WebRemoteOutputBuffer(byteLimit: Self.maxIngressOutputBytes)
                if buffer.append(bytes, count: byteCount, sequence: sequence) {
                    pendingTerminalOutput[pane] = buffer
                } else {
                    pendingTerminalOutput.removeValue(forKey: pane)
                    overflowedTerminalOutput.insert(pane)
                }
            }
            if !terminalOutputDrainScheduled {
                terminalOutputDrainScheduled = true
                shouldScheduleDrain = true
            }
        }
        subscriptionLock.unlock()
        guard interested else { return }
        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drainTerminalOutputLocked()
            }
        }
    }

    private func drainTerminalOutputLocked() {
        subscriptionLock.lock()
        let batches = pendingTerminalOutput
        let overflowedPanes = overflowedTerminalOutput
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        overflowedTerminalOutput.removeAll(keepingCapacity: true)
        terminalOutputDrainScheduled = false
        subscriptionLock.unlock()

        let overflowedClientIDs = clients.values.compactMap { client -> UUID? in
            guard client.authenticated,
                  let pane = client.pendingPane ?? client.subscribedPane,
                  overflowedPanes.contains(pane)
            else { return nil }
            return client.id
        }
        overflowedClientIDs.forEach { dropSlowClientLocked($0) }

        var slowClientIDs = Set<UUID>()
        for (pane, buffer) in batches {
            for client in clients.values where client.authenticated {
                if client.pendingPane == pane {
                    if !client.pendingSelectionOutput.append(contentsOf: buffer) {
                        slowClientIDs.insert(client.id)
                    }
                } else if client.subscribedPane == pane,
                          !client.sendTerminalOutput(buffer.data, pane: pane) {
                    slowClientIDs.insert(client.id)
                }
            }
        }
        slowClientIDs.forEach { dropSlowClientLocked($0) }
    }

    private func startLocked() {
        stopLocked(emitStatus: false)
        emit(.starting)
        token = WebRemoteAccessKeyStore.loadOrCreate()
        tokenKey = WebRemoteCrypto.tokenKey(from: token) ?? Data()
        ports = WebRemotePortStore.loadOrCreate()
        let currentRun = UUID()
        runID = currentRun

        do {
            let isExplicitWildcard = listenInterface == WebRemoteListenTarget.any
            let bindAddress = WebRemoteListenTarget.bindAddress(for: listenInterface)
            // A user-chosen NIC that currently has no IPv4 must fail loudly.
            // bindAddress returns nil both for "explicit All interfaces" and
            // for "selected NIC vanished"; conflating them would silently widen
            // exposure to 0.0.0.0 — the opposite of picking a NIC.
            guard isExplicitWildcard || bindAddress != nil else {
                failLocked("Selected interface is no longer available.")
                return
            }
            lastBoundAddress = bindAddress
            // Restrict the listener to the chosen local address instead of the
            // default wildcard (0.0.0.0 + ::). loopback → 127.0.0.1, a named
            // interface → its current IPv4. The endpoint's port must be 0
            // ("any"); a concrete port collides with the listener's `on:` and
            // fails with EINVAL (NWError 22).
            let localEndpoint: NWEndpoint? = bindAddress.flatMap { address in
                IPv4Address(address).map { .hostPort(host: .ipv4($0), port: 0) }
            }

            let httpParameters = NWParameters.tcp
            httpParameters.allowLocalEndpointReuse = true
            guard let httpPort = NWEndpoint.Port(rawValue: ports.http),
                  let webSocketPort = NWEndpoint.Port(rawValue: ports.webSocket)
            else {
                failLocked("Invalid web remote port.")
                return
            }
            httpParameters.requiredLocalEndpoint = localEndpoint

            let http = try NWListener(using: httpParameters, on: httpPort)
            // Advertising via mDNS only makes sense when the listener is
            // reachable from the LAN; skip it for loopback.
            if listenInterface != WebRemoteListenTarget.loopback {
                http.service = NWListener.Service(name: "Glint Remote", type: "_http._tcp")
            }

            let webSocketParameters = NWParameters.tcp
            webSocketParameters.allowLocalEndpointReuse = true
            webSocketParameters.requiredLocalEndpoint = localEndpoint
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            webSocketParameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            let webSocket = try NWListener(using: webSocketParameters, on: webSocketPort)

            httpListener = http
            webSocketListener = webSocket
            configure(http, kind: .http, runID: currentRun)
            configure(webSocket, kind: .webSocket, runID: currentRun)
            http.newConnectionHandler = { [weak self] connection in
                self?.handleHTTPConnection(connection)
            }
            webSocket.newConnectionHandler = { [weak self] connection in
                self?.handleWebSocketConnection(connection)
            }
            http.start(queue: queue)
            webSocket.start(queue: queue)
            startPathMonitorLocked(currentRun)
        } catch {
            failLocked(error.localizedDescription)
        }
    }

    /// Watch for the bound NIC's IPv4 changing while the server runs (DHCP
    /// renewal, Wi-Fi switch, sleep/wake). loopback and explicit-wildcard are
    /// address-stable / address-agnostic and skip the monitor. On a real
    /// change we coalesce into a single rebind (stop+start re-resolves the
    /// current IPv4 and refreshes the access URLs); a vanished NIC rebinds and
    /// then fails loudly via the guard in `startLocked`.
    private func startPathMonitorLocked(_ runID: UUID) {
        pathMonitor?.cancel()
        guard listenInterface != WebRemoteListenTarget.loopback,
              listenInterface != WebRemoteListenTarget.any,
              lastBoundAddress != nil
        else {
            pathMonitor = nil
            return
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.handlePathUpdate(runID: runID)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func handlePathUpdate(runID: UUID) {
        guard runID == self.runID, !pathRestartScheduled else { return }
        let current = WebRemoteAddressResolver.currentIPv4(forInterface: listenInterface)
        guard current != lastBoundAddress else { return }
        // NWPathMonitor can fire a burst of updates on a topology change; wait
        // for things to settle, then rebind once.
        pathRestartScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pathRestartScheduled else { return }
            self.pathRestartScheduled = false
            guard self.runID == runID else { return }
            webRemoteLogger.info("Web remote interface address changed; rebinding")
            self.startLocked()
        }
    }

    private func configure(_ listener: NWListener, kind: ListenerKind, runID: UUID) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.runID == runID else { return }
            switch state {
            case .ready:
                self.readyListeners.insert(kind)
                if self.readyListeners.count == 2 {
                    webRemoteLogger.info("Web remote listening on ports \(self.ports.http) and \(self.ports.webSocket)")
                    self.emit(.ready(urls: self.accessURLsLocked()))
                }
            case let .failed(error):
                let port = kind == .http ? self.ports.http : self.ports.webSocket
                if case .posix(.EADDRINUSE) = error {
                    self.failLocked(status: .portConflict(port: port))
                } else {
                    self.failLocked(error.localizedDescription)
                }
            default:
                break
            }
        }
    }

    private func resetCredentialsLocked() {
        WebRemoteAccessKeyStore.reset()
        WebRemotePortStore.reset()
        startLocked()
    }

    private func accessURLsLocked() -> [String] {
        let hosts: [String]
        switch listenInterface {
        case WebRemoteListenTarget.loopback:
            hosts = ["127.0.0.1"]
        case WebRemoteListenTarget.any:
            let addresses = WebRemoteAddressResolver.localIPv4Addresses()
            hosts = addresses.isEmpty ? ["127.0.0.1"] : addresses
        default:
            // Named interface: show its current IPv4. If the interface has gone
            // away, fall back to loopback for display — the bind itself will
            // fail and surface `.failed`.
            let address = WebRemoteAddressResolver.currentIPv4(forInterface: listenInterface)
            hosts = [address ?? "127.0.0.1"]
        }
        return hosts.map { "http://\($0):\(ports.http)/#token=\(token)" }
    }

    private func stopLocked(emitStatus: Bool) {
        let controlledPanes = controlledPanesLocked()
        runID = nil
        httpListener?.cancel()
        webSocketListener?.cancel()
        httpListener = nil
        webSocketListener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        readyListeners.removeAll()
        token = ""
        tokenKey = Data()
        pathMonitor?.cancel()
        pathMonitor = nil
        pathRestartScheduled = false
        lastBoundAddress = nil
        updateSubscribedPanesLocked()
        releaseTerminalSizes(controlledPanes)
        if emitStatus {
            webRemoteLogger.info("Web remote stopped")
            emit(.stopped)
        }
    }

    private func failLocked(_ message: String) {
        failLocked(status: .failed(message: message))
    }

    private func failLocked(status: WebRemoteStatus) {
        let controlledPanes = controlledPanesLocked()
        runID = nil
        httpListener?.cancel()
        webSocketListener?.cancel()
        httpListener = nil
        webSocketListener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        readyListeners.removeAll()
        token = ""
        tokenKey = Data()
        pathMonitor?.cancel()
        pathMonitor = nil
        pathRestartScheduled = false
        lastBoundAddress = nil
        updateSubscribedPanesLocked()
        releaseTerminalSizes(controlledPanes)
        webRemoteLogger.error("Web remote failed: \(String(describing: status), privacy: .public)")
        emit(status)
    }

    private func emit(_ status: WebRemoteStatus) {
        guard let statusHandler else { return }
        DispatchQueue.main.async {
            statusHandler(status)
        }
    }

    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveHTTPRequest(connection, buffer: Data())
            case .failed,
                 .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHTTPRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self, weak connection] content, _, complete, error in
            guard let self, let connection else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let content { next.append(content) }
            if next.count > 16_384 {
                self.sendHTTPError(431, reason: "Request Header Fields Too Large", to: connection)
                return
            }
            if next.range(of: Data([13, 10, 13, 10])) != nil {
                self.serveHTTPRequest(next, on: connection)
                return
            }
            if complete {
                self.sendHTTPError(400, reason: "Bad Request", to: connection)
                return
            }
            self.receiveHTTPRequest(connection, buffer: next)
        }
    }

    private func serveHTTPRequest(_ data: Data, on connection: NWConnection) {
        guard let request = WebRemoteHTTPRequest.parse(data) else {
            sendHTTPError(400, reason: "Bad Request", to: connection)
            return
        }
        guard let asset = WebRemoteAssets.asset(for: request.path) else {
            sendHTTPError(404, reason: "Not Found", to: connection)
            return
        }
        let cacheKey = "\(asset.resource).\(asset.fileExtension)"
        let body: Data
        if let cached = assetCache[cacheKey] {
            body = cached
        } else {
            guard let url = Bundle.main.url(
                forResource: asset.resource,
                withExtension: asset.fileExtension
            ), let loaded = try? Data(contentsOf: url) else {
                sendHTTPError(500, reason: "Internal Server Error", to: connection)
                return
            }
            assetCache[cacheKey] = loaded
            body = loaded
        }

        let response = WebRemoteHTTPResponse.make(
            status: 200,
            reason: "OK",
            contentType: asset.contentType,
            cacheControl: asset.cacheControl,
            body: body,
            includeBody: request.method == .get
        )
        sendHTTP(response, to: connection)
    }

    private func sendHTTPError(_ status: Int, reason: String, to connection: NWConnection) {
        let body = Data("\(status) \(reason)\n".utf8)
        let response = WebRemoteHTTPResponse.make(
            status: status,
            reason: reason,
            contentType: "text/plain; charset=utf-8",
            body: body
        )
        sendHTTP(response, to: connection)
    }

    private func sendHTTP(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleWebSocketConnection(_ connection: NWConnection) {
        let id = UUID()
        let client = WebRemoteClientConnection(id: id, connection: connection, server: self)
        clients[id] = client
        client.start(on: queue)
    }

    fileprivate func removeClient(_ id: UUID) {
        queue.async { [weak self] in
            self?.removeClientLocked(id, cancelConnection: false)
        }
    }

    private func dropSlowClientLocked(_ id: UUID) {
        dropClientLocked(id, reason: "send queue overflow; will reconnect and resnapshot")
    }

    private func removeClientLocked(_ id: UUID, cancelConnection: Bool) {
        guard let client = clients.removeValue(forKey: id) else { return }
        let affectedPanes = Set([client.subscribedPane, client.pendingPane].compactMap { $0 })
        if cancelConnection { client.cancel() }
        updateSubscribedPanesLocked()
        affectedPanes.forEach { reconcileTerminalSizeLocked(for: $0) }
    }

    /// Entry point from the receive loop. Pre-encryption, the only plaintext a
    /// client may send is the `authenticate` proof — pass it straight through.
    /// Once encrypted, every inbound frame is `nonce(12) || ciphertext || tag`
    /// and is decrypted here before JSON parsing. A truncated frame, a replayed
    /// (regressed) nonce, or an auth-tag mismatch drops the connection.
    fileprivate func handleWebSocketFrame(_ content: Data, from clientID: UUID) {
        guard let client = clients[clientID] else { return }
        guard content.count <= 1_048_576 else {
            dropClientLocked(clientID, reason: "oversized frame")
            return
        }
        guard client.encrypted,
              let c2sKey = client.c2sKey,
              content.count > WebRemoteCrypto.nonceLength + WebRemoteCrypto.tagLength
        else {
            handleWebSocketData(content, from: clientID)
            return
        }
        let nonce = content.prefix(WebRemoteCrypto.nonceLength)
        let body = content.subdata(in: WebRemoteCrypto.nonceLength ..< content.count)
        guard let counter = WebRemoteCrypto.counter(fromNonce: nonce),
              counter >= client.receiveCounter,
              let plaintext = WebRemoteCrypto.openFrame(nonce: nonce, body: body, key: c2sKey)
        else {
            dropClientLocked(clientID, reason: "decrypt/replay failure")
            return
        }
        client.receiveCounter = counter + 1
        handleWebSocketData(plaintext, from: clientID)
    }

    fileprivate func handleWebSocketData(_ data: Data, from clientID: UUID) {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let client = clients[clientID]
        else {
            sendError("bad-request", to: clientID)
            return
        }

        if type == "authenticate" {
            // Challenge-response: the client proves it knows the token with an
            // HMAC over the per-connection challenge, without ever sending the
            // token. A previous failure is still inside its backoff window;
            // ignore the new attempt — `completeAuthFailure` answers it. This
            // caps a flooding attacker at one pending timer per client.
            guard !client.authBackoffPending else { return }
            guard let proofString = object["proof"] as? String,
                  let provided = Data(base64Encoded: proofString),
                  let challenge = client.pendingChallenge,
                  !tokenKey.isEmpty
            else {
                failAuthenticationLocked(for: clientID)
                return
            }
            let expected = WebRemoteCrypto.proof(tokenKey: tokenKey, challenge: challenge)
            guard WebRemoteCrypto.constantTimeEquals(provided, expected) else {
                failAuthenticationLocked(for: clientID)
                return
            }
            client.authFailureCount = 0
            let keys = WebRemoteCrypto.sessionKeys(tokenKey: tokenKey, challenge: challenge)
            client.beginEncryption(c2s: keys.c2s, s2c: keys.s2c)
            client.pendingChallenge = nil
            client.authenticated = true
            // The first frame sent after here is encrypted; the client learns
            // auth succeeded by successfully decrypting it.
            sendJSON(["type": "authenticated"], to: clientID)
            sendState(to: clientID)
            return
        }

        guard client.authenticated else {
            sendError("unauthorized", to: clientID)
            return
        }

        switch type {
        case "list":
            sendState(to: clientID)
        case "select":
            guard let pane = object["pane"] as? String,
                  pane.count <= 128,
                  let size = WebRemoteTerminalSize.parse(object)
            else {
                sendError("bad-request", to: clientID)
                return
            }
            selectPane(pane, size: size, for: clientID)
        case "resize":
            guard let pane = object["pane"] as? String,
                  pane == client.subscribedPane,
                  let size = WebRemoteTerminalSize.parse(object)
            else {
                sendError("bad-request", to: clientID)
                return
            }
            resizePane(pane, size: size, for: clientID)
        case "input":
            guard let pane = object["pane"] as? String,
                  pane == client.subscribedPane,
                  let encoded = object["data"] as? String,
                  let bytes = Data(base64Encoded: encoded),
                  !bytes.isEmpty,
                  bytes.count <= 65_536
            else {
                sendError("bad-request", to: clientID)
                return
            }
            sendInput(bytes, pane: pane, clientID: clientID)
        case "createProject":
            guard let path = object["path"] as? String, !path.isEmpty, path.count <= 4096 else {
                sendError("bad-request", to: clientID)
                return
            }
            createProject(path: path, clientID: clientID)
        case "createTerminal":
            guard let value = object["workspace"] as? String,
                  value.count <= 36,
                  let workspaceID = UUID(uuidString: value)
            else {
                sendError("bad-request", to: clientID)
                return
            }
            createTerminal(workspace: workspaceID, clientID: clientID)
        case "closeTerminal":
            guard let pane = object["pane"] as? String, pane.count <= 128 else {
                sendError("bad-request", to: clientID)
                return
            }
            closeTerminal(
                pane: pane,
                confirmed: object["confirmed"] as? Bool ?? false,
                clientID: clientID
            )
        default:
            sendError("unknown-command", to: clientID)
        }
    }

    private func sendState(to clientID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            var message: [String: Any] = [
                "type": "state",
                "workspaces": store.webRemoteWorkspacePayload(),
                "theme": store.webRemoteThemePayload(),
            ]
            if let brand = store.webRemoteBrandPayload() {
                message["brand"] = brand
            }
            if let selected = store.selectedWorkspaceID {
                message["selectedWorkspace"] = selected.uuidString
            }
            self.queue.async { [weak self] in
                self?.sendJSON(message, to: clientID)
            }
        }
    }

    private func selectPane(
        _ pane: String,
        size: WebRemoteTerminalSize,
        for clientID: UUID
    ) {
        guard let client = clients[clientID], client.pendingPane == nil else {
            sendError("selection-in-progress", to: clientID)
            return
        }

        let previousPane = client.subscribedPane
        client.subscribedPane = nil
        client.pendingPane = pane
        client.pendingSelectionOutput = WebRemoteOutputBuffer(
            byteLimit: Self.maxSelectionOutputBytes
        )
        client.terminalSize = nil
        updateSubscribedPanesLocked()
        if let previousPane {
            reconcileTerminalSizeLocked(for: previousPane)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            if let error = store.controlFocus(pane: pane, activateApp: false) {
                self.queue.async { [weak self] in
                    self?.finishSelectionFailure(error, pane: pane, clientID: clientID)
                }
                return
            }
            let result = store.webRemoteTerminalSnapshot(pane: pane)
            self.queue.async { [weak self, weak store] in
                guard let self,
                      let store,
                      let client = clients[clientID],
                      client.authenticated,
                      client.pendingPane == pane
                else { return }
                switch result {
                case let .success(snapshot):
                    let bufferedOutput = client.pendingSelectionOutput.take(
                        after: snapshot.outputSequence
                    )
                    client.pendingPane = nil
                    client.subscribedPane = pane
                    recordTerminalSizeLocked(size, for: client)
                    updateSubscribedPanesLocked()
                    sendJSON([
                        "type": "snapshot",
                        "pane": pane,
                        "data": snapshot.payload.base64EncodedString(),
                    ], to: clientID)
                    if !bufferedOutput.isEmpty,
                       !client.sendTerminalOutput(bufferedOutput, pane: pane) {
                        dropSlowClientLocked(clientID)
                        return
                    }
                    DispatchQueue.main.async { [weak self, weak store] in
                        guard let self, let store else { return }
                        if let error = store.webRemoteSetTerminalSize(pane: pane, size: size) {
                            self.queue.async { [weak self] in self?.sendError(error, to: clientID) }
                        }
                    }
                case let .failure(error):
                    finishSelectionFailure(error, pane: pane, clientID: clientID)
                }
            }
        }
    }

    private func finishSelectionFailure(_ error: String, pane: String, clientID: UUID) {
        guard let client = clients[clientID], client.pendingPane == pane else { return }
        _ = client.pendingSelectionOutput.take()
        client.pendingPane = nil
        updateSubscribedPanesLocked()
        reconcileTerminalSizeLocked(for: pane)
        sendError(error, to: clientID)
    }

    private func resizePane(
        _ pane: String,
        size: WebRemoteTerminalSize,
        for clientID: UUID
    ) {
        guard let client = clients[clientID] else { return }
        recordTerminalSizeLocked(size, for: client)
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            if let error = store.webRemoteSetTerminalSize(pane: pane, size: size) {
                self.queue.async { [weak self] in self?.sendError(error, to: clientID) }
            }
        }
    }

    private func sendInput(_ data: Data, pane: String, clientID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            if let error = store.webRemoteSendInput(pane: pane, data: data) {
                self.queue.async { [weak self] in self?.sendError(error, to: clientID) }
            }
        }
    }

    private func createProject(path: String, clientID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            switch store.webRemoteOpenProject(path: path) {
            case let .success(workspaceID):
                self.queue.async { [weak self] in
                    self?.sendJSON([
                        "type": "projectCreated",
                        "workspace": workspaceID.uuidString,
                    ], to: clientID)
                    self?.sendState(to: clientID)
                }
            case let .failure(error):
                self.queue.async { [weak self] in self?.sendError(error, to: clientID) }
            }
        }
    }

    private func createTerminal(workspace workspaceID: UUID, clientID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            switch store.webRemoteCreateTerminal(workspace: workspaceID) {
            case let .success(pane):
                self.queue.async { [weak self] in
                    self?.sendJSON([
                        "type": "terminalCreated",
                        "pane": pane,
                    ], to: clientID)
                    self?.sendState(to: clientID)
                }
            case let .failure(error):
                self.queue.async { [weak self] in self?.sendError(error, to: clientID) }
            }
        }
    }

    private func closeTerminal(pane: String, confirmed: Bool, clientID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            switch store.webRemoteCloseTerminal(pane: pane, confirmed: confirmed) {
            case .success:
                self.queue.async { [weak self] in
                    self?.finishTerminalCloseLocked(pane: pane)
                }
            case .confirmationRequired:
                self.queue.async { [weak self] in
                    self?.sendJSON([
                        "type": "terminalCloseConfirmation",
                        "pane": pane,
                    ], to: clientID)
                }
            case let .failure(error):
                self.queue.async { [weak self] in self?.sendError(error, to: clientID) }
            }
        }
    }

    private func finishTerminalCloseLocked(pane: String) {
        let authenticatedClients = clients.values.filter(\.authenticated)
        for client in authenticatedClients {
            if client.subscribedPane == pane {
                client.subscribedPane = nil
                client.terminalSize = nil
            }
            if client.pendingPane == pane {
                client.pendingPane = nil
                _ = client.pendingSelectionOutput.take()
            }
        }
        updateSubscribedPanesLocked()
        for client in authenticatedClients {
            sendJSON([
                "type": "terminalClosed",
                "pane": pane,
            ], to: client.id)
            sendState(to: client.id)
        }
    }

    private func sendJSON(_ object: [String: Any], to clientID: UUID) {
        guard let data = SafeJSON.data(object) else { return }
        clients[clientID]?.send(data)
    }

    private func sendError(_ code: String, to clientID: UUID) {
        sendJSON([
            "type": "error",
            "code": code,
        ], to: clientID)
    }

    private func completeAuthFailure(for clientID: UUID) {
        guard let client = clients[clientID] else { return }
        client.authBackoffPending = false
        // Connection is still pre-encryption during the handshake, so the
        // error travels as a plaintext frame.
        sendError("unauthorized", to: clientID)
    }

    /// A failed/missing proof schedules an exponentially-backed-off
    /// `unauthorized`, throttling online guessing of the access key.
    private func failAuthenticationLocked(for clientID: UUID) {
        guard let client = clients[clientID] else { return }
        client.authFailureCount = min(client.authFailureCount + 1, Self.authFailureCountCap)
        client.authBackoffPending = true
        let delay = Self.authBackoffSeconds(forFailures: client.authFailureCount)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.completeAuthFailure(for: clientID)
        }
    }

    private func dropClientLocked(_ id: UUID, reason: String) {
        webRemoteLogger.warning("Dropping WebSocket client: \(reason, privacy: .public)")
        removeClientLocked(id, cancelConnection: true)
    }

    private func updateSubscribedPanesLocked() {
        let panes = Set(clients.values.flatMap { client -> [String] in
            guard client.authenticated else { return [] }
            return [client.subscribedPane, client.pendingPane].compactMap { $0 }
        })
        subscriptionLock.lock()
        subscribedPanes = panes
        pendingTerminalOutput = pendingTerminalOutput.filter { panes.contains($0.key) }
        overflowedTerminalOutput.formIntersection(panes)
        subscriptionLock.unlock()
    }

    private func controlledPanesLocked() -> Set<String> {
        Set(clients.values.flatMap { client in
            [client.subscribedPane, client.pendingPane].compactMap { $0 }
        })
    }

    private func recordTerminalSizeLocked(
        _ size: WebRemoteTerminalSize,
        for client: WebRemoteClientConnection
    ) {
        terminalSizeRevision &+= 1
        client.terminalSize = size
        client.terminalSizeRevision = terminalSizeRevision
    }

    private func reconcileTerminalSizeLocked(for pane: String) {
        let size = clients.values
            .filter { $0.authenticated && $0.subscribedPane == pane && $0.terminalSize != nil }
            .max { $0.terminalSizeRevision < $1.terminalSizeRevision }?
            .terminalSize
        DispatchQueue.main.async {
            guard let store = WorkspaceStore.current else { return }
            if let size {
                _ = store.webRemoteSetTerminalSize(pane: pane, size: size)
            } else {
                store.webRemoteReleaseTerminalSize(pane: pane)
            }
        }
    }

    private func releaseTerminalSizes(_ panes: Set<String>) {
        guard !panes.isEmpty else { return }
        DispatchQueue.main.async {
            guard let store = WorkspaceStore.current else { return }
            panes.forEach { store.webRemoteReleaseTerminalSize(pane: $0) }
        }
    }
}

private final class WebRemoteClientConnection: @unchecked Sendable {
    let id: UUID
    var authenticated = false
    var subscribedPane: String?
    var pendingPane: String?
    var pendingSelectionOutput = WebRemoteOutputBuffer(byteLimit: 0)
    var terminalSize: WebRemoteTerminalSize?
    var terminalSizeRevision: UInt64 = 0
    var authFailureCount = 0
    var authBackoffPending = false

    /// Challenge-response + encryption state. `pendingChallenge` is set when the
    /// connection comes up; once the proof verifies, `encrypted` flips true and
    /// `c2s`/`s2c` carry the per-direction AES-256-GCM keys. Counters are
    /// per-direction and never reused under their key.
    var pendingChallenge: Data?
    var encrypted = false
    var c2sKey: SymmetricKey?
    var s2cKey: SymmetricKey?
    var sendCounter: UInt64 = 0
    var receiveCounter: UInt64 = 0

    private static let maxQueuedOutputBytes = 512 * 1024
    private let connection: NWConnection
    private weak var server: WebRemoteServer?
    private var outbound = WebRemoteOutboundBuffer(
        maxQueuedOutputBytes: WebRemoteClientConnection.maxQueuedOutputBytes
    )
    private var sendInFlight = false
    private var cancelled = false

    init(id: UUID, connection: NWConnection, server: WebRemoteServer) {
        self.id = id
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Issue the per-connection challenge before reading anything.
                // Sent as a plaintext text frame (we are still pre-encryption).
                pendingChallenge = WebRemoteCrypto.newChallenge()
                if let challenge = pendingChallenge,
                   let payload = SafeJSON.data([
                       "type": "auth-challenge",
                       "challenge": challenge.base64EncodedString(),
                   ]) {
                    send(payload)
                }
                receiveNextMessage()
            case .failed,
                 .cancelled:
                server?.removeClient(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        outbound.removeAll()
        _ = pendingSelectionOutput.take()
        connection.cancel()
    }

    /// Activate encryption after the proof verifies. Counters start at 0 for
    /// both directions; the first encrypted frame is `authenticated`.
    func beginEncryption(c2s: SymmetricKey, s2c: SymmetricKey) {
        c2sKey = c2s
        s2cKey = s2c
        sendCounter = 0
        receiveCounter = 0
        encrypted = true
    }

    func send(_ data: Data) {
        guard !cancelled else { return }
        outbound.enqueueMessage(data)
        sendNextIfNeeded()
    }

    func sendTerminalOutput(_ data: Data, pane: String) -> Bool {
        guard !cancelled,
              outbound.enqueueTerminalOutput(data, pane: pane)
        else { return false }
        sendNextIfNeeded()
        return true
    }

    private func sendNextIfNeeded() {
        guard !cancelled, !sendInFlight, let item = outbound.next() else { return }
        let data: Data?
        switch item {
        case let .message(message):
            data = message
        case let .terminalOutput(pane, output):
            data = SafeJSON.data([
                "type": "output",
                "pane": pane,
                "data": output.base64EncodedString(),
            ])
        }
        guard let data else {
            sendNextIfNeeded()
            return
        }

        // Once encrypted, wrap the JSON plaintext as a binary GCM frame and
        // send it as a binary WS message. The counter is consumed only here, at
        // actual send time — items are never re-sent (a failed send cancels the
        // connection), so nonces are never reused.
        var wireData = data
        var opcode = NWProtocolWebSocket.Opcode.text
        if encrypted, let s2c = s2cKey {
            guard let frame = WebRemoteCrypto.sealFrame(
                plaintext: data,
                key: s2c,
                counter: sendCounter
            ) else {
                cancel()
                return
            }
            sendCounter &+= 1
            wireData = frame
            opcode = .binary
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: "glint-web-remote",
            metadata: [metadata]
        )
        sendInFlight = true
        connection.send(
            content: wireData,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.sendInFlight = false
                if let error {
                    webRemoteLogger.error("WebSocket send failed: \(error.localizedDescription, privacy: .public)")
                    self.cancel()
                } else {
                    self.sendNextIfNeeded()
                }
            }
        )
    }

    private func receiveNextMessage() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                server?.removeClient(id)
                return
            }
            guard let content, !content.isEmpty else {
                receiveNextMessage()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard let metadata, metadata.opcode == .text || metadata.opcode == .binary else {
                receiveNextMessage()
                return
            }
            server?.handleWebSocketFrame(content, from: id)
            receiveNextMessage()
        }
    }
}
