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

final class WebRemoteServer: @unchecked Sendable {
    static let shared = WebRemoteServer()
    static let httpPort: UInt16 = 43871
    static let webSocketPort: UInt16 = 43872

    private enum ListenerKind: Hashable {
        case http
        case webSocket
    }

    private let queue = DispatchQueue(label: "app.glint.web-remote", qos: .utility)
    private let subscriptionLock = NSLock()
    private var subscribedPanes = Set<String>()
    private var httpListener: NWListener?
    private var webSocketListener: NWListener?
    private var clients: [UUID: WebRemoteClientConnection] = [:]
    private var readyListeners = Set<ListenerKind>()
    private var runID: UUID?
    private var token = ""
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

    func forwardTerminalOutput(
        pane: String,
        bytes: UnsafePointer<UInt8>?,
        count: UInt
    ) {
        guard let bytes, count > 0 else { return }
        subscriptionLock.lock()
        let interested = subscribedPanes.contains(pane)
        subscriptionLock.unlock()
        guard interested else { return }

        let data = Data(bytes: bytes, count: Int(count))
        queue.async { [weak self] in
            guard let self else { return }
            let recipients = clients.values.filter {
                $0.authenticated && $0.subscribedPane == pane
            }
            guard !recipients.isEmpty,
                  let payload = SafeJSON.data([
                    "type": "output",
                    "pane": pane,
                    "data": data.base64EncodedString(),
                  ])
            else { return }
            recipients.forEach { $0.send(payload) }
        }
    }

    private func startLocked() {
        stopLocked(emitStatus: false)
        emit(.starting)
        token = WebRemoteAccessKeyStore.loadOrCreate()
        let currentRun = UUID()
        runID = currentRun

        do {
            let httpParameters = NWParameters.tcp
            httpParameters.allowLocalEndpointReuse = true
            guard let httpPort = NWEndpoint.Port(rawValue: Self.httpPort),
                  let webSocketPort = NWEndpoint.Port(rawValue: Self.webSocketPort)
            else {
                failLocked("Invalid web remote port.")
                return
            }

            let http = try NWListener(using: httpParameters, on: httpPort)
            http.service = NWListener.Service(name: "Glint Remote", type: "_http._tcp")

            let webSocketParameters = NWParameters.tcp
            webSocketParameters.allowLocalEndpointReuse = true
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
        } catch {
            failLocked(error.localizedDescription)
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
        let addresses = WebRemoteAddressResolver.localIPv4Addresses()
        let hosts = addresses.isEmpty ? ["127.0.0.1"] : addresses
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
            guard let self else { return }
            guard let client = clients.removeValue(forKey: id) else { return }
            updateSubscribedPanesLocked()
            releaseTerminalSizes(Set([client.subscribedPane, client.pendingPane].compactMap { $0 }))
        }
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
            guard WebRemoteAccessToken.matches(object["token"] as? String, expected: token) else {
                sendError("unauthorized", to: clientID)
                return
            }
            client.authenticated = true
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
        let paneIsInUse = clients.contains { id, candidate in
            id != clientID && (candidate.subscribedPane == pane || candidate.pendingPane == pane)
        }
        guard !paneIsInUse else {
            sendError("pane-in-use", to: clientID)
            return
        }

        let previousPane = client.subscribedPane
        client.subscribedPane = nil
        client.pendingPane = pane
        updateSubscribedPanesLocked()

        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            if let previousPane {
                store.webRemoteReleaseTerminalSize(pane: previousPane)
            }
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
                    client.pendingPane = nil
                    client.subscribedPane = pane
                    updateSubscribedPanesLocked()
                    sendJSON([
                        "type": "snapshot",
                        "pane": pane,
                        "data": snapshot.base64EncodedString(),
                    ], to: clientID)
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
        client.pendingPane = nil
        updateSubscribedPanesLocked()
        releaseTerminalSizes([pane])
        sendError(error, to: clientID)
    }

    private func resizePane(
        _ pane: String,
        size: WebRemoteTerminalSize,
        for clientID: UUID
    ) {
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

    private func updateSubscribedPanesLocked() {
        let panes = Set(clients.values.compactMap { client in
            client.authenticated ? client.subscribedPane : nil
        })
        subscriptionLock.lock()
        subscribedPanes = panes
        subscriptionLock.unlock()
    }

    private func controlledPanesLocked() -> Set<String> {
        Set(clients.values.flatMap { client in
            [client.subscribedPane, client.pendingPane].compactMap { $0 }
        })
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

    private let connection: NWConnection
    private weak var server: WebRemoteServer?

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
        connection.cancel()
    }

    func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "glint-web-remote",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    webRemoteLogger.error("WebSocket send failed: \(error.localizedDescription, privacy: .public)")
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
