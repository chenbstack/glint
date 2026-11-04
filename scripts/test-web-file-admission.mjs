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
const protocolSource = fs.readFileSync(path.join(root, "Glint/WebRemote/WebRemoteProtocol.swift"), "utf8");
const requestErrorStart = protocolSource.indexOf("    func error(_ code: WebRemoteFiles.ErrorCode)");
const requestErrorEnd = protocolSource.indexOf("\n    }", requestErrorStart) + 6;
assert.ok(requestErrorStart >= 0 && requestErrorEnd > requestErrorStart);
const requestError = protocolSource.slice(requestErrorStart, requestErrorEnd);
const codeStart = protocolSource.indexOf("    enum ErrorCode: String, Error {");
const codeEnd = protocolSource.indexOf("\n    }", codeStart) + 6;
assert.ok(codeStart >= 0 && codeEnd > codeStart);
const errorCodes = protocolSource.slice(codeStart, codeEnd);
const start = source.indexOf("    private func accessFiles(");
const end = source.indexOf("\n    private func ", start + 1);
assert.ok(start >= 0 && end > start, "accessFiles extraction markers changed");

// Exercise the complete shipped accessFiles implementation, including all of
// its main/server/background queue hops. Replace file I/O with an NSCondition
// gate; workspace/file-request types and transport are narrow in-memory stubs.
// Disconnect/stop here only clear fixture clients: these tests verify that the
// work budget survives that change. test-http-lifecycle.mjs separately executes
// the production stopLocked method over real loopback connections.
const fixture = String.raw`import Foundation
struct Failure: Error { let message: String }
/// Verify a regression condition; inputs are condition and explanation; throws on failure.
func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
final class IOGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var releases: Set<String> = []
    private var autoRelease = false
    private var started: [String] = []
    private var running = 0
    private var maximum = 0
    /// Block one synthetic operation; input is its unique path; returns after explicit release.
    func perform(_ path: String) {
        condition.lock()
        started.append(path)
        running += 1
        maximum = max(maximum, running)
        while !autoRelease && !releases.contains(path) { condition.wait() }
        running -= 1
        condition.unlock()
    }
    /// Release one operation; input is its unique path; returns nothing.
    func release(_ path: String) { condition.lock(); releases.insert(path); condition.broadcast(); condition.unlock() }
    /// Release current and future operations for cleanup; takes no inputs; returns nothing.
    func releaseAll() { condition.lock(); autoRelease = true; condition.broadcast(); condition.unlock() }
    /// Snapshot started paths and concurrency; takes no inputs; returns observed counters.
    func snapshot() -> (paths: [String], running: Int, maximum: Int) {
        condition.lock(); defer { condition.unlock() }
        return (started, running, maximum)
    }
}
enum WebRemoteFiles {
FILECODES
    static let maxEntries = 200
    static var gate = IOGate()
    /// Classify a synthetic image; input is path; returns whether its extension is PNG.
    static func isImage(_ path: String) -> Bool { path.hasSuffix(".png") }
    /// Classify a synthetic HTML page; input is path; returns whether its extension is HTML.
    static func isHTML(_ path: String) -> Bool { path.hasSuffix(".html") }
    /// Simulate a blocked image read; inputs are root and path; returns a small injected payload or error.
    static func readImage(root: String, path: String) -> Result<Data, ErrorCode> {
        gate.perform(path)
        return path.contains("fail") ? .failure(.unavailable) : .success(Data([1, 2]))
    }
    /// Simulate a blocked text read; inputs are root and path; returns injected text or error.
    static func read(root: String, path: String) -> Result<String, ErrorCode> {
        gate.perform(path)
        return path.contains("fail") ? .failure(.unavailable) : .success("contents")
    }
    /// Simulate a blocked listing; inputs are root and path; returns an injected listing or error.
    static func list(root: String, path: String) -> Result<[[String: String]], ErrorCode> {
        gate.perform(path)
        return path.contains("fail") ? .failure(.unavailable) : .success([["name": "file.txt"]])
    }
}
final class WorkspaceStore {
    static var current: WorkspaceStore?
    var root: String? = "/allowed"
    /// Return an in-memory file root; inputs are workspace and pane; returns the configured root.
    func webRemoteFileRoot(workspace: UUID, pane: String) -> String? { root }
}
struct WebRemoteFileRequest {
    var workspace = UUID()
    var pane = "pane"
    var path: String
    var root = "/allowed"
    var requestID = UUID().uuidString
    var read = true
    /// Validate the fixture root binding; input is the current root; returns its path or an error.
    func validatedRoot(current: String?) -> Result<String, WebRemoteFiles.ErrorCode> {
        guard let current else { return .failure(.rootUnavailable) }
        guard root == current else { return .failure(.rootChanged) }
        return .success(current)
    }
    /// Encode a fixture error; input is its code; returns a correlated response dictionary.
REQUESTERROR
}
final class AdmissionFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "glint.tests.file-admission")
    private var clients: [UUID: Bool] = [:]
    private var activeFileRequests: [UUID: UUID] = [:]
    private var drops: Set<UUID> = []
    private var replies: [(UUID, [String: Any])] = []
    private var suppressed = 0
    /// Register a synthetic client; takes no inputs; returns its new identity.
    func addClient() -> UUID { queue.sync { let id = UUID(); clients[id] = true; return id } }
    /// Remove a client without completing its I/O; input is its identity; returns nothing.
    func disconnect(_ id: UUID) { queue.sync { clients[id] = nil } }
    /// Model stop/restart's client clearing only; takes no inputs; returns nothing.
    func clearClients() { queue.sync { clients.removeAll() } }
    /// Run real admission on its serial queue; inputs are request and client; returns nothing.
    func submit(_ request: WebRemoteFileRequest, client: UUID) { queue.sync { accessFiles(request, clientID: client) } }
    /// Snapshot ticket and transport state; takes no inputs; returns observed state.
    func snapshot() -> (tickets: Int, drops: Set<UUID>, replies: [(UUID, [String: Any])], suppressed: Int) {
        queue.sync { (activeFileRequests.count, drops, replies, suppressed) }
    }
    /// Record the production admission failure action; inputs are client and reason; returns nothing.
    private func dropClientLocked(_ id: UUID, reason: String) { drops.insert(id); clients[id] = nil }
    /// Model production's missing-client no-op; inputs are response and client; returns nothing.
    private func sendJSON(_ response: [String: Any], to id: UUID) {
        guard clients[id] != nil else { suppressed += 1; return }
        replies.append((id, response))
    }
ACCESS
}
@MainActor enum AdmissionTests {
    static var fixture: AdmissionFixture!
    /// Let queued production callbacks progress; takes no inputs; returns nothing.
    static func settle() async { for _ in 0..<100 { await Task.yield() } }
    /// Wait for an observed event with a bounded deadline; inputs are explanation and predicate; throws on timeout.
    static func until(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<2000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure(message: "timeout: \(label)")
    }
    /// Prepare isolated gate/store/transport state; takes no inputs; returns nothing.
    static func setup() {
        WebRemoteFiles.gate = IOGate()
        WorkspaceStore.current = WorkspaceStore()
        fixture = AdmissionFixture()
    }
    /// Release synthetic I/O and drain callbacks; takes no inputs; returns nothing.
    static func cleanup() async {
        WebRemoteFiles.gate.releaseAll()
        await settle()
        try? await until("cleanup I/O") { WebRemoteFiles.gate.snapshot().running == 0 }
        await settle()
        fixture = nil
        WorkspaceStore.current = nil
    }
    /// A client has two slots and keeps their tickets after overflow; takes no inputs; throws on mismatch.
    static func clientLimit() async throws {
        let client = fixture.addClient()
        fixture.submit(WebRemoteFileRequest(path: "one.txt"), client: client)
        fixture.submit(WebRemoteFileRequest(path: "two.txt"), client: client)
        try await until("two blocked reads") { WebRemoteFiles.gate.snapshot().running == 2 }
        fixture.submit(WebRemoteFileRequest(path: "three.txt"), client: client)
        try await until("per-client overflow response") { fixture.snapshot().replies.contains { $0.0 == client } }
        try expect(!fixture.snapshot().drops.contains(client), "a file burst disconnected its terminal")
        try expect(fixture.snapshot().replies.last?.1["code"] as? String == "file-busy", "overflow did not return busy")
        try expect(fixture.snapshot().replies.last?.1["path"] as? String == "three.txt", "busy response lost request correlation")
        try expect(fixture.snapshot().tickets == 2, "dropping a client freed running I/O tickets")
        try expect(WebRemoteFiles.gate.snapshot().paths.count == 2, "third request started I/O")
        WebRemoteFiles.gate.releaseAll()
        try await until("dropped client's tickets released") { fixture.snapshot().tickets == 0 }
        try expect(fixture.snapshot().replies.count == 3, "connected client did not receive busy and both completed reads")
    }
    /// Global tickets survive disconnects and restarts until I/O actually completes; takes no inputs; throws on mismatch.
    static func globalLimitSurvivesRestart() async throws {
        var clients: [UUID] = []
        for index in 0..<4 {
            let client = fixture.addClient(); clients.append(client)
            fixture.submit(WebRemoteFileRequest(path: "\(index)-a.txt"), client: client)
            fixture.submit(WebRemoteFileRequest(path: "\(index)-b.txt"), client: client)
        }
        try await until("eight blocked global reads") { WebRemoteFiles.gate.snapshot().running == 8 }
        fixture.disconnect(clients[0])
        fixture.clearClients()
        try expect(fixture.snapshot().tickets == 8, "disconnect/stop freed unfinished global work")
        let rejected = fixture.addClient()
        fixture.submit(WebRemoteFileRequest(path: "overflow.txt"), client: rejected)
        try await until("global overflow response") { fixture.snapshot().replies.contains { $0.0 == rejected } }
        try expect(!fixture.snapshot().drops.contains(rejected), "global file pressure disconnected a terminal")
        try expect(fixture.snapshot().replies.last?.1["code"] as? String == "file-busy", "global overflow did not return busy")
        try expect(WebRemoteFiles.gate.snapshot().paths.count == 8, "overflow started a ninth operation")
        WebRemoteFiles.gate.release("0-a.txt")
        try await until("one old ticket completes") { fixture.snapshot().tickets == 7 }
        let admitted = fixture.addClient()
        fixture.submit(WebRemoteFileRequest(path: "new.txt"), client: admitted)
        try await until("replacement starts in freed slot") { WebRemoteFiles.gate.snapshot().paths.contains("new.txt") }
        try expect(fixture.snapshot().tickets == 8, "completed ticket did not release exactly one slot")
        WebRemoteFiles.gate.releaseAll()
        try await until("all tickets complete") { fixture.snapshot().tickets == 0 }
        try expect(WebRemoteFiles.gate.snapshot().maximum <= 8, "actual concurrent I/O exceeded eight")
        try expect(fixture.snapshot().replies.count == 2 && fixture.snapshot().replies.last?.0 == admitted,
                   "late I/O replied to a removed client")
        try expect(fixture.snapshot().suppressed == 8, "missing-client transport no-op was not exercised")
    }
    /// Missing workspace state releases admission without reading; takes no inputs; throws on mismatch.
    static func missingStore() async throws {
        WorkspaceStore.current = nil
        let client = fixture.addClient()
        fixture.submit(WebRemoteFileRequest(path: "missing-store.txt"), client: client)
        await settle()
        try await until("missing store releases ticket") { fixture.snapshot().tickets == 0 }
        try expect(WebRemoteFiles.gate.snapshot().paths.isEmpty, "missing store initiated I/O")
    }
    /// Missing and mismatched roots release tickets with correlated errors; takes no inputs; throws on mismatch.
    static func invalidRoots() async throws {
        let client = fixture.addClient()
        WorkspaceStore.current?.root = nil
        fixture.submit(WebRemoteFileRequest(path: "missing-root.txt"), client: client)
        try await until("missing root response") { fixture.snapshot().replies.count == 1 }
        try expect(fixture.snapshot().tickets == 0, "missing root leaked its ticket")
        try expect(fixture.snapshot().replies.last?.1["code"] as? String == "files-unavailable", "wrong missing-root error")
        WorkspaceStore.current?.root = "/other"
        fixture.submit(WebRemoteFileRequest(path: "changed-root.txt"), client: client)
        try await until("changed root response") { fixture.snapshot().replies.count == 2 }
        try expect(fixture.snapshot().tickets == 0, "invalid root leaked its ticket")
        try expect(fixture.snapshot().replies.last?.1["code"] as? String == "file-root-changed", "wrong changed-root error")
        try expect(WebRemoteFiles.gate.snapshot().paths.isEmpty, "invalid roots reached file I/O")
    }
    /// Dead clients must not begin I/O before or after the main-queue hop; takes no inputs; throws on mismatch.
    static func disappearingClient() async throws {
        fixture.submit(WebRemoteFileRequest(path: "absent.txt"), client: UUID())
        try expect(fixture.snapshot().tickets == 0, "absent client received an admission ticket")
        let client = fixture.addClient()
        fixture.submit(WebRemoteFileRequest(path: "disappeared.txt"), client: client)
        fixture.disconnect(client)
        await settle()
        try await until("disappeared client releases ticket") { fixture.snapshot().tickets == 0 }
        try expect(WebRemoteFiles.gate.snapshot().paths.isEmpty, "disappeared client initiated I/O")
        try expect(fixture.snapshot().replies.isEmpty, "disappeared client received a reply")
    }
    /// Every read/list success and error path releases its ticket; takes no inputs; throws on mismatch.
    static func completionPaths() async throws {
        let client = fixture.addClient()
        let cases: [(String, Bool, String)] = [
            ("read.txt", true, "fileContent"), ("read.html", true, "fileContent"),
            ("image.png", true, "fileImage"), ("directory", false, "fileList"),
            ("fail.txt", true, "fileError"), ("fail.png", true, "fileError"),
            ("fail-directory", false, "fileError"),
        ]
        for (index, item) in cases.enumerated() {
            let request = WebRemoteFileRequest(path: item.0, read: item.1)
            fixture.submit(request, client: client)
            try await until("I/O starts: \(item.0)") { WebRemoteFiles.gate.snapshot().paths.contains(item.0) }
            WebRemoteFiles.gate.release(item.0)
            try await until("I/O responds: \(item.0)") { fixture.snapshot().replies.count == index + 1 }
            try expect(fixture.snapshot().tickets == 0, "completion leaked ticket: \(item.0)")
            try expect(fixture.snapshot().replies.last?.1["type"] as? String == item.2, "wrong response branch: \(item.0)")
        }
    }
    /// A changed root during I/O is rejected and releases its ticket; takes no inputs; throws on mismatch.
    static func changedRootDuringRead() async throws {
        let client = fixture.addClient()
        fixture.submit(WebRemoteFileRequest(path: "late.txt"), client: client)
        try await until("late read blocks") { WebRemoteFiles.gate.snapshot().running == 1 }
        WorkspaceStore.current?.root = "/other"
        WebRemoteFiles.gate.release("late.txt")
        try await until("changed-root response") { fixture.snapshot().replies.count == 1 }
        try expect(fixture.snapshot().tickets == 0, "revalidation leaked ticket")
        try expect(fixture.snapshot().replies.last?.1["code"] as? String == "file-root-changed", "late read bypassed root revalidation")
    }
}
@main struct Runner {
    /// Run isolated production-method regressions; takes no inputs; exits nonzero on failure.
    @MainActor static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("per-client file I/O cap", AdmissionTests.clientLimit),
            ("global cap survives disconnect/stop/restart", AdmissionTests.globalLimitSurvivesRestart),
            ("missing WorkspaceStore releases ticket", AdmissionTests.missingStore),
            ("invalid roots release tickets", AdmissionTests.invalidRoots),
            ("clients disappearing before I/O release tickets", AdmissionTests.disappearingClient),
            ("all read/list completion paths release tickets", AdmissionTests.completionPaths),
            ("root revalidation releases tickets", AdmissionTests.changedRootDuringRead),
        ]
        var failures = 0
        for (name, test) in tests {
            AdmissionTests.setup()
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
            await AdmissionTests.cleanup()
        }
        print("Executed \(tests.count) Web file-admission cases; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "glint-web-file-admission-"));
try {
  const swift = path.join(directory, "Admission.swift");
  fs.writeFileSync(swift, fixture.replace("ACCESS", source.slice(start, end)).replace("REQUESTERROR", requestError).replace("FILECODES", errorCodes));
  const binary = path.join(directory, "file-admission-tests");
  const compile = spawnSync("swiftc", ["-swift-version", "5", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "glint-file-admission-cache"), swift, "-o", binary], { encoding: "utf8", timeout: 60000 });
  process.stdout.write(compile.stdout ?? "");
  process.stderr.write(compile.stderr ?? "");
  if (compile.error) throw compile.error;
  if (compile.status !== 0) process.exitCode = compile.status ?? 1;
  else {
    const run = spawnSync(binary, [], { encoding: "utf8", timeout: 20000 });
    process.stdout.write(run.stdout ?? "");
    process.stderr.write(run.stderr ?? "");
    if (run.error) throw run.error;
    process.exitCode = run.status ?? 1;
  }
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
