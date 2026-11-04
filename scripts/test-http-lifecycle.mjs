import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const baseline = process.argv.includes("--baseline");
const source = baseline
  ? spawnSync("git", ["show", "HEAD:Glint/WebRemote/WebRemoteServer.swift"], { cwd: root, encoding: "utf8" }).stdout
  : fs.readFileSync(path.join(root, "Glint/WebRemote/WebRemoteServer.swift"), "utf8");

/** Extract a shipped private method including its body; input is its name; returns its source. */
function method(name) {
  const start = source.indexOf(`    private func ${name}(`);
  assert.ok(start >= 0, `Missing method ${name}`);
  const end = source.indexOf("\n    private func ", start + 1);
  return source.slice(start, end < 0 ? undefined : end);
}

const handlerStart = source.indexOf("    private func handleHTTPConnection(");
const handlerEnd = source.indexOf("    private func serveHTTPRequest(", handlerStart);
assert.ok(handlerStart >= 0 && handlerEnd > handlerStart, "HTTP extraction markers changed");
const admission = baseline ? "handleHTTPConnection(connection)" : "handleHTTPConnection(connection, runID: admissionRun)";
const maximum = source.match(/static let maxHTTPConnections = (\d+)/)?.[1] ?? "32";
// Use real Network.framework connections on an ephemeral loopback port. The
// asset lookup is a tiny fixture; admission, header reads, send completion and
// the entire stopLocked method come verbatim from the shipped server.
const fixture = String.raw`import Foundation
import Network
import Darwin
import os
private let webRemoteLogger = Logger(subsystem: "app.glint.tests", category: "HTTP")
private enum Status { case stopped }
private final class NoopClient {
    /// Stand in for unrelated WebSocket cancellation; takes no inputs; returns nothing.
    func cancel() {}
}
private struct NoopThrottle {
    /// Stand in for unrelated auth cleanup; takes no inputs; returns nothing.
    mutating func removeAll() {}
}
final class HTTPFixture {
    static let maxHTTPConnections = MAXIMUM
    private let queue = DispatchQueue(label: "glint.tests.http-lifecycle")
    private var runID: UUID? = UUID()
    private var admissionRun = UUID()
    private var httpConnections: [ObjectIdentifier: NWConnection] = [:]
    private var httpHeadersPending = Set<ObjectIdentifier>()
    private var httpSendGenerations: [ObjectIdentifier: UUID] = [:]
    private var httpSendTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let httpSendIdleTimeout: TimeInterval = 0.5
    private var accepted: [NWConnection] = []
    private let httpRequestTimeout: TimeInterval
    private var httpListener: NWListener?
    private var webSocketListener: NWListener?
    private var clients: [UUID: NoopClient] = [:]
    private var authThrottle = NoopThrottle()
    private var readyListeners: Set<Int> = []
    private var token = ""
    private var tokenKey = Data()
    private var pathMonitor: NWPathMonitor?
    private var pathRestartScheduled = false
    private var interfaceRetryTimer: DispatchSourceTimer?
    private var lastBoundAddress: String?
    /// Configure a test lifetime; input is the HTTP deadline; returns a fixture.
    init(timeout: TimeInterval) { httpRequestTimeout = timeout }
    /// Start only an ephemeral loopback listener; input selects a stale generation; returns its port.
    func start(stale: Bool = false) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        httpListener = listener
        admissionRun = stale ? UUID() : runID!
        let ready = DispatchSemaphore(value: 0)
        var listening = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: listening = true; ready.signal()
            case let .failed(error): print("Listener failed: \(error)"); ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // Retain baseline connections too, so ARC cannot imitate a timeout.
            self.accepted.append(connection)
            self.ADMISSION
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listening,
              let port = listener.port, port.rawValue != 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        return port.rawValue
    }
    /// Invoke the actual stop implementation; takes no inputs; returns nothing.
    func stop() { queue.sync { stopLocked(emitStatus: false) } }
    /// Clean fixture connections even against an unfixed baseline; takes no inputs; returns nothing.
    func cleanup() {
        queue.sync {
            httpListener?.cancel()
            for connection in accepted { connection.cancel() }
            accepted.removeAll()
        }
    }
    /// Stand in for unrelated terminal state; takes no inputs; returns no panes.
    private func controlledPanesLocked() -> [String] { [] }
    /// Stand in for unrelated subscriptions; takes no inputs; returns nothing.
    private func updateSubscribedPanesLocked() {}
    /// Stand in for unrelated terminal restoration; input is panes; returns nothing.
    private func releaseTerminalSizes(_ panes: [String]) {}
    /// Stand in for unrelated UI notifications; input is status; returns nothing.
    private func emit(_ status: Status) {}
    /// Complete an HTTP request without bundles or user files; inputs are data and connection; returns nothing.
    private func serveHTTPRequest(_ data: Data, on connection: NWConnection) {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8)
        if String(decoding: data, as: UTF8.self).contains("/slow") {
            queue.asyncAfter(deadline: .now() + 0.4) { self.sendHTTP(response, to: connection) }
        } else { sendHTTP(response, to: connection) }
    }
    /// Complete a malformed request; inputs are status, reason and connection; returns nothing.
    private func sendHTTPError(_ status: Int, reason: String, to connection: NWConnection) {
        sendHTTP(Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\n\r\n".utf8), to: connection)
    }
HANDLERS
SEND
STOP
}
struct Failure: Error { let message: String }
/// Verify one condition; inputs are its value and label; throws on failure.
func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
/// Connect a bounded raw HTTP peer; inputs are port and receive timeout; returns its file descriptor.
func connectPeer(_ port: UInt16, timeout: TimeInterval = 0.5) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
    var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return fd
}
/// Send bytes through a raw peer; inputs are descriptor and text; throws on failure.
func send(_ fd: Int32, _ text: String) throws {
    let data = Data(text.utf8)
    let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    guard count == data.count else { throw POSIXError(.EPIPE) }
}
/// Observe closure within the peer's deadline; input is its descriptor; returns whether EOF/reset arrived.
func peerClosed(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    let count = recv(fd, &byte, 1, 0)
    return count == 0 || (count < 0 && (errno == ECONNRESET || errno == ENOTCONN))
}
/// Verify silent connections expire; takes no inputs; throws on failure.
func testSilent() throws {
    let fixture = HTTPFixture(timeout: 0.2)
    defer { fixture.cleanup() }
    let peer = try connectPeer(fixture.start())
    defer { close(peer) }
    try expect(peerClosed(peer), "silent connection did not expire")
}
/// Verify partial progress does not reset the fixed deadline; takes no inputs; throws on failure.
func testPartial() throws {
    let fixture = HTTPFixture(timeout: 0.3)
    defer { fixture.cleanup() }
    let peer = try connectPeer(fixture.start())
    defer { close(peer) }
    let started = Date()
    try send(peer, "GET / HTTP/1.1\r\nX: ")
    usleep(100_000)
    try send(peer, "a")
    usleep(100_000)
    try send(peer, "b")
    try expect(peerClosed(peer), "partial headers did not expire")
    try expect(Date().timeIntervalSince(started) < 0.45, "header progress extended the fixed deadline")
}
/// Verify the 33rd pending connection is rejected before the deadline; takes no inputs; throws on failure.
func testCapacity() throws {
    let fixture = HTTPFixture(timeout: 3)
    defer { fixture.cleanup() }
    let port = try fixture.start()
    var peers: [Int32] = []
    defer { for peer in peers { close(peer) } }
    for _ in 0..<HTTPFixture.maxHTTPConnections { peers.append(try connectPeer(port)) }
    usleep(50_000)
    let overflow = try connectPeer(port)
    defer { close(overflow) }
    try expect(peerClosed(overflow), "connection cap did not reject excess peer")
}
/// Verify stop closes pending headers immediately; takes no inputs; throws on failure.
func testStop() throws {
    let fixture = HTTPFixture(timeout: 3)
    defer { fixture.cleanup() }
    let peer = try connectPeer(fixture.start())
    defer { close(peer) }
    try send(peer, "GET / HTTP/1.1\r\nX: ")
    usleep(50_000)
    fixture.stop()
    try expect(peerClosed(peer), "stop left an accepted HTTP connection alive")
}
/// Verify old listener callbacks cannot create a new live connection; takes no inputs; throws on failure.
func testStaleGeneration() throws {
    let fixture = HTTPFixture(timeout: 3)
    defer { fixture.cleanup() }
    let peer = try connectPeer(fixture.start(stale: true))
    defer { close(peer) }
    try expect(peerClosed(peer), "stale listener generation accepted a peer")
}
/// Verify valid requests finish and release their connection; takes no inputs; throws on failure.
func testCompleteRequest() throws {
    let fixture = HTTPFixture(timeout: 1)
    defer { fixture.cleanup() }
    let peer = try connectPeer(fixture.start())
    defer { close(peer) }
    try send(peer, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = recv(peer, &bytes, bytes.count, 0)
    try expect(count > 0 && String(decoding: bytes.prefix(max(count, 0)), as: UTF8.self).contains("200 OK"), "valid HTTP request failed")
    try expect(peerClosed(peer), "successful response left its connection alive")
}
/// A valid request may outlive its header deadline; no inputs; throws on premature cancellation.
func testResponseOutlivesHeaderDeadline() throws {
    let fixture = HTTPFixture(timeout: 0.15)
    defer { fixture.cleanup() }
    let peer = try connectPeer(fixture.start(), timeout: 1)
    defer { close(peer) }
    try send(peer, "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = recv(peer, &bytes, bytes.count, 0)
    try expect(count > 0 && String(decoding: bytes.prefix(max(count, 0)), as: UTF8.self).contains("200 OK"), "header deadline cancelled a valid response phase")
}
let tests: [(String, () throws -> Void)] = [
    ("silent headers expire", testSilent), ("partial headers have a fixed deadline", testPartial),
    ("HTTP connection cap is enforced", testCapacity), ("stop cancels pending HTTP", testStop),
    ("stale listener generations reject peers", testStaleGeneration), ("valid HTTP response completes", testCompleteRequest), ("response outlives header deadline", testResponseOutlivesHeaderDeadline),
]
var failures = 0
for (name, test) in tests {
    do { try test(); print("PASS: \(name)") }
    catch { failures += 1; print("FAIL: \(name): \(error)") }
}
print("Executed \(tests.count) HTTP lifecycle cases; \(failures) failures")
exit(failures == 0 ? 0 : 1)
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "glint-http-lifecycle-"));
try {
  const swift = fixture.replace("MAXIMUM", maximum).replace("ADMISSION", admission)
    .replace("HANDLERS", source.slice(handlerStart, handlerEnd))
    .replace("SEND", method("sendHTTP") + "\n" + method("sendHTTPChunk")).replace("STOP", method("stopLocked"));
  fs.writeFileSync(path.join(directory, "main.swift"), swift);
  const binary = path.join(directory, "http-lifecycle-tests");
  const compile = spawnSync("swiftc", ["-swift-version", "5", "-module-cache-path", path.join(os.tmpdir(), "glint-http-lifecycle-cache"), path.join(directory, "main.swift"), "-o", binary], { encoding: "utf8", timeout: 60000 });
  process.stdout.write(compile.stdout ?? "");
  process.stderr.write(compile.stderr ?? "");
  if (compile.error) throw compile.error;
  if (compile.status !== 0) process.exitCode = compile.status ?? 1;
  else {
    const run = spawnSync(binary, [], { encoding: "utf8", timeout: 15000 });
    process.stdout.write(run.stdout ?? "");
    process.stderr.write(run.stderr ?? "");
    if (run.error) throw run.error;
    process.exitCode = run.status ?? 1;
  }
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
