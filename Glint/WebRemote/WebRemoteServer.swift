import Foundation
import Network
import os

private let webRemoteLogger = Logger(subsystem: "app.glint", category: "WebRemote")

enum WebRemoteStatus: Equatable {
    case stopped
    case starting
    case ready(urls: [String])
    case failed(message: String)
}

struct WebRemoteOutputBuffer {
    let byteLimit: Int
    private(set) var data = Data()

    var isEmpty: Bool { data.isEmpty }

    init(byteLimit: Int) {
        precondition(byteLimit >= 0)
        self.byteLimit = byteLimit
    }

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= byteLimit - data.count else { return false }
        data.append(chunk)
        return true
    }

    mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count <= byteLimit - data.count else { return false }
        data.append(bytes, count: count)
        return true
    }

    mutating func take() -> Data {
        let result = data
        data = Data()
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
    static let httpPort: UInt16 = 43871
    static let webSocketPort: UInt16 = 43872

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

    func resetAccessKey() {
        queue.async { [weak self] in
            self?.resetAccessKeyLocked()
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

    func refreshTheme() {
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
        count: UInt
    ) {
        guard let bytes, count > 0, let byteCount = Int(exactly: count) else { return }
        var shouldScheduleDrain = false
        subscriptionLock.lock()
        let interested = subscribedPanes.contains(pane)
        if interested {
            if !overflowedTerminalOutput.contains(pane) {
                var buffer = pendingTerminalOutput[pane]
                    ?? WebRemoteOutputBuffer(byteLimit: Self.maxIngressOutputBytes)
                if buffer.append(bytes, count: byteCount) {
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
        let batches = pendingTerminalOutput.mapValues { $0.data }
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
        for (pane, data) in batches {
            for client in clients.values where client.authenticated {
                if client.pendingPane == pane {
                    if !client.pendingSelectionOutput.append(data) {
                        slowClientIDs.insert(client.id)
                    }
                } else if client.subscribedPane == pane,
                          !client.sendTerminalOutput(data, pane: pane) {
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
            guard let httpPort = NWEndpoint.Port(rawValue: Self.httpPort),
                  let webSocketPort = NWEndpoint.Port(rawValue: Self.webSocketPort)
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
                    webRemoteLogger.info("Web remote listening on ports \(Self.httpPort) and \(Self.webSocketPort)")
                    self.emit(.ready(urls: self.accessURLsLocked()))
                }
            case let .failed(error):
                self.failLocked(error.localizedDescription)
            default:
                break
            }
        }
    }

    private func resetAccessKeyLocked() {
        let controlledPanes = controlledPanesLocked()
        token = WebRemoteAccessKeyStore.reset()
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        updateSubscribedPanesLocked()
        releaseTerminalSizes(controlledPanes)
        if runID != nil, readyListeners.count == 2 {
            emit(.ready(urls: accessURLsLocked()))
        }
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
        return hosts.map { "http://\($0):\(Self.httpPort)/#token=\(token)" }
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
        pathMonitor?.cancel()
        pathMonitor = nil
        pathRestartScheduled = false
        lastBoundAddress = nil
        updateSubscribedPanesLocked()
        releaseTerminalSizes(controlledPanes)
        webRemoteLogger.error("Web remote failed: \(message, privacy: .public)")
        emit(.failed(message: message))
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
        webRemoteLogger.warning("Dropping slow WebSocket client; it will reconnect and resnapshot")
        removeClientLocked(id, cancelConnection: true)
    }

    private func removeClientLocked(_ id: UUID, cancelConnection: Bool) {
        guard let client = clients.removeValue(forKey: id) else { return }
        let affectedPanes = Set([client.subscribedPane, client.pendingPane].compactMap { $0 })
        if cancelConnection { client.cancel() }
        updateSubscribedPanesLocked()
        affectedPanes.forEach { reconcileTerminalSizeLocked(for: $0) }
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
            // A previous failure is still inside its backoff window; ignore the
            // new attempt — the scheduled `completeAuthFailure` will answer it.
            // This caps a flooding attacker at one pending timer per client.
            guard !client.authBackoffPending else { return }
            if WebRemoteAccessToken.matches(object["token"] as? String, expected: token) {
                client.authFailureCount = 0
                client.authenticated = true
                sendJSON(["type": "authenticated"], to: clientID)
                sendState(to: clientID)
                return
            }
            client.authFailureCount = min(client.authFailureCount + 1, Self.authFailureCountCap)
            client.authBackoffPending = true
            let delay = Self.authBackoffSeconds(forFailures: client.authFailureCount)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.completeAuthFailure(for: clientID)
            }
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
                    let bufferedOutput = client.pendingSelectionOutput.take()
                    client.pendingPane = nil
                    client.subscribedPane = pane
                    recordTerminalSizeLocked(size, for: client)
                    updateSubscribedPanesLocked()
                    sendJSON([
                        "type": "snapshot",
                        "pane": pane,
                        "data": snapshot.base64EncodedString(),
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
        sendError("unauthorized", to: clientID)
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

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "glint-web-remote",
            metadata: [metadata]
        )
        sendInFlight = true
        connection.send(
            content: data,
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
            server?.handleWebSocketData(content, from: id)
            receiveNextMessage()
        }
    }
}
