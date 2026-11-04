import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'Glint/WebRemote/WebRemoteServer.swift'), 'utf8');
const start = source.indexOf('struct WebRemoteOutboundBuffer {');
const end = source.indexOf('\nstruct WebRemoteAuthThrottle', start);
if (start < 0 || end < 0) throw new Error('Outbound extraction markers changed');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'glint-outbound-test-'));
/** Extract one production method; marker is its declaration; returns its body and signature. */
function method(marker) {
  const begin = source.indexOf(marker);
  if (begin < 0) throw new Error('Missing client method: ' + marker);
  const brace = source.indexOf('{', begin);
  let depth = 1;
  let finish = brace + 1;
  for (; finish < source.length && depth; finish++) {
    if (source[finish] === '{') depth++;
    if (source[finish] === '}') depth--;
  }
  return source.slice(begin, finish).replace(/^private /, '');
}
const client = String.raw`
final class SlowConnection {
    var cancellations = 0
    /// Record cancellation; no inputs; returns nothing.
    func cancel() { cancellations += 1 }
}
final class SlowClient {
    var cancelled = false
    var sendTimeout: DispatchWorkItem?
    var sendGeneration: UUID?
    var outbound = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 512 * 1024)
    var pendingSelectionOutput = WebRemoteOutputBuffer(byteLimit: 32)
    let connection = SlowConnection()
    /// Simulate an already blocked sender; no inputs or result; never dequeues.
    func sendNextIfNeeded() {}
` + method('func cancel() {') + '\n@discardableResult\n' + method('func send(_ data: Data)') + '\n}\n';
const tests = String.raw`
/// Assert a regression condition; value and label are inputs; returns nothing or exits.
func check(_ value: Bool, _ label: String) {
    guard value else { print("FAIL: \(label)"); exit(1) }
    print("PASS: \(label)")
}
var buffer = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 512 * 1024)
let image = Data(repeating: 1, count: 7 * 1024 * 1024)
buffer.enqueueMessage(image)
check(buffer.next() != nil, "legal base64 image fits ordinary response budget")
for _ in 0..<32 { buffer.enqueueMessage(Data(repeating: 1, count: 1024 * 1024)) }
var bytes = 0
while let item = buffer.next() {
    if case let .message(data) = item { bytes += data.count }
}
check(bytes <= 16 * 1024 * 1024, "ordinary responses obey total byte budget")
buffer.removeAll()
for _ in 0..<1000 { buffer.enqueueMessage(Data()) }
var count = 0
while buffer.next() != nil { count += 1 }
check(count <= 256, "zero-byte responses obey item budget")
check(buffer.enqueueTerminalOutput(Data(repeating: 2, count: 512 * 1024), pane: "a"), "terminal output fits its separate budget")
check(!buffer.enqueueTerminalOutput(Data([1]), pane: "a"), "terminal stream overflow is rejected")
buffer.removeAll()
check(buffer.enqueueTerminalOutput(Data([1]), pane: "a"), "cancel clears byte accounting")
var mixed = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 2, maxQueuedBytes: 10, maxQueuedItems: 3)
check(mixed.enqueueMessage(Data(repeating: 1, count: 8)), "ordinary message uses shared total")
check(!mixed.enqueueTerminalOutput(Data([1, 2, 3]), pane: "a"), "mixed queue cannot exceed shared bytes")
check(mixed.enqueueTerminalOutput(Data([1, 2]), pane: "a"), "mixed queue exact byte limit accepted")
check(!mixed.enqueueMessage(Data()), "ordinary messages obey shared item count")
_ = mixed.next()
check(mixed.enqueueMessage(Data(repeating: 1, count: 8)), "dequeue restores only consumed bytes")
mixed.removeAll()
check(mixed.enqueueMessage(Data(repeating: 1, count: 8)), "reset releases the full ordinary-response budget")
let slow = SlowClient()
for _ in 0..<3 { slow.send(image) }
check(!slow.cancelled && slow.connection.cancellations == 0, "temporary ordinary queue pressure preserves the terminal connection")
check(slow.outbound.next() != nil, "overflow preserves queued data for delivery")
slow.send(Data([1]))
check(!slow.cancelled, "ordinary queue overflow remains recoverable")
let large = SlowClient()
large.send(Data(repeating: 0x41, count: 17 * 1024 * 1024))
check(!large.cancelled, "one oversized message does not force a reconnect loop")
var notices = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 8, maxQueuedBytes: 64)
let fileReply = try! JSONSerialization.data(withJSONObject: [
    "type": "fileImage", "workspace": "workspace", "pane": "pane", "root": "/allowed",
    "path": "picture.png", "request": "request-7", "data": "payload",
])
notices.rejectMessage(fileReply)
guard case let .message(notice)? = notices.next(),
      let object = try! JSONSerialization.jsonObject(with: notice) as? [String: String] else { fatalError("missing rejection") }
check(object["type"] == "fileError" && object["code"] == "response-too-large", "oversized file produces a recoverable file error")
check(object["request"] == "request-7" && object["path"] == "picture.png" && object["root"] == "/allowed",
      "rejection preserves request identity and root")
for _ in 0..<1000 { notices.rejectMessage(fileReply) }
var noticeCount = 0
var noticeBytes = 0
while let next = notices.next() {
    if case let .message(data) = next { noticeCount += 1; noticeBytes += data.count }
}
check(noticeCount <= 33 && noticeBytes <= 64 * 1024 + 100, "error flood remains byte and item bounded")
check(notices.enqueueMessage(Data("snapshot".utf8)), "snapshot queues after notices drain")
check(notices.enqueueTerminalOutput(Data("ab".utf8), pane: "pane"), "snapshot's output queues behind it")
notices.rejectMessage(fileReply)
if case let .message(data)? = notices.next() { check(data == Data("snapshot".utf8), "older snapshots arrive before later rejection notices") }
else { fatalError("missing snapshot") }
if case let .terminalOutput(_, data)? = notices.next() { check(data == Data("ab".utf8), "notices do not reorder terminal bytes") }
else { fatalError("missing terminal output") }
if case let .message(data)? = notices.next(),
   let error = try! JSONSerialization.jsonObject(with: data) as? [String: String] {
    check(error["code"] == "response-too-large", "new rejection remains visible after older snapshot and output")
} else { fatalError("missing ordered rejection") }
var protectedBytes = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 4, maxQueuedBytes: 12, maxQueuedItems: 8)
for _ in 0..<4 { protectedBytes.enqueueMessage(Data(repeating: 1, count: 4)) }
check(protectedBytes.enqueueTerminalOutput(Data(repeating: 2, count: 4), pane: "pane"),
      "ordinary byte pressure leaves terminal stream capacity")
var protectedItems = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 4, maxQueuedBytes: 12, maxQueuedItems: 4)
for _ in 0..<4 { protectedItems.enqueueMessage(Data()) }
check(protectedItems.enqueueTerminalOutput(Data([1]), pane: "pane"),
      "ordinary item pressure leaves a terminal stream slot")
var interleaved = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 4, maxQueuedBytes: 16, maxQueuedItems: 3)
_ = interleaved.enqueueTerminalOutput(Data([1]), pane: "pane")
_ = interleaved.enqueueMessage(Data([2]))
_ = interleaved.enqueueMessage(Data([3]))
check(interleaved.enqueueTerminalOutput(Data([4]), pane: "pane"), "interleaved messages preserve a slot for the next terminal segment")
var snapshotBoundary = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 16, maxQueuedBytes: 128)
let failedSnapshot = try! JSONSerialization.data(withJSONObject: ["type": "snapshot", "pane": "pane", "data": String(repeating: "x", count: 200)])
_ = snapshotBoundary.enqueueTerminalOutput(Data("old".utf8), pane: "pane")
snapshotBoundary.rejectMessage(failedSnapshot)
_ = snapshotBoundary.enqueueTerminalOutput(Data("new".utf8), pane: "pane")
if case let .terminalOutput(_, data)? = snapshotBoundary.next() { check(data == Data("old".utf8), "snapshot rejection prevents cross-boundary output coalescing") }
else { fatalError("missing old output") }
_ = snapshotBoundary.next()
if case let .terminalOutput(_, data)? = snapshotBoundary.next() { check(data == Data("new".utf8), "post-boundary bytes follow the snapshot error") }
else { fatalError("missing new output") }
var fileBoundary = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 16, maxQueuedBytes: 128)
_ = fileBoundary.enqueueTerminalOutput(Data("old".utf8), pane: "pane")
fileBoundary.rejectMessage(fileReply)
_ = fileBoundary.enqueueTerminalOutput(Data("new".utf8), pane: "pane")
if case let .terminalOutput(_, data)? = fileBoundary.next() { check(data == Data("oldnew".utf8), "independent file errors do not fragment or revoke the terminal stream") }
else { fatalError("missing terminal output") }
var saturated = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 8, maxQueuedBytes: 512, maxQueuedItems: 4)
let oldSnapshot = try! JSONSerialization.data(withJSONObject: ["type": "snapshot", "pane": "pane", "data": "old"])
let freshSnapshot = try! JSONSerialization.data(withJSONObject: ["type": "snapshot", "pane": "pane", "data": "fresh"])
_ = saturated.enqueueMessage(oldSnapshot)
_ = saturated.enqueueMessage(Data("state-one".utf8))
_ = saturated.enqueueMessage(Data("state-two".utf8))
for _ in 0..<32 { saturated.rejectMessage(fileReply) }
saturated.rejectMessage(freshSnapshot)
var ordered: [[String: String]] = []
if case let .message(data)? = saturated.next() {
    ordered.append((try! JSONSerialization.jsonObject(with: data)) as! [String: String])
}
check(saturated.enqueueMessage(freshSnapshot), "a later successful snapshot fits after old data drains")
while let next = saturated.next() {
    if case let .message(data) = next,
       let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] { ordered.append(value) }
}
let oldPosition = ordered.firstIndex { $0["type"] == "snapshot" && $0["data"] == "old" }
let rejectionPosition = ordered.firstIndex { $0["code"] == "snapshot-busy" && $0["pane"] == "pane" }
let freshPosition = ordered.firstIndex { $0["type"] == "snapshot" && $0["data"] == "fresh" }
check(oldPosition != nil && rejectionPosition != nil && freshPosition != nil,
      "saturated file notices cannot erase a pane's snapshot rejection")
check(oldPosition! < rejectionPosition! && rejectionPosition! < freshPosition!,
      "old snapshot, control rejection and successful retry retain causal order")
var controlFlood = WebRemoteOutboundBuffer(maxQueuedOutputBytes: 8, maxQueuedBytes: 512)
for _ in 0..<1000 { controlFlood.rejectMessage(fileReply); controlFlood.rejectMessage(freshSnapshot) }
var controlNoticeCount = 0
var controlNoticeBytes = 0
var snapshotNoticeCount = 0
while let next = controlFlood.next() {
    if case let .message(data) = next {
        controlNoticeCount += 1; controlNoticeBytes += data.count
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        if object["code"] == "snapshot-busy" { snapshotNoticeCount += 1 }
    }
}
check(controlNoticeCount <= 34 && controlNoticeBytes <= 64 * 1024 + 2200 && snapshotNoticeCount == 1,
      "a snapshot error flood retains one bounded latest control notice")
let longPane = String(repeating: "\u{1}", count: 100_000)
controlFlood.rejectMessage(try! JSONSerialization.data(withJSONObject: ["type": "snapshot", "pane": longPane]))
if case let .message(data)? = controlFlood.next() {
    check(data.count <= 2048, "the reserved snapshot notice has a fixed byte bound even for malformed metadata")
} else { fatalError("missing bounded snapshot notice") }
`;
try {
  fs.writeFileSync(path.join(dir, 'main.swift'), 'import Foundation\n' + source.slice(source.indexOf('struct WebRemoteOutputBuffer {'), end) + client + tests);
  const build = spawnSync('swiftc', ['-swift-version', '5', '-module-cache-path', path.join(dir, 'cache'), path.join(dir, 'main.swift'), '-o', path.join(dir, 'test')], { encoding: 'utf8', timeout: 60000 });
  process.stderr.write(build.stderr ?? '');
  if (build.status !== 0) process.exitCode = 1;
  else {
    const run = spawnSync(path.join(dir, 'test'), [], { encoding: 'utf8', timeout: 10000 });
    process.stdout.write(run.stdout ?? ''); process.stderr.write(run.stderr ?? '');
    process.exitCode = run.status ?? 1;
  }
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
