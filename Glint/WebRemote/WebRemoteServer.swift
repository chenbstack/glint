import CryptoKit
import Foundation
import Network
import os

private let webRemoteLogger = Logger(subsystem: "app.glint", category: "WebRemote")

enum WebRemoteStatus: Equatable {
    case stopped
    case starting
    case waitingForInterface(name: String)
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
    let maxQueuedBytes: Int
    let maxQueuedItems: Int
    private var items: [Item] = []
    private var queuedOutputBytes = 0
    private var queuedBytes = 0
    private var queuedMessageBytes = 0
    private struct RejectionNotice {
        let data: Data
        var itemsAhead: Int
        let coalesced: Bool
        let streamBoundaryPane: String?
        let snapshot: Bool
    }
    private var rejectionNotices: [RejectionNotice] = []
    private var rejectionBytes = 0
    private var hasBusyNotice = false

    /// Ordinary responses leave the terminal stream's byte allowance available.
    private var maxQueuedMessageBytes: Int { max(0, maxQueuedBytes - maxQueuedOutputBytes) }

    /// Set stream, total-byte and item budgets; returns an empty response queue.
    /// The total allows a 5 MiB image after base64/JSON encoding and snapshots.
    init(maxQueuedOutputBytes: Int, maxQueuedBytes: Int = 16 * 1024 * 1024,
         maxQueuedItems: Int = 256) {
        precondition(maxQueuedOutputBytes >= 0)
        precondition(maxQueuedBytes >= 0 && maxQueuedItems > 0)
        self.maxQueuedOutputBytes = maxQueuedOutputBytes
        self.maxQueuedBytes = maxQueuedBytes
        self.maxQueuedItems = maxQueuedItems
    }

    /// Queue a JSON response; data is its encoded body; returns false at capacity.
    @discardableResult
    mutating func enqueueMessage(_ data: Data) -> Bool {
        // An existing output item may precede messages, so it cannot absorb the
        // next bytes. Always leave a slot for that next terminal segment.
        let messageItemLimit = maxQueuedItems - 1
        guard data.count <= maxQueuedMessageBytes - queuedMessageBytes,
              data.count <= maxQueuedBytes - queuedBytes,
              items.count < messageItemLimit else { return false }
        items.append(.message(data))
        queuedBytes += data.count
        queuedMessageBytes += data.count
        return true
    }

    /// Record a rejected response without retaining its body; data identifies
    /// the original request. Returns nothing. Ordinary notices use 64 KiB/32
    /// slots, plus one coalesced busy and one latest control notice (under 2 KiB).
    mutating func rejectMessage(_ data: Data) {
        let tooLarge = data.count > maxQueuedMessageBytes
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if object?["type"] as? String == "snapshot" {
            // Only the latest pending pane selection can establish control.
            // Reserve one small control notice so a file-error flood cannot
            // turn its rejection into an unrelated file-pressure notification.
            let pane = String(decoding: (object?["pane"] as? String ?? "").utf8.prefix(256), as: UTF8.self)
            let control: [String: String] = [
                "type": "error", "pane": pane,
                "code": tooLarge ? "response-too-large" : "snapshot-busy",
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: control) else { return }
            rejectionBytes -= rejectionNotices.filter(\.snapshot).reduce(0) { $0 + $1.data.count }
            rejectionNotices.removeAll { $0.snapshot }
            rejectionNotices.append(RejectionNotice(data: encoded, itemsAhead: items.count,
                                                   coalesced: false, streamBoundaryPane: pane, snapshot: true))
            rejectionBytes += encoded.count
            return
        }
        let fileResponse = ["fileList", "fileContent", "fileImage", "fileError"]
            .contains(object?["type"] as? String ?? "")
        var notice: [String: Any] = [
            "type": fileResponse ? "fileError" : "error",
            "code": tooLarge ? "response-too-large" : (fileResponse ? "file-busy" : "send-queue-busy"),
        ]
        for key in fileResponse ? ["workspace", "pane", "path", "root", "request"] : ["pane"] {
            if let value = object?[key] as? String { notice[key] = value }
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: notice),
              encoded.count <= 64 * 1024 - rejectionBytes,
              rejectionNotices.count < 32 else {
            if !hasBusyNotice {
                let busy = Data(#"{"type":"error","code":"send-queue-busy"}"#.utf8)
                rejectionNotices.append(RejectionNotice(data: busy, itemsAhead: items.count,
                                                       coalesced: true, streamBoundaryPane: nil, snapshot: false))
                rejectionBytes += busy.count
                hasBusyNotice = true
            }
            return
        }
        rejectionNotices.append(RejectionNotice(data: encoded, itemsAhead: items.count,
                                               coalesced: false, streamBoundaryPane: nil, snapshot: false))
        rejectionBytes += encoded.count
    }

    /// Queue terminal bytes for a pane; returns false when either budget is full.
    mutating func enqueueTerminalOutput(_ data: Data, pane: String) -> Bool {
        guard data.count <= maxQueuedOutputBytes - queuedOutputBytes,
              data.count <= maxQueuedBytes - queuedBytes else { return false }
        // File errors do not revoke terminal control and can share its existing
        // segment. A rejected snapshot is a control boundary for that pane.
        let crossesSnapshotBoundary = rejectionNotices.contains {
            $0.itemsAhead == items.count && $0.streamBoundaryPane == pane
        }
        if !crossesSnapshotBoundary, let last = items.last,
           case let .terminalOutput(existingPane, existingData) = last,
           existingPane == pane {
            var combined = existingData
            combined.append(data)
            items[items.index(before: items.endIndex)] = .terminalOutput(
                pane: pane,
                data: combined
            )
        } else {
            guard items.count < maxQueuedItems else { return false }
            items.append(.terminalOutput(pane: pane, data: data))
        }
        queuedOutputBytes += data.count
        queuedBytes += data.count
        return true
    }

    /// Remove the next response and release its budget; no parameters; returns nil if empty.
    mutating func next() -> Item? {
        // A later error must not overtake an older snapshot for the same pane:
        // the browser could otherwise restore control from that stale snapshot.
        if rejectionNotices.first?.itemsAhead == 0 {
            let notice = rejectionNotices.removeFirst()
            rejectionBytes -= notice.data.count
            if notice.coalesced { hasBusyNotice = false }
            return .message(notice.data)
        }
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        for index in rejectionNotices.indices where rejectionNotices[index].itemsAhead > 0 {
            rejectionNotices[index].itemsAhead -= 1
        }
        switch item {
        case let .terminalOutput(_, data):
            queuedOutputBytes -= data.count
            queuedBytes -= data.count
        case let .message(data):
            queuedBytes -= data.count
            queuedMessageBytes -= data.count
        }
        return item
    }

    /// Clear queued responses and all accounting; no parameters or return value.
    mutating func removeAll() {
        items.removeAll()
        queuedOutputBytes = 0
        queuedBytes = 0
        queuedMessageBytes = 0
        rejectionNotices.removeAll()
        rejectionBytes = 0
        hasBusyNotice = false
    }
}

struct WebRemoteAuthThrottle {
    private struct Failure {
        var count: Int
        var lastFailure: TimeInterval
    }

    private let countCap: Int
    private let expirySeconds: TimeInterval
    private var failuresBySource: [String: Failure] = [:]

    init(countCap: Int = 7, expirySeconds: TimeInterval) {
        precondition(countCap > 0)
        precondition(expirySeconds > 0)
        self.countCap = countCap
        self.expirySeconds = expirySeconds
    }

    mutating func recordFailure(
        for source: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Int {
        failuresBySource = failuresBySource.filter {
            now >= $0.value.lastFailure
                && now - $0.value.lastFailure < expirySeconds
        }
        let count = min((failuresBySource[source]?.count ?? 0) + 1, countCap)
        failuresBySource[source] = Failure(count: count, lastFailure: now)
        return count
    }

    mutating func removeAll() {
        failuresBySource.removeAll()
    }
}

final class WebRemoteServer: @unchecked Sendable {
    static let shared = WebRemoteServer()

    static let maxClientConnections = 32
    static let maxUnauthenticatedConnections = 8
    static let maxHTTPConnections = 32
    private static let maxIngressOutputBytes = 256 * 1024
    private static let maxSelectionOutputBytes = 512 * 1024
    private static let authFailureCountCap = 7
    private static let authFailureExpirySeconds: TimeInterval = 60
    private static let authenticationTimeoutSeconds: TimeInterval = 30

    /// Delay before answering a failed `authenticate`, growing exponentially
    /// with the source-address failure count to throttle reconnect-based guessing.
    /// 0.25s → 0.5s → 1s → … → 16s (capped at the 7th failure). Honest clients
    /// almost never fail auth, so this only bites brute-forcers.
    static func authBackoffSeconds(forFailures count: Int) -> TimeInterval {
        let safe = min(max(count, 1), authFailureCountCap)
        let multiplier = pow(2.0, Double(safe - 1))
        return min(0.25 * multiplier, 16)
    }

    static func allowsNewClient(total: Int, unauthenticated: Int) -> Bool {
        total < maxClientConnections
            && unauthenticated < maxUnauthenticatedConnections
    }

    static func authSourceKey(for endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return String(describing: host)
        }
        return String(describing: endpoint)
    }

    static func panesToReconcileWhenSelecting(
        subscribedPane: String?,
        pendingPane: String?,
        nextPane: String
    ) -> Set<String>? {
        guard pendingPane != nextPane else { return nil }
        return Set([subscribedPane, pendingPane].compactMap { $0 })
    }

    static func isCurrentPaneSelection(
        pendingPane: String?,
        pendingGeneration: UInt64,
        pane: String,
        generation: UInt64
    ) -> Bool {
        pendingPane == pane && pendingGeneration == generation
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
    private var httpConnections: [ObjectIdentifier: NWConnection] = [:]
    private var httpHeadersPending = Set<ObjectIdentifier>()
    private var httpSendGenerations: [ObjectIdentifier: UUID] = [:]
    private var httpSendTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var activeFileRequests: [UUID: UUID] = [:]
    private let httpRequestTimeout: TimeInterval
    private let httpSendIdleTimeout: TimeInterval
    private var authThrottle = WebRemoteAuthThrottle(
        countCap: WebRemoteServer.authFailureCountCap,
        expirySeconds: WebRemoteServer.authFailureExpirySeconds
    )
    private var readyListeners = Set<ListenerKind>()
    private var runID: UUID?
    private var token = ""
    /// Raw 32-byte key material decoded from `token`; empty until the server
    /// starts with a valid token. Drives the challenge-response handshake.
    private var tokenKey = Data()
    private let defaults: UserDefaults
    private let resolveBindAddress: (String) -> String?
    private let interfaceRetryInterval: TimeInterval
    private var ports: WebRemotePorts
    private var listenInterface = WebRemoteListenTarget.loopback
    private var lastBoundAddress: String?
    private var pathMonitor: NWPathMonitor?
    private var pathRestartScheduled = false
    private var interfaceRetryTimer: DispatchSourceTimer?
    private var terminalSizeRevision: UInt64 = 0
    private var assetCache: [String: Data] = [:]
    private var statusHandler: ((WebRemoteStatus) -> Void)?
    private var secretStorage: WebRemoteSecretStorage = WebRemoteKeychainStorage.shared

    init(
        defaults: UserDefaults = .standard,
        interfaceRetryInterval: TimeInterval = 5,
        httpRequestTimeout: TimeInterval = 10,
        httpSendIdleTimeout: TimeInterval = 30,
        resolveBindAddress: @escaping (String) -> String? = WebRemoteListenTarget.bindAddress
    ) {
        self.defaults = defaults
        self.interfaceRetryInterval = interfaceRetryInterval
        self.httpRequestTimeout = httpRequestTimeout
        self.httpSendIdleTimeout = httpSendIdleTimeout
        self.resolveBindAddress = resolveBindAddress
        ports = WebRemotePortStore.loadOrCreate(defaults: defaults)
    }

    /// Swap the access-token backing store. Staged like `setListenInterface`:
    /// it takes effect on the next `start()`.
    ///
    /// Only the tests use this. Driving the real server against the Keychain
    /// pops a login-password prompt, because the test binary is ad-hoc signed
    /// and so is not the identity the Keychain item's ACL trusts — the run
    /// then blocks on that dialog until `start()` times out. Injecting
    /// `WebRemoteEphemeralSecretStorage` keeps the token in memory for the
    /// test process and leaves the user's Keychain untouched.
    func setSecretStorage(_ storage: WebRemoteSecretStorage) {
        queue.async { [weak self] in
            self?.secretStorage = storage
        }
    }

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

    func refreshListenAddress() {
        queue.async { [weak self] in
            guard let self, let runID = self.runID else { return }
            self.handlePathUpdate(runID: runID)
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
        token = WebRemoteAccessKeyStore.loadOrCreate(storage: secretStorage)
        tokenKey = WebRemoteCrypto.tokenKey(from: token) ?? Data()
        ports = WebRemotePortStore.loadOrCreate(defaults: defaults)
        let currentRun = UUID()
        runID = currentRun

        do {
            let isExplicitWildcard = listenInterface == WebRemoteListenTarget.any
            let bindAddress = resolveBindAddress(listenInterface)
            // A selected NIC may temporarily lose IPv4 during DHCP or wake.
            // Keep waiting for that NIC; nil must never become a wildcard bind.
            guard isExplicitWildcard || bindAddress != nil else {
                waitForInterfaceLocked()
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
                guard let self else { connection.cancel(); return }
                self.handleHTTPConnection(connection, runID: currentRun)
            }
            webSocket.newConnectionHandler = { [weak self] connection in
                self?.handleWebSocketConnection(connection)
            }
            http.start(queue: queue)
            webSocket.start(queue: queue)
            startPathMonitorLocked(currentRun)
        } catch {
            if shouldWaitForInterface(after: error) {
                waitForInterfaceLocked()
            } else {
                failLocked(error.localizedDescription)
            }
        }
    }

    private var usesNamedInterface: Bool {
        listenInterface != WebRemoteListenTarget.loopback
            && listenInterface != WebRemoteListenTarget.any
    }

    private func shouldWaitForInterface(after error: Error) -> Bool {
        guard usesNamedInterface else { return false }
        if case let .posix(code) = error as? NWError {
            if code == .EADDRINUSE { return false }
            if code == .EADDRNOTAVAIL || code == .ENETDOWN || code == .ENETUNREACH { return true }
        }
        return resolveBindAddress(listenInterface) == nil
    }

    private func waitForInterfaceLocked() {
        stopLocked(emitStatus: false)
        let currentRun = UUID()
        runID = currentRun
        // Remember this snapshot so the monitor's initial callback does not
        // repeatedly retry an address that still cannot be bound.
        lastBoundAddress = resolveBindAddress(listenInterface)
        emit(.waitingForInterface(name: listenInterface))
        startPathMonitorLocked(currentRun)

        // Path updates need not accompany every IPv4 assignment. Poll only
        // while waiting, with a modest cadence and leeway; ready/stopped
        // servers have no retry timer.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interfaceRetryInterval,
            repeating: interfaceRetryInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.runID == currentRun,
                  self.resolveBindAddress(self.listenInterface) != nil
            else { return }
            self.startLocked()
        }
        interfaceRetryTimer = timer
        timer.resume()
    }

    /// Watch for the bound NIC's IPv4 changing while the server runs (DHCP
    /// renewal, Wi-Fi switch, sleep/wake). loopback and explicit-wildcard are
    /// address-stable / address-agnostic and skip the monitor. On a real
    /// change we coalesce into a single rebind (stop+start re-resolves the
    /// current IPv4 and refreshes the access URLs). Keep watching while a NIC
    /// is unavailable so its return can recover without toggling the server.
    private func startPathMonitorLocked(_ runID: UUID) {
        pathMonitor?.cancel()
        guard usesNamedInterface else {
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
        guard runID == self.runID, usesNamedInterface, !pathRestartScheduled else { return }
        let current = resolveBindAddress(listenInterface)
        guard current != lastBoundAddress else { return }
        // NWPathMonitor can fire a burst of updates on a topology change; wait
        // for things to settle, then rebind once.
        pathRestartScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.runID == runID, self.pathRestartScheduled else { return }
            self.pathRestartScheduled = false
            // The address may already have returned during the debounce.
            // Preserve healthy listeners and their browser sessions in that case.
            guard self.resolveBindAddress(self.listenInterface) != self.lastBoundAddress else { return }
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
                } else if self.shouldWaitForInterface(after: error) {
                    self.waitForInterfaceLocked()
                } else {
                    self.failLocked(error.localizedDescription)
                }
            case let .waiting(error):
                if self.shouldWaitForInterface(after: error) {
                    self.waitForInterfaceLocked()
                }
            default:
                break
            }
        }
    }

    private func resetCredentialsLocked() {
        WebRemoteAccessKeyStore.reset(storage: secretStorage)
        WebRemotePortStore.reset(defaults: defaults)
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
            // Advertise the address actually bound, not a newer resolver
            // snapshot that the listeners have not moved to yet.
            hosts = lastBoundAddress.map { [$0] } ?? []
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
        for connection in httpConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        httpConnections.removeAll()
        httpHeadersPending.removeAll()
        httpSendTimeouts.values.forEach { $0.cancel() }
        httpSendTimeouts.removeAll()
        httpSendGenerations.removeAll()
        authThrottle.removeAll()
        readyListeners.removeAll()
        token = ""
        tokenKey = Data()
        pathMonitor?.cancel()
        pathMonitor = nil
        pathRestartScheduled = false
        interfaceRetryTimer?.cancel()
        interfaceRetryTimer = nil
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
        stopLocked(emitStatus: false)
        webRemoteLogger.error("Web remote failed: \(String(describing: status), privacy: .public)")
        emit(status)
    }

    private func emit(_ status: WebRemoteStatus) {
        guard let statusHandler else { return }
        DispatchQueue.main.async {
            statusHandler(status)
        }
    }

    /// Track a connection for this listener generation; returns nothing. The
    /// fixed deadline covers only headers; response sends have progress deadlines.
    private func handleHTTPConnection(_ connection: NWConnection, runID: UUID) {
        guard self.runID == runID, httpConnections.count < Self.maxHTTPConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        httpConnections[id] = connection
        httpHeadersPending.insert(id)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.httpConnections[id] === connection else { return }
            switch state {
            case .ready:
                self.receiveHTTPRequest(connection, buffer: Data())
            case .failed,
                 .cancelled:
                self.finishHTTPConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + httpRequestTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.httpConnections[id] === connection,
                  self.httpHeadersPending.contains(id) else { return }
            self.finishHTTPConnection(connection)
        }
    }

    /// Remove and cancel a tracked HTTP connection; no return value.
    private func finishHTTPConnection(_ connection: NWConnection) {
        httpConnections.removeValue(forKey: ObjectIdentifier(connection))
        let id = ObjectIdentifier(connection)
        httpHeadersPending.remove(id)
        httpSendTimeouts.removeValue(forKey: id)?.cancel()
        httpSendGenerations.removeValue(forKey: id)
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Receive bounded headers for a tracked connection; buffer is accumulated
    /// header data. Returns nothing and stops on completion, failure or deadline.
    private func receiveHTTPRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self, weak connection] content, _, complete, error in
            guard let self, let connection,
                  self.httpConnections[ObjectIdentifier(connection)] === connection else { return }
            if error != nil {
                self.finishHTTPConnection(connection)
                return
            }
            var next = buffer
            if let content { next.append(content) }
            if next.count > 16_384 {
                self.sendHTTPError(431, reason: "Request Header Fields Too Large", to: connection)
                return
            }
            if next.range(of: Data([13, 10, 13, 10])) != nil {
                self.httpHeadersPending.remove(ObjectIdentifier(connection))
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

    /// Send a response without a total transfer deadline; data and connection
    /// are inputs. Returns nothing; each bounded chunk must make send progress.
    private func sendHTTP(_ data: Data, to connection: NWConnection) {
        httpHeadersPending.remove(ObjectIdentifier(connection))
        sendHTTPChunk(data, offset: 0, to: connection)
    }

    /// Send the next 64 KiB response chunk; data, byte offset and connection
    /// identify the transfer. Returns nothing; stale completions cannot restart it.
    private func sendHTTPChunk(_ data: Data, offset: Int, to connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard httpConnections[id] === connection else { return }
        guard offset < data.count else { finishHTTPConnection(connection); return }
        let generation = UUID()
        httpSendGenerations[id] = generation
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.httpSendGenerations[id] == generation else { return }
            self.finishHTTPConnection(connection)
        }
        httpSendTimeouts[id]?.cancel()
        httpSendTimeouts[id] = timeout
        queue.asyncAfter(deadline: .now() + httpSendIdleTimeout, execute: timeout)
        let end = min(offset + 64 * 1024, data.count)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection, self.httpSendGenerations[id] == generation else { return }
            self.httpSendTimeouts.removeValue(forKey: id)?.cancel()
            self.httpSendGenerations.removeValue(forKey: id)
            if error != nil { self.finishHTTPConnection(connection); return }
            self.sendHTTPChunk(data, offset: end, to: connection)
        })
    }

    private func handleWebSocketConnection(_ connection: NWConnection) {
        let unauthenticated = clients.values.lazy.filter { !$0.authenticated }.count
        guard Self.allowsNewClient(
            total: clients.count,
            unauthenticated: unauthenticated
        ) else {
            webRemoteLogger.warning("Rejecting WebSocket client: connection limit reached")
            connection.cancel()
            return
        }
        let id = UUID()
        let client = WebRemoteClientConnection(
            id: id,
            authSourceKey: Self.authSourceKey(for: connection.endpoint),
            connection: connection,
            server: self
        )
        clients[id] = client
        client.start(
            on: queue,
            authenticationTimeout: Self.authenticationTimeoutSeconds
        )
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
        // The handshake is the only time a plaintext frame is legitimate.
        guard client.encrypted, let c2sKey = client.c2sKey else {
            handleWebSocketData(content, from: clientID)
            return
        }
        // Past the handshake EVERY frame must authenticate. A frame too short
        // to even hold nonce+tag is a forgery, not a command — dropping it
        // keeps "encrypted ⇒ authenticated" true for every inbound byte.
        // Falling through to the plaintext path here would let an injected
        // sub-28-byte frame execute against an authenticated session.
        guard content.count > WebRemoteCrypto.nonceLength + WebRemoteCrypto.tagLength else {
            dropClientLocked(clientID, reason: "unencrypted frame after handshake")
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
        case "listFiles", "readFile":
            guard let request = WebRemoteFileRequest(object) else {
                sendError("bad-request", to: clientID)
                return
            }
            accessFiles(request, clientID: clientID)
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
        guard let client = clients[clientID],
              let previousPanes = Self.panesToReconcileWhenSelecting(
                  subscribedPane: client.subscribedPane,
                  pendingPane: client.pendingPane,
                  nextPane: pane
              )
        else { return }

        client.paneSelectionGeneration &+= 1
        let selectionGeneration = client.paneSelectionGeneration
        client.subscribedPane = nil
        client.pendingPane = pane
        client.pendingSelectionOutput = WebRemoteOutputBuffer(
            byteLimit: Self.maxSelectionOutputBytes
        )
        // Order size ownership by request arrival, not asynchronous snapshot completion.
        recordTerminalSizeLocked(size, for: client)
        updateSubscribedPanesLocked()
        previousPanes.forEach { reconcileTerminalSizeLocked(for: $0) }

        DispatchQueue.main.async { [weak self] in
            guard let self, let store = WorkspaceStore.current else { return }
            store.webRemoteTerminalSnapshot(pane: pane, size: size) { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    guard let client = clients[clientID],
                          client.authenticated,
                          Self.isCurrentPaneSelection(
                              pendingPane: client.pendingPane,
                              pendingGeneration: client.paneSelectionGeneration,
                              pane: pane,
                              generation: selectionGeneration
                          )
                    else { return }
                    switch result {
                    case let .success(snapshot):
                        let bufferedOutput = client.pendingSelectionOutput.take(
                            after: snapshot.outputSequence
                        )
                        guard sendJSON([
                            "type": "snapshot",
                            "pane": pane,
                            "data": snapshot.payload.base64EncodedString(),
                        ], to: clientID) else {
                            client.pendingPane = nil
                            client.subscribedPane = nil
                            updateSubscribedPanesLocked()
                            reconcileTerminalSizeLocked(for: pane)
                            return
                        }
                        client.pendingPane = nil
                        client.subscribedPane = pane
                        updateSubscribedPanesLocked()
                        if !bufferedOutput.isEmpty,
                           !client.sendTerminalOutput(bufferedOutput, pane: pane) {
                            dropSlowClientLocked(clientID)
                            return
                        }
                    case let .failure(error):
                        finishSelectionFailure(
                            error,
                            pane: pane,
                            generation: selectionGeneration,
                            clientID: clientID
                        )
                    }
                }
            }
        }
    }

    private func finishSelectionFailure(
        _ error: String,
        pane: String,
        generation: UInt64,
        clientID: UUID
    ) {
        guard let client = clients[clientID],
              Self.isCurrentPaneSelection(
                  pendingPane: client.pendingPane,
                  pendingGeneration: client.paneSelectionGeneration,
                  pane: pane,
                  generation: generation
              )
        else { return }
        _ = client.pendingSelectionOutput.take()
        client.pendingPane = nil
        client.terminalSize = nil
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

    /// Read/list files for a live client; inputs identify its request. Returns
    /// nothing. Keep tickets until I/O finishes, even across stop/restart, so
    /// toggling the server cannot bypass the global background-work budget.
    private func accessFiles(_ request: WebRemoteFileRequest, clientID: UUID) {
        guard clients[clientID] != nil else { return }
        guard activeFileRequests.count < 8,
              activeFileRequests.values.filter({ $0 == clientID }).count < 2 else {
            sendJSON(request.error(.busy), to: clientID)
            return
        }
        let ticket = UUID()
        activeFileRequests[ticket] = clientID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let store = WorkspaceStore.current else {
                self.queue.async { self.activeFileRequests.removeValue(forKey: ticket) }
                return
            }
            let currentRoot = store.webRemoteFileRoot(workspace: request.workspace, pane: request.pane)
            guard case let .success(root) = request.validatedRoot(current: currentRoot) else {
                let error: WebRemoteFiles.ErrorCode = currentRoot == nil ? .rootUnavailable : .rootChanged
                self.queue.async {
                    self.activeFileRequests.removeValue(forKey: ticket)
                    self.sendJSON(request.error(error), to: clientID)
                }
                return
            }
            self.queue.async { [self] in
                guard self.clients[clientID] != nil else {
                    self.activeFileRequests.removeValue(forKey: ticket)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    var response: [String: Any] = [
                        "workspace": request.workspace.uuidString, "pane": request.pane,
                        "path": request.path, "root": root, "request": request.requestID,
                    ]
                    if request.read {
                        if WebRemoteFiles.isImage(request.path) {
                            switch WebRemoteFiles.readImage(root: root, path: request.path) {
                            case let .success(png):
                                response["type"] = "fileImage"
                                response["data"] = png.base64EncodedString()
                            case let .failure(error): response = request.error(error)
                            }
                        } else {
                            switch WebRemoteFiles.read(root: root, path: request.path) {
                            case let .success(content):
                                response["type"] = "fileContent"
                                response["content"] = content
                                response["format"] = WebRemoteFiles.isHTML(request.path) ? "html" : "text"
                            case let .failure(error): response = request.error(error)
                            }
                        }
                    } else {
                        switch WebRemoteFiles.list(root: root, path: request.path) {
                        case let .success(entries):
                            response["type"] = "fileList"
                            response["entries"] = entries
                            response["limit"] = WebRemoteFiles.maxEntries
                        case let .failure(error): response = request.error(error)
                        }
                    }
                    // I/O can outlive a cd, pane removal, or transition to SSH.
                    // Revalidate before handing the result back to the browser.
                    let completedResponse = response
                    DispatchQueue.main.async { [weak self] in
                        let latest = WorkspaceStore.current?.webRemoteFileRoot(
                            workspace: request.workspace, pane: request.pane
                        )
                        let checkedResponse = latest == root ? completedResponse
                            : request.error(latest == nil ? .rootUnavailable : .rootChanged)
                        self?.queue.async { [weak self] in
                            self?.activeFileRequests.removeValue(forKey: ticket)
                            self?.sendJSON(checkedResponse, to: clientID)
                        }
                    }
                }
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
                client.terminalSize = nil
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

    /// Queue a JSON response for a client; inputs identify payload and client;
    /// returns whether it was accepted so snapshots can retain stream ordering.
    @discardableResult
    private func sendJSON(_ object: [String: Any], to clientID: UUID) -> Bool {
        guard let data = SafeJSON.data(object) else { return false }
        return clients[clientID]?.send(data) ?? false
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
    /// `unauthorized`. Failure history is shared by source address, so reconnecting
    /// does not reset the delay.
    private func failAuthenticationLocked(for clientID: UUID) {
        guard let client = clients[clientID] else { return }
        client.authBackoffPending = true
        let failureCount = authThrottle.recordFailure(for: client.authSourceKey)
        let delay = Self.authBackoffSeconds(forFailures: failureCount)
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
            .filter {
                $0.authenticated
                    && ($0.subscribedPane == pane || $0.pendingPane == pane)
                    && $0.terminalSize != nil
            }
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
    let authSourceKey: String
    var authenticated = false
    var subscribedPane: String?
    var pendingPane: String?
    var paneSelectionGeneration: UInt64 = 0
    var pendingSelectionOutput = WebRemoteOutputBuffer(byteLimit: 0)
    var terminalSize: WebRemoteTerminalSize?
    var terminalSizeRevision: UInt64 = 0
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
    private var sendQueue: DispatchQueue?
    private var sendGeneration: UUID?
    private var sendTimeout: DispatchWorkItem?

    init(
        id: UUID,
        authSourceKey: String,
        connection: NWConnection,
        server: WebRemoteServer
    ) {
        self.id = id
        self.authSourceKey = authSourceKey
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue, authenticationTimeout: TimeInterval) {
        sendQueue = queue
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
        queue.asyncAfter(deadline: .now() + authenticationTimeout) { [weak self] in
            guard let self, !authenticated else { return }
            cancel()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        sendTimeout?.cancel()
        sendTimeout = nil
        sendGeneration = nil
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

    /// Queue ordinary data; returns false and records a bounded error notice
    /// when the response is too large or the queue is temporarily full.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !cancelled else { return false }
        guard outbound.enqueueMessage(data) else {
            outbound.rejectMessage(data)
            sendNextIfNeeded()
            return false
        }
        sendNextIfNeeded()
        return true
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
        let generation = UUID()
        sendGeneration = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.sendGeneration == generation, self.sendInFlight else { return }
            self.cancel()
        }
        sendTimeout?.cancel()
        sendTimeout = timeout
        sendQueue?.asyncAfter(deadline: .now() + 30, execute: timeout)
        connection.send(
            content: wireData,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, !self.cancelled, self.sendGeneration == generation else { return }
                self.sendTimeout?.cancel()
                self.sendTimeout = nil
                self.sendGeneration = nil
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
                cancel()
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
