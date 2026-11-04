import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const scratch = mkdtempSync(join(tmpdir(), 'glint-git-review-'));
let failures = 0;
let passed = 0;

/** Run an executable. Parameters: executable, argv, options. Returns stdout or throws on failure. */
function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, { encoding: 'utf8', ...options });
  assert.equal(result.status, 0, `${executable}: ${result.stderr || result.error}`);
  return result.stdout;
}

/** Extract one production Swift function. Parameters: source and signature. Returns its complete body. */
function extractFunction(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `Missing production function: ${signature}`);
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

/** Record a behavioral check without hiding other failures. Parameters: name and body. Returns nothing. */
function check(name, body) {
  try { body(); passed++; console.log(`PASS ${name}`); }
  catch (error) { failures++; console.error(`FAIL ${name}: ${error.message}`); }
}

try {
  const service = readFileSync(join(root, 'Glint/Git/GitService.swift'), 'utf8');
  const diff = readFileSync(join(root, 'Glint/Git/GitDiff.swift'), 'utf8');
  const review = readFileSync(join(root, 'Glint/Review/ReviewWindow.swift'), 'utf8');
  const reviewModel = review.slice(review.indexOf('@MainActor\nfinal class ReviewModel:'), review.indexOf('// MARK: - Root view'))
    .replace('ReviewModel: ObservableObject', 'ReviewModel').replaceAll('@Published ', '');
  // Compile the complete production diff extension; only the process runner and
  // unrelated application types are stand-ins, so command flags are exercised.
  const support = String.raw`
import Foundation
enum GitTimeout { case read }
struct GitResult { let exitCode: Int32; let stdout: String; let stderr: String; var wasSignaled = false; var ok: Bool { exitCode == 0 } }
enum GitError: Error { case commandFailed(args: [String], exitCode: Int32, stderr: String); case launchFailed(String) }
protocol GitRunner: Sendable {
    func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult
    func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int]
}
struct LocalGitRunner: GitRunner {
    /// Execute real Git. Parameters: argv and cwd. Returns decoded output and success.
    func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd.map { URL(fileURLWithPath: $0) }
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(exitCode: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self),
                         stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    /// Stub unused untracked counts. Parameters: repo and paths. Returns an empty map.
    func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int] { [:] }
}
struct GitService {
    var runner: any GitRunner = LocalGitRunner()
    GIT_FUNCTION
}
struct FailureRunner: GitRunner {
    let stage: String
    /// Simulate Git transport/command failures; parameters are argv/cwd/timeout; returns fixture output or throws.
    func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult {
        if stage == "launch" { throw GitError.launchFailed("unavailable") }
        if ["head-permission", "ref-permission"].contains(stage) {
            if args.first == "rev-parse" {
                return GitResult(exitCode: 1, stdout: "", stderr: stage == "head-permission" ? "permission denied" : "")
            }
            if args.first == "symbolic-ref" { return GitResult(exitCode: 0, stdout: "refs/heads/new\n", stderr: "") }
            if args.first == "show-ref" { return GitResult(exitCode: 1, stdout: "", stderr: "permission denied") }
        }
        if args.contains(stage) || (stage == "signal" && args.contains("--numstat")) {
            return GitResult(exitCode: stage == "signal" ? 0 : 128, stdout: "partial", stderr: "failed", wasSignaled: stage == "signal")
        }
        let out = args.contains("--name-status") ? "M\0file.txt\0" : args.contains("--numstat") ? "1\t1\tfile.txt\0" : args.contains("rev-parse") ? String(repeating: "a", count: 40) + "\n" : ""
        return GitResult(exitCode: 0, stdout: out, stderr: "")
    }
    /// Stub untracked counters; parameters are repo/paths; returns no counts.
    func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int] { [:] }
}
final class RecoveringRunner: GitRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String = "--name-status"
    /// Change the fixture failure; parameter is its stage; returns nothing.
    func setStage(_ stage: String) { lock.withLock { failure = stage } }
    /// Delegate fixture output; parameters are argv/cwd/timeout; returns result or throws.
    func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult {
        let stage = lock.withLock { failure }
        return try await FailureRunner(stage: stage).run(args, cwd: cwd, timeout: timeout)
    }
    /// Stub untracked counters; parameters are repo/paths; returns no counts.
    func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int] { [:] }
}
actor ReviewProbeRunner: GitRunner {
    private var calls: [[String]] = []
    private var head = String(repeating: "a", count: 40)
    private var blockNames = false
    private var gate: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    /// Record fixture reads with a controllable list gate; inputs mirror GitRunner; returns literal Git output.
    func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult {
        calls.append(args)
        if args.first == "rev-parse" { return GitResult(exitCode: 0, stdout: head + "\n", stderr: "") }
        if args.contains("--name-status") {
            if blockNames {
                blockNames = false
                await withCheckedContinuation { gate = $0; observers.forEach { $0.resume() }; observers.removeAll() }
            }
            return GitResult(exitCode: 0, stdout: "M\0file.txt\0", stderr: "")
        }
        if args.contains("--numstat") { return GitResult(exitCode: 0, stdout: "1\t1\tfile.txt\0", stderr: "") }
        if args.contains("--unified=1000000") { return GitResult(exitCode: 0, stdout: "@@ -1 +1 @@\n-old\n+new\n", stderr: "") }
        return GitResult(exitCode: 0, stdout: "", stderr: "")
    }
    /// Supply empty counts; inputs are repo and paths; returns no records.
    func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int] { [:] }
    /// Count one observable Git operation; input is its argv marker; returns recorded call count.
    func count(_ marker: String) -> Int { calls.filter { $0.contains(marker) }.count }
    /// Read baseline arguments used for file diffs; no inputs; returns their complete argv.
    func diffs() -> [[String]] { calls.filter { $0.contains("--unified=1000000") } }
    /// Change the next HEAD result; input is a complete OID; returns nothing.
    func setHead(_ oid: String) { head = oid }
    /// Suspend the next names request; no inputs or return value.
    func blockNextList() { blockNames = true }
    /// Observe the names request actually suspended; no inputs; returns after reaching the gate.
    func waitForList() async {
        if gate != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    /// Resume the controlled list request; no inputs or return value.
    func releaseList() { let old = gate; gate = nil; old?.resume() }
}
struct TreeNode {
    /// Stand in for UI tree layout; parameter is changed files; returns placeholder nodes.
    static func build(_ files: [GitFileChange]) -> [TreeNode] { files.map { _ in TreeNode() } }
}
struct CombinedGroup { let dir: String; let files: [GitFileChange] }
enum SyntaxLanguage {
    case plain
    /// Stand in for syntax choice; parameter is path; returns plain text.
    static func from(path: String) -> SyntaxLanguage { .plain }
}
struct DiffDocument {
    static let empty = DiffDocument(text: "", language: .plain)
    let text: String
    let language: SyntaxLanguage
}
`;
  const entry = String.raw`
struct Row: Encodable { let path: String; let kind: String; let additions: Int; let deletions: Int; let binary: Bool; let diff: String }
@main struct Regression {
    /// Drive production diff/quote functions. Parameters: command-line args. Returns JSON or shell token to stdout.
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args[1] == "quote" { print(SSHGitRunner.quoteRemoteCwd(args[2])); return }
        if args[1] == "parse" {
            let paths = ["中文.txt", "tab\tfile.txt", "line\nfile.txt", "quote\"file.txt"]
            let names = paths.map { "M\0" + $0 + "\0" }.joined() + "D\0mode.txt\0"
            let nums = paths.map { "2\t1\t" + $0 + "\0" }.joined() + "-\t-\tbinary.dat\0"
            let files = GitService.mergeNameNumstat(nameStatus: names, numstat: nums)
            let rows = files.values.sorted { $0.path < $1.path }.map { Row(path: $0.path, kind: $0.kind.rawValue, additions: $0.additions, deletions: $0.deletions, binary: $0.isBinary, diff: "") }
            print(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)); return
        }
        if args[1] == "failure" {
            let git = GitService(runner: FailureRunner(stage: args[2]))
            do {
                if args[2] == "diff" {
                    _ = try await git.fileDiff(repo: "unused", scope: .branch(base: "main"),
                        file: GitFileChange(path: "file.txt", kind: .modified, additions: 1, deletions: 1, isBinary: false))
                } else { _ = try await git.changedFiles(repo: "unused", scope: .workingTree) }
                print("false")
            } catch { print("true") }
            return
        }
        if args[1] == "partial-model" {
            let model = ReviewModel(repo: "unused", title: "Partial", scopes: [.workingTree], runner: FailureRunner(stage: "ls-files"))
            await model.reload()
            print(String(decoding: try JSONEncoder().encode([model.files.count == 1, model.filesError == nil, model.selected?.path == "file.txt", model.filesWarning != nil]), as: UTF8.self))
            return
        }
        if args[1] == "baseline-model" {
            let runner = ReviewProbeRunner()
            let model = ReviewModel(repo: "unused", title: "Baseline", scopes: [.workingTree], runner: runner)
            await model.reload()
            await model.select(model.files[0])
            let first = await runner.count("rev-parse") == 1
            await runner.setHead(String(repeating: "b", count: 40))
            await model.reload()
            let second = await runner.count("rev-parse") == 2
            let diffs = await runner.diffs()
            let pinned = diffs.count == 3 && diffs[0].contains(String(repeating: "a", count: 40)) && diffs[1].contains(String(repeating: "a", count: 40)) && diffs[2].contains(String(repeating: "b", count: 40))
            print(String(decoding: try JSONEncoder().encode([first, second, pinned]), as: UTF8.self)); return
        }
        if args[1] == "loading-model" {
            let runner = ReviewProbeRunner()
            let model = ReviewModel(repo: "unused", title: "Loading", scopes: [.workingTree], runner: runner)
            await model.reload()
            let old = model.files[0]
            await runner.blockNextList()
            let reload = Task { await model.reload() }
            await runner.waitForList()
            let loading = model.loadingFiles && model.diffText.isEmpty && model.selected == nil
            let before = await runner.count("--unified=1000000")
            await model.select(old)
            let ignored = await runner.count("--unified=1000000") == before
            await runner.releaseList()
            await reload.value
            let loaded = !model.loadingFiles && !model.loadingDiff && model.selected?.path == "file.txt" && !model.diffText.isEmpty
            print(String(decoding: try JSONEncoder().encode([loading, ignored, loaded]), as: UTF8.self)); return
        }
        if args[1] == "overlap-model" {
            let runner = ReviewProbeRunner()
            let model = ReviewModel(repo: "unused", title: "Overlap", scopes: [.workingTree], runner: runner)
            await runner.blockNextList()
            let old = Task { await model.reload() }
            await runner.waitForList()
            await runner.setHead(String(repeating: "b", count: 40))
            await model.reload()
            await runner.releaseList()
            await old.value
            await model.select(model.files[0])
            let diffs = await runner.diffs()
            let newest = diffs.last?.contains(String(repeating: "b", count: 40)) == true
            print(String(decoding: try JSONEncoder().encode([newest, !model.loadingFiles, !model.loadingDiff]), as: UTF8.self)); return
        }
        if args[1] == "snapshot-real" {
            let git = GitService()
            let first = try await git.reviewChanges(repo: args[2], scope: .workingTree)
            _ = try await git.git(["add", "."], cwd: args[2], timeout: .read)
            _ = try await git.git(["commit", "-qm", "advance HEAD"], cwd: args[2], timeout: .read)
            let diff = try await git.fileDiff(repo: args[2], scope: .workingTree, file: first.files[0], baseline: first.baseline)
            let second = try await git.reviewChanges(repo: args[2], scope: .workingTree)
            print(String(decoding: try JSONEncoder().encode(["pinned": diff.contains("-before") && diff.contains("+after"), "reload": first.baseline != second.baseline && second.files.isEmpty]), as: UTF8.self)); return
        }
        if args[1] == "model" {
            let runner = RecoveringRunner()
            let model = ReviewModel(repo: "unused", title: "Review", scopes: [.workingTree], runner: runner)
            let stale = GitFileChange(path: "stale", kind: .modified, additions: 1, deletions: 1, isBinary: false)
            model.files = [stale]; model.selected = stale; model.diffText = "old diff"
            await model.reload()
            let failed = model.filesError != nil && model.files.isEmpty && model.selected == nil && !model.loadingFiles && model.diffText.isEmpty
            runner.setStage("")
            await model.reload()
            let recovered = model.filesError == nil && model.files.count == 1 && model.selected?.path == "file.txt" && !model.loadingFiles
            runner.setStage("diff")
            await model.select(stale)
            let diffFailed = model.diffError != nil && model.diffText.isEmpty && !model.loadingDiff
            runner.setStage("")
            await model.select(stale)
            let diffRecovered = model.diffError == nil && !model.loadingDiff
            print(String(decoding: try JSONEncoder().encode([failed, recovered, diffFailed, diffRecovered]), as: UTF8.self))
            return
        }
        do {
        let scope: DiffScope = args[1] == "working" ? .workingTree : .branch(base: args[3])
        let git = GitService()
        var rows: [Row] = []
        for file in try await git.changedFiles(repo: args[2], scope: scope) {
            rows.append(Row(path: file.path, kind: file.kind.rawValue, additions: file.additions, deletions: file.deletions,
                            binary: file.isBinary, diff: try await git.fileDiff(repo: args[2], scope: scope, file: file)))
        }
        print(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))
        } catch { print("{\"error\":true}") }
    }
}
`;
  const swiftPath = join(scratch, 'Regression.swift');
  const executable = join(scratch, 'regression');
  writeFileSync(swiftPath, support.replace('GIT_FUNCTION', extractFunction(service, 'func git(_ args:')) + diff + '\n' + reviewModel + extractFunction(service, 'func posixShellQuoted(')
    + '\nenum SSHGitRunner {\n' + extractFunction(service, 'static func quoteRemoteCwd(') + '\n}\n' + entry);
  run('/usr/bin/swiftc', ['-parse-as-library', '-module-cache-path', join(scratch, 'cache'), swiftPath, '-o', executable]);

  const paths = ['中文.txt', 'tab\tfile.txt', 'line\nfile.txt', 'quote"file.txt'];
  check('NUL parsing preserves names, mode-only changes and binary counts', () => {
    const rows = JSON.parse(run(executable, ['parse']));
    assert.deepEqual(rows.map(row => row.path).sort(), [...paths, 'mode.txt', 'binary.dat'].sort());
    for (const path of paths) assert.deepEqual(rows.find(row => row.path === path),
      { path, kind: 'modified', additions: 2, deletions: 1, binary: false, diff: '' });
    assert.equal(rows.find(row => row.path === 'mode.txt').kind, 'deleted');
    assert.equal(rows.find(row => row.path === 'binary.dat').binary, true);
  });

  check('untracked enumeration failure keeps tracked changes available in Review', () => {
    assert.deepEqual(JSON.parse(run(executable, ['partial-model'])), [true, true, true, true]);
  });
  check('Review resolves a baseline once per reload and pins file selections to that OID', () => {
    assert.deepEqual(JSON.parse(run(executable, ['baseline-model'])), [true, true, true]);
  });
  check('Review refresh clears obsolete content and rejects old rows while the list is loading', () => {
    assert.deepEqual(JSON.parse(run(executable, ['loading-model'])), [true, true, true]);
  });
  check('late file-list loads cannot overwrite the newest comparison baseline', () => {
    assert.deepEqual(JSON.parse(run(executable, ['overlap-model'])), [true, true, true]);
  });
  const changing = join(scratch, 'changing');
  run('/usr/bin/git', ['init', '-q', changing]);
  run('/usr/bin/git', ['-C', changing, 'config', 'user.name', 'Regression']);
  run('/usr/bin/git', ['-C', changing, 'config', 'user.email', 'regression@example.invalid']);
  writeFileSync(join(changing, 'file.txt'), 'before\n');
  run('/usr/bin/git', ['-C', changing, 'add', '.']);
  run('/usr/bin/git', ['-C', changing, 'commit', '-qm', 'before']);
  writeFileSync(join(changing, 'file.txt'), 'after\n');
  check('a real commit between listing and selection does not change the loaded baseline', () => {
    assert.deepEqual(JSON.parse(run(executable, ['snapshot-real', changing])), { pinned: true, reload: true });
  });
  const unborn = join(scratch, 'unborn');
  run('/usr/bin/git', ['init', '-q', unborn]);
  writeFileSync(join(unborn, 'first.txt'), 'first change\n');
  run('/usr/bin/git', ['-C', unborn, 'add', '.']);
  writeFileSync(join(unborn, 'first.txt'), 'first change\nworking edit\n');
  check('initial repository includes staged files and subsequent working edits', () => {
    const rows = JSON.parse(run(executable, ['working', unborn]));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].path, 'first.txt');
    assert.equal(rows[0].kind, 'added');
    assert.equal(rows[0].additions, 2);
    assert.match(rows[0].diff, /\+first change/);
    assert.match(rows[0].diff, /\+working edit/);
  });
  const sha256 = join(scratch, 'sha256');
  const sha256Init = spawnSync('/usr/bin/git', ['init', '-q', '--object-format=sha256', sha256], { encoding: 'utf8' });
  if (sha256Init.status === 0) {
    writeFileSync(join(sha256, 'first.txt'), 'sha256 first change\n');
    run('/usr/bin/git', ['-C', sha256, 'add', '.']);
    check('SHA-256 initial repository uses its own empty-tree hash', () => {
      const rows = JSON.parse(run(executable, ['working', sha256]));
      assert.equal(rows.length, 1);
      assert.equal(rows[0].path, 'first.txt');
      assert.equal(rows[0].additions, 1);
      assert.match(rows[0].diff, /\+sha256 first change/);
    });
  } else {
    console.log('SKIP SHA-256 repository: installed Git does not support this object format');
  }
  const broken = join(scratch, 'broken');
  run('/usr/bin/git', ['init', '-q', broken]);
  const branch = run('/usr/bin/git', ['-C', broken, 'symbolic-ref', 'HEAD']).trim();
  writeFileSync(join(broken, '.git', branch), 'f'.repeat(40) + '\n');
  check('broken existing HEAD is not treated as an unborn branch', () => {
    assert.deepEqual(JSON.parse(run(executable, ['working', broken])), { error: true });
  });
  for (const stage of ['--name-status', '--numstat', 'diff', 'launch', 'signal', 'head-permission', 'ref-permission']) {
    check(`Git failure is surfaced for ${stage}`, () => {
      assert.equal(JSON.parse(run(executable, ['failure', stage])), true);
    });
  }
  check('Review model publishes list/diff errors, clears stale content and recovers on retry', () => {
    assert.deepEqual(JSON.parse(run(executable, ['model'])), [true, true, true, true]);
  });
  check('non-repository errors remain errors', () => {
    assert.deepEqual(JSON.parse(run(executable, ['working', scratch])), { error: true });
  });

  const repo = join(scratch, 'repo');
  run('/usr/bin/git', ['init', '-q', repo]);
  run('/usr/bin/git', ['-C', repo, 'config', 'user.name', 'Regression']);
  run('/usr/bin/git', ['-C', repo, 'config', 'user.email', 'regression@example.invalid']);
  run('/usr/bin/git', ['-C', repo, 'config', 'diff.renames', 'true']);
  for (const path of [...paths, 'old.txt']) writeFileSync(join(repo, path), 'old\n');
  run('/usr/bin/git', ['-C', repo, 'add', '.']);
  run('/usr/bin/git', ['-C', repo, 'commit', '-qm', 'base']);
  const base = run('/usr/bin/git', ['-C', repo, 'rev-parse', 'HEAD']).trim();
  for (const path of paths) writeFileSync(join(repo, path), 'new\n');
  run('/usr/bin/git', ['-C', repo, 'mv', 'old.txt', 'new.txt']);

  /** Validate Review rows against real files. Parameters: scope and arguments. Returns nothing. */
  function verifyScope(scope, args) {
    const rows = JSON.parse(run(executable, args));
    check(`${scope}: special filenames retain readable diffs and correct counts`, () => {
      for (const path of paths) {
        const row = rows.find(row => row.path === path);
        assert.ok(row, `Missing literal path ${JSON.stringify(path)}`);
        assert.equal(row.additions, 1); assert.equal(row.deletions, 1);
        assert.match(row.diff, /\+new/); assert.match(row.diff, /-old/);
      }
    });
    check(`${scope}: rename yields deletion and addition without phantom paths`, () => {
      assert.deepEqual(rows.map(row => row.path).sort(), [...paths, 'old.txt', 'new.txt'].sort());
      const old = rows.find(row => row.path === 'old.txt'), added = rows.find(row => row.path === 'new.txt');
      assert.equal(old.kind, 'deleted'); assert.equal(old.deletions, 1); assert.match(old.diff, /-old/);
      assert.equal(added.kind, 'added'); assert.equal(added.additions, 1); assert.match(added.diff, /\+old/);
    });
  }
  verifyScope('working tree', ['working', repo]);
  run('/usr/bin/git', ['-C', repo, 'add', '.']);
  run('/usr/bin/git', ['-C', repo, 'commit', '-qm', 'changes']);
  verifyScope('branch', ['branch', repo, base]);
  check('invalid branch baseline produces an error', () => {
    assert.deepEqual(JSON.parse(run(executable, ['branch', repo, 'does-not-exist'])), { error: true });
  });
  check('successful empty repository result remains empty', () => {
    assert.deepEqual(JSON.parse(run(executable, ['working', repo])), []);
  });
  writeFileSync(join(repo, 'untracked.txt'), 'fresh\n');
  check('no-index diff exit one remains a successful untracked diff', () => {
    const rows = JSON.parse(run(executable, ['working', repo]));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].kind, 'untracked');
    assert.match(rows[0].diff, /\+fresh/);
  });

  for (const shell of ['/bin/bash', '/bin/sh', '/bin/zsh']) {
    for (const path of ['~/code', '~/has space/a\'b;$(printf injected)`printf bad`', '~', '/absolute/a\'b;$(printf bad)', '~bad;rm/code']) {
      check(`${shell}: quotes ${JSON.stringify(path)} safely`, () => {
        const token = run(executable, ['quote', path]).trimEnd();
        const actual = run(shell, ['-c', `printf '%s' ${token}`]);
        const expected = path === '~' ? process.env.HOME : path.startsWith('~/') ? process.env.HOME + path.slice(1) : path;
        assert.equal(actual, expected);
      });
    }
    const username = run('/usr/bin/id', ['-un']).trim();
    check(`${shell}: named user tilde expands before quoted suffix`, () => {
      const token = run(executable, ['quote', `~${username}/has space`]).trimEnd();
      const home = run(shell, ['-c', `printf '%s' ~${username}`]);
      assert.equal(run(shell, ['-c', `printf '%s' ${token}`]), home + '/has space');
    });
  }
  console.log(`Git Review regression: ${passed} passed, ${failures} failed`);
  process.exitCode = failures ? 1 : 0;
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
