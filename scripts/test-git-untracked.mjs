import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Extract a production Swift declaration; parameters are source/signature; returns the declaration body. */
function declaration(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, signature);
  const open = source.indexOf('{', start);
  let depth = 1;
  let end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}

test('untracked line counts preserve Git semantics and enforce bounded reads', async t => {
  const scratch = mkdtempSync(join(tmpdir(), 'glint-count-regression-'));
  try {
    const source = readFileSync(join(root, 'Glint/Git/GitService.swift'), 'utf8');
    const limit = source.match(/maxLocalCountBytes\s*=\s*([\d_]+)/)?.[1];
    assert.ok(limit);
    const count = declaration(source, 'private static func addCountFromBytes(')
      .replace('private static', 'static').replaceAll('FileHandle', 'ObservedFileHandle')
      .replaceAll('Darwin.open(', 'observedOpen(').replaceAll('Darwin.close(', 'observedClose(');
    // The observer forwards the actual read to Foundation and can grow a real
    // file between preflight and opening. The counting implementation is unchanged.
    const harness = String.raw`
import Foundation
import Darwin
enum IOObservation {
    static var requested: [Int] = []; static var opened = 0; static var growAtOpen = false
    static var growBeforeRead = false; static var failRead = false; static var path = ""; static var race = ""
    static var descriptors: [Int32] = []; static var closed: [Int32] = []
}
/// Replace a preflighted path; parameter is its path; returns nothing or throws.
func performOpenRace(_ path: String) throws {
    IOObservation.path = path
    if IOObservation.growAtOpen {
        try Data(repeating: 0x0A, count: Counts.maxLocalCountBytes + 200).write(to: URL(fileURLWithPath: path))
    }
    if IOObservation.race == "fifo" {
        try FileManager.default.removeItem(atPath: path)
        guard mkfifo(path, 0o600) == 0 else { fatalError("mkfifo failed") }
    } else if IOObservation.race == "symlink" {
        let target = path + ".target"
        try Data("target contents\n".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
}
/// Observe a real open after racing; parameters are path/flags; returns its actual descriptor.
func observedOpen(_ path: String, _ flags: Int32) -> Int32 {
    IOObservation.opened += 1
    do { try performOpenRace(path) } catch { fatalError("fixture replacement failed") }
    let fd = Darwin.open(path, flags)
    if fd >= 0 { IOObservation.descriptors.append(fd) }
    return fd
}
/// Record real descriptor closure; parameter is descriptor; returns Darwin's close result.
func observedClose(_ descriptor: Int32) -> Int32 {
    IOObservation.closed.append(descriptor)
    return Darwin.close(descriptor)
}
final class ObservedFileHandle {
    let real: FileHandle
    /// Open a real file after optional growth; parameter is its URL; returns a handle or throws.
    init(forReadingFrom url: URL) throws {
        IOObservation.opened += 1
        try performOpenRace(url.path)
        real = try FileHandle(forReadingFrom: url)
    }
    /// Wrap the production descriptor; parameters are descriptor/ownership; returns a Foundation handle.
    init(fileDescriptor: Int32, closeOnDealloc: Bool) {
        real = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: closeOnDealloc)
    }
    /// Forward a bounded read; parameter is the byte cap; returns real bytes or throws.
    func read(upToCount count: Int) throws -> Data? {
        IOObservation.requested.append(count)
        if IOObservation.failRead { throw CocoaError(.fileReadUnknown) }
        if IOObservation.growBeforeRead {
            let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: IOObservation.path))
            defer { try? writer.close() }
            try writer.write(contentsOf: Data(repeating: 0x0A, count: Counts.maxLocalCountBytes + 200))
        }
        return try real.read(upToCount: count)
    }
    /// Close the forwarded handle; no parameters; returns nothing or throws.
    func close() throws { try real.close() }
}
enum Counts {
    static let maxLocalCountBytes = LIMIT
    COUNT
}
var failures = 0
/// Assert one behavior; parameters are condition/name; returns nothing and records failure.
func verify(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}
let dir = CommandLine.arguments[1]
if CommandLine.arguments.count > 2 {
    let mode = CommandLine.arguments[2]
    let path = dir + "/race-" + mode
    try Data("original\n".utf8).write(to: URL(fileURLWithPath: path))
    if mode == "growth-before" { IOObservation.growAtOpen = true }
    else if mode == "read-error" { IOObservation.failRead = true }
    else { IOObservation.race = mode }
    let result = Counts.addCountFromBytes(repo: dir, relPath: "race-" + mode)
    verify(result == 0, "\(mode) replacement is rejected")
    verify(mode == "read-error" ? IOObservation.requested == [Counts.maxLocalCountBytes + 1] : IOObservation.requested.isEmpty,
           "\(mode) read attempt matches policy")
    verify(IOObservation.descriptors == IOObservation.closed, "\(mode) descriptors are closed")
    if failures > 0 { exit(1) }
    exit(0)
}
/// Count fixture bytes through production code; parameter is file data; returns additions.
func count(_ bytes: Data) throws -> Int {
    IOObservation.requested = []; IOObservation.opened = 0
    try bytes.write(to: URL(fileURLWithPath: dir + "/file"))
    return Counts.addCountFromBytes(repo: dir, relPath: "file")
}
verify(try count(Data()) == 0, "empty")
verify(try count(Data("one\ntwo\n".utf8)) == 2, "LF text")
verify(try count(Data("one\ntwo".utf8)) == 2, "missing trailing LF")
verify(try count(Data([0xFF, 0x0A, 0xFE])) == 2, "non UTF-8 text")
verify(try count(Data([0, 0x0A])) == 0, "binary probe")
verify(try count(Data(repeating: 0x41, count: 8001) + Data([0, 0x0A])) == 1, "tail NUL stays text")
verify(try count(Data(repeating: 0x0A, count: Counts.maxLocalCountBytes)) == Counts.maxLocalCountBytes, "exact limit")
verify(IOObservation.requested == [Counts.maxLocalCountBytes + 1], "actual read uses limit plus one")
verify(try count(Data(repeating: 0x0A, count: Counts.maxLocalCountBytes + 1)) == 0, "oversized file")
verify(IOObservation.opened == 0, "oversized preflight prevents opening")
IOObservation.growBeforeRead = true
verify(try count(Data("small\n".utf8)) == 0, "file growth after preflight is rejected")
verify(IOObservation.requested == [Counts.maxLocalCountBytes + 1], "growing file read remains bounded")
IOObservation.growBeforeRead = false
IOObservation.opened = 0
verify(Counts.addCountFromBytes(repo: dir, relPath: ".") == 0, "directory skipped")
verify(IOObservation.opened == 0, "non-regular file preflight prevents opening")
try FileManager.default.createSymbolicLink(atPath: dir + "/symlink", withDestinationPath: dir + "/file")
verify(Counts.addCountFromBytes(repo: dir, relPath: "symlink") == 0, "symlink skipped")
verify(IOObservation.opened == 0, "symlink does not follow target")
verify(Counts.addCountFromBytes(repo: dir, relPath: "missing") == 0, "missing file")
verify(IOObservation.descriptors == IOObservation.closed, "all normal descriptors are closed")
if failures > 0 { exit(1) }
`;
    const swift = join(scratch, 'main.swift');
    const executable = join(scratch, 'count');
    writeFileSync(swift, harness.replace('LIMIT', limit).replace('COUNT', count));
    const compile = spawnSync('/usr/bin/swiftc', ['-module-cache-path', join(scratch, 'cache'), swift, '-o', executable], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(executable, [scratch], { encoding: 'utf8' });
    console.log(result.stdout);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    for (const race of ['fifo', 'symlink', 'growth-before', 'read-error']) {
      await t.test(`path replacement before open: ${race}`, () => {
        const raced = spawnSync(executable, [scratch, race], { encoding: 'utf8', timeout: 3000 });
        console.log(raced.stdout);
        assert.equal(raced.error?.code, undefined, `blocked read: ${raced.error?.message}`);
        assert.equal(raced.status, 0, raced.stderr || raced.stdout);
      });
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
