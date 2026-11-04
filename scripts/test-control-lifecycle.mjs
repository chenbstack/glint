import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

// Compile the entire bridge with a temporary HOME substituted only in the test
// copy. Exercise its real Unix socket, accept loop and stop/start lifecycle.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'glint-control-test-'));
const support = String.raw`
import Foundation
import Darwin
enum ControlTestGate {
    static let lock = NSLock()
    static var before: (() -> Void)?
    static var after: (() -> Void)?
    /// Install deterministic queue gates; inputs are before/after callbacks; returns nothing.
    static func set(before: (() -> Void)?, after: (() -> Void)?) {
        lock.lock(); self.before = before; self.after = after; lock.unlock()
    }
    /// Pause before the actual main-thread hop; no inputs or return value.
    static func invokeBefore() {
        lock.lock(); let block = before; lock.unlock(); block?()
    }
    /// Observe completion of the actual main-thread hop; no inputs or return value.
    static func invokeAfter() {
        lock.lock(); let block = after; lock.unlock(); block?()
    }
}
final class WorkspaceStore {
    static let current: WorkspaceStore? = WorkspaceStore()
    var injections = 0
    var externalControlEnabled = true
    enum ControlGridResult { case success(Data), failure(String) }
    /// List stub panes; no inputs; returns an empty list.
    func controlListPanes() -> [[String: Any]] { [] }
    /// Focus a stub pane; pane is its identifier; returns no error.
    func controlFocus(pane: String) -> String? { nil }
    /// Record a command; arguments match production; returns no error.
    func controlSendText(pane: String, text: String, enter: Bool) -> String? { injections += 1; return nil }
    /// Accept stub keys; arguments match production; returns no error.
    func controlSendKeys(pane: String, keys: [String]) -> String? { nil }
    /// Stand in for terminal-grid export; arguments match production; returns a safe unavailable result.
    func controlReadGrid(pane: String, scrollback: Bool, maxLines: Int) -> ControlGridResult { .failure("pane-not-ready") }
}
enum GhosttySurfaceView {
    /// Stand in for grid decoding; inputs match production; returns no text without a real engine.
    static func controlText(fromRenderGrid data: Data, scrollback: Bool, maxLines: Int) -> String? { nil }
}
extension ControlBridge {
    /// Construct an isolated bridge; no inputs; returns a bridge without starting it.
    static func isolated() -> ControlBridge { ControlBridge() }
}
`;
const main = String.raw`
import Foundation
import Darwin
/// Fail a regression; condition and label are inputs; returns nothing or exits.
func check(_ value: Bool, _ label: String) {
    guard value else { print("FAIL: \(label)"); exit(1) }
    print("PASS: \(label)")
}
/// Open the temporary Unix socket; path is the socket path; returns its owned descriptor.
func connectSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { src in
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
        }
    }
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    check(result == 0, "connect temporary socket")
    var flag: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}
/// Send one request and read a response; fd and token are inputs; returns parsed JSON or nil on closed connection.
func request(_ fd: Int32, _ token: String) -> [String: Any]? {
    let data = try! JSONSerialization.data(withJSONObject: ["cmd": "send-text", "pane": "test:1", "text": "test", "token": token]) + Data([10])
    let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard sent > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = Darwin.read(fd, &bytes, bytes.count)
    guard count > 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count)))) as? [String: Any]
}
let bridge = ControlBridge.isolated()
DispatchQueue.global().async {
    DispatchQueue.main.sync { bridge.start() }
    let oldToken = try! String(contentsOfFile: bridge.tokenPath, encoding: .utf8)
    let fd = connectSocket(bridge.socketPath)
    check(request(fd, oldToken)?["ok"] as? Bool == true, "active command succeeds")
    DispatchQueue.main.sync { bridge.stop() }
    check(request(fd, oldToken)?["ok"] as? Bool != true, "stop revokes already accepted connection")
    close(fd)
    DispatchQueue.main.sync { bridge.start() }
    let newToken = try! String(contentsOfFile: bridge.tokenPath, encoding: .utf8)
    check(newToken != oldToken, "restart rotates token")
    let next = connectSocket(bridge.socketPath)
    check(request(next, oldToken)?["error"] as? String == "unauthorized", "new connection rejects old token")
    check(request(next, newToken)?["ok"] as? Bool == true, "new token succeeds")
    let mainBlocked = DispatchSemaphore(value: 0)
    let unblockMain = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { mainBlocked.signal(); unblockMain.wait() }
    check(mainBlocked.wait(timeout: .now() + 3) == .success, "main queue is deliberately occupied")
    let unauthorized = connectSocket(bridge.socketPath)
    let rejected = request(unauthorized, "not-the-token")
    unblockMain.signal()
    close(unauthorized)
    check(rejected?["error"] as? String == "unauthorized", "invalid token is rejected without waiting for the main queue")
    let reachedGate = DispatchSemaphore(value: 0)
    let resumeRequest = DispatchSemaphore(value: 0)
    let handled = DispatchSemaphore(value: 0)
    let requestFinished = DispatchSemaphore(value: 0)
    ControlTestGate.set(before: { reachedGate.signal(); resumeRequest.wait() }, after: { handled.signal() })
    let racing = connectSocket(bridge.socketPath)
    DispatchQueue.global().async { _ = request(racing, newToken); requestFinished.signal() }
    check(reachedGate.wait(timeout: .now() + 3) == .success, "request waits before main-thread execution")
    DispatchQueue.main.sync { bridge.stop() }
    resumeRequest.signal()
    check(handled.wait(timeout: .now() + 3) == .success, "queued request finishes after revocation")
    check(requestFinished.wait(timeout: .now() + 3) == .success, "revoked socket unblocks its peer")
    ControlTestGate.set(before: nil, after: nil)
    close(racing)
    close(next)
    check(WorkspaceStore.current!.injections == 2, "only authorized live commands execute")
    exit(0)
}
dispatchMain()
`;
try {
  const source = fs.readFileSync(process.env.GLINT_CONTROL_SOURCE ?? path.join(root, 'Glint/Agent/ControlBridge.swift'), 'utf8')
    .replaceAll('FileManager.default.homeDirectoryForCurrentUser', 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLINT_TEST_HOME"]!)')
    // Pause around the real main-thread hop without replacing its validation.
    .replace('        var response = Self.errorResponse("unknown-cmd")', '        ControlTestGate.invokeBefore()\n        var response = Self.errorResponse("unknown-cmd")')
    .replace('        return response\n    }', '        ControlTestGate.invokeAfter()\n        return response\n    }');
  fs.writeFileSync(path.join(dir, 'Bridge.swift'), source + support);
  fs.writeFileSync(path.join(dir, 'main.swift'), main);
  const build = spawnSync('swiftc', ['-swift-version', '5', '-module-cache-path', path.join(dir, 'cache'), path.join(dir, 'Bridge.swift'), path.join(root, 'Glint/Agent/SafeJSON.swift'), path.join(root, 'Shared/CLIInstallation.swift'), path.join(dir, 'main.swift'), '-o', path.join(dir, 'test')], { encoding: 'utf8', timeout: 60000 });
  process.stdout.write(build.stdout ?? ''); process.stderr.write(build.stderr ?? '');
  if (build.status !== 0) process.exitCode = 1;
  else {
    const run = spawnSync(path.join(dir, 'test'), [], { encoding: 'utf8', timeout: 20000, env: { ...process.env, GLINT_TEST_HOME: dir } });
    process.stdout.write(run.stdout ?? ''); process.stderr.write(run.stderr ?? '');
    process.exitCode = run.status ?? 1;
    if (run.error) process.stderr.write(String(run.error));
  }
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
