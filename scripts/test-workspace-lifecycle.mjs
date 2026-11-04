import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

// Exercise production archive/capture/flush/termination bodies without starting
// WorkspaceStore, AppKit, Ghostty, hooks, or the real Application Support path.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const storeSource = fs.readFileSync(path.join(root, 'Glint/Workspace/WorkspaceStore.swift'), 'utf8');
const surfaceSource = fs.readFileSync(path.join(root, 'Glint/Pane/GhosttySurfaceView.swift'), 'utf8');

/** Extract a production method; source and signature identify it; returns the unchanged body with test-visible access. */
function method(source, signature) {
  const at = source.indexOf(signature);
  if (at < 0) throw new Error(`Missing production method ${signature}`);
  const start = source.lastIndexOf('\n', at) + 1;
  const end = source.indexOf('\n    }', at);
  if (end < 0) throw new Error(`Missing method boundary ${signature}`);
  return source.slice(start, end + 6).replace(/\b(?:fileprivate|private) func /g, 'func ');
}

const modelStart = storeSource.indexOf('enum SplitDirection:');
const factoryStart = storeSource.indexOf('\nextension Workspace {', modelStart);
const factoryEnd = storeSource.indexOf('    /// The currently visible tab', factoryStart);
const marker = storeSource.indexOf('forName: NSApplication.willTerminateNotification');
const observerStart = storeSource.lastIndexOf('        observerTokens.append(NotificationCenter.default.addObserver(', marker);
const observerEnd = storeSource.indexOf('\n        })', marker) + '\n        })'.length;
if ([modelStart, factoryStart, factoryEnd, marker, observerStart].some(index => index < 0)) {
  throw new Error('Lifecycle extraction markers changed');
}
const pruneAt = storeSource.indexOf('        // Drop scrollback snapshots for panes that no longer exist.');
const pruneEnd = storeSource.indexOf('        // Block-based observers', pruneAt);
if (pruneAt < 0 || pruneEnd < 0) throw new Error('Startup prune markers changed');
const source = `import Foundation
import Darwin
struct Color {
    /// Provide UI color placeholder; hex is a color string; returns a placeholder.
    init?(hex: String) {}
    /// Provide UI color placeholder; parameters are RGB values; returns a placeholder.
    init(red: Double, green: Double, blue: Double) {}
}
enum PaneAgentKind: String { case claude, codex, opencode, devin, omp, grok }
${storeSource.slice(modelStart, factoryStart)}
${storeSource.slice(factoryStart, factoryEnd)}
}
extension Workspace { var displayName: String { name } }
struct WorkspacePaneKey: Hashable { let workspace: UUID; let pane: PaneID }
var events: [String] = []
var grids: [Int: String] = [:]
var exports = 0
var failures = 0
var scenarios = 0
struct Grid { let ptr: UnsafeMutablePointer<CChar>?; let len: Int }
/// Read a fake live grid; parameters match the C API; returns its current bytes.
func ghostty_surface_render_grid_json(_ surface: Int, _ q: String, _ a: Int, _ b: Int, _ n: UInt) -> Grid {
    exports += 1
    let text = grids[surface] ?? ""
    return Grid(ptr: strdup(text), len: text.utf8.count)
}
/// Release the fake C buffer; grid contains its allocation; returns no value.
func ghostty_string_free(_ grid: Grid) { free(grid.ptr) }
/// Hold the foreground process stable; surface is the fake handle; returns its PID.
func ghostty_surface_foreground_pid(_ surface: Int) -> Int32 { 77 }
enum ScrollbackArchive {
    static var pending: [String: String] = [:]
    static var saved: [String: String] = [:]
    static var pruned: Set<String>?
    /// Queue a fake archive write; arguments match production; returns no value.
    static func writeRendered(id: String, gridJSON: Data, maxLines: Int, priorHistory: String?, restoreMarker: String) {
        events.append("snapshot:" + id)
        pending[id] = String(decoding: gridJSON, as: UTF8.self)
    }
    /// Map fake pane keys to archive IDs; input is a pane key; returns its test ID.
    static func fileID(forPaneKey key: String) -> String { key }
    /// Execute real callers' pruning policy; input is live IDs; returns no value.
    static func prune(keeping ids: Set<String>) {
        events.append("prune"); pruned = ids
        saved = saved.filter { ids.contains($0.key) }
    }
    /// Complete queued writes; no parameters; returns no value.
    static func drain() {
        events.append("drain")
        saved.merge(pending) { _, new in new }
        pending = [:]
    }
}
struct RemoteContext { let target: String; let port: Int?; let remotePath: String? }
final class GhosttySurfaceView {
    let surface: Int?
    let scrollbackID: String?
    let maxScrollbackLines = 3000
    let restoredHistory: String? = nil
    static let restoreMarkerText = "restored"
    var scrollbackNeedsFlush = true
    var scrollbackLastFlushedPid: pid_t = 0
    var process = "codex"
    var remoteReviewContext: RemoteContext? = nil
    var remoteHost: String? = nil
    /// Create an isolated surface; handle and ID identify its fake grid; returns a surface.
    init(handle: Int, id: String) { surface = handle; scrollbackID = id }
    /// Record release; no inputs; returns no value.
    deinit { events.append("release:" + (scrollbackID ?? "")) }
    /// Read final cwd; no parameters; returns the fake terminal directory.
    func currentCwd() -> String? { events.append("capture:" + (scrollbackID ?? "")); return "/final/cwd" }
    /// Read the live process; no parameters; returns the fixture's current process name.
    func foregroundProcessName() -> String? { process }
${method(surfaceSource, 'func flushScrollbackToDisk(')}
${method(surfaceSource, 'func noteForegroundPidForScrollback(')}
}
enum NSSound {
    /// Record the last-workspace refusal; no parameters; returns no value.
    static func beep() { events.append("beep") }
}
enum NSApplication { static let willTerminateNotification = Notification.Name("lifecycle-test-terminate") }
enum ModalResponse { case alertFirstButtonReturn, alertSecondButtonReturn }
final class NSAlert {
    enum Style { case warning }
    var messageText = ""
    var informativeText = ""
    var alertStyle = Style.warning
    static var decisions: [() -> ModalResponse] = []
    static var prompts: [String] = []
    /// Record a test button; input is its label; returns no value.
    func addButton(withTitle title: String) {}
    /// Drive only modal input; no inputs; returns the next fixture decision.
    func runModal() -> ModalResponse {
        Self.prompts.append(informativeText)
        guard !Self.decisions.isEmpty else { return .alertSecondButtonReturn }
        return Self.decisions.removeFirst()()
    }
}
final class UserDefaults {
    static let standard = UserDefaults()
    /// Avoid global preferences; input is a key; returns nil to use the production default.
    func object(forKey key: String) -> Any? { nil }
}
enum Persistence {
    static var requiresLoadRetry = false
    static var next: PersistedState?
    static var reads = 0
    static var blockedSaves = 0
    static var saved: [PersistedState] = []
    /// Model the separately disk-tested load boundary; no inputs; returns the next snapshot and only then permits writes.
    static func load() -> PersistedState? {
        reads += 1
        guard let next else { return nil }
        requiresLoadRetry = false
        return next
    }
    /// Model the separately disk-tested write boundary; input is the state; returns no value.
    static func save(_ state: PersistedState) {
        if requiresLoadRetry { blockedSaves += 1 } else { saved.append(state) }
    }
}
enum Status { case thinking, tool, compacting, needsPermission, idle }
struct AgentState { let status: Status }
final class Store {
    var workspaces: [Workspace] = []
    var selectedWorkspaceID: UUID?
    var sidebarCollapsed = false
    var pendingInitialInput: [WorkspacePaneKey: String] = [:]
    var gitStatuses: [UUID: Int] = [:]
    var webRemoteControlledPanes = Set<WorkspacePaneKey>()
    var surfaceViews: [WorkspacePaneKey: GhosttySurfaceView] = [:]
    var paneAgentState: [WorkspacePaneKey: AgentState] = [:]
    var paneProcesses: [WorkspacePaneKey: String] = [:]
    var restoreTerminalScrollback = true
    var observerTokens: [NSObjectProtocol] = []
    var persisted: [Workspace] = []
    var activeWorkspaces: [Workspace] { workspaces.filter { !$0.archived } }
    static var informativePrompts: [String] = []
    static var allowConfirmation = true
    static var duringConfirmation: (() -> Void)?
    static let benignShells: Set<String> = ["zsh", "bash", "sh", "fish"]
    /// Match known agent process names; name is the process; returns its agent kind or nil.
    static func agentKind(forProcessName name: String) -> PaneAgentKind? { PaneAgentKind(rawValue: name) }
    /// Match agent names for busy detection; name is the process; returns its agent kind or nil.
    static func agentKind(named name: String) -> PaneAgentKind? { agentKind(forProcessName: name) }
    /// Classify shell names; name is the process; returns whether it is benign.
    static func isBenignShellProcessName(_ name: String) -> Bool { benignShells.contains(name) }
    /// Stand in for the modal only; arguments are prompt text and preference key; returns the fixture response.
    static func confirmDestruction(message: String, informative: String, confirmTitle: String, suppressionKey: String) -> Bool {
        informativePrompts.append(informative)
        events.append("confirm:" + suppressionKey)
        let reentry = duringConfirmation
        duringConfirmation = nil
        reentry?()
        return allowConfirmation
    }
    /// Record badge cleanup; keys identify archived panes; returns no value.
    func clearDockBadges(for keys: [WorkspacePaneKey]) { events.append("clear-badges") }
    /// Record termination badge cleanup; no parameters; returns no value.
    func clearDockBadge() { events.append("clear-badge") }
    /// Record a process update; key and name identify it; returns no value.
    func logProcessChange(key: WorkspacePaneKey, name: String) {}
    /// Stand in for unrelated agent presentation; key and processName are inputs; returns no value.
    func reconcileAgentState(key: WorkspacePaneKey, processName: String) {}
    /// Record persistence order and contents; no parameters; returns no value.
    func persist() {
        events.append("persist"); persisted = workspaces
        Persistence.save(PersistedState(workspaces: workspaces, selectedWorkspaceID: selectedWorkspaceID, sidebarCollapsed: sidebarCollapsed))
    }
    /// Record watcher reconciliation; no inputs; returns no value.
    func syncGitWatchers() { events.append("watchers") }
    /// Record status loading; no inputs; returns no value.
    func refreshAllGitStatuses() { events.append("git-status") }
    /// Clear unrelated live control presentation; no inputs; returns no value.
    func clearExternalControlActivity() { events.append("clear-external") }
    /// Run the actual startup-prune block; no inputs; returns no value.
    func pruneStartupScrollback() {
${storeSource.slice(pruneAt, pruneEnd)}
    }
${method(storeSource, 'func offerSavedSessionRecovery(')}
    /// Remove temporary notification observers; no parameters; returns no value.
    deinit { for token in observerTokens { NotificationCenter.default.removeObserver(token) } }
${method(storeSource, 'func paneNeedsCloseConfirmation(')}
${method(storeSource, 'func archiveWorkspace(')}
${method(storeSource, 'func flushScrollback(')}
${method(storeSource, 'func captureCwdsFromLiveSurfaces(')}
${method(storeSource, 'func captureSurfaceState(from view:')}
${method(storeSource, 'func captureSurfaceState(for key:')}
    /// Register the actual production termination observer; no parameters; returns no value.
    func installTerminationObserver() {
${storeSource.slice(observerStart, observerEnd)}
    }
}
/// Assert fixture behavior; condition and message are inputs; returns no value.
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: " + message) }
}
/// Run a lifecycle scenario; name and body identify it; returns no value.
func scenario(_ name: String, _ body: () -> Void) {
    scenarios += 1
    events = []; ScrollbackArchive.saved = [:]; ScrollbackArchive.pending = [:]
    Store.duringConfirmation = nil; Store.informativePrompts = []
    NSAlert.decisions = []; NSAlert.prompts = []
    Persistence.requiresLoadRetry = false; Persistence.next = nil; Persistence.reads = 0; Persistence.blockedSaves = 0; Persistence.saved = []
    ScrollbackArchive.pruned = nil
    let before = failures
    body()
    print("\\(failures == before ? "PASS" : "FAIL"): \\(name)")
}
/// Build two live workspaces; process controls the first pane; returns the store with clean previous snapshots.
func fixture(process: String = "codex") -> Store {
    let store = Store()
    var first = Workspace.fresh(name: "Target", accentHex: "5E5CE6", symbol: "T")
    first.panes[PaneID(value: 0)]?.sessionIds = ["codex": "keep-session", "claude": "stale-session"]
    first.panes[PaneID(value: 0)]?.codexHome = "/custom/codex"
    let second = Workspace.fresh(name: "Other", accentHex: "5E5CE6", symbol: "O")
    store.workspaces = [first, second]; store.selectedWorkspaceID = first.id
    for (index, workspace) in store.workspaces.enumerated() {
        let handle = index + 1
        let id = String(handle)
        grids[handle] = "before-" + id
        let view = GhosttySurfaceView(handle: handle, id: id)
        view.process = index == 0 ? process : "zsh"
        store.surfaceViews[WorkspacePaneKey(workspace: workspace.id, pane: PaneID(value: 0))] = view
        view.flushScrollbackToDisk()
    }
    ScrollbackArchive.drain(); events = []
    grids[1] = "final-output-1"; grids[2] = "final-output-2"
    return store
}
scenario("busy archive cancellation keeps terminal and state") {
    let store = fixture(); Store.allowConfirmation = false
    let target = store.workspaces[0].id
    let key = WorkspacePaneKey(workspace: target, pane: PaneID(value: 0))
    store.archiveWorkspace(target)
    check(store.surfaceViews[key] != nil && !store.workspaces[0].archived, "cancel must retain terminal and workspace")
    check(store.selectedWorkspaceID == target && store.persisted.isEmpty, "cancel must preserve selection and saved state")
    check(events.contains(where: { $0.hasPrefix("confirm:") }), "busy archive must ask")
    check(!events.contains("capture:1") && !events.contains("drain"), "cancel must not begin destructive preparation")
}
scenario("one busy pane gets singular archive confirmation") {
    let store = fixture(); Store.allowConfirmation = false
    store.archiveWorkspace(store.workspaces[0].id)
    check(Store.informativePrompts == ["1 of its panes still has something running; archiving will terminate its processes."], "one-pane prompt must use singular grammar")
}
scenario("multiple busy panes get formatted plural archive confirmation") {
    let store = fixture(); Store.allowConfirmation = false
    let target = store.workspaces[0].id
    let pane = PaneID(value: 1)
    store.workspaces[0].panes[pane] = Pane(id: pane, title: "Second")
    store.paneProcesses[WorkspacePaneKey(workspace: target, pane: pane)] = "vim"
    store.archiveWorkspace(target)
    check(Store.informativePrompts == ["2 of its panes still have something running; archiving will terminate their processes."], "multiple-pane prompt must format Int64 without truncation")
}
scenario("confirmed archive captures final metadata and drains before release") {
    let store = fixture(); Store.allowConfirmation = true
    let target = store.workspaces[0].id
    store.archiveWorkspace(target)
    check(store.workspaces[0].archived && store.surfaceViews.count == 1, "only archived terminals should release")
    let pane = store.workspaces[0].panes[PaneID(value: 0)]!
    check(pane.workingDirectory == "/final/cwd" && pane.lastAgent == "codex", "archive must capture final cwd and agent")
    check(pane.sessionIds == ["codex": "keep-session"] && pane.codexHome == "/custom/codex", "archive must reconcile and retain agent resume state")
    check(ScrollbackArchive.saved["1"] == "final-output-1", "archive must force latest grid with unchanged PID")
    check(ScrollbackArchive.saved["2"] == "before-2", "archive must leave unrelated terminal snapshot alone")
    let drained = events.firstIndex(of: "drain"), released = events.firstIndex(of: "release:1")
    check(drained != nil && released != nil && drained! < released!, "archive must drain before releasing")
    check(events.last == "persist" && store.persisted.first?.archived == true, "archive must persist its final state")
    check(store.selectedWorkspaceID == store.workspaces[1].id, "archive should select next active workspace")
}
scenario("deleting target during confirmation cannot archive its survivor") {
    let store = fixture(); Store.allowConfirmation = true
    let target = store.workspaces[0].id
    Store.duringConfirmation = { store.workspaces.removeAll { $0.id == target } }
    store.archiveWorkspace(target)
    check(store.workspaces.count == 1 && !store.workspaces[0].archived, "deleted target must not redirect archive to its survivor")
    check(!events.contains("capture:1") && !events.contains("drain") && store.persisted.isEmpty, "missing target must abort before final capture or release")
}
scenario("reordering during confirmation archives the identified workspace") {
    let store = fixture(); Store.allowConfirmation = true
    let target = store.workspaces[0].id, other = store.workspaces[1].id
    Store.duringConfirmation = { store.workspaces.reverse() }
    store.archiveWorkspace(target)
    check(store.workspaces.first(where: { $0.id == target })?.archived == true, "reorder must preserve target identity")
    check(store.workspaces.first(where: { $0.id == other })?.archived == false && store.selectedWorkspaceID == other, "reorder must leave other workspace active and selected")
}
scenario("confirmation cannot archive the last remaining active workspace") {
    let store = fixture(); Store.allowConfirmation = true
    let target = store.workspaces[0].id
    Store.duringConfirmation = { store.workspaces[1].archived = true }
    store.archiveWorkspace(target)
    check(!store.workspaces[0].archived && store.activeWorkspaces.count == 1, "changed active count must prevent final workspace archive")
    check(store.surfaceViews.count == 2 && !events.contains("capture:1") && store.persisted.isEmpty, "last active workspace must keep its surface untouched")
}
scenario("target already archived during confirmation is not archived twice") {
    let store = fixture(); Store.allowConfirmation = true
    let target = store.workspaces[0].id
    Store.duringConfirmation = { store.workspaces[0].archived = true }
    store.archiveWorkspace(target)
    check(!events.contains("capture:1") && !events.contains("drain") && store.persisted.isEmpty, "already archived target must abort before capture and release")
}
scenario("idle archive clears completed session without confirmation") {
    let store = fixture(process: "zsh"); Store.allowConfirmation = false
    store.archiveWorkspace(store.workspaces[0].id)
    let pane = store.workspaces[0].panes[PaneID(value: 0)]!
    check(store.workspaces[0].archived && !events.contains(where: { $0.hasPrefix("confirm:") }), "idle archive should proceed without prompt")
    check(pane.lastAgent == nil && pane.sessionIds.isEmpty && pane.codexHome == nil, "archive must capture completed agent state")
}
scenario("last active workspace cannot archive") {
    let store = fixture(); store.workspaces.removeLast()
    store.archiveWorkspace(store.workspaces[0].id)
    check(!store.workspaces[0].archived && events == ["beep"], "last active workspace must stay live")
}
scenario("disabled scrollback does not create a final snapshot") {
    let store = fixture(process: "zsh"); store.restoreTerminalScrollback = false
    store.archiveWorkspace(store.workspaces[0].id)
    check(ScrollbackArchive.saved["1"] == "before-1" && !events.contains("snapshot:1"), "disabled feature must not capture scrollback")
}
scenario("daily clean flush still avoids grid serialization") {
    let store = fixture(); let before = exports
    store.flushScrollback()
    check(exports == before && ScrollbackArchive.pending.isEmpty, "normal flush should retain dirty optimization")
}
scenario("termination forces latest grids before drain") {
    let store = fixture(); store.installTerminationObserver()
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    check(ScrollbackArchive.saved["1"] == "final-output-1" && ScrollbackArchive.saved["2"] == "final-output-2", "termination must save output that arrived with unchanged PID and no input")
    check(events.last == "drain" && store.persisted.first?.panes[PaneID(value: 0)]?.workingDirectory == "/final/cwd", "termination must drain and persist captured state")
}
/// Construct a recoverable snapshot; name identifies it; returns a saved state with valid selection.
func restoredSnapshot(_ name: String = "Restored") -> PersistedState {
    let workspace = Workspace.fresh(name: name, accentHex: "5E5CE6", symbol: "R")
    return PersistedState(workspaces: [workspace], selectedWorkspaceID: workspace.id, sidebarCollapsed: true)
}
scenario("read-failure startup never prunes original session history") {
    let store = fixture(); Persistence.requiresLoadRetry = true
    ScrollbackArchive.saved["original-history"] = "last saved output"
    store.pruneStartupScrollback()
    check(ScrollbackArchive.saved["original-history"] == "last saved output" && ScrollbackArchive.pruned == nil, "temporary models must not prune saved history")
}
scenario("continuing a temporary session retains terminals and blocks autosave") {
    let store = fixture(); let ids = store.workspaces.map(\\.id)
    Persistence.requiresLoadRetry = true; Persistence.next = restoredSnapshot()
    NSAlert.decisions = [{ .alertSecondButtonReturn }]
    store.offerSavedSessionRecovery(); store.persist()
    check(store.workspaces.map(\\.id) == ids && store.surfaceViews.count == 2, "cancel must preserve temporary terminals")
    check(Persistence.reads == 0 && Persistence.blockedSaves == 1 && Persistence.saved.isEmpty, "cancel must not load or overwrite the original")
}
scenario("failed recovery read keeps protection and permits another decision") {
    let store = fixture(); Persistence.requiresLoadRetry = true
    NSAlert.decisions = [{ .alertFirstButtonReturn }, { .alertSecondButtonReturn }]
    store.offerSavedSessionRecovery(); store.persist()
    check(NSAlert.prompts.count == 2 && Persistence.reads == 1, "failed retry must remain recoverable")
    check(store.surfaceViews.count == 2 && Persistence.blockedSaves == 1 && Persistence.saved.isEmpty, "read failure must retain terminals and protect saves")
}
scenario("confirmed recovery adopts state after draining temporary terminals") {
    let store = fixture(); let restored = restoredSnapshot()
    Persistence.requiresLoadRetry = true; Persistence.next = restored
    store.webRemoteControlledPanes = Set(store.surfaceViews.keys)
    store.pendingInitialInput = [store.surfaceViews.keys.first!: "do not replay"]
    NSAlert.decisions = [{ .alertFirstButtonReturn }]
    store.offerSavedSessionRecovery()
    check(store.workspaces.map(\\.id) == restored.workspaces.map(\\.id) && store.selectedWorkspaceID == restored.selectedWorkspaceID && store.sidebarCollapsed, "retry must adopt the exact saved session")
    check(store.surfaceViews.isEmpty && store.paneProcesses.isEmpty && store.paneAgentState.isEmpty && store.pendingInitialInput.isEmpty && store.webRemoteControlledPanes.isEmpty, "restoration must clear temporary live state")
    let drained = events.firstIndex(of: "drain"), released = events.firstIndex(where: { $0.hasPrefix("release:") })
    check(drained != nil && released != nil && drained! < released!, "temporary snapshots must drain before surface release")
    check(ScrollbackArchive.pruned?.count == restored.workspaces[0].panes.count && events.contains("watchers"), "restored IDs must drive pruning and watchers")
    store.persist()
    check(Persistence.saved.last?.workspaces.first?.id == restored.workspaces.first?.id, "saves may resume only with the adopted model")
}
scenario("new workspace during recovery confirmation requires another decision") {
    let store = fixture(); let original = store.workspaces[0].id
    Persistence.requiresLoadRetry = true; Persistence.next = restoredSnapshot()
    NSAlert.decisions = [{ store.workspaces.append(Workspace.fresh(name: "New", accentHex: "5E5CE6", symbol: "N")); return .alertFirstButtonReturn }, { .alertSecondButtonReturn }]
    store.offerSavedSessionRecovery()
    check(Persistence.reads == 0 && NSAlert.prompts.count == 2 && store.workspaces.first?.id == original && store.workspaces.count == 3, "new workspaces must not be closed without a fresh decision")
}
scenario("replaced surface during recovery confirmation requires another decision") {
    let store = fixture(); let key = store.surfaceViews.keys.first!
    Persistence.requiresLoadRetry = true; Persistence.next = restoredSnapshot()
    NSAlert.decisions = [{ store.surfaceViews[key] = GhosttySurfaceView(handle: 3, id: "replacement"); return .alertFirstButtonReturn }, { .alertSecondButtonReturn }]
    store.offerSavedSessionRecovery()
    check(Persistence.reads == 0 && NSAlert.prompts.count == 2 && store.surfaceViews[key]?.scrollbackID == "replacement", "new surface identity must be re-confirmed")
}
scenario("a newly busy temporary terminal requires another decision") {
    let store = fixture(process: "zsh"); let key = store.surfaceViews.keys.first!
    Persistence.requiresLoadRetry = true; Persistence.next = restoredSnapshot()
    NSAlert.decisions = [{ store.surfaceViews[key]?.process = "vim"; return .alertFirstButtonReturn }, { .alertSecondButtonReturn }]
    store.offerSavedSessionRecovery()
    check(Persistence.reads == 0 && NSAlert.prompts.count == 2 && store.surfaceViews[key]?.process == "vim", "new busy terminals must not be killed by a prior decision")
}
scenario("saved data is reread after the recovery decision") {
    let store = fixture(); Persistence.requiresLoadRetry = true; Persistence.next = restoredSnapshot("Before")
    NSAlert.decisions = [{ Persistence.next = restoredSnapshot("Changed"); return .alertFirstButtonReturn }]
    store.offerSavedSessionRecovery()
    check(Persistence.reads == 1 && store.workspaces.first?.name == "Changed", "recovery must reread the current original")
}

print("Executed \\(scenarios) lifecycle scenarios; \\(failures) assertion failures")
exit(failures == 0 ? 0 : 1)
`;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'glint-lifecycle-'));
try {
  const main = path.join(dir, 'main.swift');
  fs.writeFileSync(main, source);
  const run = spawnSync('swift', ['-swift-version', '5', '-module-cache-path', path.join(os.tmpdir(), 'glint-lifecycle-cache'), main],
    { encoding: 'utf8', timeout: 120000 });
  process.stdout.write(run.stdout ?? '');
  process.stderr.write(run.stderr ?? '');
  if (run.error) throw run.error;
  process.exitCode = run.status ?? 1;
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
