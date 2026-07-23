import SwiftUI
import Combine
import AppKit
import Darwin
import UserNotifications

enum TerminalOfflinePolicy {
    private static let idleShells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "login",
    ]

    static func isIdleShell(_ processName: String?) -> Bool {
        guard let processName else { return false }
        return idleShells.contains(processName.lowercased())
    }

    static func shouldTakeOffline(enabled: Bool,
                                  hasLiveSurface: Bool,
                                  inactiveSince: Date?,
                                  now: Date,
                                  timeout: TimeInterval,
                                  promptStateDetectionEnabled: Bool = true,
                                  needsConfirmQuit: Bool,
                                  foregroundProcessName: String?,
                                  hasUserOrJobState: Bool = false) -> Bool {
        guard enabled,
              hasLiveSurface,
              promptStateDetectionEnabled,
              !needsConfirmQuit,
              !hasUserOrJobState,
              let inactiveSince,
              now.timeIntervalSince(inactiveSince) >= timeout,
              isIdleShell(foregroundProcessName) else { return false }
        return true
    }
}

enum TerminalFocusPolicy {
    static func isPaneFocused(workspaceIsSelected: Bool,
                              paneIsFocused: Bool) -> Bool {
        workspaceIsSelected && paneIsFocused
    }

    /// A pane the user can currently SEE must never be swapped for the
    /// offline placeholder in front of them — keyboard focus may legitimately
    /// live in the sidebar/search for long stretches. `viewIsAttachedToWindow`
    /// is the visibility proxy: workspace/tab switches detach pane views.
    static func protectsFromIdleOfflining(appIsActive: Bool,
                                          workspaceIsSelected: Bool,
                                          viewIsFirstResponder: Bool,
                                          viewIsAttachedToWindow: Bool) -> Bool {
        appIsActive && workspaceIsSelected
            && (viewIsFirstResponder || viewIsAttachedToWindow)
    }
}

// MARK: - Domain types

enum SplitDirection: String, Codable, Hashable {
    case horizontal
    case vertical
}

struct PaneID: Hashable, Identifiable, Codable {
    let value: UInt32
    var id: UInt32 { value }
}

struct TabID: Hashable, Identifiable, Codable {
    let value: UInt32
    var id: UInt32 { value }
}

indirect enum SplitNode: Codable {
    case leaf(PaneID)
    case split(direction: SplitDirection, ratio: CGFloat, a: SplitNode, b: SplitNode)

    private enum CodingKeys: String, CodingKey { case kind, id, direction, ratio, a, b }
    private enum Kind: String, Codable { case leaf, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .leaf:
            self = .leaf(try c.decode(PaneID.self, forKey: .id))
        case .split:
            let dir = try c.decode(SplitDirection.self, forKey: .direction)
            let r = try c.decode(CGFloat.self, forKey: .ratio)
            let a = try c.decode(SplitNode.self, forKey: .a)
            let b = try c.decode(SplitNode.self, forKey: .b)
            self = .split(direction: dir, ratio: r, a: a, b: b)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try c.encode(Kind.leaf, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .split(let dir, let r, let a, let b):
            try c.encode(Kind.split, forKey: .kind)
            try c.encode(dir, forKey: .direction)
            try c.encode(r, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }
}

extension SplitNode {
    /// Every pane in this subtree, left-to-right (pre-order).
    var leaves: [PaneID] {
        switch self {
        case .leaf(let id):            return [id]
        case .split(_, _, let a, let b): return a.leaves + b.leaves
        }
    }
}

/// Where a workspace's shell/agent/git actually run, and what repo/branch it's
/// bound to. `plain` is the zero-cost default (a bare shell, no repo) so the
/// common "just open a terminal" path stays untouched. Worktree fields are
/// Phase 1; SSH/remote fields are reserved for Phase 2/3 and decode to nil.
enum WorkspaceSourceKind: String, Codable {
    case plain
    case localRepo
    case localWorktree
    case sshProject
    case sshWorktree
    case remoteTask
}

struct WorkspaceSource: Codable, Equatable {
    var kind: WorkspaceSourceKind
    /// Main worktree top-level of the bound repo (`git rev-parse --show-toplevel`).
    var repoRoot: String?
    var branch: String?
    var baseBranch: String?
    /// Filesystem path of the dedicated worktree (kind == .localWorktree).
    var worktreePath: String?
    // Reserved for Phase 2/3 — unused today, decode to nil on old + new saves.
    var sshConnectionID: UUID?
    var remotePath: String?
    var remoteWorkspaceID: String?

    static let plain = WorkspaceSource(kind: .plain)

    var isWorktree: Bool { kind == .localWorktree || kind == .sshWorktree }
    var isRemote: Bool { kind == .sshProject || kind == .sshWorktree || kind == .remoteTask }
    /// The directory git operations should target: the worktree if there is one,
    /// otherwise the repo root.
    var gitPath: String? { worktreePath ?? repoRoot }

    init(kind: WorkspaceSourceKind,
         repoRoot: String? = nil, branch: String? = nil, baseBranch: String? = nil,
         worktreePath: String? = nil, sshConnectionID: UUID? = nil,
         remotePath: String? = nil, remoteWorkspaceID: String? = nil) {
        self.kind = kind
        self.repoRoot = repoRoot
        self.branch = branch
        self.baseBranch = baseBranch
        self.worktreePath = worktreePath
        self.sshConnectionID = sshConnectionID
        self.remotePath = remotePath
        self.remoteWorkspaceID = remoteWorkspaceID
    }
}

struct Pane: Identifiable, Codable {
    let id: PaneID
    var title: String
    /// Last-known working directory; used to re-spawn the shell in the same
    /// place after a restart. Updated periodically while running.
    var workingDirectory: String?
    /// Foreground CLI-agent ("claude"/"codex") that was running on this pane
    /// at the last poll, or nil if the pane was sitting on a bare shell.
    /// Drives the optional "resume agent session on restart" behavior — see
    /// `restoreClaudeSession` / `restoreCodexSession`. Reflects the CURRENT
    /// state, not sticky: an agent that quit back to the shell clears it.
    var lastAgent: String?
    /// Remote SSH context for Review-over-SSH — the ssh destination the user
    /// typed, its port, the remote host (display only), and the remote cwd
    /// mined from the terminal title. Transient (NOT persisted): re-derived
    /// from the live surface on a title/command event, so it's nil until the
    /// remote shell's title reports a cwd. Mirrors `workingDirectory`'s
    /// snapshot-from-surface pattern. Optional → defaults nil, so the custom
    /// Codable below ignores them without a CodingKeys/init/encode change.
    var remoteTarget: String?
    var remotePort: Int?
    var remoteHost: String?
    var remotePath: String?
    /// Per-agent session id captured from hook events, keyed by
    /// `PaneAgentKind.rawValue` ("claude"/"codex"/"opencode"/"devin"/"omp"/"grok"). When
    /// set, restore-on-launch issues the agent's `--resume <id>` /
    /// `--session <id>` form so multiple panes in one workspace don't
    /// collapse onto the most-recent session (#45). Lifecycle: entries are
    /// dropped in `captureCwdsFromLiveSurfaces` the moment the foreground
    /// agent stops matching the entry's key, so a stale id can't leak
    /// across an exit/relaunch.
    var sessionIds: [String: String]
    /// Resolved `CODEX_HOME` path a non-default-home Codex pane was launched
    /// under, so restart can re-prefix `codex resume …` with it (#45 for the
    /// multi-home feature). nil for default-home / non-codex panes. Cleared in
    /// `captureCwdsFromLiveSurfaces` once the foreground stops being Codex, so
    /// a later default-Codex launch on the same pane can't inherit a stale home.
    var codexHome: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory, lastAgent, sessionIds, codexHome
    }

    /// Field shape from the first cut of #45 (one Optional per agent). Read
    /// at decode for forward-compat with already-persisted state from that
    /// shape; never written. Once a Pane is re-encoded it migrates to
    /// `sessionIds` and these keys disappear from disk.
    private enum LegacyKeys: String, CodingKey {
        case lastClaudeSessionId, lastCodexSessionId
        case lastOpenCodeSessionId, lastDevinSessionId
    }

    init(id: PaneID, title: String, workingDirectory: String? = nil,
         lastAgent: String? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastAgent = lastAgent
        self.sessionIds = [:]
        self.codexHome = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(PaneID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.lastAgent = try c.decodeIfPresent(String.self, forKey: .lastAgent)
        self.codexHome = try c.decodeIfPresent(String.self, forKey: .codexHome)
        if let map = try c.decodeIfPresent([String: String].self, forKey: .sessionIds) {
            self.sessionIds = map
        } else {
            // No `sessionIds` key — either a pre-#45 pane (no agent state at
            // all → empty dict) or one persisted by the first per-agent-field
            // cut (#45 v1) which we migrate field-by-field. `decodeIfPresent`
            // tolerates absent legacy keys but lets a typeMismatch propagate
            // so a corrupt String→Int flip on disk surfaces as a decode error
            // (caught by Persistence.stripBadPanes) instead of silently
            // dropping the session hint and giving the user a #45 regression
            // with no diagnostic.
            var map: [String: String] = [:]
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let v = try legacy.decodeIfPresent(String.self, forKey: .lastClaudeSessionId) { map[PaneAgentKind.claude.rawValue] = v }
            if let v = try legacy.decodeIfPresent(String.self, forKey: .lastCodexSessionId) { map[PaneAgentKind.codex.rawValue] = v }
            if let v = try legacy.decodeIfPresent(String.self, forKey: .lastOpenCodeSessionId) { map[PaneAgentKind.opencode.rawValue] = v }
            if let v = try legacy.decodeIfPresent(String.self, forKey: .lastDevinSessionId) { map[PaneAgentKind.devin.rawValue] = v }
            self.sessionIds = map
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(lastAgent, forKey: .lastAgent)
        try c.encodeIfPresent(codexHome, forKey: .codexHome)
        // Skip the key entirely when there's nothing to remember — most
        // panes never see an agent, and an empty `{}` on every pane would
        // be persistent noise in the autosave file.
        if !sessionIds.isEmpty {
            try c.encode(sessionIds, forKey: .sessionIds)
        }
    }
}

/// One tab inside a workspace. Owns its own split tree and focused pane; the
/// panes themselves live in the workspace's global `panes` registry (so the
/// `(workspace, pane)` key for surfaces / scrollback / agent state is the
/// same no matter which tab a pane is in).
struct WorkspaceTab: Identifiable, Codable {
    let id: TabID
    /// User-chosen name; nil ⇒ derive a label from the focused pane's cwd.
    var name: String?
    var root: SplitNode
    var focusedPane: PaneID
}

struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    /// True once the user has explicitly renamed this workspace. When false
    /// we display a path-derived auto name instead of `name`.
    var userNamed: Bool
    /// Hex string like "5E5CE6" for Codable simplicity.
    var accentHex: String
    var symbol: String
    /// Parked away from the main sidebar list. The model (panes, splits,
    /// cwd, lastAgent) survives intact; only the live surfaces are dropped,
    /// so unarchive resumes from the saved state via the same code path as
    /// an app restart. ⌘1…⌘9 skip archived workspaces.
    var archived: Bool
    /// Open tabs, in display order. Never empty — a workspace always has at
    /// least one tab.
    var tabs: [WorkspaceTab]
    /// The currently visible tab.
    var selectedTabID: TabID
    /// Monotonic TabID source within this workspace (values are never reused).
    var nextTabSeq: UInt32
    /// Pane registry, GLOBAL to the workspace (not per-tab). PaneIDs are
    /// unique within the workspace, so `WorkspacePaneKey(workspace, pane)` is
    /// unaffected by which tab a pane lives in.
    var panes: [PaneID: Pane]
    var nextPaneSeq: UInt32
    /// Repo/worktree/remote binding. Defaults to `.plain`; only persisted when
    /// non-plain, so existing saves and plain workspaces stay byte-clean.
    var source: WorkspaceSource

    var accent: Color {
        Color(hex: accentHex) ?? Color(red: 0.37, green: 0.36, blue: 0.90)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, userNamed, accentHex, symbol, archived
        case tabs, selectedTabID, nextTabSeq, panes, nextPaneSeq, source
        // Legacy single-tree keys, still read so pre-tabs saves migrate.
        case root, focusedPane
    }

    init(id: UUID, name: String, userNamed: Bool, accentHex: String, symbol: String,
         tabs: [WorkspaceTab], selectedTabID: TabID, nextTabSeq: UInt32,
         panes: [PaneID: Pane], nextPaneSeq: UInt32,
         archived: Bool = false, source: WorkspaceSource = .plain) {
        self.id = id
        self.name = name
        self.userNamed = userNamed
        self.accentHex = accentHex
        self.symbol = symbol
        self.archived = archived
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.nextTabSeq = nextTabSeq
        self.panes = panes
        self.nextPaneSeq = nextPaneSeq
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        // Old saves don't have `userNamed`; assume the existing name was the
        // user's choice so we don't suddenly relabel their workspaces.
        self.userNamed = (try? c.decode(Bool.self, forKey: .userNamed)) ?? true
        self.accentHex = try c.decode(String.self, forKey: .accentHex)
        self.symbol = try c.decode(String.self, forKey: .symbol)
        // Older saves predate the archive feature — default to active.
        self.archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        self.panes = try c.decode([PaneID: Pane].self, forKey: .panes)
        self.nextPaneSeq = try c.decode(UInt32.self, forKey: .nextPaneSeq)
        // Additive: old saves predate source binding — default to plain.
        self.source = (try? c.decode(WorkspaceSource.self, forKey: .source)) ?? .plain

        if let tabs = try? c.decode([WorkspaceTab].self, forKey: .tabs), !tabs.isEmpty {
            self.tabs = tabs
            self.selectedTabID = (try? c.decode(TabID.self, forKey: .selectedTabID)) ?? tabs[0].id
            let maxSeq = tabs.map(\.id.value).max() ?? 0
            self.nextTabSeq = (try? c.decode(UInt32.self, forKey: .nextTabSeq))
                .map { Swift.max($0, maxSeq + 1) } ?? (maxSeq + 1)
        } else {
            // Migrate a pre-tabs save: its single (root, focusedPane) becomes
            // tab 0. Fall back to the first pane / a fresh leaf if those keys
            // are somehow absent, so decoding never throws on an old file.
            let root = (try? c.decode(SplitNode.self, forKey: .root))
                ?? .leaf(panes.keys.sorted { $0.value < $1.value }.first ?? PaneID(value: 0))
            let focused = (try? c.decode(PaneID.self, forKey: .focusedPane))
                ?? root.leaves.first ?? PaneID(value: 0)
            self.tabs = [WorkspaceTab(id: TabID(value: 0), name: nil,
                                      root: root, focusedPane: focused)]
            self.selectedTabID = TabID(value: 0)
            self.nextTabSeq = 1
        }
    }

    // Explicit because CodingKeys carries the legacy `root`/`focusedPane`
    // cases (read by the migration decoder) which have no stored property —
    // that blocks Encodable synthesis. We write only the current shape; the
    // legacy keys are never emitted, so saves are clean going forward.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(userNamed, forKey: .userNamed)
        try c.encode(accentHex, forKey: .accentHex)
        try c.encode(symbol, forKey: .symbol)
        if archived { try c.encode(true, forKey: .archived) }   // omit the common case
        try c.encode(tabs, forKey: .tabs)
        try c.encode(selectedTabID, forKey: .selectedTabID)
        try c.encode(nextTabSeq, forKey: .nextTabSeq)
        try c.encode(panes, forKey: .panes)
        try c.encode(nextPaneSeq, forKey: .nextPaneSeq)
        if source.kind != .plain { try c.encode(source, forKey: .source) }  // omit the common case
    }
}

// MARK: - Persisted store snapshot

struct PersistedState: Codable {
    /// On-disk schema version. Bump only for shape changes that tolerant
    /// decoding can't paper over; plain additions should use
    /// `decodeIfPresent` + a default instead, so old files keep loading.
    static let currentVersion = 1

    var version: Int
    var workspaces: [Workspace]
    var selectedWorkspaceID: UUID?
    var sidebarCollapsed: Bool

    init(workspaces: [Workspace], selectedWorkspaceID: UUID?, sidebarCollapsed: Bool) {
        self.version = Self.currentVersion
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sidebarCollapsed = sidebarCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspaces, selectedWorkspaceID, sidebarCollapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Files written before versioning have no `version` key — they are
        // retroactively v1.
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        self.selectedWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        self.sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
    }

    static var fresh: PersistedState {
        let personal = Workspace.fresh(name: "Personal", accentHex: "5E5CE6", symbol: "P")
        let anthropic = Workspace.fresh(name: "Anthropic", accentHex: "FF6582", symbol: "A")
        let research = Workspace.fresh(name: "Research", accentHex: "30D158", symbol: "R")
        return PersistedState(
            workspaces: [personal, anthropic, research],
            selectedWorkspaceID: personal.id,
            sidebarCollapsed: false
        )
    }
}

extension Workspace {
    static func fresh(name: String, accentHex: String, symbol: String) -> Workspace {
        let first = PaneID(value: 0)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil,
                               root: .leaf(first), focusedPane: first)
        return Workspace(
            id: UUID(),
            name: name,
            userNamed: false,
            accentHex: accentHex,
            symbol: symbol,
            tabs: [tab],
            selectedTabID: tab.id,
            nextTabSeq: 1,
            panes: [first: Pane(id: first, title: "zsh", workingDirectory: nil)],
            nextPaneSeq: 1
        )
    }

    /// The currently visible tab (the model guarantees one exists, but the
    /// accessor stays optional so a transient inconsistent state can't crash).
    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    var selectedTabIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }

    /// What to show as the workspace label in the sidebar. If the user has
    /// renamed it, use their name; otherwise derive a short label from the
    /// selected tab's focused pane's working directory.
    var displayName: String {
        if userNamed && !name.isEmpty { return name }
        // Worktree/repo workspaces read better as "repo · branch" than as a
        // generic cwd label — the branch is the whole point of the worktree.
        if source.kind != .plain, let branch = source.branch {
            let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
            if let root = source.repoRoot {
                return "\((root as NSString).lastPathComponent) · \(leaf)"
            }
            return leaf
        }
        let cwd = (selectedTab?.focusedPane).flatMap { panes[$0]?.workingDirectory }
            ?? panes.values.compactMap(\.workingDirectory).first
        return Self.shortLabel(forCwd: cwd) ?? name
    }

    /// Label for a tab chip: the user's name if set, otherwise the focused
    /// pane's folder name, otherwise a generic fallback.
    func tabDisplayName(_ tab: WorkspaceTab) -> String {
        if let n = tab.name, !n.isEmpty { return n }
        return Self.shortTabLabel(forCwd: tabCwd(tab)) ?? String(localized: "Terminal")
    }

    /// Tooltip for a tab chip. The visible label stays compact, while hover
    /// still exposes the full working directory when Glint knows it.
    func tabHelpText(_ tab: WorkspaceTab) -> String {
        let display = tabDisplayName(tab)
        guard let cwd = tabCwd(tab), !cwd.isEmpty, cwd != display else { return display }
        return "\(display)\n\(cwd)"
    }

    /// Focused pane's cwd for a tab, falling back to the first pane that has
    /// reported one. Internal so `WorkspaceStore`'s per-tab Copy Path /
    /// Reveal-in-Finder can resolve the same cwd the chip label shows.
    func tabCwd(_ tab: WorkspaceTab) -> String? {
        panes[tab.focusedPane]?.workingDirectory
            ?? tab.root.leaves.compactMap { panes[$0]?.workingDirectory }.first
    }

    /// Shared cwd → label preamble: trims trailing slashes and resolves the
    /// special roots so the two formatters below can't drift on them. Returns
    /// `.done` for a finished label (`~` / `/` / nil-when-unusable), or
    /// `.path` with the cleaned absolute path + home for the caller to shorten.
    private enum CwdBase { case done(String?), path(String, home: String) }
    private static func cwdBase(_ path: String?) -> CwdBase {
        guard var path, !path.isEmpty else { return .done(nil) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let home = NSHomeDirectory()
        if path == home { return .done("~") }
        if path == "/" { return .done("/") }
        return .path(path, home: home)
    }

    /// Compact tab-chip label: just the folder name.
    private static func shortTabLabel(forCwd path: String?) -> String? {
        switch cwdBase(path) {
        case .done(let label): return label
        case .path(let path, _):
            let label = URL(fileURLWithPath: path).lastPathComponent
            return label.isEmpty ? nil : label
        }
    }

    /// Sidebar label: home-relative, keeping up to two trailing segments.
    private static func shortLabel(forCwd path: String?) -> String? {
        switch cwdBase(path) {
        case .done(let label): return label
        case .path(let path, let home):
            if path.hasPrefix(home + "/") {
                let rel = String(path.dropFirst(home.count + 1))
                let parts = rel.split(separator: "/")
                // ~/foo or ~/foo/bar — keep up to two trailing segments.
                if parts.count <= 2 {
                    return "~/" + parts.joined(separator: "/")
                }
                return "~/…/" + parts.suffix(2).joined(separator: "/")
            }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

// MARK: - Store

@MainActor
final class WorkspaceStore: ObservableObject {

    @Published var workspaces: [Workspace]
    @Published var selectedWorkspaceID: UUID?
    @Published var sidebarCollapsed: Bool
    /// High-frequency, non-persistent pane state is published separately so
    /// agent hooks and foreground-process changes don't invalidate every view
    /// that observes the workspace model (including the terminal subtree).
    let activity: PaneActivityStore
    /// Latest foreground-process name per (workspace, pane). Event-driven with
    /// a slow fallback capture; drives the workspace card icon. Non-persistent.
    var paneProcesses: [WorkspacePaneKey: String] {
        get { activity.paneProcesses }
        set { activity.paneProcesses = newValue }
    }
    /// CLI-agent state per pane (push-driven via AgentBridge hooks).
    /// Beats `paneProcesses` for icon/state because hooks carry live
    /// status (thinking/permission/…) a process-name capture can't know.
    /// Non-persistent.
    var paneAgentState: [WorkspacePaneKey: PaneAgentState] {
        get { activity.paneAgentState }
        set { activity.paneAgentState = newValue }
    }

    /// Drives the command-palette overlay. Toggled by the toolbar's ⌘
    /// button and the ⌘⇧P global shortcut. Mutually exclusive with the agent
    /// chooser — opening one dismisses the other so they can't stack.
    @Published var commandPaletteOpen: Bool = false {
        didSet { if commandPaletteOpen { agentChooserIntent = nil } }
    }

    /// The pending "new terminal" action awaiting an agent pick from the chooser
    /// overlay — non-nil ⇒ the chooser is shown. Set by the `request*` helpers
    /// when `promptAgentOnNew` is on; cleared by `resolveAgentChooser`. Pops the
    /// command palette closed so the two overlays never appear at once (e.g. ⌘T
    /// while the palette is open).
    @Published var agentChooserIntent: NewTerminalIntent? {
        didSet { if agentChooserIntent != nil { commandPaletteOpen = false } }
    }

    /// Drives the Settings sheet attached to the main window. We host
    /// Settings inside the window (not as a separate scene) so it
    /// inherits the workspace context and feels of-the-app rather than
    /// of-the-OS.
    @Published var settingsOpen: Bool = false

    /// True while a workspace (sidebar) or tab (tab bar) rename field is the
    /// focused first responder. Gates the click-away dismissal monitor in
    /// `ContentView` so it resigns *only* during an actual rename — the sidebar
    /// search and other text fields stay on macOS's default focus behavior.
    @Published var isRenaming: Bool = false

    /// Hand-authored "What's New" notes to show in the centered card overlay.
    /// Non-empty ⇒ the card is up (one entry on manual open, possibly several
    /// when catching up across skipped versions). See `ReleaseNotes.swift`.
    @Published var whatsNewNotes: [ReleaseNote] = []
    /// One-shot guard so the launch evaluation (driven from `ContentView`'s
    /// `.onAppear`, which can fire more than once) only runs the first time.
    private var whatsNewEvaluated = false
    private static let whatsNewVersionKey = "glint.lastWhatsNewVersion"

    /// Drives the New Worktree sheet (the worktree-creation window).
    @Published var newWorkspaceSheetOpen: Bool = false
    /// Optional repo path to pre-fill the sheet with (e.g. "New Worktree from
    /// Here" on a specific card), overriding the current-workspace guess.
    @Published var newWorkspaceRepoHint: String? = nil
    /// Workspace whose worktree the user asked to delete. Drives a single shared
    /// confirm dialog (hosted in ContentView) so every entry point — card menu,
    /// command palette — funnels through the same "this deletes files" gate.
    @Published var pendingWorktreeDelete: UUID? = nil
    /// Set when a worktree was created but "bring uncommitted changes" failed to
    /// copy them in. Drives a one-shot warning alert (hosted in ContentView) so
    /// the failure isn't silent — the changes are untouched in the base checkout.
    @Published var worktreeCarryFailed: Bool = false
    func openNewWorkspace(repoHint: String? = nil) {
        newWorkspaceRepoHint = repoHint
        newWorkspaceSheetOpen = true
    }

    /// Lightweight git status per workspace, keyed by workspace id. Refreshed by
    /// filesystem/command events plus a slow fallback. NON-persistent — it's live
    /// state, recomputed each launch, never written to state.json.
    @Published var gitStatuses: [UUID: GitStatus] = [:]
    /// Serializes `git status` per workspace while retaining one coalesced
    /// follow-up request. A bare in-flight Set dropped an invalidation when a
    /// trailing event landed while the previous async status/log pair was still
    /// suspended, leaving a stale badge until the slow fallback poll.
    private var gitRefreshGate = GitRefreshInFlightGate()
    /// Resolved cwds confirmed (via a `rev-parse` probe) NOT to be inside a git
    /// repo. A plain shell sitting in such a dir is skipped on subsequent polls
    /// instead of re-spawning a doomed `git status` every tick. Only ever holds
    /// *guessed* paths (plain sources); bound repo/worktree paths are never
    /// cached, and a path is evicted the moment a status there succeeds.
    private var knownNonRepoPaths: Set<String> = []

    /// Out-of-band git (Plan B): runs as a subprocess, never via the terminal.
    let git = GitService()

    /// One-shot launch command for a freshly-minted pane (e.g. start `claude` in
    /// a new worktree). Consumed by `surfaceView` the first time that pane's
    /// surface is created, then removed — unlike `lastAgent` resume, it isn't
    /// persisted and never re-runs.
    private var pendingInitialInput: [WorkspacePaneKey: String] = [:]

    /// Tick incremented whenever the global ⌘F is fired. `SidebarView`
    /// observes this and pulls focus into its search field. Using a tick
    /// (vs. a `Bool` toggle) avoids the bool's "already true" no-op when
    /// the user fires the shortcut twice without an intervening blur.
    @Published var sidebarSearchFocusTick: Int = 0
    func focusSidebarSearch() {
        // Auto-expand sidebar if collapsed — otherwise ⌘F appears to
        // do nothing because the search field isn't on screen.
        if sidebarCollapsed { sidebarCollapsed = false }
        sidebarSearchFocusTick &+= 1
    }

    /// One-shot: stays false until a launch focus claim actually succeeds, so
    /// a claim that bailed (e.g. a modal was already up) isn't marked done.
    /// The only call site is launch-time, so this flips at most once.
    private var launchFocusClaimed = false

    /// True while an in-window modal owns keyboard focus. These capture and
    /// restore the first responder themselves, so the launch assertion must
    /// not displace them.
    private var modalOwnsFocus: Bool {
        commandPaletteOpen || agentChooserIntent != nil
            || !whatsNewNotes.isEmpty || settingsOpen || newWorkspaceSheetOpen
    }

    /// The already-minted surface for the focused pane of the selected
    /// workspace, or nil if it hasn't been rendered yet. Non-minting — safe
    /// to call from launch-time focus assertions that must NOT spawn a shell
    /// as a side effect.
    var currentFocusedSurfaceView: GhosttySurfaceView? {
        guard let wsID = selectedWorkspaceID else { return nil }
        return surfaceViews[WorkspacePaneKey(workspace: wsID, pane: currentFocusedPane)]
    }

    /// At launch, put keyboard focus in the focused pane's terminal instead of
    /// the sidebar's search field. With no view explicitly claiming first
    /// responder, AppKit's default key-view traversal hands the window's
    /// initial focus to the sidebar search field (its field editor — an
    /// `NSText` — becomes first responder). `PaneSurfaceRepresentable`'s ~1/s
    /// focus sync then SKIPS, because it deliberately refuses to yank focus
    /// away from an active text editor (so it can't steal focus from a search
    /// box the user clicked), so the terminal never wins it back. This claims
    /// the surface directly — bypassing that guard, which is safe because no
    /// user clicked the search field at launch. Mirrors the command-palette's
    /// focus-claim dance (#32).
    ///
    /// Launch-safety — this cannot break app launch:
    ///  • It never touches launch-fragile singletons: the window comes from
    ///    `surface.window` (held alive by the rendered pane), NOT
    ///    `NSApp.keyWindow`, which can still be nil early in launch (the #43
    ///    trap was the same shape of launch-time nil deref).
    ///  • It runs only via `DispatchQueue.main.async` — strictly after the
    ///    window is on screen and the run loop is turning, never inline in
    ///    the launch path.
    ///  • Every step is optional-guarded behind `[weak self]`; any nil or
    ///    mid-teardown state degrades to a no-op rather than trapping.
    ///  • Only first-responder APIs stable since macOS 10.0 are used (deploy
    ///    target is 14.0), so there's no version-conditional behaviour.
    /// No-ops once a modal that owns focus (palette, What's New, settings
    /// sheet, …) is up.
    func assertTerminalFocusOnLaunch() {
        guard !launchFocusClaimed, !modalOwnsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.launchFocusClaimed,
                  let surface = self.currentFocusedSurfaceView,
                  let window = surface.window,
                  !self.modalOwnsFocus else { return }
            if window.makeFirstResponder(surface) {
                self.launchFocusClaimed = true
            }
        }
    }

    /// Preferred UI language identifier. `"system"` follows the OS; any
    /// other value is a BCP-47 tag (e.g. `"en"`, `"zh-Hans"`). Persists
    /// across launches via UserDefaults so the choice survives quits.
    @Published var preferredLanguage: String = UserDefaults.standard.string(forKey: "glint.preferredLanguage") ?? "system" {
        didSet {
            UserDefaults.standard.set(preferredLanguage, forKey: "glint.preferredLanguage")
        }
    }

    /// Terminal appearance settings. Each is persisted to UserDefaults and
    /// fed into ghostty via `GhosttyManager.reloadConfig()` whenever it
    /// changes. The `didSet` hooks both persist and trigger live reload.
    ///
    /// 读写都规范化为「去首尾空白」的形式 —— 下游 FontCatalog 的 Current 行用
    /// trimmed 值匹配,如果绑定值不 trim,选中态会对不上(老 UserDefaults 里
    /// 留下 " SF Mono " 会让下拉同时出 Recommended 与 Current 两条)。CJK 路径
    /// 已经这么做,这里保持对称。
    @Published var terminalFontFamily: String = {
        let raw = (UserDefaults.standard.string(forKey: "glint.terminalFontFamily") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "SF Mono" : raw
    }() {
        didSet {
            let canonical = terminalFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            if canonical != terminalFontFamily {
                terminalFontFamily = canonical
                return
            }
            UserDefaults.standard.set(canonical, forKey: "glint.terminalFontFamily")
            GhosttyManager.shared.reloadConfig()
        }
    }
    @Published var terminalFontSize: Double = {
        let v = UserDefaults.standard.double(forKey: "glint.terminalFontSize")
        return v == 0 ? 13 : v
    }() {
        didSet {
            UserDefaults.standard.set(terminalFontSize, forKey: "glint.terminalFontSize")
            GhosttyManager.shared.reloadConfig()
        }
    }
    /// 整个终端文本以字体的 Bold 变体渲染。开 → 注入 `font-style = Bold`(同时把
    /// `font-style-bold` 也定到 Bold,避免 ANSI bold 退化到合成描边)。家族里没有
    /// Bold 切片时 ghostty 会回落到 regular,不会换家族。
    @Published var terminalFontBold: Bool = (UserDefaults.standard.object(forKey: "glint.terminalFontBold") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(terminalFontBold, forKey: "glint.terminalFontBold")
            GhosttyManager.shared.reloadConfig()
        }
    }
    /// CJK fallback 字体家族。空 = 不注入，CJK 字形交给系统/ghostty 默认 fallback
    /// 链(macOS 上通常就是苹方)。非空 = 在主字体与 Menlo 之间插一行
    /// `font-family = <family>`,主字体缺 CJK 字形时优先回落到这里。
    ///
    /// 读写都规范化为「去首尾空白」的形式 —— 下游 FontCatalog 的 Current 行
    /// 用 trimmed 值匹配,如果绑定值不 trim,选中态会对不上。
    @Published var terminalCJKFontFamily: String = (UserDefaults.standard.string(forKey: "glint.terminalCJKFontFamily") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    {
        didSet {
            let canonical = terminalCJKFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            if canonical != terminalCJKFontFamily {
                // 反向写回:避免 didSet 递归调用,只在确实需要时改 @Published 值。
                terminalCJKFontFamily = canonical
                return
            }
            UserDefaults.standard.set(canonical, forKey: "glint.terminalCJKFontFamily")
            GhosttyManager.shared.reloadConfig()
        }
    }
    /// One of `block` / `bar` / `underline`, matching ghostty's `cursor-style`.
    @Published var terminalCursorStyle: String = UserDefaults.standard.string(forKey: "glint.terminalCursorStyle") ?? "block" {
        didSet {
            UserDefaults.standard.set(terminalCursorStyle, forKey: "glint.terminalCursorStyle")
            GhosttyManager.shared.reloadConfig()
        }
    }
    @Published var terminalCursorBlink: Bool = (UserDefaults.standard.object(forKey: "glint.terminalCursorBlink") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(terminalCursorBlink, forKey: "glint.terminalCursorBlink")
            GhosttyManager.shared.reloadConfig()
        }
    }
    @Published var terminalScrollbackLimitBytes: Int = {
        let defaults = UserDefaults.standard
        let choices = [5, 10, 25, 50, 100, 250].map { $0 * 1_000_000 }
        if let bytes = defaults.object(forKey: "glint.terminalScrollbackLimitBytes") as? Int,
           bytes > 0 {
            let normalized = choices.first { $0 >= bytes } ?? bytes
            if normalized != bytes {
                defaults.set(normalized, forKey: "glint.terminalScrollbackLimitBytes")
            }
            return normalized
        }

        // Migration from the old UI, where this setting was presented as a
        // row count even though Ghostty accepts a byte budget.
        let oldRows = defaults.integer(forKey: "glint.terminalScrollback")
        let rows = oldRows == 0 ? 10_000 : oldRows
        let bytes = rows * 2_500
        let normalized = choices.first { $0 >= bytes } ?? bytes
        defaults.set(normalized, forKey: "glint.terminalScrollbackLimitBytes")
        return normalized
    }() {
        didSet {
            UserDefaults.standard.set(terminalScrollbackLimitBytes, forKey: "glint.terminalScrollbackLimitBytes")
            GhosttyManager.shared.reloadConfig()
        }
    }

    static let idleTerminalTimeoutChoices = [60, 300, 600, 900, 1_800, 3_600]

    /// Opt-in memory saving: release inactive Ghostty surfaces only when they
    /// are sitting at a plain shell prompt. The pane itself remains and wakes
    /// in its last directory when selected again.
    @Published var freeIdleTerminalsEnabled: Bool =
        (UserDefaults.standard.object(forKey: "glint.freeIdleTerminalsEnabled") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(freeIdleTerminalsEnabled,
                                      forKey: "glint.freeIdleTerminalsEnabled")
            if freeIdleTerminalsEnabled { resetIdleTerminalTimeouts() }
        }
    }

    @Published var idleTerminalTimeoutSeconds: Int = {
        let saved = UserDefaults.standard.integer(forKey: "glint.idleTerminalTimeoutSeconds")
        return WorkspaceStore.idleTerminalTimeoutChoices.contains(saved) ? saved : 300
    }() {
        didSet {
            guard Self.idleTerminalTimeoutChoices.contains(idleTerminalTimeoutSeconds) else {
                idleTerminalTimeoutSeconds = 300
                return
            }
            UserDefaults.standard.set(idleTerminalTimeoutSeconds,
                                      forKey: "glint.idleTerminalTimeoutSeconds")
            resetIdleTerminalTimeouts()
        }
    }

    /// Which Claude icon family the UI draws: the animated robot mascot, or
    /// the spark mark (StatusIconsPreview.jsx port — see
    /// scripts/generate_claude_spark_icons.py). Completion has no spark
    /// animation by design: the traffic-light status dot carries that state.
    @Published var claudeIconStyle: ClaudeIconStyle = {
        let raw = UserDefaults.standard.string(forKey: "glint.claudeIconStyle") ?? ""
        return ClaudeIconStyle(rawValue: raw) ?? .spark
    }() {
        didSet {
            UserDefaults.standard.set(claudeIconStyle.rawValue, forKey: "glint.claudeIconStyle")
        }
    }

    /// Whether Glint's Claude Code hook script is currently registered in
    /// `~/.claude/settings.json`. Mirrors `AgentHookInstaller.isInstalled()`
    /// so the Settings UI can react without polling.
    @Published var claudeHooksInstalled: Bool = false

    /// Whether Glint's Codex hook script is registered in `~/.codex/hooks.json`.
    @Published var codexHooksInstalled: Bool = false

    /// Whether Glint's OpenCode plugin is installed in `~/.config/opencode/plugins`.
    @Published var opencodeHooksInstalled: Bool = false

    /// Whether Glint's Devin hook entries are registered in `~/.config/devin/config.json`.
    @Published var devinHooksInstalled: Bool = false

    /// Whether Glint's OMP extension is registered in `~/.omp/agent/settings.json`.
    @Published var ompHooksInstalled: Bool = false

    /// Whether Glint's Grok Build hooks are registered in `~/.grok/hooks/glint.json`.
    @Published var grokHooksInstalled: Bool = false

    /// Whether Glint's pi extension is installed in `~/.pi/agent/extensions`.
    @Published var piHooksInstalled: Bool = false

    /// Whether Glint's modified-Enter shell keybindings are present in the
    /// user's shell rc (~/.zshrc / ~/.bashrc). Opt-in, default off.
    @Published var shellKeybindsInstalled: Bool = false

    /// Single switch for all behind-window vibrancy in the chrome (sidebar,
    /// toolbar, and the matching settings sidebar). When off, chrome falls
    /// back to flat opaque surfaces — useful on older Macs and gives a
    /// noticeably flatter look. Defaults to on.
    @Published var glassEffect: Bool = (UserDefaults.standard.object(forKey: "glint.glassEffect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(glassEffect, forKey: "glint.glassEffect") }
    }

    /// When on, every "instant" new-terminal action (⌘T / ⌘D / ⌘N and the tab
    /// bar's "+") pops the agent chooser instead of opening a bare shell, so the
    /// new tab / pane / workspace can start in Claude / Codex / … Default off —
    /// the fast shell path stays the default. Persisted under glint.promptAgentOnNew.
    @Published var promptAgentOnNew: Bool = (UserDefaults.standard.object(forKey: "glint.promptAgentOnNew") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(promptAgentOnNew, forKey: "glint.promptAgentOnNew") }
    }

    /// UI accent color. Drives focus/selection highlights across the chrome,
    /// plus the terminal cursor and selection highlight. Values: "indigo" |
    /// "cyan" | "pink" | "orange" | "green". Default "indigo". Persists
    /// across launches.
    @Published var accentName: String = UserDefaults.standard.string(forKey: "glint.accentName") ?? "indigo" {
        didSet {
            UserDefaults.standard.set(accentName, forKey: "glint.accentName")
            GhosttyManager.shared.reloadConfig()
        }
    }

    var accent: Color { Theme.accent(named: accentName) }

    /// 当前主题 id(见 GlintTheme/ThemeRegistry)。改变时:持久化 → 更新 ThemeProvider
    /// → 重注入 ghostty 终端配色 → bump themeRevision 触发 chrome 刷新。默认 glint-dark。
    @Published var themeName: String = UserDefaults.standard.string(forKey: "glint.themeName") ?? "glint-dark" {
        didSet {
            UserDefaults.standard.set(themeName, forKey: "glint.themeName")
            ThemeProvider.shared.current = ThemeRegistry.theme(id: themeName)
            GhosttyManager.shared.reloadConfig()
            GhosttyManager.shared.syncWindowAppearance()   // 浅/暗主题 → 玻璃材质跟随
            themeRevision &+= 1
        }
    }

    /// 单调计数器,主题切换时 bump。chrome 根容器依赖它来强制整树重新求值——因为
    /// Theme.xxx 是 computed,SwiftUI 不会自动感知 ThemeProvider 内部的变化。
    @Published var themeRevision: Int = 0

    /// 临时套用某主题做「实时预览」——**不写 UserDefaults、不改 themeName**,只动
    /// ThemeProvider.current + 重注入终端 + bump 刷新 chrome。主题浏览器用方向键/hover
    /// 扫过列表时调它,让整窗即时变样;关闭时若未确认,用 `previewTheme(id: themeName)`
    /// 还原回已确认的真值即可(themeName 全程没被动过)。
    func previewTheme(id: String) {
        ThemeProvider.shared.current = ThemeRegistry.theme(id: id)
        GhosttyManager.shared.reloadConfig()
        GhosttyManager.shared.syncWindowAppearance()
        themeRevision &+= 1
    }

    // MARK: 透明度与模糊
    //
    // 终端区和 chrome(侧栏/工具栏)各一条透明度,可分开调:让桌面从背后透出。
    // 窗口本身已是 isOpaque=false(AppDelegate),所以这里只需让各背景层带上 opacity,
    // 并给 ghostty 注入 background-opacity / background-blur。默认全 1.0 / 0 = 现状不变。

    /// 终端区透明度(ghostty 背景 + 终端 pane 的 Glint 兜底背景)。0.3…1.0。
    @Published var terminalOpacity: Double =
        (UserDefaults.standard.object(forKey: "glint.terminalOpacity") as? Double) ?? 1.0 {
        didSet {
            UserDefaults.standard.set(terminalOpacity, forKey: "glint.terminalOpacity")
            GhosttyManager.shared.reloadConfig()   // 重注入 background-opacity
            themeRevision &+= 1                     // 刷新 Glint 终端背景层
        }
    }

    /// 终端是否透明(opacity < 1)。SwiftUI 侧的单一判定来源 —— 视图不再各自
    /// 内联 `terminalOpacity < 1.0`。AppKit 侧(GhosttySurfaceView / 容器层)走
    /// `GhosttyManager.terminalIsTransparent`,两者都以「opacity < 1」为唯一阈值,
    /// 且都最终从已写入的 `glint.terminalOpacity` 派生,稳态下恒一致。
    var isTerminalTransparent: Bool { terminalOpacity < 1.0 }

    /// 侧栏 / 工具栏透明度。0.3…1.0。不动 ghostty,只刷新 chrome 背景层。
    @Published var chromeOpacity: Double =
        (UserDefaults.standard.object(forKey: "glint.chromeOpacity") as? Double) ?? 1.0 {
        didSet {
            UserDefaults.standard.set(chromeOpacity, forKey: "glint.chromeOpacity")
            themeRevision &+= 1
        }
    }

    /// 背景模糊半径(ghostty background-blur)。0 = 关。把透出的桌面磨砂虚化。
    @Published var backgroundBlur: Double =
        (UserDefaults.standard.object(forKey: "glint.backgroundBlur") as? Double) ?? 0 {
        didSet {
            UserDefaults.standard.set(backgroundBlur, forKey: "glint.backgroundBlur")
            GhosttyManager.shared.reloadConfig()
        }
    }

    /// Dock icon the user picked. `.default` keeps the bundle's `.icon`
    /// asset (Liquid Glass on macOS 26); every other case overrides the
    /// running Dock tile with a static, pre-rendered image via
    /// `applyAppIcon()`. Persists across launches; `AppDelegate` restores
    /// it on startup.
    @Published var appIconPreset: AppIconPreset = {
        let raw = UserDefaults.standard.string(forKey: "glint.appIconPreset") ?? ""
        return AppIconPreset(rawValue: raw) ?? .default
    }() {
        didSet {
            UserDefaults.standard.set(appIconPreset.rawValue, forKey: "glint.appIconPreset")
            applyAppIcon()
        }
    }

    /// Push `appIconPreset` to the live Dock tile. A `nil` image restores
    /// the bundle icon (so macOS 26 re-applies Liquid Glass); a named asset
    /// overrides it with a static icon. Runtime icon overrides go through
    /// `NSImage`, which bypasses Liquid Glass — that's why the non-default
    /// presets are pre-rendered with their own padding and corner.
    /// Must run on the main thread; `didSet` and the launch restore both do.
    func applyAppIcon() {
        // `NSApp` is `NSApplication!` (IUO). Touching it during @StateObject
        // boxing at launch traps (#43), so guard like the dock-tile paths.
        // Today's callers (the `appIconPreset` didSet and AppDelegate's
        // main.async-deferred launch restore) land after NSApp is set, but a
        // future init-time caller would otherwise hit the same trap.
        guard let app = NSApp else { return }
        if let asset = appIconPreset.assetName {
            app.applicationIconImage = NSImage(named: asset)
        } else {
            app.applicationIconImage = nil
        }
    }

    /// On launch, re-select the workspace that was focused at last quit.
    /// When off, Glint starts on the first workspace in the list. Persists
    /// to UserDefaults so the choice survives restarts. Defaults to on.
    @Published var restoreLastWorkspace: Bool = (UserDefaults.standard.object(forKey: "glint.restoreLastWorkspace") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(restoreLastWorkspace, forKey: "glint.restoreLastWorkspace") }
    }

    /// On restart, auto-resume the last Claude session on any pane that was
    /// running `claude` at quit time, by feeding `claude --continue` as the
    /// pane's initial input. Opt-in (defaults to off) because it spawns a
    /// network-hitting CLI without user confirmation. The pane's `lastAgent`
    /// field is set by the foreground-process poller, so this only fires for
    /// panes where claude was actually live at the last poll.
    @Published var restoreClaudeSession: Bool = (UserDefaults.standard.object(forKey: "glint.restoreClaudeSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restoreClaudeSession, forKey: "glint.restoreClaudeSession") }
    }

    /// Same as `restoreClaudeSession` but for Codex — feeds `codex resume --last`.
    @Published var restoreCodexSession: Bool = (UserDefaults.standard.object(forKey: "glint.restoreCodexSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restoreCodexSession, forKey: "glint.restoreCodexSession") }
    }

    /// Same as `restoreClaudeSession` but for OpenCode — feeds `opencode --continue`.
    @Published var restoreOpenCodeSession: Bool = (UserDefaults.standard.object(forKey: "glint.restoreOpenCodeSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restoreOpenCodeSession, forKey: "glint.restoreOpenCodeSession") }
    }

    /// Same as `restoreClaudeSession` but for Devin — feeds `devin --continue`.
    @Published var restoreDevinSession: Bool = (UserDefaults.standard.object(forKey: "glint.restoreDevinSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restoreDevinSession, forKey: "glint.restoreDevinSession") }
    }

    /// Same as `restoreClaudeSession` but for OMP — feeds `omp -c` / `omp -r <id>`.
    @Published var restoreOmpSession: Bool = (UserDefaults.standard.object(forKey: "glint.restoreOmpSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restoreOmpSession, forKey: "glint.restoreOmpSession") }
    }

    /// Same as `restoreClaudeSession` but for Grok Build — feeds `grok --continue` / `grok --resume <id>`.
    @Published var restoreGrokSession: Bool = (UserDefaults.standard.object(forKey: "glint.restoreGrokSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restoreGrokSession, forKey: "glint.restoreGrokSession") }
    }

    /// Same as `restoreClaudeSession` but for pi — feeds `pi --continue` / `pi --session-id <id>`.
    @Published var restorePiSession: Bool = (UserDefaults.standard.object(forKey: "glint.restorePiSession") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(restorePiSession, forKey: "glint.restorePiSession") }
    }

    /// Maps each agent kind to the @Published toggle that gates its
    /// session-restore-on-launch. Single source of truth: adding a new
    /// agent means adding ONE entry here, not editing two parallel switches
    /// across files (one here, one in `PaneAgentKind.restoreCommand`).
    private static let restoreToggleKeyPaths: [PaneAgentKind: ReferenceWritableKeyPath<WorkspaceStore, Bool>] = [
        .claude:   \.restoreClaudeSession,
        .codex:    \.restoreCodexSession,
        .opencode: \.restoreOpenCodeSession,
        .devin:    \.restoreDevinSession,
        .omp:      \.restoreOmpSession,
        .grok:     \.restoreGrokSession,
        .pi:       \.restorePiSession,
    ]

    /// Whether session-restore-on-launch is enabled for `kind`. Used by
    /// `surfaceView` so the resume dispatch stays kind-agnostic.
    private func restoreEnabled(for kind: PaneAgentKind) -> Bool {
        guard let path = Self.restoreToggleKeyPaths[kind] else { return false }
        return self[keyPath: path]
    }

    /// Master switch for the external control socket (control.sock). Off by
    /// default — the socket lets any local process holding the 0600 token
    /// inject keystrokes into your terminals, so it's opt-in. The didSet
    /// starts/stops the listener immediately, so toggling takes effect live
    /// with no app restart.
    @Published var externalControlEnabled: Bool = (UserDefaults.standard.object(forKey: "glint.externalControlEnabled") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(externalControlEnabled, forKey: "glint.externalControlEnabled")
            if externalControlEnabled { ControlBridge.shared.start() }
            else { ControlBridge.shared.stop() }
        }
    }

    /// Whether the sidebar's "Archived" section is currently expanded.
    /// Persists across launches so a user who keeps it open doesn't have to
    /// re-open it every cold start.
    @Published var archiveExpanded: Bool = (UserDefaults.standard.object(forKey: "glint.archiveExpanded") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(archiveExpanded, forKey: "glint.archiveExpanded") }
    }

    /// Inline command suggestion (zsh ghost text). Toggling this writes /
    /// strips a fenced block in `~/.zshrc` that sources Glint's bundled
    /// zsh-autosuggestions copy. We use the shell-side rendering rather than
    /// a macOS-side overlay because the overlay never matches ghostty's
    /// rasterization exactly (font fallback + cell-height adjustment +
    /// baseline metrics misalign on every pane). Already-running zsh
    /// sessions only pick up the change after they restart; newly opened
    /// panes get it immediately. Bash / fish panes are unaffected — the
    /// block lives in `.zshrc` only. Defaults to on.
    @Published var inlineSuggestionEnabled: Bool = (UserDefaults.standard.object(forKey: "glint.inlineSuggestion.enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(inlineSuggestionEnabled, forKey: "glint.inlineSuggestion.enabled")
            InlineSuggestionInstaller.apply(enabled: inlineSuggestionEnabled)
        }
    }

    /// Restore each pane's previous scrollback (colors intact) on launch via a
    /// render-grid snapshot taken off the hot path; off = nothing written or
    /// read. Defaults to off — opt-in, since it persists terminal contents to
    /// disk. Turning it off also purges any snapshots already on disk, so the
    /// feature leaves no residual persisted history behind.
    @Published var restoreTerminalScrollback: Bool = (UserDefaults.standard.object(forKey: "glint.restoreTerminalScrollback") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(restoreTerminalScrollback, forKey: "glint.restoreTerminalScrollback")
            if !restoreTerminalScrollback { ScrollbackArchive.purgeAll() }
        }
    }

    /// Play a chime when the focused pane in a background workspace flips
    /// to `.needsPermission`. Background-only so the chime doesn't fire on
    /// the workspace the user is already watching. Defaults to on.
    @Published var soundOnPermissionRequest: Bool = (UserDefaults.standard.object(forKey: "glint.soundOnPermissionRequest") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(soundOnPermissionRequest, forKey: "glint.soundOnPermissionRequest") }
    }

    /// Play a softer chime when a background workspace's agent finishes a
    /// turn (transitions into `.justCompleted`). Same background-only rule.
    /// Defaults to on.
    @Published var soundOnTurnComplete: Bool = (UserDefaults.standard.object(forKey: "glint.soundOnTurnComplete") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(soundOnTurnComplete, forKey: "glint.soundOnTurnComplete") }
    }

    /// Play an error tone when a background workspace's agent turn ends in an
    /// API/transport error (transitions into `.failed`). Same background-only
    /// rule as the other cues. Defaults to on.
    @Published var soundOnError: Bool = (UserDefaults.standard.object(forKey: "glint.soundOnError") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(soundOnError, forKey: "glint.soundOnError") }
    }

    /// 在后台 agent 需要关注时(权限请求 / 完成 / 出错),除了 chime 之外再弹一个
    /// 静默的 macOS 通知横幅。一个总开关覆盖三种状态。默认 off:横幅比 chime 更
    /// 打扰、且需要系统授权,让用户主动开启。
    @Published var systemNotificationOnAgentAttention: Bool =
        (UserDefaults.standard.object(forKey: "glint.systemNotificationOnAgentAttention") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(systemNotificationOnAgentAttention,
                                      forKey: "glint.systemNotificationOnAgentAttention")
            if systemNotificationOnAgentAttention {
                // 用户首次开启时请求授权;系统级已拒绝则为空操作。
                Task { try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
            }
        }
    }

    /// Show a Dock badge count for background agent states that need a look.
    /// Unlike notification banners this stays quiet and carries no prompt or
    /// transcript text. Defaults to on because it is non-interruptive.
    @Published var dockBadgeOnAgentAttention: Bool = (UserDefaults.standard.object(forKey: "glint.dockBadgeOnAgentAttention") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(dockBadgeOnAgentAttention, forKey: "glint.dockBadgeOnAgentAttention")
            if !dockBadgeOnAgentAttention { dockBadgePaneStatuses.removeAll() }
            updateDockBadge()
        }
    }

    /// For a plain (non-git-bound) workspace whose focused pane sits inside a
    /// git repo, review the whole repository from its root (on, default) or just
    /// the focused pane's current-directory subtree (off). Git-bound workspaces
    /// always review at the repo root — their gitPath is already root — so this
    /// only selects the scope for plain workspaces. See `openReview`.
    @Published var reviewAtRepoRoot: Bool = (UserDefaults.standard.object(forKey: "glint.reviewAtRepoRoot") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(reviewAtRepoRoot, forKey: "glint.reviewAtRepoRoot") }
    }

    /// Same choice, independent, for Reveal in Finder (⌘⇧F): reveal the repo
    /// root (on, default) or the focused pane's cwd (off) for plain workspaces.
    /// Git-bound workspaces always reveal their bound root. See
    /// `revealCurrentInFinder`.
    @Published var revealAtRepoRoot: Bool = (UserDefaults.standard.object(forKey: "glint.revealAtRepoRoot") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(revealAtRepoRoot, forKey: "glint.revealAtRepoRoot") }
    }

    /// NSSound names for the three audio cues, persisted; the defaults are
    /// the original hardcoded chimes.
    @Published var soundPermissionName: String = UserDefaults.standard.string(forKey: "glint.soundPermissionName") ?? "Funk" {
        didSet { UserDefaults.standard.set(soundPermissionName, forKey: "glint.soundPermissionName") }
    }
    @Published var soundCompleteName: String = UserDefaults.standard.string(forKey: "glint.soundCompleteName") ?? "Glass" {
        didSet { UserDefaults.standard.set(soundCompleteName, forKey: "glint.soundCompleteName") }
    }
    @Published var soundErrorName: String = UserDefaults.standard.string(forKey: "glint.soundErrorName") ?? "Basso" {
        didSet { UserDefaults.standard.set(soundErrorName, forKey: "glint.soundErrorName") }
    }

    /// Names offered by the sound pickers in Settings: the system alert
    /// sounds (the .aiff files in /System/Library/Sounds — same set the
    /// macOS Sound preference pane lists).
    static let systemSoundNames: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = files.filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(".aiff".count)) }
            .sorted()
        return names.isEmpty ? ["Basso", "Funk", "Glass"] : names
    }()

    /// Float workspaces whose agents just finished a turn (`.justCompleted`)
    /// to the top of the sidebar list. The status auto-clears when the user
    /// focuses that workspace's pane, so the card sinks back to its drag-
    /// assigned slot — i.e. this is a soft visual nudge, not a permanent
    /// reorder. Defaults to off so existing users see no change.
    @Published var sortCompletedFirst: Bool = (UserDefaults.standard.object(forKey: "glint.sortCompletedFirst") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(sortCompletedFirst, forKey: "glint.sortCompletedFirst") }
    }

    /// Show the "Paste potentially unsafe text?" confirm dialog when the
    /// clipboard contains newlines or control characters. The underlying
    /// default (`glint.skipUnsafePasteConfirmation`) is inverted so the
    /// "Don't ask again" checkbox in the alert flips this off, and the
    /// settings toggle reads "Warn before pasting multi-line text".
    @Published var warnBeforeUnsafePaste: Bool = !UserDefaults.standard.bool(forKey: "glint.skipUnsafePasteConfirmation") {
        didSet { UserDefaults.standard.set(!warnBeforeUnsafePaste, forKey: "glint.skipUnsafePasteConfirmation") }
    }

    /// Offer to install both agents' hooks on the very first launch so
    /// status tracking works out of the box — but ask first (these write
    /// into another tool's config files), and ask exactly once. "Not Now"
    /// never re-prompts and launches never silently re-add the entries;
    /// the Settings → Install button is the only way back in.
    ///
    /// For agents that remain installed, Glint-owned hook entries are
    /// refreshed every launch — script-body and event-list updates shipped
    /// with new Glint versions must propagate even though the prompt is
    /// skipped.
    private struct AgentHookSpec {
        let handledKey: String
        let displayName: String
        let isPresent: () -> Bool
        let isInstalled: () -> Bool
        let install: () -> Void
    }

    private static func agentHookSpecs(socketPath: String) -> [AgentHookSpec] {
        [
            AgentHookSpec(
                handledKey: "glint.claudeHooksAutoInstalled",
                displayName: "Claude Code",
                isPresent: AgentHookInstaller.isAgentPresent,
                isInstalled: AgentHookInstaller.isInstalled,
                install: { AgentHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
            AgentHookSpec(
                handledKey: "glint.codexHooksAutoInstalled",
                displayName: "Codex",
                isPresent: CodexHookInstaller.isAgentPresent,
                isInstalled: CodexHookInstaller.isInstalled,
                install: { CodexHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
            AgentHookSpec(
                handledKey: "glint.opencodeHooksAutoInstalled",
                displayName: "OpenCode",
                isPresent: OpenCodeHookInstaller.isAgentPresent,
                isInstalled: OpenCodeHookInstaller.isInstalled,
                install: { OpenCodeHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
            AgentHookSpec(
                handledKey: "glint.devinHooksAutoInstalled",
                displayName: "Devin",
                isPresent: DevinHookInstaller.isAgentPresent,
                isInstalled: { DevinHookInstaller.isInstalled() },
                install: { DevinHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
            AgentHookSpec(
                handledKey: "glint.ompHooksAutoInstalled",
                displayName: "OMP",
                isPresent: OmpHookInstaller.isAgentPresent,
                isInstalled: { OmpHookInstaller.isInstalled() },
                install: { OmpHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
            AgentHookSpec(
                handledKey: "glint.grokHooksAutoInstalled",
                displayName: "Grok",
                isPresent: GrokHookInstaller.isAgentPresent,
                isInstalled: { GrokHookInstaller.isInstalled() },
                install: { GrokHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
            AgentHookSpec(
                handledKey: "glint.piHooksAutoInstalled",
                displayName: "Pi",
                isPresent: PiHookInstaller.isAgentPresent,
                isInstalled: { PiHookInstaller.isInstalled() },
                install: { PiHookInstaller.installIfNeeded(socketPath: socketPath) }
            ),
        ]
    }

    private static func autoInstallAgentHooksOnFirstLaunch(socketPath: String) {
        // Skip the modal dialog when running under XCTest — the alert blocks
        // the test runner and there's no user to click the button.
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return }

        let defaults = UserDefaults.standard
        let specs = agentHookSpecs(socketPath: socketPath)

        // Refresh hooks we already manage so script-body / event-list changes
        // shipped with a new Glint version propagate even when the prompt is
        // skipped.
        for spec in specs where defaults.bool(forKey: spec.handledKey) && spec.isInstalled() {
            spec.install()
        }

        // Only offer to install for agents the user actually has on this Mac
        // AND we haven't asked about yet. Absent agents are deliberately NOT
        // marked handled, so if one is installed later we'll offer hooks for
        // it on a future launch instead of blindly writing config for tools
        // that aren't there.
        let pending = specs.filter { !defaults.bool(forKey: $0.handledKey) && $0.isPresent() }
        guard !pending.isEmpty else { return }

        // Defer past launch so the alert doesn't pop before the main window.
        Task { @MainActor in
            let names = pending.map(\.displayName)
            let list = ListFormatter.localizedString(byJoining: names)
            let alert = NSAlert()
            alert.messageText = String(localized: "Show agent status in the sidebar?")
            alert.informativeText = String(
                format: String(localized: "Glint can register status hooks with %@ that report when an agent is thinking, finished, or waiting for approval. They only send events to Glint on this Mac. You can uninstall them anytime in Settings → Agents."),
                list
            )
            alert.addButton(withTitle: String(localized: "Install Hooks"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            let install = alert.runModal() == .alertFirstButtonReturn
            for spec in pending {
                if install { spec.install() }
                defaults.set(true, forKey: spec.handledKey)
            }
            WorkspaceStore.current?.claudeHooksInstalled = AgentHookInstaller.isInstalled()
            WorkspaceStore.current?.codexHooksInstalled = CodexHookInstaller.isInstalled()
            WorkspaceStore.current?.opencodeHooksInstalled = OpenCodeHookInstaller.isInstalled()
            WorkspaceStore.current?.devinHooksInstalled = DevinHookInstaller.isInstalled()
            WorkspaceStore.current?.ompHooksInstalled = OmpHookInstaller.isInstalled()
            WorkspaceStore.current?.grokHooksInstalled = GrokHookInstaller.isInstalled()
            WorkspaceStore.current?.piHooksInstalled = PiHookInstaller.isInstalled()
        }
    }

    /// Re-run the hook installer and refresh `claudeHooksInstalled`.
    func installClaudeHooks() {
        AgentHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.claudeHooksInstalled = AgentHookInstaller.isInstalled()
    }

    /// Remove Glint's hook entries from Claude's settings and delete the
    /// script. Idempotent.
    func uninstallClaudeHooks() {
        AgentHookInstaller.uninstall()
        self.claudeHooksInstalled = AgentHookInstaller.isInstalled()
    }

    func installCodexHooks() {
        CodexHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.codexHooksInstalled = CodexHookInstaller.isInstalled()
    }

    func uninstallCodexHooks() {
        CodexHookInstaller.uninstall()
        self.codexHooksInstalled = CodexHookInstaller.isInstalled()
    }

    func installOpenCodeHooks() {
        OpenCodeHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.opencodeHooksInstalled = OpenCodeHookInstaller.isInstalled()
    }

    func uninstallOpenCodeHooks() {
        OpenCodeHookInstaller.uninstall()
        self.opencodeHooksInstalled = OpenCodeHookInstaller.isInstalled()
    }

    func installDevinHooks() {
        DevinHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.devinHooksInstalled = DevinHookInstaller.isInstalled()
    }

    func uninstallDevinHooks() {
        DevinHookInstaller.uninstall()
        self.devinHooksInstalled = DevinHookInstaller.isInstalled()
    }

    func installOmpHooks() {
        OmpHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.ompHooksInstalled = OmpHookInstaller.isInstalled()
    }

    func uninstallOmpHooks() {
        OmpHookInstaller.uninstall()
        self.ompHooksInstalled = OmpHookInstaller.isInstalled()
    }

    func installGrokHooks() {
        GrokHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.grokHooksInstalled = GrokHookInstaller.isInstalled()
    }

    func uninstallGrokHooks() {
        GrokHookInstaller.uninstall()
        self.grokHooksInstalled = GrokHookInstaller.isInstalled()
    }

    func installPiHooks() {
        PiHookInstaller.installIfNeeded(socketPath: AgentBridge.shared.socketPath)
        self.piHooksInstalled = PiHookInstaller.isInstalled()
    }

    func uninstallPiHooks() {
        PiHookInstaller.uninstall()
        self.piHooksInstalled = PiHookInstaller.isInstalled()
    }

    func installShellKeybinds() {
        ShellKeybindInstaller.install()
        self.shellKeybindsInstalled = ShellKeybindInstaller.isInstalled()
    }

    func uninstallShellKeybinds() {
        ShellKeybindInstaller.uninstall()
        self.shellKeybindsInstalled = ShellKeybindInstaller.isInstalled()
    }

    /// Best-effort "is this agent installed on this Mac" checks, surfaced in
    /// Settings → Agents so a card reads "Not detected" instead of silently
    /// offering to install hooks for a tool the user doesn't have.
    var claudeDetected: Bool { AgentHookInstaller.isAgentPresent() }
    var codexDetected: Bool { CodexHookInstaller.isAgentPresent() }
    var opencodeDetected: Bool { OpenCodeHookInstaller.isAgentPresent() }
    var devinDetected: Bool { DevinHookInstaller.isAgentPresent() }
    var ompDetected: Bool { OmpHookInstaller.isAgentPresent() }
    var grokDetected: Bool { GrokHookInstaller.isAgentPresent() }
    var piDetected: Bool { PiHookInstaller.isAgentPresent() }

    /// Locale to inject into the SwiftUI environment. Driven by
    /// `preferredLanguage`. On macOS 14+, SwiftUI re-resolves
    /// `LocalizedStringKey` lookups when this env value changes, so
    /// language switching takes effect immediately without a relaunch.
    var preferredLocale: Locale {
        switch preferredLanguage {
        case "system":
            return .autoupdatingCurrent
        default:
            return Locale(identifier: preferredLanguage)
        }
    }

    /// Persistent NSView per global pane identity. Surfaces are keyed by
    /// (workspaceID, paneID) so switching workspaces doesn't destroy them.
    private var surfaceViews: [WorkspacePaneKey: GhosttySurfaceView] = [:]
    private var dockBadgePaneStatuses: [WorkspacePaneKey: PaneAgentStatus] = [:]

    private var saveCancellable: AnyCancellable?
    private var gitWatcherCancellable: AnyCancellable?
    private var fallbackTimer: Timer?
    private var fallbackGitTick = 0
    private var observerTokens: [NSObjectProtocol] = []
    private struct GitWatchRegistration {
        let path: String
        let watcher: GitRepositoryWatcher
    }
    private var gitWatchers: [UUID: GitWatchRegistration] = [:]
    /// Coalesces the command-finished and FSEvents channels so one logical
    /// change spawns at most one `git status` (see its own doc comment for the
    /// timing gap it closes before the in-flight gate is involved).
    private let gitRefreshCoordinator = GitRefreshCoordinator()

    /// The app's single live store. AppDelegate consults it for the quit
    /// confirmation (it has no other path to the store — the store is
    /// created by GlintApp as a @StateObject).
    static private(set) weak var current: WorkspaceStore?

    convenience init() {
        self.init(activity: PaneActivityStore())
    }

    init(activity: PaneActivityStore) {
        self.activity = activity
        let loaded = Persistence.load() ?? PersistedState.fresh
        self.workspaces = loaded.workspaces
        let shouldRestore = (UserDefaults.standard.object(forKey: "glint.restoreLastWorkspace") as? Bool) ?? true
        let firstActiveID = loaded.workspaces.first(where: { !$0.archived })?.id
            ?? loaded.workspaces.first?.id
        let restored = shouldRestore ? (loaded.selectedWorkspaceID ?? firstActiveID) : firstActiveID
        // If the persisted selection points at an archived workspace (e.g. the
        // user archived it in a prior session), drop back to the first active
        // one so the sidebar opens on something visible.
        if let id = restored,
           let ws = loaded.workspaces.first(where: { $0.id == id }),
           ws.archived {
            self.selectedWorkspaceID = firstActiveID
        } else {
            self.selectedWorkspaceID = restored
        }
        self.sidebarCollapsed = loaded.sidebarCollapsed
        Self.current = self
        // Drain paths Launch Services handed us before the store existed (cold
        // launch with a folder/file/glint:// URL). No-op when nothing's pending;
        // AppDelegate.deliver also calls flush() for warm-launch opens.
        DispatchQueue.main.async { AppDelegate.flush() }

        // Reconcile the zsh-side inline-suggestion install on every launch:
        // first-ever launch installs from the current default; subsequent
        // launches no-op (the snippet + zshrc block are already in place);
        // an app upgrade with a newer bundled zsh-autosuggestions copy gets
        // a fresh ~/.config/glint copy via content-diff. The didSet on the
        // toggle doesn't run during init, so we have to call this here.
        InlineSuggestionInstaller.apply(enabled: self.inlineSuggestionEnabled)

        // Debounced autosave: only persistable @Published fields trigger a save.
        // Wiring this to bare `objectWillChange` re-encodes on every transient
        // hook event (paneAgentState/paneProcesses/UI-only flags) — none of
        // which are part of PersistedState — so the disk write does nothing but
        // burn CPU and IO during active agent turns. Subscribe to the actual
        // persisted publishers instead, drop the synthetic initial value, and
        // map each one to Void so they merge into a single sink.
        saveCancellable = Publishers.MergeMany(
            $workspaces.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $selectedWorkspaceID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $sidebarCollapsed.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.persist() }

        // Repository bindings change rarely, but workspace model updates are
        // frequent. Reconcile by path so ordinary cwd/process updates don't
        // recreate FSEvent streams.
        gitWatcherCancellable = $workspaces
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncGitWatchers() }
        syncGitWatchers()

        // Shell integration drives normal cwd/process/git updates. This slow,
        // active-app-only timer is a correctness fallback for shells without
        // OSC 7 / command-finished integration and for long-running TUIs.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            // scheduledTimer fires on the main run loop, so this is already the
            // main actor — assumeIsolated avoids allocating a Task per fallback.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.offlineIdleTerminals()
                guard NSApp.isActive else { return }
                self.captureCwdsFromLiveSurfaces()
                self.flushScrollback()
                self.fallbackGitTick += 1
                if self.fallbackGitTick >= 2 {
                    self.fallbackGitTick = 0
                    self.refreshAllGitStatuses()
                }
            }
        }
        // Prime status for restored worktree workspaces right away.
        refreshAllGitStatuses()

        // Drop scrollback snapshots for panes that no longer exist.
        var liveScrollbackIDs = Set<String>()
        for ws in workspaces {
            for paneID in ws.panes.keys {
                liveScrollbackIDs.insert(
                    ScrollbackArchive.fileID(forPaneKey: "\(ws.id.uuidString):\(paneID.value)"))
            }
        }
        ScrollbackArchive.prune(keeping: liveScrollbackIDs)

        // Block-based observers hold their tokens in `observerTokens`; the
        // store currently lives as long as the app, but if it's ever torn
        // down (multi-window, tests) deinit removes them cleanly.

        // Final flush + save on app terminate. Must run synchronously: a Task
        // scheduled from willTerminate may never get a tick before the process
        // exits, and the snapshot writes are async on a utility queue — drain
        // blocks until they actually hit disk.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearDockBadge()
                self.captureCwdsFromLiveSurfaces()
                self.flushScrollback()
                self.persist()
            }
            ScrollbackArchive.drain()
        })

        // Event-driven cwd updates: ghostty fires this when a shell reports
        // its working directory via OSC 7.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .ghosttyCwdChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let view = note.object as? GhosttySurfaceView else { return }
                self?.captureSurfaceState(from: view)
            }
        })

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .ghosttyRemoteTitleChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let view = note.object as? GhosttySurfaceView else { return }
                self?.captureSurfaceState(from: view)
            }
        })

        // Command completion is the high-value event: update the one pane,
        // persist its scrollback, and refresh only its repository.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .ghosttyCommandFinished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let view = note.object as? GhosttySurfaceView,
                      let key = self.captureSurfaceState(from: view) else { return }
                if self.restoreTerminalScrollback {
                    view.noteCommandFinishedForScrollback()
                }
                let wsID = key.workspace
                // Route through the refresh coordinator so the FSEvents
                // callback that follows this same change ~0.5s later doesn't
                // spawn a second `git status` (the in-flight gate only merges
                // runs that overlap in time; a fast git finishes first).
                self.gitRefreshCoordinator.request(wsID, source: .commandFinished) { [weak self] in
                    self?.refreshGitStatusNow(for: wsID)
                }
            }
        })

        // Start the idle grace period at the moment the app loses focus rather
        // than at the next 30-second fallback tick.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let now = Date()
                self?.surfaceViews.values.forEach {
                    $0.applicationDidResignActive(now: now)
                }
            }
        })

        // "✓ done" is an unread badge cleared by *seeing* the workspace.
        // Selecting it is one way; the other is ⌘Tab-ing back to Glint while
        // already on it — without this, the badge would outlast the look.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                for (key, view) in self.surfaceViews {
                    view.applicationDidBecomeActive(
                        now: now,
                        workspaceIsSelected: key.workspace == self.selectedWorkspaceID
                    )
                }
                if let id = self.selectedWorkspaceID {
                    self.acknowledgeCompletionIfNeeded(for: id)
                }
                self.captureCwdsFromLiveSurfaces()
                self.flushScrollback()
                self.refreshAllGitStatuses()
            }
        })

        // Boot the CLI-agent IPC channel and route hook events into pane state.
        AgentBridge.shared.start()
        // Boot the inbound control channel (focus / inject / list) only if the
        // user opted in — see externalControlEnabled / ControlBridge and
        // docs/external-pane-control.md. Toggling it later is live.
        if externalControlEnabled { ControlBridge.shared.start() }
        else { ControlBridge.shared.reapStale() }
        Self.autoInstallAgentHooksOnFirstLaunch(socketPath: AgentBridge.shared.socketPath)
        self.claudeHooksInstalled = AgentHookInstaller.isInstalled()
        self.codexHooksInstalled = CodexHookInstaller.isInstalled()
        self.opencodeHooksInstalled = OpenCodeHookInstaller.isInstalled()
        self.devinHooksInstalled = DevinHookInstaller.isInstalled()
        self.ompHooksInstalled = OmpHookInstaller.isInstalled()
        self.grokHooksInstalled = GrokHookInstaller.isInstalled()
        self.shellKeybindsInstalled = ShellKeybindInstaller.isInstalled()
        // Defer to the next main-loop tick so this runs after
        // `applicationDidFinishLaunching`. Hitting `NSApp.dockTile` while
        // SwiftUI is still boxing `@StateObject` (which is when `init()` runs)
        // can race against AppKit's `NSApp` setup — see #43 on macOS 15.1.1.
        DispatchQueue.main.async { [weak self] in self?.updateDockBadge() }
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .glintAgentEvent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleAgentEvent(note.userInfo) }
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .glintPaneEscPressed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handlePaneEsc(note.userInfo) }
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .glintPaneReturnPressed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handlePaneReturn(note.userInfo) }
        })
    }

    deinit {
        fallbackTimer?.invalidate()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: surface registry

    struct WorkspacePaneKey: Hashable {
        let workspace: UUID
        let pane: PaneID
    }

    private func resetIdleTerminalTimeouts(now: Date = Date()) {
        for (key, view) in surfaceViews {
            view.resetIdleTimeout(
                now: now,
                workspaceIsSelected: key.workspace == selectedWorkspaceID
            )
        }
    }

    private func offlineIdleTerminals(now: Date = Date()) {
        guard freeIdleTerminalsEnabled else { return }
        let timeout = TimeInterval(idleTerminalTimeoutSeconds)
        for (key, view) in surfaceViews {
            view.takeOfflineIfEligible(
                enabled: true,
                timeout: timeout,
                now: now,
                workspaceIsSelected: key.workspace == selectedWorkspaceID
            )
        }
    }

    func surfaceView(workspaceID: UUID, paneID: PaneID, cwd: String?) -> GhosttySurfaceView {
        let key = WorkspacePaneKey(workspace: workspaceID, pane: paneID)
        if let v = surfaceViews[key] { return v }
        if ProcessInfo.processInfo.environment["GLINT_LOG_VISIBLE"] != nil {
            let known = workspaces.first { $0.id == workspaceID }?.panes.keys.contains(paneID) ?? false
            NSLog("[glint.visible] MINT surface ws=\(workspaceID.uuidString.prefix(8)) pane=\(paneID.value) inModel=\(known)")
        }
        let paneKey = "\(workspaceID.uuidString):\(paneID.value)"
        // Only top-edge panes need the padded launcher (clear + blank rows
        // to escape the floating header). A pane sitting below a vertical
        // split divider already starts mid-window, so padding leaves empty
        // rows above the prompt.
        let topAligned: Bool = {
            guard let ws = workspaces.first(where: { $0.id == workspaceID }) else { return true }
            for tab in ws.tabs {
                if let v = Self.leafTopAlignment(tab.root, target: paneID) { return v }
            }
            return true
        }()
        // Auto-resume the agent that was live on this pane at last quit, if
        // its per-agent toggle is on. Fed into ghostty as `initial_input` so
        // it runs after the shell prints its prompt — no timing dance on our
        // side. Resolved once at mint time; later toggle changes don't reach
        // a surface that already booted.
        // A pending one-shot command (e.g. launch the agent chosen when this
        // worktree workspace was created) wins over agent-resume and is consumed
        // exactly once.
        // Auto-resume the agent that was live on this pane at last quit, if
        // its per-agent toggle is on. We prefer `--resume <id>` (or each CLI's
        // equivalent) so multiple panes in the same cwd each land in their OWN
        // previous session instead of collapsing onto the most-recent one
        // (#45). No id captured ⇒ fall back to "resume most recent" — handles
        // pre-fix data and panes where no hook fired before shutdown.
        let restoreCommand: String? = {
            if let pending = pendingInitialInput.removeValue(forKey: key) { return pending }
            guard let pane = workspaces.first(where: { $0.id == workspaceID })?.panes[paneID],
                  let token = pane.lastAgent,
                  let kind = PaneAgentKind(rawValue: token),
                  restoreEnabled(for: kind) else { return nil }
            let sid = pane.sessionIds[kind.rawValue]
                .flatMap { Self.isValidSessionId($0) ? $0 : nil }
            return kind.restoreCommand(sessionId: sid, codexHome: pane.codexHome)
        }()
        let v = GhosttySurfaceView(
            frame: .zero,
            initialCwd: cwd,
            paneKey: paneKey,
            agentSocketPath: AgentBridge.shared.socketPath,
            topAligned: topAligned,
            initialInput: restoreCommand
        )
        surfaceViews[key] = v
        return v
    }

    /// Walks the split tree to decide whether `target` sits flush with the
    /// top edge of the window. Returns nil if the leaf isn't in this tree.
    /// Horizontal splits don't change top-alignment (both sides reach the
    /// top); a vertical split's `b` child (the lower half) does not.
    private static func leafTopAlignment(_ node: SplitNode, target: PaneID) -> Bool? {
        switch node {
        case .leaf(let id):
            return id == target ? true : nil
        case .split(.horizontal, _, let a, let b):
            if let v = leafTopAlignment(a, target: target) { return v }
            return leafTopAlignment(b, target: target)
        case .split(.vertical, _, let a, let b):
            if let v = leafTopAlignment(a, target: target) { return v }
            if leafTopAlignment(b, target: target) != nil { return false }
            return nil
        }
    }

    /// Snapshot every live surface's cwd back into the workspace model and
    /// refresh the per-pane foreground process name. Called periodically, on
    /// app exit, and whenever ghostty pushes a PWD update via its action
    /// callback.
    /// Persist every live pane's recorded terminal output. No-op when the
    /// feature is off. Each view only writes when it has new bytes.
    func flushScrollback() {
        guard restoreTerminalScrollback else { return }
        for view in surfaceViews.values {
            // Mark dirty when the pane's foreground pid changed since the last
            // flush — catches the "user `cd`'d / launched a TUI / agent
            // exited" case where no keystroke would have flipped the bit but
            // the grid clearly evolved. Cheap (a single sysctl read; the cwd
            // sweep just did the same one) and idempotent.
            view.noteForegroundPidForScrollback()
            view.flushScrollbackToDisk()
        }
    }

    func captureCwdsFromLiveSurfaces() {
        var newProcesses: [WorkspacePaneKey: String] = [:]
        for (key, view) in surfaceViews {
            if let name = captureSurfaceState(for: key, view: view) {
                newProcesses[key] = name
            }
        }
        if newProcesses != paneProcesses {
            for (key, name) in newProcesses where paneProcesses[key] != name {
                logProcessChange(key: key, name: name)
            }
            paneProcesses = newProcesses
        }
        for (key, name) in newProcesses {
            reconcileAgentState(key: key, processName: name)
        }
    }

    /// Capture only the surface named by a Ghostty event instead of rescanning
    /// every pane. Returns its model key for event-specific follow-up work.
    @discardableResult
    private func captureSurfaceState(from view: GhosttySurfaceView) -> WorkspacePaneKey? {
        guard let key = surfaceViews.first(where: { $0.value === view })?.key else { return nil }
        guard let name = captureSurfaceState(for: key, view: view) else { return key }
        if paneProcesses[key] != name {
            logProcessChange(key: key, name: name)
            paneProcesses[key] = name
        }
        reconcileAgentState(key: key, processName: name)
        return key
    }

    private func captureSurfaceState(for key: WorkspacePaneKey,
                                     view: GhosttySurfaceView) -> String? {
        guard let i = workspaces.firstIndex(where: { $0.id == key.workspace }),
              workspaces[i].panes[key.pane] != nil else { return nil }

        if let cwd = view.currentCwd(),
           workspaces[i].panes[key.pane]?.workingDirectory != cwd {
            workspaces[i].panes[key.pane]?.workingDirectory = cwd
        }
        let rctx = view.remoteReviewContext
        let rhost = view.remoteHost
        if workspaces[i].panes[key.pane]?.remoteTarget != rctx?.target
            || workspaces[i].panes[key.pane]?.remotePort != rctx?.port
            || workspaces[i].panes[key.pane]?.remotePath != rctx?.remotePath
            || workspaces[i].panes[key.pane]?.remoteHost != rhost {
            workspaces[i].panes[key.pane]?.remoteTarget = rctx?.target
            workspaces[i].panes[key.pane]?.remotePort = rctx?.port
            workspaces[i].panes[key.pane]?.remotePath = rctx?.remotePath
            workspaces[i].panes[key.pane]?.remoteHost = rhost
        }

        guard let name = view.foregroundProcessName() else { return nil }
        let agentKind = Self.agentKind(forProcessName: name)
        let agentToken = agentKind?.rawValue
        let foregroundIsExit = agentKind == nil && Self.isBenignShellProcessName(name)
        if agentKind != nil || foregroundIsExit {
            if workspaces[i].panes[key.pane]?.lastAgent != agentToken {
                workspaces[i].panes[key.pane]?.lastAgent = agentToken
            }
            if let existing = workspaces[i].panes[key.pane]?.sessionIds, !existing.isEmpty {
                let kept = existing.filter { $0.key == agentToken }
                if kept.count != existing.count {
                    workspaces[i].panes[key.pane]?.sessionIds = kept
                }
            }
        }
        if workspaces[i].panes[key.pane]?.codexHome != nil,
           Self.isBenignShellProcessName(name) {
            workspaces[i].panes[key.pane]?.codexHome = nil
        }
        return name
    }

    private func logProcessChange(key: WorkspacePaneKey, name: String) {
        NSLog("[glint] pane process changed: ws=\(key.workspace.uuidString.prefix(8)) pane=\(key.pane.value) -> \(name)")
    }

    private func reconcileAgentState(key: WorkspacePaneKey, processName: String) {
        guard var state = paneAgentState[key] else { return }
        guard let runningKind = Self.agentKind(named: processName) else {
            if state.status == .idle, Self.isBenignShellProcessName(processName) {
                paneAgentState.removeValue(forKey: key)
            }
            return
        }
        if runningKind != state.kind, state.status == .idle {
            state.kind = runningKind
            state.status = .idle
            state.detail = nil
            state.updatedAt = Date()
            paneAgentState[key] = state
        }
    }

    // MARK: agent hook events

    static func permissionRequestStatus(
        kind: PaneAgentKind,
        approvalsReviewer: String?
    ) -> PaneAgentStatus {
        guard kind == .codex else { return .needsPermission }
        // Only `auto_review` (Codex's guardian subagent) approves without the
        // human. `user`, nil, or any unrecognised reviewer still needs a person
        // — see AgentBridge.codexApprovalReviewer for why the default is
        // conservative rather than "anything but user".
        switch approvalsReviewer {
        case "auto_review": return .thinking
        default: return .needsPermission
        }
    }

    /// Translate one hook from the AgentBridge into pane state.
    func handleAgentEvent(_ info: [AnyHashable: Any]?) {
        guard let info,
              let paneStr = info["pane"] as? String,
              let hook = info["hook"] as? String,
              let key = Self.parsePaneKey(paneStr) else { return }

        let explicitKind = (info["agent"] as? String).flatMap(Self.agentKind(named:))
        let foregroundKind = surfaceViews[key]?.foregroundProcessName()
            .flatMap(Self.agentKind(named:))
        let polledKind = paneProcesses[key].flatMap(Self.agentKind(named:))
        // `resolvedKind` is best-guess identification for THIS event; nil when
        // we genuinely don't know which CLI fired. We still process the event
        // (status badge, detail text, kind = .claude as a safe display default
        // — see `kind` below), but a nil resolvedKind MUST NOT be used to key a
        // sessionId write: stashing a Codex/OpenCode/Devin uuid under "claude"
        // could stick until the next capture and a quit in that
        // window persists a misrouted resume map — restart would run
        // `claude --resume <foreign-uuid>` and fail. Every Glint-installed
        // reporter sets `agent` already, so this nil-path is normally
        // unreachable; the guard is defense-in-depth for future agent
        // integrations whose installer forgets the AGENT arg.
        let resolvedKind: PaneAgentKind? = explicitKind ?? paneAgentState[key]?.kind ?? foregroundKind ?? polledKind
        let kind = resolvedKind ?? .claude

        // Stash the per-pane session id whenever the hook carries one. The
        // shared reporter extracts it from each CLI's stdin payload via
        // `plutil`, the OpenCode JS plugin walks event payloads — by the
        // time AgentBridge has decoded `session_b64` they all land here as
        // `info["session"]`. Without this stash the restart path can only
        // run `--continue`/`--last`, which collapses every same-cwd pane
        // onto one session (#45). Skip the write when `resolvedKind` is nil
        // (see above) so we never cross-contaminate sessionIds.
        if let resolvedKind,
           let sessionId = info["session"] as? String,
           Self.isValidSessionId(sessionId),
           let wsIdx = workspaces.firstIndex(where: { $0.id == key.workspace }),
           workspaces[wsIdx].panes[key.pane]?.sessionIds[resolvedKind.rawValue] != sessionId {
            workspaces[wsIdx].panes[key.pane]?.sessionIds[resolvedKind.rawValue] = sessionId
        }

        // Note: we deliberately do NOT force-write paneProcesses here. The
        // surface capture owns that dictionary. Icon/state
        // already prefer paneAgentState (set below), which this event keeps
        // authoritative.

        var state = paneAgentState[key]
            ?? PaneAgentState(kind: kind, status: .idle, detail: nil, updatedAt: Date())
        state.kind = kind
        let oldStatus = state.status
        let now = Date()
        switch hook {
        case "SessionStart":      state.status = .idle
        case "UserPromptSubmit":  state.status = .thinking
        case "PreToolUse":        state.status = .tool
        case "PostToolUse":
            // Hook delivery is one process per event, so a PostToolUse from
            // the previous tool can arrive just after PermissionRequest and
            // incorrectly hide an active approval prompt. A real approval
            // should be followed by PreToolUse, which clears this state once
            // the requested tool actually starts.
            if state.status == .needsPermission,
               now.timeIntervalSince(state.updatedAt) < 2 {
                return
            }
            state.status = .thinking
        case "Notification":      break   // noisy: background/idle prompts, ignore
        case "PermissionRequest":
            state.status = Self.permissionRequestStatus(
                kind: kind,
                approvalsReviewer: info["approvals_reviewer"] as? String
            )
        case "PreCompact":        state.status = .compacting
        case "Stop":
            // `.justCompleted` persists until the user actually views this
            // pane — see `acknowledgeCompletionIfNeeded(for:)`. This is an
            // unread-style badge: switching to it clears it. We only skip
            // the badge when the user is actually watching: Glint frontmost
            // AND this pane on screen (its workspace selected and its tab
            // the selected tab). A finish in a background tab of the current
            // workspace still earns its green dot on the tab chip.
            if NSApp.isActive && isPaneVisible(key) {
                state.status = .idle
            } else {
                state.status = .justCompleted
            }
        case "StopFailure":
            // The turn died on an API/transport error (socket closed, rate-
            // limit, auth, overload). Claude fires StopFailure instead of Stop,
            // so this is the only end-of-turn signal we get — without it the
            // pane stays stuck on `.thinking`. Surface a sticky error badge,
            // cleared when the user views the workspace (like justCompleted).
            // Always set it, even if the user is watching: an error is worth a
            // beat of red rather than silently snapping to idle.
            state.status = .failed
        case "NeedsReply":
            // OMP's bridge sends NeedsReply when the agent invokes its `ask`
            // tool mid-turn — it's blocked on a question, not done (a normal
            // turn end still arrives as Stop). Always set the sticky badge,
            // even when the user is watching: unlike Stop's justCompleted,
            // NeedsReply means "your move", so it should never silently snap
            // to idle. Cleared on view like justCompleted/failed, or by the
            // answer's own tool_result → PostToolUse flipping back to busy.
            state.status = .needsReply
        default: break
        }
        // Anchor the turn clock at the start of active work, then keep it
        // through intermediate tool/thinking transitions — so the sidebar shows
        // total turn time, not per-step time. Two events (re)set it:
        //   • non-busy → busy: a fresh turn begins (UserPromptSubmit: idle → thinking)
        //   • leaving needsPermission back into work: the user just approved, so
        //     restart the clock — the (possibly long) approval wait shouldn't
        //     count toward the post-approval work time.
        let nowBusy = Self.isBusyStatus(state.status)
        let startsTurn = nowBusy && !Self.isBusyStatus(oldStatus)
        let resumesAfterApproval = nowBusy
            && oldStatus == .needsPermission && state.status != .needsPermission
        if startsTurn || resumesAfterApproval {
            state.turnStartedAt = now
        }
        state.updatedAt = now
        paneAgentState[key] = state

        // Audio cues fire whenever the user is NOT actively watching this
        // pane — that means Glint isn't the frontmost app, or the user is on
        // a different workspace, or on a different tab of this workspace. If
        // Glint has focus AND the pane is on screen, stay quiet.
        let userIsWatching = NSApp.isActive && isPaneVisible(key)
        if !userIsWatching && oldStatus != state.status {
            switch state.status {
            case .needsPermission where soundOnPermissionRequest:
                NSSound(named: soundPermissionName)?.play()
            case .justCompleted where soundOnTurnComplete:
                NSSound(named: soundCompleteName)?.play()
            case .needsReply where soundOnTurnComplete:
                NSSound(named: soundCompleteName)?.play()
            case .failed where soundOnError:
                NSSound(named: soundErrorName)?.play()
            default:
                break
            }
        }
        // 通知比 chime 门更严:仅在整个 Glint 处于后台时弹(前台切到别的 workspace
        // 不弹——横幅不该盖在用户正用的 app 上)。chime 走上面的 `!userIsWatching` 宽门。
        if systemNotificationOnAgentAttention && !NSApp.isActive && oldStatus != state.status {
            postAttentionNotification(status: state.status, key: key)
        }
        syncDockBadge(for: key, oldStatus: oldStatus, newStatus: state.status, userIsWatching: userIsWatching)
    }

    /// User pressed plain Esc in a pane whose agent is mid-turn. Neither
    /// claude nor codex emit any hook on user interrupt (`Stop` explicitly
    /// does not fire for interrupts), so this keypress is the only signal
    /// we get — optimistically flip busy → idle. False positives are
    /// self-correcting: if the agent is still working, its next hook
    /// event (PreToolUse/PostToolUse/…) restores the busy status.
    func handlePaneEsc(_ info: [AnyHashable: Any]?) {
        guard let info,
              let paneStr = info["pane"] as? String,
              let key = Self.parsePaneKey(paneStr),
              var state = paneAgentState[key] else { return }
        switch state.status {
        case .thinking, .tool, .compacting, .needsPermission:
            state.status = .idle
            state.updatedAt = Date()
            paneAgentState[key] = state
            clearDockBadge(for: key)
        case .idle, .justCompleted, .failed, .needsReply:
            // justCompleted/failed/needsReply are unread badges — only viewing
            // the workspace clears them, not a stray Esc.
            break
        }
    }

    /// User submitted a permission choice in an agent pane. Codex currently
    /// reports the prompt (`PermissionRequest`) but not the approval decision
    /// itself; the next hook may be `PostToolUse` or `Stop` after the tool
    /// finishes. Clear the waiting state as soon as Return is pressed so the
    /// tab/sidebar reflect that Glint is no longer blocked on the user.
    func handlePaneReturn(_ info: [AnyHashable: Any]?) {
        guard let info,
              let paneStr = info["pane"] as? String,
              let key = Self.parsePaneKey(paneStr) else { return }
        // Return commonly launches a foreground process. Query this pane once
        // after the shell has had time to exec instead of polling every pane.
        if let view = surfaceViews[key] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak view] in
                guard let self, let view else { return }
                self.captureSurfaceState(from: view)
            }
        }
        guard var state = paneAgentState[key],
              state.status == .needsPermission else { return }
        let now = Date()
        state.status = .tool
        state.updatedAt = now
        state.turnStartedAt = now
        paneAgentState[key] = state
        clearDockBadge(for: key)
    }

    /// Clear any `.justCompleted` / `.failed` / `.needsReply` panes back to
    /// `.idle` — but only the ones actually on screen: panes in
    /// `workspaceID`'s *selected tab*. Called when the user selects the
    /// workspace, switches to a tab, or ⌘Tabs back to Glint — each is "I saw
    /// it finished / saw it errored / saw it waiting". Background tabs keep
    /// their badge until visited.
    func acknowledgeCompletionIfNeeded(for workspaceID: UUID) {
        guard let ws = workspaces.first(where: { $0.id == workspaceID }),
              let tab = ws.selectedTab else { return }
        let visible = Set(tab.root.leaves)
        for key in Array(dockBadgePaneStatuses.keys)
        where key.workspace == workspaceID && visible.contains(key.pane) {
            clearDockBadge(for: key)
        }
        for (key, state) in paneAgentState
        where key.workspace == workspaceID && visible.contains(key.pane)
            && (state.status == .justCompleted || state.status == .failed || state.status == .needsReply) {
            paneAgentState[key]?.status = .idle
            paneAgentState[key]?.updatedAt = Date()
        }
    }

    private static func isDockBadgeStatus(_ status: PaneAgentStatus) -> Bool {
        switch status {
        case .needsPermission, .justCompleted, .failed, .needsReply:
            return true
        case .idle, .thinking, .tool, .compacting:
            return false
        }
    }

    /// 与 chime 镜像的静默横幅。title 用 workspace 名(数据、不翻译),body 走本地化。
    /// userInfo 带定位(workspace + pane),点击通知时据此呼出 app 并切到该 pane。
    private func postAttentionNotification(status: PaneAgentStatus, key: WorkspacePaneKey) {
        let body: String
        switch status {
        case .needsPermission: body = String(localized: "Waiting for your approval")
        case .justCompleted:   body = String(localized: "Agent finished its turn")
        case .failed:          body = String(localized: "Agent's turn ended in an error")
        case .needsReply:      body = String(localized: "Agent is waiting for your reply")
        default: return
        }
        let title = workspaces.first { $0.id == key.workspace }?.displayName
            ?? String(localized: "Glint")
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        // 不设 soundName — chime 已覆盖声音,横幅只负责视觉。
        c.userInfo = [
            "workspace": key.workspace.uuidString,
            "pane": String(key.pane.value),
        ]
        // Stable id per pane: a fresh banner replaces the stale one instead of
        // stacking up in Notification Center, where — once the process exits —
        // they become dead links that cold-launch a new instance on click.
        let id = "glint.attention.\(key.workspace.uuidString).\(key.pane.value)"
        let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func syncDockBadge(for key: WorkspacePaneKey,
                               oldStatus: PaneAgentStatus,
                               newStatus: PaneAgentStatus,
                               userIsWatching: Bool) {
        if userIsWatching {
            clearDockBadge(for: key)
            return
        }
        guard dockBadgeOnAgentAttention else { return }
        if oldStatus != newStatus, Self.isDockBadgeStatus(newStatus) {
            dockBadgePaneStatuses[key] = newStatus
        } else if !Self.isDockBadgeStatus(newStatus) {
            dockBadgePaneStatuses.removeValue(forKey: key)
        }
        updateDockBadge()
    }

    private func clearDockBadge(for key: WorkspacePaneKey) {
        guard dockBadgePaneStatuses.removeValue(forKey: key) != nil else { return }
        updateDockBadge()
    }

    private func clearDockBadges(for keys: [WorkspacePaneKey]) {
        var changed = false
        for key in keys where dockBadgePaneStatuses.removeValue(forKey: key) != nil {
            changed = true
        }
        if changed { updateDockBadge() }
    }

    private func clearDockBadge() {
        // `NSApp` is `NSApplication!` — touching `.dockTile` before AppKit has
        // wired up the shared instance traps with a Swift IUO unwrap. Bail out
        // silently in that window (issue #43 reproduces on macOS 15.1.1 where
        // SwiftUI's `@StateObject` box can run before `NSApp` is set).
        guard let app = NSApp else { return }
        guard !dockBadgePaneStatuses.isEmpty || app.dockTile.badgeLabel != nil else { return }
        dockBadgePaneStatuses.removeAll()
        updateDockBadge()
    }

    private func updateDockBadge() {
        guard let app = NSApp else { return }
        guard dockBadgeOnAgentAttention else {
            app.dockTile.badgeLabel = nil
            return
        }
        let count = dockBadgePaneStatuses.count
        app.dockTile.badgeLabel = count == 0 ? nil : "\(count)"
    }

    /// True when `key`'s pane is on screen right now: its workspace is the
    /// selected workspace AND it lives in that workspace's selected tab.
    /// Shared by the idle-release "is the user watching" checks and the
    /// deferred surface re-pin guard in `PaneSurfaceRepresentable` — the two
    /// must agree on what "visible" means, so don't fork this logic.
    func isPaneVisible(_ key: WorkspacePaneKey) -> Bool {
        Self.paneIsVisible(key, selectedWorkspaceID: selectedWorkspaceID,
                           in: selectedWorkspace)
    }

    /// Pure core of `isPaneVisible(_:)`, split out so tests can exercise it
    /// without a live store (whose init loads persisted state and touches
    /// the filesystem).
    static func paneIsVisible(_ key: WorkspacePaneKey,
                              selectedWorkspaceID: UUID?,
                              in selectedWorkspace: Workspace?) -> Bool {
        guard selectedWorkspaceID == key.workspace,
              let tab = selectedWorkspace?.selectedTab else { return false }
        return tab.root.leaves.contains(key.pane)
    }

    private static func parsePaneKey(_ s: String) -> WorkspacePaneKey? {
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let ws = UUID(uuidString: String(parts[0])),
              let seq = UInt32(parts[1]) else { return nil }
        return WorkspacePaneKey(workspace: ws, pane: PaneID(value: seq))
    }

    func persist() {
        let state = PersistedState(
            workspaces: workspaces,
            selectedWorkspaceID: selectedWorkspaceID,
            sidebarCollapsed: sidebarCollapsed
        )
        Persistence.save(state)
    }

    // MARK: convenience accessors

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Sidebar's main list: every workspace that isn't parked in the archive.
    /// ⌘1…⌘9 and the cycle shortcuts index into this, not `workspaces`,
    /// so the keyboard navigation matches what the user actually sees.
    var activeWorkspaces: [Workspace] {
        workspaces.filter { !$0.archived }
    }

    var archivedWorkspaces: [Workspace] {
        workspaces.filter { $0.archived }
    }

    private var currentIndex: Int? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspaces.firstIndex { $0.id == id }
    }

    var currentRoot: SplitNode {
        selectedWorkspace?.selectedTab?.root ?? .leaf(PaneID(value: 0))
    }

    var currentFocusedPane: PaneID {
        selectedWorkspace?.selectedTab?.focusedPane ?? PaneID(value: 0)
    }

    var currentPanes: [PaneID: Pane] {
        selectedWorkspace?.panes ?? [:]
    }

    var focusedPaneValue: Pane? {
        guard let ws = selectedWorkspace, let f = ws.selectedTab?.focusedPane else { return nil }
        return ws.panes[f]
    }

    // MARK: pane operations on the current workspace

    /// Queue a command to run in a freshly created pane once its surface comes
    /// up. Reuses the same one-shot channel as the worktree sheet
    /// (`pendingInitialInput` → `GhosttySurfaceView.pendingInitialInput`); a nil/empty
    /// command leaves the pane a bare shell. Call right after creating the pane,
    /// before its surface is built, so the lookup finds the entry.
    private func queueInitialInput(_ command: String?, codexHome: String? = nil,
                                   workspace: UUID, pane: PaneID) {
        guard let cmd = command, !cmd.isEmpty else { return }
        let key = WorkspacePaneKey(workspace: workspace, pane: pane)
        pendingInitialInput[key] = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
        // Persist a non-default Codex home on the pane so a restart can
        // re-prefix `codex resume …` with the same CODEX_HOME (see
        // `Pane.codexHome`). The pane was just created above us, so the
        // subscript hits.
        if let home = codexHome,
           let wi = workspaces.firstIndex(where: { $0.id == workspace }) {
            workspaces[wi].panes[pane]?.codexHome = home
        }
    }

    // MARK: new-terminal entry points (honor the "ask which agent" setting)
    //
    // The menu / keyboard / "+" entry points call these instead of newTab /
    // splitFocused / addWorkspace directly. With `promptAgentOnNew` off they run
    // immediately (a bare shell, unchanged); with it on they stash the intent and
    // raise the chooser overlay, which calls `resolveAgentChooser` on pick.

    func requestNewTab() {
        if promptAgentOnNew { agentChooserIntent = .tab } else { newTab() }
    }

    func requestSplit(_ direction: SplitDirection) {
        guard promptAgentOnNew else { splitFocused(direction); return }
        agentChooserIntent = (direction == .horizontal) ? .splitRight : .splitDown
    }

    func requestNewWorkspace() {
        if promptAgentOnNew { agentChooserIntent = .workspace } else { addWorkspace() }
    }

    /// Resolve the chooser: nil = cancelled (no-op); otherwise run the pending
    /// action seeded with the picked agent's command (`.shell` → bare shell).
    func resolveAgentChooser(_ item: AgentLaunchItem?) {
        guard let intent = agentChooserIntent else { return }
        agentChooserIntent = nil
        guard let item else { return }
        let cmd = item.command
        let home = item.codexHome
        switch intent {
        case .tab:        newTab(agentCommand: cmd, codexHome: home)
        case .splitRight: splitFocused(.horizontal, agentCommand: cmd, codexHome: home)
        case .splitDown:  splitFocused(.vertical, agentCommand: cmd, codexHome: home)
        case .workspace:  addWorkspace(agentCommand: cmd, codexHome: home)
        }
    }

    func splitFocused(_ direction: SplitDirection, agentCommand: String? = nil, codexHome: String? = nil) {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        let new = PaneID(value: workspaces[i].nextPaneSeq)
        workspaces[i].nextPaneSeq += 1
        workspaces[i].panes[new] = Pane(id: new, title: "zsh", workingDirectory: nil)
        workspaces[i].tabs[t].root = Self.splitLeaf(
            workspaces[i].tabs[t].root,
            target: workspaces[i].tabs[t].focusedPane,
            direction: direction,
            newID: new
        ) ?? workspaces[i].tabs[t].root
        workspaces[i].tabs[t].focusedPane = new
        queueInitialInput(agentCommand, codexHome: codexHome, workspace: workspaces[i].id, pane: new)
    }

    /// Shells whose presence as the foreground process means "nothing of
    /// value is running" — closing the pane loses no work. Shared by the
    /// close-confirmation check and the workspace icon picker.
    static let benignShells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "login", "tmux"]

    /// Resolve a foreground-process name into the agent kind it corresponds
    /// to (nil for benign shells / unrelated tools). Callers that need the
    /// `lastAgent` string form go through `kind.rawValue`, which is the same
    /// alphabet `sessionIds` is keyed by — guaranteeing the writer side and
    /// the reader side can't drift on casing/spelling.
    static func agentKind(forProcessName name: String) -> PaneAgentKind? {
        agentKind(named: name)
    }

    /// Thin alias kept for backwards-compatible call sites. The actual spec
    /// lives on `PaneAgentKind.isValid(sessionId:)` — single source of truth
    /// shared with the OpenCode JS plugin's regex.
    static func isValidSessionId(_ s: String) -> Bool {
        PaneAgentKind.isValid(sessionId: s)
    }

    /// Classify a foreground-process name or a hook's agent token into an
    /// agent kind. Both are matched identically (by substring), so there is
    /// one resolver rather than separate process-name / token variants.
    static func agentKind(named name: String) -> PaneAgentKind? {
        let lower = name.lowercased()
        if lower.contains("claude") { return .claude }
        if lower.contains("codex") { return .codex }
        // "opencode" before a bare "omp" is not an issue (different strings);
        // match exact basename-style names first so short tokens don't steal
        // longer product names later.
        if lower.contains("opencode") { return .opencode }
        if lower.contains("devin") { return .devin }
        // Exact match for "omp" — it's only three letters, so a substring
        // check would false-positive on process names like "compiz".
        if lower == "omp" || lower.hasSuffix("/omp") { return .omp }
        if lower.contains("grok") { return .grok }
        // Exact match for "pi" — it's only two letters, so a substring check
        // would false-positive on process names like "pipe", "pip", "copy",
        // "spiped". pi is an npm bin shim (node dist/cli.js), but
        // GhosttySurfaceView.scriptBasenameFromArgv already resolves the
        // shim's argv to its basename "pi", so the comm/argv we see here is
        // the clean short name.
        if lower == "pi" || lower.hasSuffix("/pi") { return .pi }
        return nil
    }

    private static func isBenignShellProcessName(_ name: String) -> Bool {
        !name.isEmpty && benignShells.contains(name.lowercased())
    }

    /// True when killing this pane would interrupt real work: a CLI agent
    /// with a live session (even an idle one — closing kills the session),
    /// or any non-shell foreground process (vim, ssh, a build, …).
    func paneNeedsCloseConfirmation(_ key: WorkspacePaneKey) -> Bool {
        // Destructive actions are rare, so consult the live surface first
        // instead of trusting the event-driven cache. In particular, an agent
        // launched through Ghostty's `initial_input` does not pass through our
        // Return-key observer; before the fallback capture ran, paneProcesses
        // still said "zsh" and close/quit silently killed the live session.
        let processName = surfaceViews[key]?.foregroundProcessName()
            ?? paneProcesses[key]
        let name = processName?.lowercased()
        if paneAgentState[key] != nil,
           let name,
           Self.agentKind(named: name) != nil {
            return true
        }
        if let s = paneAgentState[key]?.status,
           s == .thinking || s == .tool || s == .compacting || s == .needsPermission {
            return true
        }
        if let name, !name.isEmpty,
           !Self.benignShells.contains(name) {
            return true
        }
        return false
    }

    /// Number of panes (across all workspaces) that would warrant a
    /// confirmation before being killed. Drives the quit confirmation.
    var panesNeedingQuitConfirmation: Int {
        var n = 0
        for ws in workspaces {
            for paneID in ws.panes.keys
            where paneNeedsCloseConfirmation(WorkspacePaneKey(workspace: ws.id, pane: paneID)) {
                n += 1
            }
        }
        return n
    }

    /// Modal confirm for destructive actions, with a "Don't ask again"
    /// suppression checkbox persisted per action kind. Returns true when
    /// the action should proceed.
    static func confirmDestruction(message: String, informative: String,
                                   confirmTitle: String, suppressionKey: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: suppressionKey) { return true }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: suppressionKey)
        }
        return true
    }

    func closeFocused() {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        // Last pane in this tab → close the whole tab instead (which itself
        // beeps when it's also the workspace's last tab).
        guard workspaces[i].tabs[t].root.leaves.count > 1 else {
            closeTab(workspaces[i].tabs[t].id)
            return
        }
        let target = workspaces[i].tabs[t].focusedPane
        let key = WorkspacePaneKey(workspace: workspaces[i].id, pane: target)
        if paneNeedsCloseConfirmation(key),
           !Self.confirmDestruction(
               message: String(localized: "Close this pane?"),
               informative: String(localized: "Something is still running in it and will be terminated."),
               confirmTitle: String(localized: "Close Pane"),
               suppressionKey: "glint.suppressClosePaneConfirm"
           ) {
            return
        }
        let (newRoot, survivor) = Self.removeLeaf(workspaces[i].tabs[t].root, target: target)
        if let newRoot { workspaces[i].tabs[t].root = newRoot }
        workspaces[i].panes.removeValue(forKey: target)
        surfaceViews.removeValue(forKey: key)
        // The pane is gone for good — drop its scrollback snapshot too.
        ScrollbackArchive.delete(
            id: ScrollbackArchive.fileID(forPaneKey: "\(workspaces[i].id.uuidString):\(target.value)"))
        // Drop the non-persistent side state too, or closed panes linger as
        // ghost entries forever.
        paneAgentState.removeValue(forKey: key)
        paneProcesses.removeValue(forKey: key)
        clearDockBadge(for: key)
        workspaces[i].tabs[t].focusedPane = survivor
            ?? workspaces[i].tabs[t].root.leaves.first
            ?? PaneID(value: 0)
    }

    func focusNext() {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        let leaves = workspaces[i].tabs[t].root.leaves.sorted { $0.value < $1.value }
        guard !leaves.isEmpty,
              let pos = leaves.firstIndex(of: workspaces[i].tabs[t].focusedPane) else { return }
        workspaces[i].tabs[t].focusedPane = leaves[(pos + 1) % leaves.count]
        refreshGitStatusNow(for: workspaces[i].id)
    }

    func focusPrevious() {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        let leaves = workspaces[i].tabs[t].root.leaves.sorted { $0.value < $1.value }
        guard !leaves.isEmpty,
              let pos = leaves.firstIndex(of: workspaces[i].tabs[t].focusedPane) else { return }
        workspaces[i].tabs[t].focusedPane = leaves[(pos - 1 + leaves.count) % leaves.count]
        refreshGitStatusNow(for: workspaces[i].id)
    }

    func focus(_ id: PaneID) {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        workspaces[i].tabs[t].focusedPane = id
        refreshGitStatusNow(for: workspaces[i].id)
    }

    /// 点击系统通知时呼出:切到 workspace、选中含该 pane 的 tab 并聚焦,
    /// 同时清掉它的未读(justCompleted/failed)状态与 Dock 角标。
    func revealPane(workspace: UUID, pane: PaneID) {
        guard let wi = workspaces.firstIndex(where: { $0.id == workspace }) else { return }
        selectedWorkspaceID = workspace
        if let ti = workspaces[wi].tabs.firstIndex(where: { $0.root.leaves.contains(pane) }) {
            workspaces[wi].selectedTabID = workspaces[wi].tabs[ti].id
            workspaces[wi].tabs[ti].focusedPane = pane
        }
        let key = WorkspacePaneKey(workspace: workspace, pane: pane)
        clearDockBadge(for: key)
        acknowledgeCompletionIfNeeded(for: workspace)
        refreshGitStatusNow(for: workspace)
    }

    /// ⌘⇧A: jump to the next pane that needs you. `PaneAgentStatus.attentionRank`
    /// is the shared ordering, so ⌘⇧A lands on the same pane that floats to the
    /// top of the sidebar. The current workspace is walked first (so a local
    /// attention pane wins ties against a remote one), then panes in display
    /// order (tab → leaves) — never `panes.keys`, whose order is unspecified and
    /// would make the target non-deterministic. Reuses `revealPane` (the
    /// notification-click path): it switches workspace, selects the pane's tab,
    /// focuses it, and clears the unread / dock-badge state. Nothing needs
    /// attention ⇒ beep.
    func jumpToAttention() {
        let current = selectedWorkspaceID
        let ordered = workspaces.filter { !$0.archived && $0.id == current }
            + workspaces.filter { !$0.archived && $0.id != current }
        // Walk panes in display order and keep the FIRST pane at the best
        // (lowest) attentionRank. `< bestRank` (not `<=`) preserves the
        // current-workspace-first / tab-order winner among equal ranks.
        var bestRank = Int.max
        var best: (ws: UUID, pane: PaneID)?
        for ws in ordered {
            for tab in ws.tabs {
                for paneID in tab.root.leaves {
                    let key = WorkspacePaneKey(workspace: ws.id, pane: paneID)
                    guard let rank = paneAgentState[key]?.status.attentionRank,
                          rank < PaneAgentStatus.sinkAttentionRank,   // ignore sinks (idle/thinking/…)
                          rank < bestRank else { continue }
                    bestRank = rank
                    best = (ws.id, paneID)
                }
            }
        }
        guard let target = best else { NSSound.beep(); return }
        revealPane(workspace: target.ws, pane: target.pane)
    }

    // MARK: - external control (control.sock)
    //
    // Command dispatch for ControlBridge. Each method runs on the main thread
    // (the bridge hops here via DispatchQueue.main.sync). String returns are an
    // error code (bad-request | unknown-pane | unknown-key); nil means success.
    // The pane handle is the same `GLINT_PANE_ID` hooks report: "uuid:seq".

    /// True iff the pane exists in the model, independent of whether its live
    /// surface has been minted. Lets send-* tell "no such pane" apart from
    /// "pane exists but its surface isn't ready yet".
    private func paneExists(_ key: WorkspacePaneKey) -> Bool {
        workspaces.first { $0.id == key.workspace }?.panes[key.pane] != nil
    }

    func controlListPanes() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for ws in workspaces {
            for pane in ws.panes.values {
                let key = WorkspacePaneKey(workspace: ws.id, pane: pane.id)
                var entry: [String: Any] = [
                    "pane": "\(ws.id.uuidString):\(pane.id.value)",
                    "title": pane.title,
                ]
                if let cwd = pane.workingDirectory { entry["cwd"] = cwd }
                if let st = paneAgentState[key] { entry["agent"] = st.status.rawValue }
                out.append(entry)
            }
        }
        return out
    }

    func controlSendText(pane: String, text: String, enter: Bool) -> String? {
        guard let key = Self.parsePaneKey(pane) else { return "bad-request" }
        guard paneExists(key) else { return "unknown-pane" }
        // surfaceViews only holds panes that have actually rendered; a real
        // pane in a background tab/workspace may have no live surface yet.
        // Report that distinctly instead of dropping the inject and lying with
        // {"ok":true}, or misreporting it as a nonexistent pane.
        guard let view = surfaceViews[key], view.hasLiveSurface else { return "pane-not-ready" }
        view.injectText(text)
        if enter { view.injectKey(.special(keycode: 36)) }
        return nil
    }

    func controlSendKeys(pane: String, keys: [String]) -> String? {
        guard let key = Self.parsePaneKey(pane) else { return "bad-request" }
        // Validate the whole sequence up front — reject the entire command if
        // any key is off-whitelist, so we never inject a partial sequence.
        var parsed: [GhosttySurfaceView.InjectableKey] = []
        for k in keys {
            guard let ik = GhosttySurfaceView.InjectableKey.parse(k) else { return "unknown-key" }
            parsed.append(ik)
        }
        guard paneExists(key) else { return "unknown-pane" }
        guard let view = surfaceViews[key], view.hasLiveSurface else { return "pane-not-ready" }
        for ik in parsed { view.injectKey(ik) }
        return nil
    }

    func controlFocus(pane: String) -> String? {
        guard let key = Self.parsePaneKey(pane) else { return "bad-request" }
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == key.workspace }),
              workspaces[wsIdx].panes[key.pane] != nil,
              // Panes are workspace-global; the pane lives in exactly one tab's tree.
              let tab = workspaces[wsIdx].tabs.first(where: { $0.root.leaves.contains(key.pane) })
        else { return "unknown-pane" }
        if workspaces[wsIdx].archived { workspaces[wsIdx].archived = false }
        selectWorkspace(key.workspace)
        if let i = workspaces.firstIndex(where: { $0.id == key.workspace }) {
            workspaces[i].selectedTabID = tab.id
            if let t = workspaces[i].selectedTabIndex {
                workspaces[i].tabs[t].focusedPane = key.pane
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    func selectWorkspace(_ id: UUID) {
        selectedWorkspaceID = id
        acknowledgeCompletionIfNeeded(for: id)
        refreshGitStatusNow(for: id)   // switching the shown terminal re-detects git
    }

    /// Select the nth workspace in sidebar order (0-based). Used by the
    /// ⌘1…⌘9 menu shortcuts; out-of-range indices are ignored. Indexes
    /// into `activeWorkspaces` so archived workspaces don't shift the
    /// numbering the user sees.
    func selectWorkspace(at index: Int) {
        let active = activeWorkspaces
        guard active.indices.contains(index) else { return }
        selectWorkspace(active[index].id)
    }

    /// Set the ratio of the split addressed by `path` in the current
    /// workspace's tree. `path` is the chain of branch choices walking down
    /// from the root (false = first child, true = second child); the empty
    /// path addresses the root split. Driven by divider drags in
    /// PaneTreeView; persisted with the rest of the tree.
    func setSplitRatio(path: [Bool], ratio: CGFloat) {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        let clamped = min(max(ratio, 0.1), 0.9)
        workspaces[i].tabs[t].root = Self.settingRatio(workspaces[i].tabs[t].root, path: path[...], ratio: clamped)
    }

    // MARK: tab operations on the current workspace

    /// Open a new tab in the current workspace, inheriting the focused pane's
    /// cwd (terminal convention: a new tab opens "here"). Inserts it right
    /// after the current tab and selects it.
    func newTab(cwd: String? = nil, agentCommand: String? = nil, codexHome: String? = nil) {
        guard let i = currentIndex else { return }
        let inheritedCwd = (workspaces[i].selectedTab?.focusedPane)
            .flatMap { workspaces[i].panes[$0]?.workingDirectory }
        let pane = PaneID(value: workspaces[i].nextPaneSeq)
        workspaces[i].nextPaneSeq += 1
        workspaces[i].panes[pane] = Pane(id: pane, title: "zsh", workingDirectory: cwd ?? inheritedCwd)
        let tab = WorkspaceTab(id: TabID(value: workspaces[i].nextTabSeq), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        workspaces[i].nextTabSeq += 1
        if let sel = workspaces[i].selectedTabIndex {
            workspaces[i].tabs.insert(tab, at: sel + 1)
        } else {
            workspaces[i].tabs.append(tab)
        }
        workspaces[i].selectedTabID = tab.id
        queueInitialInput(agentCommand, codexHome: codexHome, workspace: workspaces[i].id, pane: pane)
    }

    /// Close a tab and every pane it holds, cleaning up each pane's surface,
    /// scrollback snapshot, and live side-state. Confirms once if any pane is
    /// running something. The workspace's last tab can't be closed — beep
    /// instead, mirroring the last-pane rule.
    func closeTab(_ tabID: TabID) {
        guard let i = currentIndex,
              let t = workspaces[i].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard workspaces[i].tabs.count > 1 else {
            NSSound.beep()
            return
        }
        let wsID = workspaces[i].id
        let panes = workspaces[i].tabs[t].root.leaves
        let busy = panes.contains {
            paneNeedsCloseConfirmation(WorkspacePaneKey(workspace: wsID, pane: $0))
        }
        if busy,
           !Self.confirmDestruction(
               message: String(localized: "Close this tab?"),
               informative: String(localized: "Something is still running in it and will be terminated."),
               confirmTitle: String(localized: "Close Tab"),
               suppressionKey: "glint.suppressCloseTabConfirm"
           ) {
            return
        }
        let wasSelected = workspaces[i].selectedTabID == tabID
        teardownTab(at: t, in: i, wsID: wsID)
        if wasSelected {
            let nextIdx = min(t, workspaces[i].tabs.count - 1)
            workspaces[i].selectedTabID = workspaces[i].tabs[nextIdx].id
        }
    }

    /// Close every tab in the current workspace except `keepID`. Confirms once
    /// if any pane in a doomed tab is still running something, then tears them
    /// down without re-prompting (per-tab `closeTab` would re-ask and shift
    /// indices mid-loop). Leaves the kept tab selected. Mirrors `closeTab`'s
    /// no-op-when-empty + busy-confirmation shape.
    func closeOtherTabs(keeping keepID: TabID) {
        guard let i = currentIndex,
              workspaces[i].tabs.contains(where: { $0.id == keepID }) else { return }
        let doomed = workspaces[i].tabs.indices
            .filter { workspaces[i].tabs[$0].id != keepID }
        guard !doomed.isEmpty else { NSSound.beep(); return }
        let wsID = workspaces[i].id
        let doomedPanes = doomed.flatMap { workspaces[i].tabs[$0].root.leaves }
        let busy = doomedPanes.contains {
            paneNeedsCloseConfirmation(WorkspacePaneKey(workspace: wsID, pane: $0))
        }
        if busy,
           !Self.confirmDestruction(
               message: String(localized: "Close other tabs?"),
               informative: String(localized: "Something is still running in them and will be terminated."),
               confirmTitle: String(localized: "Close Tabs"),
               // Separate from the single-tab key: a user who suppressed the
               // low-stakes one-tab prompt hasn't consented to silently
               // terminating every running agent across the other tabs.
               suppressionKey: "glint.suppressCloseOtherTabsConfirm"
           ) {
            return
        }
        // Tear down highest index first so earlier indices stay valid as we
        // remove — `teardownTab` removes at the given position.
        for t in doomed.sorted(by: >) {
            teardownTab(at: t, in: i, wsID: wsID)
        }
        workspaces[i].selectedTabID = keepID
    }

    /// Remove one tab (at `index` in `workspaces[i]`) and tear down every pane
    /// it owns — surfaces, scrollback, agent/process state, dock badge. No
    /// confirmation and no selection fixup: `closeTab`/`closeOtherTabs` own
    /// those. Caller guarantees `index` is valid at call time.
    private func teardownTab(at index: Int, in i: Int, wsID: UUID) {
        let panes = workspaces[i].tabs[index].root.leaves
        for pane in panes {
            let key = WorkspacePaneKey(workspace: wsID, pane: pane)
            workspaces[i].panes.removeValue(forKey: pane)
            surfaceViews.removeValue(forKey: key)
            ScrollbackArchive.delete(
                id: ScrollbackArchive.fileID(forPaneKey: "\(wsID.uuidString):\(pane.value)"))
            paneAgentState.removeValue(forKey: key)
            paneProcesses.removeValue(forKey: key)
            clearDockBadge(for: key)
        }
        workspaces[i].tabs.remove(at: index)
    }

    func selectTab(_ tabID: TabID) {
        guard let i = currentIndex,
              workspaces[i].tabs.contains(where: { $0.id == tabID }) else { return }
        workspaces[i].selectedTabID = tabID
        // Viewing the tab is what "reads" its ✓ done / error badges.
        acknowledgeCompletionIfNeeded(for: workspaces[i].id)
        refreshGitStatusNow(for: workspaces[i].id)   // tab's focused pane may sit in a different repo
    }

    /// Set a custom display name for a tab in the current workspace. Empty
    /// (after trim) clears the override so `tabDisplayName` falls back to
    /// the auto cwd-derived label. Mirrors `renameWorkspace`'s semantics.
    func renameTab(_ tabID: TabID, to name: String) {
        guard let i = currentIndex,
              let t = workspaces[i].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[i].tabs[t].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Reorder a tab within the current workspace. `targetIndex` is the
    /// index of the chip the user dropped onto (in the workspace's `tabs`
    /// array). Mirrors `moveWorkspace`'s before/after resolution so the
    /// drop-onto-self / drop-past-self semantics match the sidebar.
    func moveTab(id: TabID, to targetIndex: Int) {
        guard let i = currentIndex,
              let source = workspaces[i].tabs.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(targetIndex, workspaces[i].tabs.count - 1))
        if source == clamped { return }
        let offset = source < clamped ? clamped + 1 : clamped
        workspaces[i].tabs.move(fromOffsets: IndexSet(integer: source), toOffset: offset)
    }

    func nextTab() {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex,
              workspaces[i].tabs.count > 1 else { return }
        let n = (t + 1) % workspaces[i].tabs.count
        workspaces[i].selectedTabID = workspaces[i].tabs[n].id
        acknowledgeCompletionIfNeeded(for: workspaces[i].id)
    }

    func previousTab() {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex,
              workspaces[i].tabs.count > 1 else { return }
        let n = (t - 1 + workspaces[i].tabs.count) % workspaces[i].tabs.count
        workspaces[i].selectedTabID = workspaces[i].tabs[n].id
        acknowledgeCompletionIfNeeded(for: workspaces[i].id)
    }

    /// Cycle to the next workspace in sidebar order, wrapping at the end.
    /// Used by the ⌘⇧] menu command — paired with `selectPreviousWorkspace`
    /// so keyboard-only navigation has parity with clicking the sidebar.
    func selectNextWorkspace() {
        let active = activeWorkspaces
        guard let id = selectedWorkspaceID,
              let idx = active.firstIndex(where: { $0.id == id }),
              !active.isEmpty else { return }
        let next = (idx + 1) % active.count
        selectWorkspace(active[next].id)
    }

    func selectPreviousWorkspace() {
        let active = activeWorkspaces
        guard let id = selectedWorkspaceID,
              let idx = active.firstIndex(where: { $0.id == id }),
              !active.isEmpty else { return }
        let prev = (idx - 1 + active.count) % active.count
        selectWorkspace(active[prev].id)
    }

    /// `confirm: false` skips the busy-pane confirmation — used when the caller
    /// already ran a stricter, destructive confirm (e.g. worktree removal, which
    /// deletes files on disk) so a second cancelable modal can't leave an
    /// orphaned workspace whose files are already gone.
    func deleteWorkspace(_ id: UUID, confirm: Bool = true) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }

        let busyPanes = workspaces[idx].panes.keys
            .filter { paneNeedsCloseConfirmation(WorkspacePaneKey(workspace: id, pane: $0)) }
        if confirm, !busyPanes.isEmpty,
           !Self.confirmDestruction(
               message: String(format: String(localized: "Delete “%@”?"), workspaces[idx].displayName),
               informative: String(format: String(localized: "%d of its panes still have something running; everything in this workspace will be terminated."), busyPanes.count),
               confirmTitle: String(localized: "Delete Workspace"),
               suppressionKey: "glint.suppressDeleteWorkspaceConfirm"
           ) {
            return
        }

        // Drop every surface tied to this workspace (their ghostty surfaces
        // get freed in GhosttySurfaceView.deinit when the dict releases them).
        surfaceViews = surfaceViews.filter { $0.key.workspace != id }
        clearDockBadges(for: workspaces[idx].panes.keys.map { WorkspacePaneKey(workspace: id, pane: $0) })
        // And their scrollback snapshots.
        for paneID in workspaces[idx].panes.keys {
            ScrollbackArchive.delete(
                id: ScrollbackArchive.fileID(forPaneKey: "\(id.uuidString):\(paneID.value)"))
        }
        paneAgentState = paneAgentState.filter { $0.key.workspace != id }
        paneProcesses = paneProcesses.filter { $0.key.workspace != id }
        // Drop the workspace-keyed git cache + any unconsumed agent launch input
        // so closing (incl. a worktree via "Close Workspace") leaves nothing
        // stale behind. (removeWorktreeWorkspace cleared gitStatuses itself; this
        // covers the plain Close path too.)
        gitStatuses[id] = nil
        pendingInitialInput = pendingInitialInput.filter { $0.key.workspace != id }

        let wasSelected = selectedWorkspaceID == id
        workspaces.remove(at: idx)

        // Never leave the user with zero workspaces — spawn a fresh one.
        if workspaces.isEmpty {
            addWorkspace()
            return
        }

        if wasSelected {
            let nextIdx = min(idx, workspaces.count - 1)
            selectedWorkspaceID = workspaces[nextIdx].id
        }
    }

    /// Park a workspace away from the main sidebar list. The model (panes,
    /// splits, cwd, lastAgent, scrollback) survives intact — only the live
    /// surfaces are dropped, so unarchive resumes from the saved state via
    /// the same code path as an app restart. Refuses to archive the last
    /// active workspace (the user must always have something visible).
    /// If the archived workspace was selected, advances to the next active
    /// one in sidebar order.
    func archiveWorkspace(_ id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces[idx].archived else { return }

        // The user must always have at least one active workspace to look at.
        guard activeWorkspaces.count > 1 else {
            NSSound.beep()
            return
        }

        // Drop live surfaces + side-state so the parked workspace doesn't
        // hold onto GPU/IOSurface memory. The Pane / SplitNode / scrollback
        // archive stay on disk so unarchive can rehydrate them.
        surfaceViews = surfaceViews.filter { $0.key.workspace != id }
        clearDockBadges(for: workspaces[idx].panes.keys.map { WorkspacePaneKey(workspace: id, pane: $0) })
        paneAgentState = paneAgentState.filter { $0.key.workspace != id }
        paneProcesses = paneProcesses.filter { $0.key.workspace != id }

        let wasSelected = selectedWorkspaceID == id
        workspaces[idx].archived = true

        if wasSelected, let next = activeWorkspaces.first {
            selectedWorkspaceID = next.id
        }
    }

    /// Lift a workspace back to the main sidebar list and select it. Surfaces
    /// will lazily re-mint as the user navigates into panes (same path as a
    /// cold launch). Also forces the archive section to expand so the user
    /// sees what they just unarchived land back in the main list.
    func unarchiveWorkspace(_ id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[idx].archived else { return }
        workspaces[idx].archived = false
        selectedWorkspaceID = id
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty → drop back to auto naming based on cwd.
            workspaces[i].userNamed = false
        } else {
            workspaces[i].name = trimmed
            workspaces[i].userNamed = true
        }
    }

    /// Reorder a workspace within the sidebar list. `targetIndex` is the
    /// index of the card the user dropped onto, in the unfiltered
    /// `workspaces` array; we resolve "before vs after" the same way
    /// `Array.move(fromOffsets:toOffset:)` does — if the source is above
    /// the target the source lands at `targetIndex` (after the target),
    /// otherwise at `targetIndex` (before the target). No-ops if either id
    /// is unknown or source == target.
    func moveWorkspace(id: UUID, to targetIndex: Int) {
        guard let source = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(targetIndex, workspaces.count - 1))
        if source == clamped { return }
        let offset = source < clamped ? clamped + 1 : clamped
        workspaces.move(fromOffsets: IndexSet(integer: source), toOffset: offset)
    }

    func addWorkspace(agentCommand: String? = nil, codexHome: String? = nil) {
        let palette = [
            ("5E5CE6", "•"), ("FF6582", "•"), ("30D158", "•"),
            ("FF9F0A", "•"), ("64D2FF", "•"), ("BF5AF2", "•"),
        ]
        let pick = palette[workspaces.count % palette.count]
        // Auto-named: fallback label is "New workspace" until the shell reports a cwd.
        let ws = Workspace.fresh(name: String(localized: "New workspace"), accentHex: pick.0, symbol: pick.1)
        workspaces.append(ws)
        selectedWorkspaceID = ws.id
        // Workspace.fresh seeds a single pane at PaneID 0.
        queueInitialInput(agentCommand, codexHome: codexHome, workspace: ws.id, pane: PaneID(value: 0))
    }

    // MARK: - Open via path (Launch Services: folders / files / glint://)

    /// Route a URL handed to Glint by Launch Services (`open -a Glint <path>`,
    /// Finder "Open With", a dock drop, an external launcher, a `glint://` link).
    /// File URLs and `glint://open?path=…` both bottom out in `openPath`. Entry
    /// point: raw `odoc`/`GURL` Apple-Event handlers registered in
    /// `AppDelegate.applicationWillFinishLaunching` (intercepted there because
    /// SwiftUI's default handling tears the single-`Window` scene down on a warm
    /// odoc); the cold-launch queue + drain live in `AppDelegate.flush`.
    func openURL(_ url: URL) {
        if url.isFileURL {
            openPath(url.path)
        } else if url.scheme == "glint" {
            // glint://open?path=<percent-encoded absolute path>. Query form so
            // slashes / special chars in the path survive URLComponents intact.
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                  !raw.isEmpty else { return }
            openPath((raw as NSString).expandingTildeInPath)
        }
    }

    /// Dispatch a filesystem path to folder- or file-handling by what's on disk.
    private func openPath(_ path: String) {
        let standardized = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir) else { return }
        if isDir.boolValue { openFolder(standardized) } else { openFile(standardized) }
    }

    /// Open a workspace anchored at `directory`. If a workspace already anchored
    /// there exists, switch to it and open a new tab; otherwise append a new one.
    /// The append runs synchronously so a concurrent open of the same folder
    /// dedupes instead of racing into a duplicate; the source is upgraded to
    /// `.localRepo` in place once git reports the repo root.
    private func openFolder(_ directory: String) {
        if let existingIndex = workspaces.firstIndex(where: { isAnchoredAt($0, directory) }) {
            if workspaces[existingIndex].archived { workspaces[existingIndex].archived = false }
            selectWorkspace(workspaces[existingIndex].id)
            newTab(cwd: directory)
            return
        }
        let dirName = (directory as NSString).lastPathComponent
        let wsID = appendWorkspace(cwd: directory, source: .plain,
                                   name: dirName.isEmpty ? String(localized: "New workspace") : dirName)
        Task {
            if let root = await git.repoRoot(at: directory),
               let i = workspaces.firstIndex(where: { $0.id == wsID }) {
                workspaces[i].source = WorkspaceSource(kind: .localRepo, repoRoot: root)
            }
            await refreshGitStatus(for: wsID)
        }
    }

    /// True if `ws` opens into `directory` — for deduping folder opens. Matches
    /// the bound repo root (or, for a worktree, its worktree path — a worktree
    /// shares `repoRoot` with the main checkout, so matching on repoRoot would
    /// wrongly absorb a main-repo open into a worktree workspace) OR the focused
    /// pane's cwd (covers a workspace opened at a repo subdir).
    private func isAnchoredAt(_ ws: Workspace, _ directory: String) -> Bool {
        let boundPath = (ws.source.kind == .localWorktree) ? ws.source.worktreePath : ws.source.repoRoot
        if boundPath == directory { return true }
        let cwd = (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
            ?? ws.panes.values.compactMap(\.workingDirectory).first
        return cwd == directory
    }

    /// Execute a plain file in a shell (mirrors Ghostty's openFile): confirm,
    /// then run `'<path>'; exit` with the parent directory as cwd. Non-executable
    /// files are refused upfront (otherwise the pane just dies with "permission
    /// denied"). Always asks — no "don't ask again" — because executing an
    /// arbitrary file is a trust boundary.
    private func openFile(_ path: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = String(format: String(localized: "\"%@\" is not executable."),
                                       (path as NSString).lastPathComponent)
            alert.informativeText = String(localized: "Glint can only run files with the executable bit set.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Allow Glint to execute \"%@\"?"), path)
        alert.informativeText = String(localized: "Glint will run this file in a shell at its parent directory.")
        alert.alertStyle = .warning
        // Cancel is the default button (Enter) so executing the file takes an
        // explicit click on Allow rather than a reflexive ⏎.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Allow"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let cmd = posixShellQuoted(path) + "; exit\n"
        appendWorkspace(cwd: (path as NSString).deletingLastPathComponent,
                        source: .plain,
                        name: (path as NSString).lastPathComponent,
                        initialInput: cmd)
    }

    /// Append a fresh single-pane workspace anchored at `cwd`, select it,
    /// optionally seed the first pane's shell input (and Codex home), and return
    /// its id. The single factory for "create an empty workspace" — used by
    /// `openFolder`, `openFile`, and `createWorktreeWorkspace`.
    @discardableResult
    private func appendWorkspace(cwd: String, source: WorkspaceSource,
                                 name: String, initialInput: String? = nil,
                                 codexHome: String? = nil) -> UUID {
        let first = PaneID(value: 0)
        let pane = Pane(id: first, title: "zsh", workingDirectory: cwd)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil, root: .leaf(first), focusedPane: first)
        let ws = Workspace(
            id: UUID(), name: name, userNamed: false,
            accentHex: nextAccentHex(), symbol: "•",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [first: pane], nextPaneSeq: 1,
            source: source)
        workspaces.append(ws)
        selectedWorkspaceID = ws.id
        // queueInitialInput also persists codexHome onto the pane (restart path).
        queueInitialInput(initialInput, codexHome: codexHome, workspace: ws.id, pane: first)
        return ws.id
    }

    // MARK: - Worktree (Plan B: out-of-band git, never via the terminal)

    private func nextAccentHex() -> String {
        let palette = ["5E5CE6", "FF6582", "30D158", "FF9F0A", "64D2FF", "BF5AF2"]
        return palette[workspaces.count % palette.count]
    }

    /// Best-effort starting point for the New Worktree sheet: the current
    /// workspace's bound repo root, else its focused pane's cwd (the sheet then
    /// validates it's actually a repo via git).
    func currentRepoGuess() -> String? {
        guard let ws = workspaces.first(where: { $0.id == selectedWorkspaceID }) else { return nil }
        if let root = ws.source.repoRoot { return root }
        return (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
            ?? ws.panes.values.compactMap(\.workingDirectory).first
    }

    /// The repo root a workspace's worktree actions should target: its bound
    /// source if any, else discovered from the focused pane's cwd.
    func repoRoot(for ws: Workspace) async -> String? {
        if let root = ws.source.repoRoot { return root }
        let cwd = (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
            ?? ws.panes.values.compactMap(\.workingDirectory).first
        guard let cwd else { return nil }
        return await git.repoRoot(at: cwd)
    }

    /// Create a worktree (out-of-band) and open a workspace bound to it. With
    /// `createBranch`, cuts a new branch off `baseBranch`; otherwise checks out
    /// the existing `branch`. Optionally launches `agentCommand` in the first
    /// pane. Throws (propagating the git error) so the sheet can surface it.
    @discardableResult
    func createWorktreeWorkspace(repoRoot: String, baseBranch: String, branch: String,
                                 worktreePath: String, createBranch: Bool = true,
                                 carryUncommitted: Bool = false,
                                 agentCommand: String?, codexHome: String? = nil) async throws -> UUID {
        let expanded = (worktreePath as NSString).expandingTildeInPath
        try await git.addWorktree(repo: repoRoot, path: expanded,
                                  newBranch: createBranch ? branch : nil,
                                  base: createBranch ? baseBranch : branch)
        // Replay base's uncommitted changes into the fresh worktree BEFORE the
        // workspace (and its agent pane) come up, so the agent never sees a
        // half-populated tree. A copy hiccup must not fail the whole creation —
        // the worktree stands and the originals stay in base — but it's surfaced
        // as a warning rather than swallowed.
        var carryFailed = false
        if carryUncommitted {
            do { try await git.carryWorkingTree(from: repoRoot, to: expanded) }
            catch { carryFailed = true }
        }

        let wsID = appendWorkspace(
            cwd: expanded,
            source: WorkspaceSource(kind: .localWorktree, repoRoot: repoRoot,
                                    branch: branch, baseBranch: baseBranch,
                                    worktreePath: expanded),
            name: String(localized: "New workspace"),
            initialInput: agentCommand,
            codexHome: codexHome)
        if carryFailed { worktreeCarryFailed = true }
        await refreshGitStatus(for: wsID)
        return wsID
    }

    /// Remove a worktree from disk (`git worktree remove`) and close its
    /// workspace. `force` is required when the worktree is dirty; gated behind a
    /// confirm in the UI. Optionally also deletes the branch.
    func removeWorktreeWorkspace(_ id: UUID, alsoDeleteBranch: Bool, force: Bool) async throws {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return }
        // Not a local worktree we can remove from disk (e.g. an sshWorktree, or a
        // source that lost its path). Throw instead of silently no-op'ing — the
        // user confirmed a destructive action and must get feedback, not silence.
        guard let repo = ws.source.repoRoot, let path = ws.source.worktreePath else {
            throw GitError.notARepository(ws.source.repoRoot ?? ws.displayName)
        }
        // Remove the worktree first; this is the primary, irreversible action.
        try await git.removeWorktree(repo: repo, path: path, force: force)
        // Branch deletion is secondary: if it fails (e.g. branch checked out
        // elsewhere) we must STILL finish closing the workspace — otherwise the
        // worktree dir is gone but the card lingers. Capture and rethrow after.
        var branchError: Error?
        if alsoDeleteBranch, let branch = ws.source.branch {
            do { try await git.deleteBranch(repo: repo, name: branch, force: true) }
            catch { branchError = error }
        }
        gitStatuses[id] = nil
        // confirm:false — the worktree-delete dialog already confirmed a stricter
        // action; a second cancelable modal here would orphan the now-deleted dir.
        deleteWorkspace(id, confirm: false)
        if let branchError { throw branchError }
    }

    /// Open the workspace's location in Finder — shared by every "Open in
    /// Finder" entry point (git popover button, sidebar context item, command
    /// palette). Mirrors the ⌘⇧F shortcut: the bound root (worktree/repo) when
    /// `revealAtRepoRoot` is on, else the focused pane's cwd — and always dives
    /// INTO the folder, so the button and the shortcut stay consistent.
    func revealWorktreeInFinder(_ id: UUID) {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return }
        // Remote SSH pane: nothing local to reveal — beep and stop before the
        // local-root chain runs against a bogus path.
        if remoteContext(for: ws) != nil { NSSound.beep(); return }
        guard let root = ws.source.worktreePath ?? ws.source.repoRoot ?? effectiveGitPath(for: ws)
        else { return }
        let paneCwd = (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
        Self.openInFinder((revealAtRepoRoot || paneCwd == nil) ? root : paneCwd!)
    }

    /// Reveal the focused pane's current directory in Finder — the global ⌘⇧F
    /// shortcut. Cwd-first so it works anywhere (even outside a git repo),
    /// falling back to the same worktree/repo-root/effective-git chain as
    /// `revealWorktreeInFinder` when no cwd has been reported yet. Nothing
    /// resolves ⇒ beep, mirroring `openReview`'s no-op.
    func revealCurrentInFinder() {
        guard let ws = selectedWorkspace else {
            NSSound.beep()
            return
        }
        // Remote SSH pane: there's no local directory to reveal — beep instead
        // of diving into a bogus local path derived from the ssh process's cwd.
        if remoteContext(for: ws) != nil { NSSound.beep(); return }
        let paneCwd = (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
        // A bound workspace's gitPath is its root (worktree root for a worktree,
        // repo root for Local Repo) — already known. A plain workspace resolves
        // the toplevel async. Either way, dive INTO revealAtRepoRoot's target:
        // the root (on, default) or the focused pane's current directory (off).
        if let root = ws.source.gitPath {
            let target = (revealAtRepoRoot || paneCwd == nil) ? root : paneCwd!
            Self.openInFinder(target)
            return
        }
        let base = paneCwd ?? ws.source.worktreePath ?? ws.source.repoRoot ?? effectiveGitPath(for: ws)
        guard let base else {
            NSSound.beep()
            return
        }
        if revealAtRepoRoot {
            Task {
                let root = await git.repoRoot(at: base) ?? base
                await MainActor.run { Self.openInFinder(root) }
            }
        } else {
            Self.openInFinder(base)
        }
    }

    /// Per-tab "Copy Path": copies the tab's focused-pane cwd — the same value
    /// the chip's tooltip shows — so a background tab's directory is reachable
    /// without first selecting it. Works outside git repos. Beeps when no cwd
    /// has been reported yet (fresh pane) or the tab is a remote-SSH session
    /// (no local path to copy), mirroring the no-op guards elsewhere.
    func copyTabPath(_ tabID: TabID) {
        guard let ws = selectedWorkspace,
              let tab = ws.tabs.first(where: { $0.id == tabID }) else { return }
        if isRemotePane(wsID: ws.id, pane: tab.focusedPane) { NSSound.beep(); return }
        guard let cwd = ws.tabCwd(tab) else { NSSound.beep(); return }
        Self.copyPath(cwd)
    }

    /// Per-tab "Reveal in Finder": reveals the tab's focused-pane cwd, falling
    /// back to the workspace's known root when the pane hasn't reported a cwd
    /// yet (fresh pane). Remote-ness is checked per-pane on the tab's focused
    /// pane (not `remoteContext(for:)`, which reads the SELECTED tab and would
    /// guard the wrong tab when right-clicking a background tab). Beeps when
    /// nothing resolves — including remote-SSH panes, where there's no local
    /// directory to reveal.
    func revealTabInFinder(_ tabID: TabID) {
        guard let ws = selectedWorkspace,
              let tab = ws.tabs.first(where: { $0.id == tabID }) else { return }
        if isRemotePane(wsID: ws.id, pane: tab.focusedPane) { NSSound.beep(); return }
        if let cwd = ws.tabCwd(tab) { Self.openInFinder(cwd); return }
        if let root = knownRoot(for: ws) {
            Self.openInFinder(root)
            return
        }
        NSSound.beep()
    }

    /// Global ⌘⇧C: copy the focused pane's cwd to the clipboard — the
    /// "where am I right now" path, useful to paste into chat/docs/another
    /// terminal. Cwd-first; when no cwd has been reported yet (fresh pane)
    /// falls back to the workspace's known root. A remote-SSH focused pane
    /// beeps (its `workingDirectory` is the ssh client's local launch dir, not
    /// a useful path to copy) — consistent with Reveal in Finder. Unlike
    /// Reveal it deliberately ignores `revealAtRepoRoot`: "copy path" should
    /// give the literal current directory, never silently jump to the repo
    /// root. Beeps when nothing resolves.
    func copyCurrentPath() {
        guard let ws = selectedWorkspace else { NSSound.beep(); return }
        if let fp = ws.selectedTab?.focusedPane, isRemotePane(wsID: ws.id, pane: fp) { NSSound.beep(); return }
        let paneCwd = (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
        if let path = paneCwd ?? knownRoot(for: ws) {
            Self.copyPath(path)
        } else {
            NSSound.beep()
        }
    }

    /// Open the read-only Review window for a workspace. Always offers the
    /// working-tree scope; for a worktree with a known base branch it also offers
    /// the whole-branch (`base...HEAD`) scope, so the segmented control appears.
    func openReview(for ws: Workspace) {
        // Remote SSH pane: review the remote repo over SSH by swapping the
        // GitRunner. `git -C <remotePath>` works from anywhere inside the repo,
        // so the remote cwd is passed straight through as `repo`; `--show-prefix`
        // gives the root-relative subdir for the file-list scope (no tilde math
        // — git resolves it remotely).
        if let rctx = remoteContext(for: ws) {
            let runner = SSHGitRunner(target: rctx.target, port: rctx.port)
            let remoteGit = GitService(runner: runner)
            Task {
                // Resolve the remote repo root once; `--show-prefix` gives the
                // cwd's root-relative subdir for the cwd-scope branch. Honor
                // `reviewAtRepoRoot` — whole root (on) vs focused-cwd subtree
                // (off) — mirroring the local Review path so the toggle behaves
                // the same over SSH.
                async let rootA = remoteGit.repoRoot(at: rctx.remotePath)
                let prefixR = try? await remoteGit.git(
                    ["rev-parse", "--show-prefix"], cwd: rctx.remotePath,
                    allowFailure: true, timeout: .poll)
                let root = await (rootA ?? rctx.remotePath)
                var subdir: String? = nil
                if !reviewAtRepoRoot,
                   let pr = prefixR, pr.ok {
                    // Trim the trailing newline git always emits, then any
                    // slashes. Root → "" → nil; a non-nil subdir (even "") makes
                    // ReviewModel.reload's prefix filter drop every file.
                    let pre = pr.stdout
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    subdir = pre.isEmpty ? nil : pre
                }
                let rootName = (root as NSString).lastPathComponent
                let label = subdir.map { "\(rootName)/\($0)" } ?? rootName
                let title = rctx.host.map { "\($0) · \(label)" } ?? label
                await MainActor.run {
                    ReviewWindowController.shared.present(repo: root, title: title,
                                                          subdir: subdir, scopes: [.workingTree],
                                                          store: self, runner: runner)
                }
            }
            return
        }
        // ssh foreground but no parsed remote cwd yet (no title fired, or the
        // remote shell's prompt doesn't print user@host:path). Beep instead of
        // falling through to the local-cwd branch, which would silently Review
        // the LOCAL directory the user happened to be in when they ran ssh.
        if let paneID = ws.selectedTab?.focusedPane,
           let view = surfaceViews[WorkspacePaneKey(workspace: ws.id, pane: paneID)],
           view.foregroundSshTarget() != nil {
            NSSound.beep()
            return
        }
        guard let cwd = ws.source.gitPath ?? effectiveGitPath(for: ws) else {
            NSSound.beep()
            return
        }
        var scopes: [DiffScope] = [.workingTree]
        if let base = ws.source.baseBranch, !base.isEmpty {
            scopes.append(.branch(base: base))
        }
        // A bound workspace's gitPath is its root (worktree/repo) — known, no
        // async. A plain workspace resolves the toplevel async. Either way
        // honor reviewAtRepoRoot: whole root (on, default) or the focused pane's
        // cwd subtree (off, filtered via `subdir`). `repo` is always the root so
        // fileDiff's root-relative paths resolve — the empty-diff bug stays
        // fixed by construction.
        let scopeToRoot = reviewAtRepoRoot
        if let root = ws.source.gitPath {
            let subdir = scopeToRoot ? nil : Self.paneSubdir(for: ws, root: root)
            // Keep the worktree's "repo · branch" identity and append the
            // reviewed subdir when scoping to it (root mode shows just the
            // identity), so the title reflects what's actually reviewed.
            let title = subdir.map { "\(ws.displayName) · \($0)" } ?? ws.displayName
            ReviewWindowController.shared.present(repo: root, title: title,
                                                  subdir: subdir, scopes: scopes, store: self)
            return
        }
        Task {
            let root = await git.repoRoot(at: cwd) ?? cwd
            let subdir = scopeToRoot ? nil : Self.paneSubdir(for: ws, root: root)
            // Title reflects what's reviewed, not ws.displayName — which for a
            // plain workspace can be a cwd-derived label that disagrees with the
            // root Review actually opens.
            let rootName = (root as NSString).lastPathComponent
            let reviewTitle = subdir.map { "\(rootName)/\($0)" } ?? rootName
            await MainActor.run {
                ReviewWindowController.shared.present(repo: root, title: reviewTitle,
                                                      subdir: subdir, scopes: scopes, store: self)
            }
        }
    }

    // MARK: - What's New (hand-authored per-version notes; see ReleaseNotes.swift)

    /// Full app version, e.g. "0.1.25-beta.1" or "0.1.25". Kept verbatim (not
    /// base-normalized) so beta builds are tracked per pre-release: each beta
    /// pops its own note, and the seen-mark distinguishes beta.1 from beta.2.
    private var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// Localized lines for a note, picked by the app's current language (Chinese
    /// when the resolved locale is `zh`, English otherwise). The copy is data, so
    /// it's chosen here rather than via the string catalog.
    func whatsNewLines(_ note: ReleaseNote) -> [String] {
        let code = preferredLocale.language.languageCode?.identifier
        return code == "zh" ? note.zh : note.en
    }

    /// Run once on launch. Pops the What's New card when the app version changed
    /// since it was last seen. The seen-mark is advanced only when we've actually
    /// shown (or deliberately seeded) — never when a version-change produced no
    /// card — so a note added in a later build still pops the next launch instead
    /// of being silently burned.
    func evaluateWhatsNewOnLaunch() {
        guard !whatsNewEvaluated else { return }
        whatsNewEvaluated = true

        let current = currentAppVersion
        // Local "dev" builds carry version "dev" (CI stamps the real one): never
        // a real upgrade, so they never auto-pop.
        guard !current.isEmpty else { return }

        let key = Self.whatsNewVersionKey
        let lastSeen = UserDefaults.standard.string(forKey: key)
        guard lastSeen != current else { return }   // already shown for this build
        func markSeen() { UserDefaults.standard.set(current, forKey: key) }

        guard let lastSeen else {
            // No seen-mark yet. An existing user (state.json already on disk) who
            // upgraded into this feature should still get the running version's
            // card once — they didn't "just install". A genuine fresh install
            // (no saved state) is seeded silently. Dev/non-numeric builds never
            // pop, only seed.
            if Persistence.hasSavedState, current.first?.isNumber == true {
                let notes = ReleaseNotes.currentOrLatest(version: current)
                if !notes.isEmpty { whatsNewNotes = notes }
            }
            markSeen()
            return
        }

        let notes = ReleaseNotes.notesToShow(lastSeen: lastSeen, current: current)
        // Advance the mark only once there's something to show; if this upgrade
        // has no authored note yet, leave the mark so a later build can still
        // surface its note rather than losing it to a burned version stamp.
        guard !notes.isEmpty else { return }
        whatsNewNotes = notes
        markSeen()
    }

    /// Manual entry point (Settings ▸ About): show the current version's note, or
    /// the latest authored one when the running version has none (dev builds).
    func showWhatsNew() {
        let notes = ReleaseNotes.currentOrLatest(version: currentAppVersion)
        if !notes.isEmpty { whatsNewNotes = notes }
    }

    func dismissWhatsNew() { whatsNewNotes = [] }

    // MARK: lightweight git status (non-persistent cache)

    /// The path git status/worktree actions run against for a workspace: the
    /// bound source's git path if any, else the focused pane's live cwd. This is
    /// what lets a *plain* workspace that's simply `cd`'d into a repo still
    /// surface git status and the tab's git button — no `.localWorktree` source
    /// required.
    /// The focused pane's remote SSH context when it's a capturable SSH session
    /// with a known remote path; else nil. The ssh `target` is authoritative
    /// for transport (it's what the user typed — resolves `~/.ssh/config`
    /// aliases/jumps via the user's own ssh); `remotePath` is mined from the
    /// remote shell's terminal title; `host` is display-only. Resolved here
    /// (not via `effectiveGitPath`) so the local status poll keeps ignoring
    /// remote panes while Review still routes through SSH.
    private func remoteContext(for ws: Workspace) -> (target: String, port: Int?, remotePath: String, host: String?)? {
        guard let paneID = ws.selectedTab?.focusedPane else { return nil }
        // Read the LIVE surface rather than the Pane snapshot. The snapshot
        // (Pane.remotePath) can lag until the next title/capture event, so pressing ⌘⇧R
        // right after a remote `cd` would otherwise review the previous
        // directory (e.g. `~` → "not a git repo" → empty Review). The surface's
        // remotePath is updated immediately when the remote shell's title fires.
        guard let view = surfaceViews[WorkspacePaneKey(workspace: ws.id, pane: paneID)],
              let ctx = view.remoteReviewContext else { return nil }
        return (ctx.target, ctx.port, ctx.remotePath, view.remoteHost)
    }

    /// True iff this pane's live foreground process is SSH. Do not require a
    /// parsed remote title/path: shells that disable title updates are still
    /// remote, and their `workingDirectory` snapshot is the ssh client's stale
    /// LOCAL launch directory. Per-pane, unlike `remoteContext(for:)` which
    /// reads the selected tab and additionally requires a reviewable path.
    private func isRemotePane(wsID: UUID, pane: PaneID) -> Bool {
        guard let view = surfaceViews[WorkspacePaneKey(workspace: wsID, pane: pane)] else {
            return false
        }
        return view.foregroundProcessName()?.lowercased() == "ssh"
            || view.remoteReviewContext != nil
    }

    func effectiveGitPath(for ws: Workspace) -> String? {
        if let p = ws.source.gitPath { return p }
        return (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
            ?? ws.panes.values.compactMap(\.workingDirectory).first
    }

    /// Best-known LOCAL root for a workspace — the last-resort fallback when a
    /// pane hasn't reported a cwd yet (fresh pane). Shared by the per-tab /
    /// global Copy Path and Reveal-in-Finder so both resolve the same root.
    /// `effectiveGitPath(for:)` already checks `gitPath` first, so no separate
    /// `gitPath ??` coalesce is needed (it was a dead branch).
    private func knownRoot(for ws: Workspace) -> String? {
        ws.source.worktreePath ?? ws.source.repoRoot ?? effectiveGitPath(for: ws)
    }

    /// Root-relative path of `cwd` under `root`, or nil if `cwd` is the root
    /// itself or not inside it. Both are normalized (symlinks resolved,
    /// "."/".." collapsed) before the prefix drop, so a symlinked repo root or
    /// a "."-laden shell cwd compare correctly. Used to scope Review's file
    /// list to a subdirectory: e.g. root=/repo, cwd=/repo/src → "src".
    /// Pure / no instance state, so Review can call it once at open time and
    /// pass the result down as `subdir`.
    nonisolated static func subdirPath(root: String, cwd: String) -> String? {
        let r = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let c = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        if c == r { return nil }
        guard c.hasPrefix(r + "/") else { return nil }   // cwd not under root
        let rel = String(c.dropFirst(r.count + 1))
        return rel.isEmpty ? nil : rel
    }

    /// The focused pane's cwd as a root-relative subdir, or nil if the pane has
    /// no cwd, is at the root, or is outside it. Shared by `openReview` (Review
    /// subtree filter) for bound and plain workspaces alike.
    nonisolated static func paneSubdir(for ws: Workspace, root: String) -> String? {
        guard let paneCwd = (ws.selectedTab?.focusedPane).flatMap({ ws.panes[$0]?.workingDirectory }) else { return nil }
        return subdirPath(root: root, cwd: paneCwd)
    }

    /// Open a folder in Finder by diving INTO it (not reveal-and-select in its
    /// parent). Shared by every Reveal-in-Finder path.
    static func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    /// Copy a filesystem path to the clipboard, clearing first. Shared by every
    /// Copy Path entry point (⌘⇧C, the tab/surface context menus, the Review
    /// file list) so pasteboard behavior lives in one place.
    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func gitStatus(for id: UUID) -> GitStatus? { gitStatuses[id] }

    private func syncGitWatchers() {
        var desired: [UUID: String] = [:]
        for ws in workspaces where !ws.archived {
            switch ws.source.kind {
            case .localRepo, .localWorktree:
                if let path = ws.source.gitPath { desired[ws.id] = path }
            default:
                break
            }
        }

        for id in gitWatchers.keys.filter({ desired[$0] == nil }) {
            gitWatchers.removeValue(forKey: id)
            gitRefreshCoordinator.cancel(id)
        }
        for (id, path) in desired {
            if gitWatchers[id]?.path == path { continue }
            let paths = GitRepositoryWatcher.watchPaths(for: path)
            let watcher = GitRepositoryWatcher(paths: paths) { [weak self] in
                guard NSApp.isActive else { return }
                self?.gitRefreshCoordinator.request(id, source: .fileWatcher) { [weak self] in
                    self?.refreshGitStatusNow(for: id)
                }
            }
            gitWatchers[id] = GitWatchRegistration(path: path, watcher: watcher)
        }
    }

    func refreshGitStatus(for id: UUID) async {
        guard let ws = workspaces.first(where: { $0.id == id }) else {
            if gitStatuses[id] != nil { gitStatuses[id] = nil }
            return
        }
        guard !ws.archived else {
            if gitStatuses[id] != nil { gitStatuses[id] = nil }
            return
        }
        // Remote SSH pane: nothing local to poll, and remote status badges are
        // out of scope for v1 (Review-over-SSH only). Skip before running local
        // git against the ssh process's stale local cwd.
        if remoteContext(for: ws) != nil {
            if gitStatuses[id] != nil { gitStatuses[id] = nil }
            return
        }
        guard let path = effectiveGitPath(for: ws) else {
            if gitStatuses[id] != nil { gitStatuses[id] = nil }
            return
        }
        // Bound sources (worktree/repo) are known repos and must never be
        // negative-cached (a transient git error mustn't freeze their badge); a
        // plain shell's guessed cwd that we've confirmed isn't a repo is skipped.
        let bound = ws.source.gitPath != nil
        if !bound, knownNonRepoPaths.contains(path) {
            if gitStatuses[id] != nil { gitStatuses[id] = nil }
            return
        }
        // Serialize per workspace, but never drop an invalidation. The current
        // status subprocess may already have snapshotted the tree while the
        // concurrent `git log` is still suspended; a request in that window
        // must trigger a fresh pass after this one completes.
        guard gitRefreshGate.begin(id) else { return }
        defer {
            if gitRefreshGate.finish(id) {
                refreshGitStatusNow(for: id)
            }
        }
        if let st = try? await git.status(at: path) {
            gitStatuses[id] = st
            knownNonRepoPaths.remove(path)
        } else {
            // cwd left the repo (or never was one) — drop the stale badge.
            if gitStatuses[id] != nil { gitStatuses[id] = nil }
            // Confirm it's genuinely not a repo (not a transient git error)
            // before caching, so we stop re-polling plain shells in non-repo dirs.
            if !bound, await git.repoRoot(at: path) == nil { knownNonRepoPaths.insert(path) }
        }
    }

    /// Poll git status for every workspace that has a path to check — bound
    /// repo/worktree sources plus plain shells whose cwd is inside a repo (so the
    /// tab's git button appears live as you `cd` around). One `git status` per
    /// workspace; non-repo cwds fail fast and clear their cache entry.
    func refreshAllGitStatuses() {
        for ws in workspaces where shouldTimerPoll(ws) {
            Task { await refreshGitStatus(for: ws.id) }
        }
    }

    /// Which workspaces an event or fallback refresh fans out to. Bound sources
    /// keep their dirty badge live; the selected workspace is what the user is
    /// looking at. Other plain shells are NOT timer-polled — they refresh on
    /// demand via `refreshGitStatusNow` when switched/focused, which avoids
    /// spawning N git subprocesses every tick for background terminals.
    static func shouldTimerPoll(_ ws: Workspace, selectedWorkspaceID: UUID?,
                                effectiveGitPath: String?, appIsActive: Bool) -> Bool {
        guard appIsActive, !ws.archived else { return false }
        guard effectiveGitPath != nil else { return false }
        if ws.id == selectedWorkspaceID { return true }
        switch ws.source.kind {
        case .localRepo, .localWorktree: return true
        default: return false
        }
    }

    private func shouldTimerPoll(_ ws: Workspace) -> Bool {
        Self.shouldTimerPoll(ws, selectedWorkspaceID: selectedWorkspaceID,
                             effectiveGitPath: effectiveGitPath(for: ws),
                             appIsActive: NSApp.isActive)
    }

    /// Fire-and-forget single refresh, used when the *displayed* terminal
    /// changes (workspace / tab / pane switch) so the tab's git button updates
    /// right away instead of waiting for a filesystem/fallback event.
    func refreshGitStatusNow(for id: UUID) {
        Task { await refreshGitStatus(for: id) }
    }

    // MARK: tree ops

    private static func splitLeaf(_ node: SplitNode, target: PaneID, direction: SplitDirection, newID: PaneID) -> SplitNode? {
        switch node {
        case .leaf(let id) where id == target:
            return .split(direction: direction, ratio: 0.5, a: .leaf(id), b: .leaf(newID))
        case .leaf:
            return nil
        case .split(let dir, let r, let a, let b):
            if let na = splitLeaf(a, target: target, direction: direction, newID: newID) {
                return .split(direction: dir, ratio: r, a: na, b: b)
            }
            if let nb = splitLeaf(b, target: target, direction: direction, newID: newID) {
                return .split(direction: dir, ratio: r, a: a, b: nb)
            }
            return nil
        }
    }

    private static func removeLeaf(_ node: SplitNode, target: PaneID) -> (SplitNode?, PaneID?) {
        switch node {
        case .leaf(let id) where id == target:
            return (nil, nil)
        case .leaf:
            return (node, nil)
        case .split(let dir, let r, let a, let b):
            if case .leaf(let aID) = a, aID == target { return (b, firstLeaf(b)) }
            if case .leaf(let bID) = b, bID == target { return (a, firstLeaf(a)) }
            let (na, sa) = removeLeaf(a, target: target)
            if let na, sa != nil { return (.split(direction: dir, ratio: r, a: na, b: b), sa) }
            let (nb, sb) = removeLeaf(b, target: target)
            if let nb, sb != nil { return (.split(direction: dir, ratio: r, a: a, b: nb), sb) }
            return (node, nil)
        }
    }

    private static func settingRatio(_ node: SplitNode, path: ArraySlice<Bool>, ratio: CGFloat) -> SplitNode {
        guard case .split(let dir, let r, let a, let b) = node else { return node }
        guard let head = path.first else {
            return .split(direction: dir, ratio: ratio, a: a, b: b)
        }
        let rest = path.dropFirst()
        return head
            ? .split(direction: dir, ratio: r, a: a, b: settingRatio(b, path: rest, ratio: ratio))
            : .split(direction: dir, ratio: r, a: settingRatio(a, path: rest, ratio: ratio), b: b)
    }

    private static func firstLeaf(_ node: SplitNode) -> PaneID {
        switch node {
        case .leaf(let id): return id
        case .split(_, _, let a, _): return firstLeaf(a)
        }
    }
}

// MARK: - Workspace icon kind

enum WorkspaceIconKind {
    case shell      // zsh / bash / fish / sh / login (nothing special running)
    case claude
    case codex
    case opencode
    case devin
    case omp
    case grok
    case pi
    case ssh
    case vim
    case python
    case node
    case git
    case other(String)

    /// SF Symbol name. Returns nil for kinds we render as a text glyph.
    var sfSymbol: String? {
        switch self {
        case .shell:  return "command"
        case .ssh:    return "network"
        case .vim:    return "text.cursor"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node:   return "hexagon.fill"
        case .git:    return "arrow.triangle.branch"
        case .claude, .codex, .opencode, .devin, .omp, .grok, .pi, .other:
            return nil
        }
    }

    /// Short text glyph used when sfSymbol is nil.
    var letter: String {
        switch self {
        case .claude: return "✦"
        case .codex:  return "λ"
        case .opencode: return "O"
        case .devin:  return "D"
        case .omp:    return "π"
        case .grok:   return "G"
        case .pi:     return "π"
        case .other(let s):
            return s.first.map { String($0).uppercased() } ?? "?"
        default:
            return ""
        }
    }

}

/// Claude icon family for the whole UI (sidebar mascot, tab chips,
/// workspace switcher). Raw values persist in UserDefaults.
enum ClaudeIconStyle: String, CaseIterable {
    case mascot
    case spark
}

/// Dock-icon palette options shown in Settings. `.default` is the bundle
/// `.icon` (Liquid Glass on macOS 26); the rest are static images backed by
/// `AppIconPreset-<name>` image sets in Assets.xcassets.
enum AppIconPreset: String, CaseIterable, Identifiable {
    case `default`
    case sunrise, classic, aurora, arctic, steel, ultraviolet, jade, ember, graphite

    var id: String { rawValue }

    /// Asset for the runtime override, or nil to fall back to the bundle icon.
    var assetName: String? {
        self == .default ? nil : "AppIconPreset-\(rawValue)"
    }

    /// Thumbnail for the Settings picker. `.default` borrows the sunrise art
    /// since the bundle icon ships that palette.
    var previewAsset: String {
        self == .default ? "AppIconPreset-sunrise" : "AppIconPreset-\(rawValue)"
    }

    /// Compact (full-bleed) logo drawn in the chrome header / settings header
    /// so it tracks the chosen palette. `.default` follows the sunrise art.
    var headerLogoAsset: String {
        self == .default ? "GlintLogo-sunrise" : "GlintLogo-\(rawValue)"
    }

    var displayName: String {
        switch self {
        case .default: return "默认"
        case .sunrise: return "日出"
        case .classic: return "经典"
        case .aurora: return "极光"
        case .arctic: return "极地"
        case .steel: return "钢蓝"
        case .ultraviolet: return "紫罗兰"
        case .jade: return "翡翠"
        case .ember: return "余烬"
        case .graphite: return "石墨"
        }
    }
}

@MainActor
final class PaneActivityStore: ObservableObject {
    @Published var paneProcesses: [WorkspaceStore.WorkspacePaneKey: String] = [:]
    @Published var paneAgentState: [WorkspaceStore.WorkspacePaneKey: PaneAgentState] = [:]
}

extension WorkspaceStore {
    /// Best attention rank across the panes that are actually present in this
    /// workspace's tab layout. This deliberately does not reuse `agentSummary`:
    /// that method chooses the status-dot winner, where an active `.thinking`
    /// pane outranks `.justCompleted`; for sidebar attention, any completed
    /// sibling must still float the workspace.
    func attentionRank(for workspace: Workspace) -> Int {
        let statuses = workspace.tabs.flatMap { tab in
            tab.root.leaves.compactMap { paneID in
                paneAgentState[WorkspacePaneKey(workspace: workspace.id, pane: paneID)]?.status
            }
        }
        return PaneAgentStatus.bestAttentionRank(in: statuses)
    }

    /// Most attention-worthy agent status across this workspace's panes.
    /// Returns nil if no pane is running an agent in a non-idle state.
    func agentStatusSummary(for workspace: Workspace) -> PaneAgentStatus? {
        agentSummary(for: workspace)?.status
    }

    /// Same as `agentStatusSummary` but also returns when the winning pane
    /// last transitioned, so the sidebar card can show a live turn timer.
    func agentSummary(for workspace: Workspace) -> (status: PaneAgentStatus, since: Date)? {
        var best: (PaneAgentStatus, Date)?
        for paneID in workspace.panes.keys {
            let key = WorkspacePaneKey(workspace: workspace.id, pane: paneID)
            guard let entry = paneAgentState[key] else { continue }
            // `since` is the turn start (not last status change) so the sidebar
            // timer shows total turn elapsed time, not per-tool-call time.
            if let cur = best {
                let merged = mergeStatus(cur.0, entry.status)
                // Take the timestamp from whichever side won the merge.
                best = (merged, merged == cur.0 ? cur.1 : entry.turnStartedAt)
            } else {
                best = (entry.status, entry.turnStartedAt)
            }
        }
        return best
    }

    /// One non-idle agent pane, for the per-pane summary cluster + hover
    /// popover. `number` is the pane's 1-based position in visual layout
    /// (left→right, tab order) so it stays stable as statuses change; the
    /// array itself is sorted by attention rank for display.
    struct AgentPaneInfo: Identifiable, Equatable {
        let paneID: PaneID
        let number: Int
        /// The pane's tab display name — same label its tab chip shows — so
        /// the popover reads like the tabs do rather than "Pane 1/2".
        let label: String
        let kind: PaneAgentKind
        let status: PaneAgentStatus
        /// Turn start — drives the "2m" elapsed label (total turn time).
        let since: Date
        var id: PaneID { paneID }
    }

    /// Per-pane breakdown over an ordered (pane, label) list. The order
    /// defines the 1-based numbering; the result keeps only non-idle agent
    /// panes (the ones with a colored beacon) and is sorted by attention
    /// rank, then most-recently-updated — same precedence as the icon merge.
    private func agentPaneBreakdown(ordered: [(pane: PaneID, label: String)],
                                    workspaceID: UUID) -> [AgentPaneInfo] {
        var out: [(info: AgentPaneInfo, updatedAt: Date)] = []
        for (idx, item) in ordered.enumerated() {
            let key = WorkspacePaneKey(workspace: workspaceID, pane: item.pane)
            guard let e = paneAgentState[key], e.status != .idle else { continue }
            out.append((AgentPaneInfo(paneID: item.pane, number: idx + 1,
                                      label: item.label, kind: e.kind,
                                      status: e.status, since: e.turnStartedAt),
                        e.updatedAt))
        }
        out.sort {
            let (ra, rb) = (statusRank($0.info.status), statusRank($1.info.status))
            if ra != rb { return ra > rb }
            return $0.updatedAt > $1.updatedAt
        }
        return out.map(\.info)
    }

    /// Non-idle agent panes in a single tab, numbered left→right within the
    /// tab and sorted by attention rank. Drives the tab chip's cluster +
    /// hover popover.
    func tabPaneSummary(_ tab: WorkspaceTab, in workspace: Workspace) -> [AgentPaneInfo] {
        let label = workspace.tabDisplayName(tab)
        return agentPaneBreakdown(ordered: tab.root.leaves.map { ($0, label) },
                                  workspaceID: workspace.id)
    }

    /// Non-idle agent panes across a whole workspace, numbered in tab order
    /// (left→right within each tab), each labelled with its own tab's name.
    /// Drives the sidebar card + switcher row.
    func workspacePaneSummary(_ workspace: Workspace) -> [AgentPaneInfo] {
        let ordered = workspace.tabs.flatMap { tab in
            tab.root.leaves.map { ($0, workspace.tabDisplayName(tab)) }
        }
        return agentPaneBreakdown(ordered: ordered, workspaceID: workspace.id)
    }

    /// A turn is actively running in these states — used to anchor the turn
    /// clock (set on the first non-busy → busy transition, kept through the
    /// turn). `.justCompleted`/`.failed`/`.idle` are turn-end / no-turn.
    static func isBusyStatus(_ s: PaneAgentStatus) -> Bool {
        switch s {
        case .thinking, .tool, .compacting, .needsPermission: return true
        case .justCompleted, .failed, .needsReply, .idle:     return false
        }
    }

    /// Attention ranking shared by the status merge and the icon pick.
    /// Which status to SHOW (the tab chip's dot) when a tab has panes at
    /// different statuses — NOT the "float to top" ordering. A different axis
    /// from `PaneAgentStatus.attentionRank` (which ranks what the sidebar
    /// floats and ⌘⇧A jumps to, and treats `.failed`/`.justCompleted` as
    /// peers); here `.failed` outranks `.justCompleted` because an error dot
    /// should win the chip. Don't "fix" one to match the other.
    private func statusRank(_ s: PaneAgentStatus) -> Int {
        switch s {
        case .needsPermission:            return 5
        case .failed:                     return 4
        case .compacting:                 return 3
        case .tool:                       return 3
        case .thinking:                   return 3
        case .justCompleted, .needsReply: return 2
        case .idle:                       return 1
        }
    }

    private func mergeStatus(_ a: PaneAgentStatus?, _ b: PaneAgentStatus) -> PaneAgentStatus {
        let rank = statusRank
        guard let a else { return b }
        return rank(b) > rank(a) ? b : a
    }

    /// Most attention-worthy agent status across a single tab's panes — drives
    /// the tab chip's status dot. nil = no agent reporting / all idle.
    func tabAgentStatus(_ tab: WorkspaceTab, in workspace: Workspace) -> PaneAgentStatus? {
        var best: PaneAgentStatus?
        for paneID in tab.root.leaves {
            let key = WorkspacePaneKey(workspace: workspace.id, pane: paneID)
            guard let entry = paneAgentState[key] else { continue }
            best = mergeStatus(best, entry.status)
        }
        return best
    }

    /// Icon for a single tab chip. Only live process/hook state affects the
    /// icon; when an agent exits back to shell, the chip returns to shell.
    func tabIconKind(_ tab: WorkspaceTab, in workspace: Workspace) -> WorkspaceIconKind {
        liveIconKind(paneIDs: tab.root.leaves, workspaceID: workspace.id)
    }

    /// Icon to display for a workspace. Only live process/hook state affects
    /// the icon; when an agent exits back to shell, the icon returns to shell.
    func iconKind(for workspace: Workspace) -> WorkspaceIconKind {
        liveIconKind(for: workspace)
    }


    /// Pick the most representative icon for a workspace based on what its
    /// panes are currently running. AI / SSH / dev tools beat plain shell.
    private func liveIconKind(for workspace: Workspace) -> WorkspaceIconKind {
        liveIconKind(paneIDs: Array(workspace.panes.keys), workspaceID: workspace.id)
    }

    /// Shared icon picker over an arbitrary pane set — used for both the whole
    /// workspace (all panes) and a single tab (just that tab's leaves).
    private func liveIconKind(paneIDs: [PaneID], workspaceID: UUID) -> WorkspaceIconKind {
        // Agent push-state wins over pid polling — if any pane reported a
        // claude/codex/opencode/devin/omp hook, surface that. With several agent panes (e.g.
        // claude + codex side by side) the busy one wins; when all are equally
        // busy/idle, the most recently active wins. `paneIDs` may come from a
        // Dictionary's keys, so without this ordering the icon would be
        // hash-order roulette.
        var bestAgent: PaneAgentState?
        for paneID in paneIDs {
            let key = WorkspacePaneKey(workspace: workspaceID, pane: paneID)
            guard let entry = paneAgentState[key] else { continue }
            guard let cur = bestAgent else { bestAgent = entry; continue }
            let (curRank, newRank) = (statusRank(cur.status), statusRank(entry.status))
            if newRank > curRank || (newRank == curRank && entry.updatedAt > cur.updatedAt) {
                bestAgent = entry
            }
        }
        if let bestAgent {
            switch bestAgent.kind {
            case .claude: return .claude
            case .codex: return .codex
            case .opencode: return .opencode
            case .devin: return .devin
            case .omp: return .omp
            case .grok: return .grok
            case .pi: return .pi
            }
        }

        let names = paneIDs.compactMap {
            paneProcesses[WorkspacePaneKey(workspace: workspaceID, pane: $0)]?.lowercased()
        }

        // Priority: ssh > AI agents > editors > runtimes > shell.
        if names.contains(where: { $0 == "ssh" || $0 == "mosh" }) { return .ssh }
        if names.contains(where: { $0.contains("claude") })        { return .claude }
        if names.contains(where: { $0 == "codex" || $0.contains("codex") }) { return .codex }
        if names.contains(where: { $0 == "opencode" || $0.contains("opencode") }) { return .opencode }
        if names.contains(where: { $0 == "devin" || $0.contains("devin") }) { return .devin }
        if names.contains(where: { $0 == "omp" || $0.hasSuffix("/omp") }) { return .omp }
        if names.contains(where: { $0 == "grok" || $0.contains("grok") }) { return .grok }
        if names.contains(where: { $0 == "pi" || $0.hasSuffix("/pi") }) { return .pi }
        if names.contains(where: { $0 == "vim" || $0 == "nvim" || $0 == "vi" }) { return .vim }
        if names.contains(where: { $0 == "python" || $0 == "python3" || $0 == "ipython" }) { return .python }
        if names.contains(where: { $0 == "node" || $0 == "deno" || $0 == "bun" }) { return .node }
        if names.contains(where: { $0 == "git" }) { return .git }

        // Anything non-shell still gets a hint — show the binary's initial.
        if let custom = names.first(where: { !Self.benignShells.contains($0) && !$0.isEmpty }) {
            return .other(custom)
        }
        return .shell
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by GhosttyManager when ghostty reports a new cwd for some
    /// surface (via OSC 7 / GHOSTTY_ACTION_PWD).
    static let ghosttyCwdChanged = Notification.Name("ghostty.cwd.changed")
    /// Posted after a title updates remote SSH state for one surface.
    static let ghosttyRemoteTitleChanged = Notification.Name("ghostty.remote-title.changed")
    /// Posted when shell integration reports that a command completed on a
    /// specific surface. Consumers can refresh only that pane/repository.
    static let ghosttyCommandFinished = Notification.Name("ghostty.command.finished")
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
