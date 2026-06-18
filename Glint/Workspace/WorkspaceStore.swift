import SwiftUI
import Combine
import AppKit

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

    private enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory, lastAgent
    }

    init(id: PaneID, title: String, workingDirectory: String? = nil, lastAgent: String? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastAgent = lastAgent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(PaneID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.lastAgent = try c.decodeIfPresent(String.self, forKey: .lastAgent)
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
    /// Last-known agent identity ("claude"/"codex") for this tab, so its chip
    /// icon survives a restart before any pane re-reports. Mirrors
    /// `Workspace.iconHint` but scoped to this tab's panes. Synthesized
    /// Codable decodes a missing key (older saves) as nil. See `tabIconKind`.
    var iconHint: String? = nil
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
    /// Last-known agent identity ("claude"/"codex") for this workspace, so its
    /// icon survives a restart before any process re-reports. Only the *kind*
    /// is persisted — the live agent *status* (thinking/needsPermission/…) is
    /// runtime-only and intentionally not saved. See `iconKind(for:)`.
    var iconHint: String?
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

    var accent: Color {
        Color(hex: accentHex) ?? Color(red: 0.37, green: 0.36, blue: 0.90)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, userNamed, accentHex, symbol, iconHint, archived
        case tabs, selectedTabID, nextTabSeq, panes, nextPaneSeq
        // Legacy single-tree keys, still read so pre-tabs saves migrate.
        case root, focusedPane
    }

    init(id: UUID, name: String, userNamed: Bool, accentHex: String, symbol: String,
         tabs: [WorkspaceTab], selectedTabID: TabID, nextTabSeq: UInt32,
         panes: [PaneID: Pane], nextPaneSeq: UInt32, iconHint: String? = nil,
         archived: Bool = false) {
        self.id = id
        self.name = name
        self.userNamed = userNamed
        self.accentHex = accentHex
        self.symbol = symbol
        self.iconHint = iconHint
        self.archived = archived
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.nextTabSeq = nextTabSeq
        self.panes = panes
        self.nextPaneSeq = nextPaneSeq
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
        // Older saves predate the persisted icon hint — fine, it stays nil and
        // the icon is derived live until an agent reports.
        self.iconHint = try c.decodeIfPresent(String.self, forKey: .iconHint)
        // Older saves predate the archive feature — default to active.
        self.archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        self.panes = try c.decode([PaneID: Pane].self, forKey: .panes)
        self.nextPaneSeq = try c.decode(UInt32.self, forKey: .nextPaneSeq)

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
        try c.encodeIfPresent(iconHint, forKey: .iconHint)
        if archived { try c.encode(true, forKey: .archived) }   // omit the common case
        try c.encode(tabs, forKey: .tabs)
        try c.encode(selectedTabID, forKey: .selectedTabID)
        try c.encode(nextTabSeq, forKey: .nextTabSeq)
        try c.encode(panes, forKey: .panes)
        try c.encode(nextPaneSeq, forKey: .nextPaneSeq)
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
        let cwd = (selectedTab?.focusedPane).flatMap { panes[$0]?.workingDirectory }
            ?? panes.values.compactMap(\.workingDirectory).first
        return Self.shortLabel(forCwd: cwd) ?? name
    }

    /// Label for a tab chip: the user's name if set, otherwise a short cwd
    /// label from the tab's focused pane, otherwise a generic fallback.
    func tabDisplayName(_ tab: WorkspaceTab) -> String {
        if let n = tab.name, !n.isEmpty { return n }
        let cwd = panes[tab.focusedPane]?.workingDirectory
            ?? tab.root.leaves.compactMap { panes[$0]?.workingDirectory }.first
        return Self.shortLabel(forCwd: cwd) ?? String(localized: "Terminal")
    }

    private static func shortLabel(forCwd path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path == "/" { return "/" }
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

// MARK: - Store

@MainActor
final class WorkspaceStore: ObservableObject {

    @Published var workspaces: [Workspace]
    @Published var selectedWorkspaceID: UUID?
    @Published var sidebarCollapsed: Bool
    /// Latest foreground-process name per (workspace, pane). Polled every
    /// few seconds; drives the workspace card icon. Non-persistent.
    @Published var paneProcesses: [WorkspacePaneKey: String] = [:]
    /// CLI-agent state per pane (push-driven via AgentBridge hooks).
    /// Beats `paneProcesses` for icon/state because hooks carry live
    /// status (thinking/permission/…) the 1s name poll can't know.
    /// Non-persistent.
    @Published var paneAgentState: [WorkspacePaneKey: PaneAgentState] = [:]

    /// Drives the command-palette overlay. Toggled by the toolbar's ⌘
    /// button and the ⌘K global shortcut.
    @Published var commandPaletteOpen: Bool = false

    /// Drives the Settings sheet attached to the main window. We host
    /// Settings inside the window (not as a separate scene) so it
    /// inherits the workspace context and feels of-the-app rather than
    /// of-the-OS.
    @Published var settingsOpen: Bool = false

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
    @Published var terminalFontFamily: String = UserDefaults.standard.string(forKey: "glint.terminalFontFamily") ?? "SF Mono" {
        didSet {
            UserDefaults.standard.set(terminalFontFamily, forKey: "glint.terminalFontFamily")
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
    @Published var terminalScrollback: Int = {
        let v = UserDefaults.standard.integer(forKey: "glint.terminalScrollback")
        return v == 0 ? 10_000 : v
    }() {
        didSet {
            UserDefaults.standard.set(terminalScrollback, forKey: "glint.terminalScrollback")
            GhosttyManager.shared.reloadConfig()
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

    /// Single switch for all behind-window vibrancy in the chrome (sidebar,
    /// toolbar, and the matching settings sidebar). When off, chrome falls
    /// back to flat opaque surfaces — useful on older Macs and gives a
    /// noticeably flatter look. Defaults to on.
    @Published var glassEffect: Bool = (UserDefaults.standard.object(forKey: "glint.glassEffect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(glassEffect, forKey: "glint.glassEffect") }
    }

    /// UI accent color. Drives focus/selection highlights across the chrome
    /// (command palette selection bar, workspace switcher checkmark, Install
    /// buttons in Settings). Values: "indigo" | "cyan" | "pink" | "orange"
    /// | "green". Default "indigo". Persists across launches.
    @Published var accentName: String = UserDefaults.standard.string(forKey: "glint.accentName") ?? "indigo" {
        didSet { UserDefaults.standard.set(accentName, forKey: "glint.accentName") }
    }

    var accent: Color {
        switch accentName {
        case "cyan":   return Theme.cyan
        case "pink":   return Theme.pink
        case "orange": return Theme.orange
        case "green":  return Theme.green
        default:       return Theme.accentBright
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

    /// Whether the sidebar's "Archived" section is currently expanded.
    /// Persists across launches so a user who keeps it open doesn't have to
    /// re-open it every cold start.
    @Published var archiveExpanded: Bool = (UserDefaults.standard.object(forKey: "glint.archiveExpanded") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(archiveExpanded, forKey: "glint.archiveExpanded") }
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
        ]
    }

    private static func autoInstallAgentHooksOnFirstLaunch(socketPath: String) {
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

    /// Best-effort "is this agent installed on this Mac" checks, surfaced in
    /// Settings → Agents so a card reads "Not detected" instead of silently
    /// offering to install hooks for a tool the user doesn't have.
    var claudeDetected: Bool { AgentHookInstaller.isAgentPresent() }
    var codexDetected: Bool { CodexHookInstaller.isAgentPresent() }
    var opencodeDetected: Bool { OpenCodeHookInstaller.isAgentPresent() }

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

    private var saveCancellable: AnyCancellable?
    private var cwdTimer: Timer?
    /// Counts 1s cwd ticks so scrollback flushes run at ~5s, not every second.
    private var scrollbackFlushTick = 0
    private var observerTokens: [NSObjectProtocol] = []

    /// The app's single live store. AppDelegate consults it for the quit
    /// confirmation (it has no other path to the store — the store is
    /// created by GlintApp as a @StateObject).
    static private(set) weak var current: WorkspaceStore?

    init() {
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

        // Debounced autosave: any @Published change → save 0.5s later.
        saveCancellable = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persist() }

        // Sweep live surface cwds every second so a crash/quit still leaves
        // recent dirs persisted. The closure captures self weakly so the
        // repeating timer doesn't retain the store forever.
        cwdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // scheduledTimer fires on the main run loop, so this is already the
            // main actor — assumeIsolated avoids allocating a Task every second.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureCwdsFromLiveSurfaces()
                // Capture the live agent identity so the icon persists across a
                // restart (writes only when it actually changes).
                self.syncIconHints()
                // Snapshot terminal scrollback to disk roughly every 5s (off
                // the IO/main hot path; skips panes with no new output).
                self.scrollbackFlushTick += 1
                if self.scrollbackFlushTick >= 5 {
                    self.scrollbackFlushTick = 0
                    self.flushScrollback()
                }
            }
        }

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
                self.captureCwdsFromLiveSurfaces()
                self.syncIconHints()
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
        ) { [weak self] _ in
            Task { @MainActor in self?.captureCwdsFromLiveSurfaces() }
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
                guard let self, let id = self.selectedWorkspaceID else { return }
                self.acknowledgeCompletionIfNeeded(for: id)
            }
        })

        // Boot the CLI-agent IPC channel and route hook events into pane state.
        AgentBridge.shared.start()
        Self.autoInstallAgentHooksOnFirstLaunch(socketPath: AgentBridge.shared.socketPath)
        self.claudeHooksInstalled = AgentHookInstaller.isInstalled()
        self.codexHooksInstalled = CodexHookInstaller.isInstalled()
        self.opencodeHooksInstalled = OpenCodeHookInstaller.isInstalled()
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
        cwdTimer?.invalidate()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: surface registry

    struct WorkspacePaneKey: Hashable {
        let workspace: UUID
        let pane: PaneID
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
        let restoreCommand: String? = {
            guard let pane = workspaces.first(where: { $0.id == workspaceID })?.panes[paneID]
            else { return nil }
            switch pane.lastAgent {
            case "claude"   where restoreClaudeSession:   return "claude --continue\n"
            case "codex"    where restoreCodexSession:    return "codex resume --last\n"
            case "opencode" where restoreOpenCodeSession: return "opencode --continue\n"
            default: return nil
            }
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
        for view in surfaceViews.values { view.flushScrollbackToDisk() }
    }

    func captureCwdsFromLiveSurfaces() {
        var newProcesses: [WorkspacePaneKey: String] = [:]
        for i in workspaces.indices {
            let wsID = workspaces[i].id
            for paneID in workspaces[i].panes.keys {
                let key = WorkspacePaneKey(workspace: wsID, pane: paneID)
                guard let view = surfaceViews[key] else { continue }
                // Only write when the value actually changed: an unconditional
                // subscript write on a @Published array fires objectWillChange
                // every tick, and since this poll (1s) outpaces the autosave
                // debounce (0.5s) that meant a JSON encode + disk write every
                // second for the app's whole lifetime.
                if let cwd = view.currentCwd(),
                   workspaces[i].panes[paneID]?.workingDirectory != cwd {
                    workspaces[i].panes[paneID]?.workingDirectory = cwd
                }
                if let name = view.foregroundProcessName() {
                    newProcesses[key] = name
                    // Track CURRENT claude/codex foreground so the next launch
                    // can optionally `--continue` / `resume --last` (gated by
                    // the per-agent setting). Not sticky: a pane that quit
                    // back to the shell clears its hint, so we don't auto-
                    // resume on a pane the user explicitly exited from.
                    let lower = name.lowercased()
                    let agent: String? = {
                        if lower.contains("claude") { return "claude" }
                        if lower.contains("codex")  { return "codex" }
                        if lower.contains("opencode") { return "opencode" }
                        return nil
                    }()
                    if workspaces[i].panes[paneID]?.lastAgent != agent {
                        workspaces[i].panes[paneID]?.lastAgent = agent
                    }
                }
            }
        }
        if newProcesses != paneProcesses {
            for (k, v) in newProcesses where paneProcesses[k] != v {
                NSLog("[glint] pane process changed: ws=\(k.workspace.uuidString.prefix(8)) pane=\(k.pane.value) -> \(v)")
            }
            paneProcesses = newProcesses
        }

        // Reconcile stale hook state. Hooks are the only writer of
        // paneAgentState and no hook fires when an agent quits, so after
        // e.g. claude → exit → codex the pane keeps kind == .claude and
        // iconKind (which prefers hook state over pid polling) never
        // flips. Claude masks this by emitting SessionStart on launch;
        // codex sends nothing until its first turn ends. When the poller
        // sees a pane actually running a *different* known agent, hand
        // the state over to it.
        for (key, name) in newProcesses {
            guard var state = paneAgentState[key] else { continue }
            let runningKind: PaneAgentKind? =
                name.contains("claude") ? .claude :
                name.contains("codex") ? .codex :
                name.contains("opencode") ? .opencode : nil
            if let runningKind, runningKind != state.kind {
                state.kind = runningKind
                state.status = .idle
                state.detail = nil
                state.updatedAt = Date()
                paneAgentState[key] = state
            }
        }
    }

    // MARK: agent hook events

    /// Translate one hook from the AgentBridge into pane state. The hook
    /// itself only carries the event name — full payload routing comes later
    /// once we wire `data` through.
    func handleAgentEvent(_ info: [AnyHashable: Any]?) {
        guard let info,
              let paneStr = info["pane"] as? String,
              let hook = info["hook"] as? String,
              let key = Self.parsePaneKey(paneStr) else { return }

        let agentStr = (info["agent"] as? String) ?? "claude"
        let kind: PaneAgentKind = {
            switch agentStr.lowercased() {
            case "codex": return .codex
            case "opencode": return .opencode
            default: return .claude
            }
        }()

        // Note: we deliberately do NOT force-write paneProcesses here. The
        // 1s poller owns that dictionary and replaces it wholesale, so any
        // value written from this path lived at most one tick. Icon/state
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
        case "PermissionRequest": state.status = .needsPermission
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
            case .failed where soundOnError:
                NSSound(named: soundErrorName)?.play()
            default:
                break
            }
        }
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
        case .idle, .justCompleted, .failed:
            // justCompleted/failed are unread badges — only viewing the
            // workspace clears them, not a stray Esc.
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
              let key = Self.parsePaneKey(paneStr),
              var state = paneAgentState[key],
              state.status == .needsPermission else { return }
        let now = Date()
        state.status = .tool
        state.updatedAt = now
        state.turnStartedAt = now
        paneAgentState[key] = state
    }

    /// Clear any `.justCompleted` / `.failed` panes back to `.idle` — but
    /// only the ones actually on screen: panes in `workspaceID`'s *selected
    /// tab*. Called when the user selects the workspace, switches to a tab,
    /// or ⌘Tabs back to Glint — each is "I saw it finished / saw it
    /// errored". Background tabs keep their badge until visited.
    func acknowledgeCompletionIfNeeded(for workspaceID: UUID) {
        guard let ws = workspaces.first(where: { $0.id == workspaceID }),
              let tab = ws.selectedTab else { return }
        let visible = Set(tab.root.leaves)
        for (key, state) in paneAgentState
        where key.workspace == workspaceID && visible.contains(key.pane)
            && (state.status == .justCompleted || state.status == .failed) {
            paneAgentState[key]?.status = .idle
            paneAgentState[key]?.updatedAt = Date()
        }
    }

    /// True when `key`'s pane is on screen right now: its workspace is the
    /// selected workspace AND it lives in that workspace's selected tab.
    private func isPaneVisible(_ key: WorkspacePaneKey) -> Bool {
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

    func splitFocused(_ direction: SplitDirection) {
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
    }

    /// Shells whose presence as the foreground process means "nothing of
    /// value is running" — closing the pane loses no work. Shared by the
    /// close-confirmation check and the workspace icon picker.
    static let benignShells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "login", "tmux"]

    /// True when killing this pane would interrupt real work: a CLI agent
    /// with a live session (even an idle one — closing kills the session),
    /// or any non-shell foreground process (vim, ssh, a build, …).
    func paneNeedsCloseConfirmation(_ key: WorkspacePaneKey) -> Bool {
        if paneAgentState[key] != nil,
           let name = paneProcesses[key]?.lowercased(),
           name.contains("claude") || name.contains("codex") {
            return true
        }
        if let s = paneAgentState[key]?.status,
           s == .thinking || s == .tool || s == .compacting || s == .needsPermission {
            return true
        }
        if let name = paneProcesses[key]?.lowercased(), !name.isEmpty,
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
    }

    func focusPrevious() {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        let leaves = workspaces[i].tabs[t].root.leaves.sorted { $0.value < $1.value }
        guard !leaves.isEmpty,
              let pos = leaves.firstIndex(of: workspaces[i].tabs[t].focusedPane) else { return }
        workspaces[i].tabs[t].focusedPane = leaves[(pos - 1 + leaves.count) % leaves.count]
    }

    func focus(_ id: PaneID) {
        guard let i = currentIndex, let t = workspaces[i].selectedTabIndex else { return }
        workspaces[i].tabs[t].focusedPane = id
    }

    func selectWorkspace(_ id: UUID) {
        selectedWorkspaceID = id
        acknowledgeCompletionIfNeeded(for: id)
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
    func newTab() {
        guard let i = currentIndex else { return }
        let inheritedCwd = (workspaces[i].selectedTab?.focusedPane)
            .flatMap { workspaces[i].panes[$0]?.workingDirectory }
        let pane = PaneID(value: workspaces[i].nextPaneSeq)
        workspaces[i].nextPaneSeq += 1
        workspaces[i].panes[pane] = Pane(id: pane, title: "zsh", workingDirectory: inheritedCwd)
        let tab = WorkspaceTab(id: TabID(value: workspaces[i].nextTabSeq), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        workspaces[i].nextTabSeq += 1
        if let sel = workspaces[i].selectedTabIndex {
            workspaces[i].tabs.insert(tab, at: sel + 1)
        } else {
            workspaces[i].tabs.append(tab)
        }
        workspaces[i].selectedTabID = tab.id
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
        for pane in panes {
            let key = WorkspacePaneKey(workspace: wsID, pane: pane)
            workspaces[i].panes.removeValue(forKey: pane)
            surfaceViews.removeValue(forKey: key)
            ScrollbackArchive.delete(
                id: ScrollbackArchive.fileID(forPaneKey: "\(wsID.uuidString):\(pane.value)"))
            paneAgentState.removeValue(forKey: key)
            paneProcesses.removeValue(forKey: key)
        }
        workspaces[i].tabs.remove(at: t)
        if wasSelected {
            let nextIdx = min(t, workspaces[i].tabs.count - 1)
            workspaces[i].selectedTabID = workspaces[i].tabs[nextIdx].id
        }
    }

    func selectTab(_ tabID: TabID) {
        guard let i = currentIndex,
              workspaces[i].tabs.contains(where: { $0.id == tabID }) else { return }
        workspaces[i].selectedTabID = tabID
        // Viewing the tab is what "reads" its ✓ done / error badges.
        acknowledgeCompletionIfNeeded(for: workspaces[i].id)
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

    func deleteWorkspace(_ id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }

        let busyPanes = workspaces[idx].panes.keys
            .filter { paneNeedsCloseConfirmation(WorkspacePaneKey(workspace: id, pane: $0)) }
        if !busyPanes.isEmpty,
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
        // And their scrollback snapshots.
        for paneID in workspaces[idx].panes.keys {
            ScrollbackArchive.delete(
                id: ScrollbackArchive.fileID(forPaneKey: "\(id.uuidString):\(paneID.value)"))
        }
        paneAgentState = paneAgentState.filter { $0.key.workspace != id }
        paneProcesses = paneProcesses.filter { $0.key.workspace != id }

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

    func addWorkspace() {
        let palette = [
            ("5E5CE6", "•"), ("FF6582", "•"), ("30D158", "•"),
            ("FF9F0A", "•"), ("64D2FF", "•"), ("BF5AF2", "•"),
        ]
        let pick = palette[workspaces.count % palette.count]
        // Auto-named: fallback label is "New workspace" until the shell reports a cwd.
        let ws = Workspace.fresh(name: "New workspace", accentHex: pick.0, symbol: pick.1)
        workspaces.append(ws)
        selectedWorkspaceID = ws.id
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
        case .claude, .codex, .opencode, .other:
            return nil
        }
    }

    /// Short text glyph used when sfSymbol is nil.
    var letter: String {
        switch self {
        case .claude: return "✦"
        case .codex:  return "λ"
        case .opencode: return "O"
        case .other(let s):
            return s.first.map { String($0).uppercased() } ?? "?"
        default:
            return ""
        }
    }

    /// Stable token for the kinds worth persisting as a workspace's identity —
    /// the AI agents. Transient process/tool kinds (ssh/vim/python/git/…) return
    /// nil: they're re-derived live each session and shouldn't stick forever.
    var persistToken: String? {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .opencode: return "opencode"
        default:      return nil
        }
    }

    static func fromPersistToken(_ token: String) -> WorkspaceIconKind? {
        switch token {
        case "claude": return .claude
        case "codex":  return .codex
        case "opencode": return .opencode
        default:       return nil
        }
    }
}

/// Claude icon family for the whole UI (sidebar mascot, tab chips,
/// workspace switcher). Raw values persist in UserDefaults.
enum ClaudeIconStyle: String, CaseIterable {
    case mascot
    case spark
}

extension WorkspaceStore {
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

    /// A turn is actively running in these states — used to anchor the turn
    /// clock (set on the first non-busy → busy transition, kept through the
    /// turn). `.justCompleted`/`.failed`/`.idle` are turn-end / no-turn.
    static func isBusyStatus(_ s: PaneAgentStatus) -> Bool {
        switch s {
        case .thinking, .tool, .compacting, .needsPermission: return true
        case .justCompleted, .failed, .idle:                  return false
        }
    }

    /// Attention ranking shared by the status merge and the icon pick.
    private func statusRank(_ s: PaneAgentStatus) -> Int {
        switch s {
        case .needsPermission: return 5
        case .failed:          return 4
        case .compacting:      return 3
        case .tool:            return 3
        case .thinking:        return 3
        case .justCompleted:   return 2
        case .idle:            return 1
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

    /// Icon for a single tab chip. Prefers what's running live; after a
    /// restart (no pane has reported yet → live falls back to `.shell`) it
    /// restores the tab's persisted agent identity, exactly like
    /// `iconKind(for:)` does for workspaces. A live agent/process always wins.
    func tabIconKind(_ tab: WorkspaceTab, in workspace: Workspace) -> WorkspaceIconKind {
        // Tab chips never restore an agent identity from `iconHint` — only
        // a live claude/codex process surfaces an agent icon. Sidebar cards
        // and the workspace switcher still go through iconKind(for:) and
        // keep their memory behavior.
        liveIconKind(paneIDs: tab.root.leaves, workspaceID: workspace.id)
    }

    /// Icon to display for a workspace. Prefers what's running live; after a
    /// restart (no process has reported yet → live falls back to `.shell`) it
    /// restores the persisted agent identity so the workspace keeps its icon.
    /// A live agent/process always wins over the saved hint.
    func iconKind(for workspace: Workspace) -> WorkspaceIconKind {
        let live = liveIconKind(for: workspace)
        if case .shell = live,
           let hint = workspace.iconHint,
           let restored = WorkspaceIconKind.fromPersistToken(hint) {
            return restored
        }
        return live
    }

    /// Persist each workspace's — and each of its tabs' — live agent identity
    /// (claude/codex) into the matching `iconHint` so icons survive a restart.
    /// Writes only on change to avoid autosave churn; never clears a hint (a
    /// workspace/tab that drops back to a bare shell keeps its last agent icon).
    /// Status is never touched.
    func syncIconHints() {
        var changed = false
        for i in workspaces.indices {
            if let token = liveIconKind(for: workspaces[i]).persistToken,
               workspaces[i].iconHint != token {
                workspaces[i].iconHint = token
                changed = true
            }
            // Same policy per tab, scoped to that tab's panes, so a folded or
            // background tab restores its own agent icon independently.
            for j in workspaces[i].tabs.indices {
                let leaves = workspaces[i].tabs[j].root.leaves
                guard let token = liveIconKind(paneIDs: leaves,
                                               workspaceID: workspaces[i].id).persistToken
                else { continue }
                if workspaces[i].tabs[j].iconHint != token {
                    workspaces[i].tabs[j].iconHint = token
                    changed = true
                }
            }
        }
        // Flush immediately rather than waiting on the 0.5s autosave debounce:
        // an agent appearing is a rare event, and a hard kill (dev `pkill -9`,
        // crash) inside the debounce window would otherwise lose the hint, so
        // the icon wouldn't restore. Cheap because `changed` is almost always
        // false (the token only flips when claude/codex first shows up).
        if changed { persist() }
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
        // claude/codex hook, surface that. With several agent panes (e.g.
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
