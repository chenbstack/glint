import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'Glint/WebRemote/WebRemoteServer.swift'), 'utf8');
const protocol = fs.readFileSync(path.join(root, 'Glint/WebRemote/WebRemoteProtocol.swift'), 'utf8');
const baseline = process.argv.includes('--baseline');
const old = baseline ? spawnSync('git', ['show', 'HEAD:Glint/WebRemote/WebRemoteServer.swift'], { cwd: root, encoding: 'utf8' }).stdout : source;

/** Extract a complete real declaration; text and marker identify it; returns source through its closing brace. */
function declaration(text, marker) {
  const start = text.indexOf(marker);
  assert.ok(start >= 0, `Missing ${marker}`);
  const brace = text.indexOf('{', start);
  let end = brace + 1;
  let depth = 1;
  for (; depth && end < text.length; end++) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return text.slice(start, end).replace(/^private /, '');
}

const buffers = source.slice(source.indexOf('struct WebRemoteOutputBuffer {'), source.indexOf('struct WebRemoteAuthThrottle {'));
const crypto = declaration(protocol, 'enum WebRemoteCrypto {');
// Only transport completion is controlled. Queueing, encryption/counter use,
// cancellation, send deadlines and pane-selection state transitions are real.
// Execute captured deadline work items deterministically instead of sleeping.
const sender = ['func cancel()', 'func send(_ data: Data)', 'func sendTerminalOutput(', 'private func sendNextIfNeeded()']
  .map(marker => declaration(source, marker)).join('\n');
const selector = declaration(old, 'private func selectPane(');
const http = ['private func finishHTTPConnection(', 'private func sendHTTP(', 'private func sendHTTPChunk(']
  .map(marker => declaration(source, marker)).join('\n');
const fixture = String.raw`import Foundation
import CryptoKit
import Security
import os
private let webRemoteLogger = Logger(subsystem: "app.glint.tests", category: "SendLifecycle")
struct Failure: Error { let message: String }
/// Check a regression; condition and label are inputs; throws on failure.
func expect(_ condition: Bool, _ label: String) throws { if !condition { throw Failure(message: label) } }
/// Await observable progress; label and condition are inputs; throws at a bounded deadline.
func until(_ label: String, _ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw Failure(message: "timeout: " + label)
}
enum NWProtocolWebSocket {
    enum Opcode { case text, binary }
    final class Metadata {
        /// Stand in for frame metadata; input is opcode; returns metadata.
        init(opcode: Opcode) {}
    }
}
final class NWConnection {
    final class ContentContext {
        /// Stand in for transport context; inputs mirror Network; returns a context.
        init(identifier: String, metadata: [NWProtocolWebSocket.Metadata]) {}
    }
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var sent: [Data] = []
    var completions: [(Error?) -> Void] = []
    var cancellations = 0
    var stateUpdateHandler: (() -> Void)?
    /// Hold a send until the test completes it; arguments mirror Network; returns nothing.
    func send(content: Data?, contentContext: ContentContext? = nil, isComplete: Bool = true, completion: SendCompletion) {
        sent.append(content ?? Data())
        if case let .contentProcessed(block) = completion { completions.append(block) }
    }
    /// Record transport cancellation; no inputs or return value.
    func cancel() { cancellations += 1 }
}
BUFFERS
CRYPTO
final class Client {
    let connection = NWConnection()
    let queue = DispatchQueue(label: "glint.tests.sender")
    var sendQueue: DispatchQueue?
    var sendGeneration: UUID?
    var sendTimeout: DispatchWorkItem?
    var cancelled = false
    var sendInFlight = false
    var outbound: WebRemoteOutboundBuffer
    var pendingSelectionOutput = WebRemoteOutputBuffer(byteLimit: 0)
    var encrypted = true
    var s2cKey: SymmetricKey? = SymmetricKey(data: Data(repeating: 7, count: 32))
    var sendCounter: UInt64 = 0
    var authenticated = true
    var subscribedPane: String?
    var pendingPane: String?
    var paneSelectionGeneration: UInt64 = 0
    /// Configure a real queue budget; input is total bytes; returns a sender.
    init(bytes: Int = 16 * 1024 * 1024) {
        outbound = WebRemoteOutboundBuffer(maxQueuedOutputBytes: min(512 * 1024, bytes / 2), maxQueuedBytes: bytes)
        sendQueue = queue
    }
SENDER
}
struct WebRemoteTerminalSize { var columns = 80; var rows = 24 }
struct WebRemoteTerminalSnapshot { let payload: Data; let outputSequence: UInt64 }
enum WebRemoteTerminalSnapshotResult { case success(WebRemoteTerminalSnapshot), failure(String) }
final class WorkspaceStore {
    static var current: WorkspaceStore? = WorkspaceStore()
    static var payload = Data()
    /// Support the old selector baseline; inputs mirror Store; returns no focus failure.
    func controlFocus(pane: String, activateApp: Bool) -> String? { nil }
    /// Supply an in-memory grid; inputs mirror Store; completes without files or Ghostty.
    func webRemoteTerminalSnapshot(pane: String, size: WebRemoteTerminalSize,
                                  completion: @escaping (WebRemoteTerminalSnapshotResult) -> Void) {
        completion(.success(WebRemoteTerminalSnapshot(payload: Self.payload, outputSequence: 0)))
    }
}
final class SelectionFixture {
    static let maxSelectionOutputBytes = 512 * 1024
    let queue = DispatchQueue(label: "glint.tests.selector")
    let client = Client(bytes: 512)
    let id = UUID()
    var clients: [UUID: Client] = [:]
    /// Register the isolated sender; no inputs; returns a selector.
    init() { clients[id] = client; client.sendQueue = queue }
    /// Invoke the real selector on its owning queue; input is pane; returns nothing.
    func select(_ pane: String) { queue.sync { selectPane(pane, size: WebRemoteTerminalSize(), for: id) } }
    /// Stand in for unrelated terminal size bookkeeping; inputs are size/client; returns nothing.
    private func recordTerminalSizeLocked(_ size: WebRemoteTerminalSize, for client: Client) {}
    /// Stand in for unrelated ingress subscription mirroring; no inputs or return value.
    private func updateSubscribedPanesLocked() {}
    /// Stand in for unrelated terminal size restoration; input is pane; returns nothing.
    private func reconcileTerminalSizeLocked(for pane: String) {}
    /// Fail if an unexpected grid failure is used; arguments mirror Store; returns nothing.
    private func finishSelectionFailure(_ error: String, pane: String, generation: UInt64, clientID: UUID) { fatalError(error) }
    /// Preserve failure on an unexpected terminal overflow; input is client ID; returns nothing.
    private func dropSlowClientLocked(_ clientID: UUID) { client.cancel() }
    /// Preserve the real client send decision; inputs are payload/client; returns acceptance.
    private func sendJSON(_ object: [String: Any], to clientID: UUID) -> Bool {
        guard let data = SafeJSON.data(object) else { return false }
        return clients[clientID]?.send(data) ?? false
    }
RECONCILE
CURRENT
SELECTOR
}
final class HTTPFixture {
    let queue = DispatchQueue(label: "glint.tests.http-send")
    let connection = NWConnection()
    var httpConnections: [ObjectIdentifier: NWConnection] = [:]
    var httpHeadersPending = Set<ObjectIdentifier>()
    var httpSendGenerations: [ObjectIdentifier: UUID] = [:]
    var httpSendTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    let httpSendIdleTimeout: TimeInterval = 0.15
    /// Track the fixture connection; no inputs; returns a response sender.
    init() { httpConnections[ObjectIdentifier(connection)] = connection }
HTTP_METHODS
}
@main enum Tests {
    /// Exercise real deadlines and snapshot decisions; no inputs; exits with regression status.
    @MainActor static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("stalled WebSocket send closes and rejects its late completion", stalledWebSocket),
            ("WebSocket completion cancels the old deadline and preserves nonces", progressingWebSocket),
            ("HTTP progress outlives a total deadline", progressingHTTP),
            ("stalled HTTP send closes and ignores late completion", stalledHTTP),
            ("snapshot rejection clears subscription and permits retry", snapshotRetry),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: " + name) }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Executed \(tests.count) send/snapshot lifecycle cases; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    /// A never-completed send expires once; no inputs; throws if late completion restarts it.
    @MainActor static func stalledWebSocket() async throws {
        let client = Client()
        client.queue.sync { _ = client.send(Data("first".utf8)); _ = client.send(Data("second".utf8)) }
        client.queue.sync { client.sendTimeout!.perform() }
        try expect(client.queue.sync { client.cancelled }, "stalled sender did not time out")
        client.queue.sync { client.connection.completions[0](nil) }
        try expect(client.queue.sync { client.connection.sent.count == 1 && client.connection.cancellations == 1 }, "late send restarted a cancelled connection")
    }
    /// Completed sends invalidate old timers and advance GCM counters once; no inputs; throws on mismatch.
    @MainActor static func progressingWebSocket() async throws {
        let client = Client()
        client.queue.sync { _ = client.send(Data("first".utf8)); _ = client.send(Data("second".utf8)) }
        client.queue.sync {
            let old = client.sendTimeout!
            client.connection.completions[0](nil)
            old.perform()
        }
        try expect(client.queue.sync { !client.cancelled && client.connection.sent.count == 2 }, "old deadline cancelled a progressing sender")
        client.queue.sync {
            let old = client.sendTimeout!
            client.connection.completions[1](nil)
            old.perform()
        }
        try expect(client.queue.sync { !client.cancelled && client.sendCounter == 2 }, "completed send retained a deadline or reused nonce")
        let counters = client.queue.sync { client.connection.sent.compactMap { WebRemoteCrypto.counter(fromNonce: $0.prefix(12)) } }
        try expect(counters == [0, 1], "wire counters were not monotonic")
        client.queue.sync { client.cancel() }
    }
    /// Multiple chunks can take longer than one idle deadline; no inputs; throws on premature cancellation.
    @MainActor static func progressingHTTP() async throws {
        let http = HTTPFixture()
        let data = Data(repeating: 1, count: 128 * 1024 + 1)
        http.queue.sync { http.sendHTTP(data, to: http.connection) }
        for index in 0..<3 {
            http.queue.sync {
                let old = http.httpSendTimeouts[ObjectIdentifier(http.connection)]!
                http.connection.completions[index](nil)
                old.perform()
            }
        }
        try expect(http.queue.sync { http.connection.sent.map(\.count) == [65536, 65536, 1] }, "response chunks were not bounded")
        try expect(http.queue.sync { http.connection.cancellations == 1 && http.httpConnections.isEmpty }, "completed response did not release connection")
    }
    /// A stopped HTTP write cannot resume from its callback; no inputs; throws on a leaked slot or send.
    @MainActor static func stalledHTTP() async throws {
        let http = HTTPFixture()
        http.queue.sync { http.sendHTTP(Data(repeating: 1, count: 128 * 1024), to: http.connection) }
        http.queue.sync { http.httpSendTimeouts[ObjectIdentifier(http.connection)]!.perform() }
        try expect(http.queue.sync { http.connection.cancellations == 1 }, "stalled HTTP sender did not time out")
        http.queue.sync { http.connection.completions[0](nil) }
        try expect(http.queue.sync { http.connection.sent.count == 1 && http.httpConnections.isEmpty }, "late HTTP completion resumed old transfer")
    }
    /// Oversized snapshots cannot enable output, but a smaller retry can; no inputs; throws on mismatch.
    @MainActor static func snapshotRetry() async throws {
        let server = SelectionFixture()
        WorkspaceStore.payload = Data(repeating: 1, count: 1024)
        server.select("pane")
        try await until("snapshot rejection") { server.queue.sync { server.client.pendingPane == nil } }
        try expect(server.queue.sync { server.client.subscribedPane == nil && !server.client.cancelled }, "rejected snapshot subscribed or disconnected its pane")
        server.queue.sync { server.client.connection.completions[0](nil) }
        WorkspaceStore.payload = Data("small".utf8)
        server.select("pane")
        try await until("successful snapshot retry") { server.queue.sync { server.client.subscribedPane == "pane" } }
        try expect(server.queue.sync { server.client.connection.sent.count == 2 }, "retry did not send a snapshot on the existing connection")
        server.queue.sync { server.client.connection.completions[1](nil); server.client.cancel() }
    }
}
`;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'glint-send-lifecycle-'));
try {
  const swift = fixture.replace('BUFFERS', buffers).replace('CRYPTO', crypto).replace('SENDER', sender)
    .replace('SELECTOR', selector).replace('HTTP_METHODS', http)
    .replace('RECONCILE', declaration(source, 'static func panesToReconcileWhenSelecting('))
    .replace('CURRENT', declaration(source, 'static func isCurrentPaneSelection('));
  fs.writeFileSync(path.join(dir, 'Tests.swift'), swift);
  const executable = path.join(dir, 'test');
  const build = spawnSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-module-cache-path', path.join(os.tmpdir(), 'glint-send-lifecycle-cache'), path.join(dir, 'Tests.swift'), path.join(root, 'Glint/Agent/SafeJSON.swift'), '-o', executable], { encoding: 'utf8', timeout: 60000 });
  process.stderr.write(build.stderr ?? '');
  if (build.status !== 0) process.exitCode = 1;
  else {
    const result = spawnSync(executable, [], { encoding: 'utf8', timeout: 10000 });
    process.stdout.write(result.stdout ?? ''); process.stderr.write(result.stderr ?? '');
    process.exitCode = result.status ?? 1;
  }
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
