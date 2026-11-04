import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(path.join(root, "Glint/Agent/UsageStore.swift"), "utf8");
const start = source.indexOf("struct AgentQuota:");
const end = source.indexOf("// MARK: - Codex (disk)");
assert.ok(start >= 0 && end > start, "UsageStore extraction markers changed");
const homesSource = fs.readFileSync(path.join(root, "Glint/Agent/CodexHome.swift"), "utf8");
const homeEnd = homesSource.indexOf("@MainActor\nfinal class CodexHomeStore:");
assert.ok(homeEnd > 0, "CodexHome extraction markers changed");

/** Keep a real reader declaration while replacing its body; input identifies reader and probe; returns a safe Swift enum. */
function probeReader({ type, method, body, documentation }) {
  const enumStart = source.indexOf(`enum ${type} {`);
  assert.ok(enumStart >= 0, `Missing reader ${type}`);
  const declarationStart = source.indexOf(`    static func ${method}(`, enumStart);
  const bodyStart = source.indexOf("{", declarationStart);
  assert.ok(declarationStart > enumStart && bodyStart > declarationStart, `Missing declaration ${type}.${method}`);
  const declaration = source.slice(declarationStart, bodyStart).trimEnd();
  assert.match(declaration, /\)\s+async\s+->\s+AgentQuota\?$/,
    `Unexpected return contract for ${type}.${method}`);
  return `enum ${type} {\n    /// ${documentation}\n${declaration} {\n        ${body}\n    }\n}\n`;
}

// Compile the shipped store and data models, replacing only platform wrappers,
// settings persistence and external readers. Every request suspends on a test
// continuation; this runner never opens auth files, keychains, hooks or sockets.
// Reader argument labels, types and defaults are copied from production so an
// invalid function reference cannot compile merely because a stub lost inputs.
const stubs = `import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    /// Wrap an observable test value; input is the initial value; returns its wrapper.
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    /// Read an in-memory preference; input is its key; returns its stored value.
    func object(forKey key: String) -> Any? { values[key] }
    /// Read in-memory data; input is its key; returns data when present.
    func data(forKey key: String) -> Data? { values[key] as? Data }
    /// Set an in-memory preference; inputs are value and key; returns nothing.
    func set(_ value: Any, forKey key: String) { values[key] = value }
    /// Remove an in-memory preference; input is its key; returns nothing.
    func removeObject(forKey key: String) { values[key] = nil }
    /// Reset test preferences; takes no inputs and returns nothing.
    func reset() { values.removeAll() }
}
@MainActor enum CodexHomeStore {
    static var homes: [CodexHome] = []
    /// Return configured test homes; takes no inputs; returns the test snapshot.
    static func configuredHomes() -> [CodexHome] { homes }
}
enum CodexHookInstaller {
    /// Avoid hook filesystem access; input is a home URL; returns a placeholder.
    static func status(in home: URL) -> CodexHookStatus { .installed }
}
enum CodexLiveReader {
    /// Avoid credential access; input is a home URL; returns a placeholder.
    static func authStatus(from home: URL) -> CodexAuthStatus { .found }
}
${probeReader({ type: "CodexUsageReader", method: "readPreferLive", body: "await Probe.shared.read(codexHome.path)",
  documentation: "Suspend a test quota request; input is its home; returns the injected quota." })}
${probeReader({ type: "ClaudeUsageReader", method: "read", body: 'await Probe.shared.read("claude")',
  documentation: "Suspend a test quota request; takes no inputs; returns the injected quota." })}
${probeReader({ type: "GrokUsageReader", method: "read", body: 'await Probe.shared.read("grok")',
  documentation: "Suspend a test quota request; input is its optional home; returns the injected quota." })}
actor Probe {
    static let shared = Probe()
    private var counts: [String: Int] = [:]
    private var continuations: [String: [Int: CheckedContinuation<AgentQuota?, Never>]] = [:]
    private var cancelled: Set<String> = []
    /// Record and suspend a request, deliberately tolerating cancellation; input is its source; returns an injected quota.
    func read(_ key: String) async -> AgentQuota? {
        let index = (counts[key] ?? 0) + 1
        counts[key] = index
        let result: AgentQuota? = await withCheckedContinuation { continuation in
            continuations[key, default: [:]][index] = continuation
        }
        if Task.isCancelled { cancelled.insert("\\(key)#\\(index)") }
        return result
    }
    /// Count requests; input is their source; returns the number started.
    func count(_ key: String) -> Int { counts[key] ?? 0 }
    /// Complete one request; inputs are source, index and quota; returns nothing.
    func complete(_ key: String, index: Int = 1, percent: Double?) {
        let quota = percent.map { AgentQuota(sessionPercent: $0, weeklyPercent: nil, sessionResetsAt: nil, weeklyResetsAt: nil, planType: nil) }
        continuations[key]?[index]?.resume(returning: quota)
        continuations[key]?[index] = nil
    }
    /// Inspect cancellation; inputs are source and index; returns whether its reader was cancelled.
    func wasCancelled(_ key: String, index: Int = 1) -> Bool { cancelled.contains("\\(key)#\\(index)") }
    /// Complete all pending reads; takes no inputs and returns nothing.
    func finishAll() {
        let pending = continuations.values.flatMap { $0.values }
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: nil) }
    }
    /// Reset counters after completion; takes no inputs and returns nothing.
    func reset() { counts.removeAll(); cancelled.removeAll() }
}
struct Failure: Error { let message: String }
/// Check a behavior; inputs are its condition and failure explanation; throws on failure.
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
`;
const tests = `
@MainActor enum RefreshTests {
    static var stores: [UsageStore] = []
    static var refreshTimeout: TimeInterval = 30
    /// Drain runnable main-actor work without wall-clock sleeps; takes no inputs; returns nothing.
    static func settle() async { for _ in 0..<100 { await Task.yield() } }
    /// Create a store with isolated enabled flags; inputs are enabled agents; returns the store.
    static func store(claude: Bool = false, codex: Bool = false, grok: Bool = false) -> UsageStore {
        UserDefaults.standard.set(claude, forKey: "glint.showClaudeUsage")
        UserDefaults.standard.set(codex, forKey: "glint.showCodexUsage")
        UserDefaults.standard.set(grok, forKey: "glint.showGrokUsage")
        let result = UsageStore(refreshTimeout: refreshTimeout)
        stores.append(result)
        return result
    }
    /// Disable stores and drain readers after each case; takes no inputs; returns nothing.
    static func cleanup() async {
        for store in stores { store.claudeEnabled = false; store.codexEnabled = false; store.grokEnabled = false }
        await Probe.shared.finishAll()
        await settle()
        stores.removeAll()
        await Probe.shared.reset()
        UserDefaults.standard.reset()
        CodexHomeStore.homes = []
        refreshTimeout = 30
    }
    /// A first enable must issue one read; takes no inputs; throws on mismatch.
    static func firstEnable() async throws {
        let usage = store()
        usage.claudeEnabled = true
        await settle()
        try expect(await Probe.shared.count("claude") == 1, "first enable sent duplicate quota requests")
        let grok = store()
        grok.grokEnabled = true
        let home = CodexHome(path: "/tmp/glint-first-enable")
        CodexHomeStore.homes = [home]
        let codex = store()
        codex.codexEnabled = true
        await settle()
        try expect(await Probe.shared.count("grok") == 1, "first Grok enable sent duplicate requests")
        try expect(await Probe.shared.count(home.resolvedURL.path) == 1, "first Codex enable sent duplicate requests")
    }
    /// Manual refreshes must share per-agent pending work; takes no inputs; throws on mismatch.
    static func agentCoalescing() async throws {
        let usage = store(claude: true, grok: true)
        await settle()
        usage.refreshNow(); usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count("claude") == 1, "Claude refreshes were not coalesced")
        try expect(await Probe.shared.count("grok") == 1, "Grok refreshes were not coalesced")
    }
    /// A disabled and reenabled agent rejects its old result; takes no inputs; throws on mismatch.
    static func agentCancellation() async throws {
        let usage = store(claude: true)
        await settle()
        usage.claudeEnabled = false
        usage.claudeEnabled = true
        await settle()
        await Probe.shared.complete("claude", index: 2, percent: 70)
        await settle()
        await Probe.shared.complete("claude", percent: 10)
        await settle()
        try expect(usage.claude?.sessionPercent == 70, "late Claude quota overwrote the new enable cycle")
        try expect(await Probe.shared.wasCancelled("claude"), "disabled Claude request was not cancelled")
    }
    /// Grok rejects the previous enable cycle's response; takes no inputs; throws on mismatch.
    static func grokCancellation() async throws {
        let usage = store(grok: true)
        await settle()
        usage.grokEnabled = false; usage.grokEnabled = true
        await settle()
        await Probe.shared.complete("grok", index: 2, percent: 65)
        await settle()
        await Probe.shared.complete("grok", percent: 5)
        await settle()
        try expect(usage.grok?.sessionPercent == 65, "late Grok quota overwrote a fresh result")
        try expect(await Probe.shared.wasCancelled("grok"), "disabled Grok request was not cancelled")
    }
    /// Multiple homes each share one pending read; takes no inputs; throws on mismatch.
    static func homeCoalescing() async throws {
        CodexHomeStore.homes = [CodexHome(path: "/tmp/glint-home-A"), CodexHome(path: "/tmp/glint-home-B")]
        let usage = store(codex: true)
        await settle()
        usage.refreshNow(); usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count("/tmp/glint-home-A") == 1, "home A has overlapping reads")
        try expect(await Probe.shared.count("/tmp/glint-home-B") == 1, "home B has overlapping reads")
    }
    /// Editing enabled homes preserves unaffected reads and cancels removed work; takes no inputs; throws on mismatch.
    static func homeChanges() async throws {
        let a = CodexHome(path: "/tmp/glint-home-A"), b = CodexHome(path: "/tmp/glint-home-B")
        let c = CodexHome(path: "/tmp/glint-home-C")
        CodexHomeStore.homes = [a, b]
        let usage = store(codex: true)
        await settle()
        CodexHomeStore.homes = [a, c]
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count(a.resolvedURL.path) == 1, "changing home B restarted unchanged home A")
        await Probe.shared.complete(c.resolvedURL.path, percent: 40)
        await Probe.shared.complete(a.resolvedURL.path, percent: 20)
        await Probe.shared.complete(b.resolvedURL.path, percent: 99)
        await settle()
        try expect(Set(usage.codexHomeStatuses.map(\\.id)) == Set([a.id, c.id]), "removed home appeared in the final quota rows")
        try expect(await Probe.shared.wasCancelled(b.resolvedURL.path), "removed home request was not cancelled")
    }
    /// A changed path with the same home ID cannot publish the old path's result; takes no inputs; throws on mismatch.
    static func homePathChange() async throws {
        let a = CodexHome(path: "/tmp/glint-home-old")
        CodexHomeStore.homes = [a]
        let usage = store(codex: true)
        await settle()
        var updated = a; updated.path = "/tmp/glint-home-new"
        CodexHomeStore.homes = [updated]
        usage.refreshNow()
        await settle()
        await Probe.shared.complete(updated.resolvedURL.path, percent: 35)
        await settle()
        await Probe.shared.complete(a.resolvedURL.path, percent: 95)
        await settle()
        try expect(usage.codex?.sessionPercent == 35, "old home path overwrote current quota")
        try expect(usage.codexHomeStatuses.first?.resolvedURL == updated.resolvedURL, "old home path remained visible")
        try expect(await Probe.shared.wasCancelled(a.resolvedURL.path), "changed home path request was not cancelled")
    }
    /// Disabling usage cancels Codex readers and prevents late publication; takes no inputs; throws on mismatch.
    static func homeDisable() async throws {
        let home = CodexHome(path: "/tmp/glint-home-disabled")
        CodexHomeStore.homes = [home]
        let usage = store(codex: true)
        await settle()
        usage.codexEnabled = false
        await Probe.shared.complete(home.resolvedURL.path, percent: 88)
        await settle()
        try expect(usage.codex == nil && usage.codexHomeStatuses.isEmpty, "disabled Codex published a late quota")
        try expect(await Probe.shared.wasCancelled(home.resolvedURL.path), "disabled Codex read was not cancelled")
    }
    /// Completed and failed work frees its slot for the next poll; takes no inputs; throws on mismatch.
    static func completedRefreshCanRepeat() async throws {
        let usage = store(claude: true, grok: true)
        await settle()
        await Probe.shared.complete("claude", percent: 25)
        await Probe.shared.complete("grok", percent: nil)
        await settle()
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count("claude") == 2, "completed Claude task was never released")
        try expect(await Probe.shared.count("grok") == 2, "failed Grok task was never released")
        await Probe.shared.complete("claude", index: 2, percent: nil)
        await settle()
        try expect(usage.claude?.sessionPercent == 25, "transient failure erased the last known quota")
    }
    /// Renaming a pending home reuses its request and latest metadata; takes no inputs; throws on mismatch.
    static func homeRename() async throws {
        var home = CodexHome(label: "Before", path: "/tmp/glint-home-rename")
        CodexHomeStore.homes = [home]
        let usage = store(codex: true)
        await settle()
        home.label = "After"
        CodexHomeStore.homes = [home]
        usage.refreshNow()
        await settle()
        await Probe.shared.complete(home.resolvedURL.path, percent: 40)
        await settle()
        try expect(await Probe.shared.count(home.resolvedURL.path) == 1, "renaming restarted a pending home read")
        try expect(usage.codexHomeStatuses.first?.home.label == "After", "completed home read reverted its label")
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count(home.resolvedURL.path) == 2, "completed home task was not released")
    }
    /// A hung agent read must release its refresh slot and reject late results; no inputs; throws on mismatch.
    static func agentDeadline() async throws {
        refreshTimeout = 0.2
        let usage = store(claude: true, grok: true)
        await settle()
        try await Task.sleep(nanoseconds: 350_000_000)
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count("claude") == 2, "hung Claude read permanently blocked refresh")
        try expect(await Probe.shared.count("grok") == 2, "hung Grok read permanently blocked refresh")
        await Probe.shared.complete("claude", index: 2, percent: 60)
        await Probe.shared.complete("grok", index: 2, percent: 70)
        await settle()
        await Probe.shared.complete("claude", percent: 1)
        await Probe.shared.complete("grok", percent: 2)
        await settle()
        try expect(usage.claude?.sessionPercent == 60 && usage.grok?.sessionPercent == 70, "timed-out agent result overwrote a newer quota")
        let claudeCancelled = await Probe.shared.wasCancelled("claude")
        let grokCancelled = await Probe.shared.wasCancelled("grok")
        try expect(claudeCancelled && grokCancelled, "expired agent reads were not cancelled")
    }
    /// Hung homes must release slots without erasing previously available quota; no inputs; throws on mismatch.
    static func homeDeadline() async throws {
        refreshTimeout = 0.2
        let home = CodexHome(path: "/tmp/glint-home-timeout")
        CodexHomeStore.homes = [home]
        let usage = store(codex: true)
        await settle()
        await Probe.shared.complete(home.resolvedURL.path, percent: 35)
        await settle()
        usage.refreshNow()
        await settle()
        try await Task.sleep(nanoseconds: 350_000_000)
        try expect(usage.codex?.sessionPercent == 35, "home timeout erased the last known quota")
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count(home.resolvedURL.path) == 3, "hung home read permanently blocked refresh")
        await Probe.shared.complete(home.resolvedURL.path, index: 3, percent: 45)
        await settle()
        await Probe.shared.complete(home.resolvedURL.path, index: 2, percent: 99)
        await settle()
        try expect(usage.codex?.sessionPercent == 45, "expired home result replaced a later successful refresh")
        try expect(await Probe.shared.wasCancelled(home.resolvedURL.path, index: 2), "expired home request was not cancelled")
    }
    /// Repeated hung reads may retry and a completed request's timer cannot clear a later request; no inputs; throws on mismatch.
    static func repeatedDeadline() async throws {
        refreshTimeout = 0.2
        let usage = store(claude: true)
        await settle()
        try await Task.sleep(nanoseconds: 350_000_000)
        usage.refreshNow()
        await settle()
        try await Task.sleep(nanoseconds: 350_000_000)
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count("claude") == 3, "second timeout left the refresh slot occupied")
        await Probe.shared.complete("claude", index: 3, percent: 55)
        await settle()
        usage.refreshNow()
        await settle()
        await Probe.shared.complete("claude", index: 4, percent: 65)
        await settle()
        await Probe.shared.complete("claude", index: 1, percent: 95)
        await Probe.shared.complete("claude", index: 2, percent: 85)
        await settle()
        try expect(usage.claude?.sessionPercent == 65, "orphaned deadline/read changed a newer completed quota")
    }
    /// A first home timeout must end its initial loading indicator; no inputs; throws on mismatch.
    static func firstHomeDeadline() async throws {
        refreshTimeout = 0.2
        let home = CodexHome(path: "/tmp/glint-first-home-timeout")
        CodexHomeStore.homes = [home]
        let usage = store(codex: true)
        await settle()
        try await Task.sleep(nanoseconds: 350_000_000)
        if case .loading = usage.codexHomeStatuses.first?.quotaStatus {
            throw Failure(message: "home timeout left its loading indicator running forever")
        }
        usage.refreshNow()
        await settle()
        try expect(await Probe.shared.count(home.resolvedURL.path) == 2, "initial home timeout did not permit retry")
    }
    /// Dropping a store cancels its readers without retaining the store; takes no inputs; throws on mismatch.
    static func deallocation() async throws {
        let home = CodexHome(path: "/tmp/glint-home-deinit")
        CodexHomeStore.homes = [home]
        var usage: UsageStore? = store(claude: true, codex: true, grok: true)
        weak var released = usage
        await settle()
        stores.removeAll()
        usage = nil
        await settle()
        try expect(released == nil, "pending reads retained the UsageStore")
        await Probe.shared.finishAll()
        await settle()
        try expect(await Probe.shared.wasCancelled("claude"), "deinit did not cancel Claude")
        try expect(await Probe.shared.wasCancelled("grok"), "deinit did not cancel Grok")
        try expect(await Probe.shared.wasCancelled(home.resolvedURL.path), "deinit did not cancel Codex")
        released = nil
    }
}
@main struct Runner {
    /// Run isolated behavior regressions; takes no inputs; exits nonzero on failure.
    @MainActor static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("first enable performs one request", RefreshTests.firstEnable),
            ("pending agent requests coalesce", RefreshTests.agentCoalescing),
            ("Claude enable cycles cancel and reject stale results", RefreshTests.agentCancellation),
            ("Grok enable cycles cancel and reject stale results", RefreshTests.grokCancellation),
            ("pending requests coalesce per Codex home", RefreshTests.homeCoalescing),
            ("home changes preserve unaffected work", RefreshTests.homeChanges),
            ("changed home paths cannot publish old results", RefreshTests.homePathChange),
            ("disabling Codex cancels pending work", RefreshTests.homeDisable),
            ("completed work permits subsequent polls", RefreshTests.completedRefreshCanRepeat),
            ("renaming a home reuses its pending request", RefreshTests.homeRename),
            ("hung agent reads expire without waiting for cancellation", RefreshTests.agentDeadline),
            ("home timeouts retain quota and reject late results", RefreshTests.homeDeadline),
            ("repeated timeouts release refresh slots", RefreshTests.repeatedDeadline),
            ("initial home timeout ends loading", RefreshTests.firstHomeDeadline),
            ("deinitializing the store cancels its readers", RefreshTests.deallocation),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \\(name)") }
            catch { failures += 1; print("FAIL: \\(name): \\(error)") }
            await RefreshTests.cleanup()
        }
        print("Executed \\(tests.count) usage-refresh cases; \\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "glint-usage-refresh-"));
try {
  const swift = path.join(directory, "UsageRefresh.swift");
  fs.writeFileSync(swift, stubs + homesSource.slice(homesSource.indexOf("struct CodexHome:"), homeEnd)
    + source.slice(start, end) + tests);
  const binary = path.join(directory, "usage-refresh-tests");
  const compile = spawnSync("swiftc", ["-swift-version", "5", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "glint-usage-refresh-module-cache"), "-o", binary, swift], { encoding: "utf8", timeout: 60000 });
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
