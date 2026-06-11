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

struct Pane: Identifiable, Codable {
    let id: PaneID
    var title: String
    /// Last-known working directory; used to re-spawn the shell in the same
    /// place after a restart. Updated periodically while running.
    var workingDirectory: String?
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
    var root: SplitNode
    var panes: [PaneID: Pane]
    var focusedPane: PaneID
    var nextPaneSeq: UInt32

    var accent: Color {
        Color(hex: accentHex) ?? Color(red: 0.37, green: 0.36, blue: 0.90)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, userNamed, accentHex, symbol, root, panes, focusedPane, nextPaneSeq
    }

    init(id: UUID, name: String, userNamed: Bool, accentHex: String, symbol: String,
         root: SplitNode, panes: [PaneID: Pane], focusedPane: PaneID, nextPaneSeq: UInt32) {
        self.id = id
        self.name = name
        self.userNamed = userNamed
        self.accentHex = accentHex
        self.symbol = symbol
        self.root = root
        self.panes = panes
        self.focusedPane = focusedPane
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
        self.root = try c.decode(SplitNode.self, forKey: .root)
        self.panes = try c.decode([PaneID: Pane].self, forKey: .panes)
        self.focusedPane = try c.decode(PaneID.self, forKey: .focusedPane)
        self.nextPaneSeq = try c.decode(UInt32.self, forKey: .nextPaneSeq)
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
        return Workspace(
            id: UUID(),
            name: name,
            userNamed: false,
            accentHex: accentHex,
            symbol: symbol,
            root: .leaf(first),
            panes: [first: Pane(id: first, title: "zsh", workingDirectory: nil)],
            focusedPane: first,
            nextPaneSeq: 1
        )
    }

    /// What to show as the workspace label in the sidebar. If the user has
    /// renamed it, use their name; otherwise derive a short label from the
    /// first pane's working directory.
    var displayName: String {
        if userNamed && !name.isEmpty { return name }
        let cwd = panes[focusedPane]?.workingDirectory
            ?? panes.values.compactMap(\.workingDirectory).first
        return Self.shortLabel(forCwd: cwd) ?? name
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

    /// Whether Glint's Claude Code hook script is currently registered in
    /// `~/.claude/settings.json`. Mirrors `AgentHookInstaller.isInstalled()`
    /// so the Settings UI can react without polling.
    @Published var claudeHooksInstalled: Bool = false

    /// Whether Glint's Codex hook script is registered in `~/.codex/hooks.json`.
    @Published var codexHooksInstalled: Bool = false

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

    /// Float workspaces whose agents just finished a turn (`.justCompleted`)
    /// to the top of the sidebar list. The status auto-clears when the user
    /// focuses that workspace's pane, so the card sinks back to its drag-
    /// assigned slot — i.e. this is a soft visual nudge, not a permanent
    /// reorder. Defaults to off so existing users see no change.
    @Published var sortCompletedFirst: Bool = (UserDefaults.standard.object(forKey: "glint.sortCompletedFirst") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(sortCompletedFirst, forKey: "glint.sortCompletedFirst") }
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
    private static func autoInstallAgentHooksOnFirstLaunch(socketPath: String) {
        let defaults = UserDefaults.standard
        let claudeHandled = defaults.bool(forKey: "glint.claudeHooksAutoInstalled")
        let codexHandled = defaults.bool(forKey: "glint.codexHooksAutoInstalled")

        if claudeHandled, AgentHookInstaller.isInstalled() {
            AgentHookInstaller.installIfNeeded(socketPath: socketPath)
        }
        if codexHandled, CodexHookInstaller.isInstalled() {
            CodexHookInstaller.installIfNeeded(socketPath: socketPath)
        }
        guard !claudeHandled || !codexHandled else { return }

        // Defer past launch so the alert doesn't pop before the main window.
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Show agent status in the sidebar?"
            alert.informativeText = "Glint can register a small hook with Claude Code (~/.claude/settings.json) and Codex (~/.codex/hooks.json) that reports when an agent is thinking, finished, or waiting for approval. It only sends events to Glint on this Mac. You can uninstall it anytime in Settings → Agents."
            alert.addButton(withTitle: "Install Hooks")
            alert.addButton(withTitle: "Not Now")
            let install = alert.runModal() == .alertFirstButtonReturn
            if !claudeHandled {
                if install { AgentHookInstaller.installIfNeeded(socketPath: socketPath) }
                defaults.set(true, forKey: "glint.claudeHooksAutoInstalled")
            }
            if !codexHandled {
                if install { CodexHookInstaller.installIfNeeded(socketPath: socketPath) }
                defaults.set(true, forKey: "glint.codexHooksAutoInstalled")
            }
            WorkspaceStore.current?.claudeHooksInstalled = AgentHookInstaller.isInstalled()
            WorkspaceStore.current?.codexHooksInstalled = CodexHookInstaller.isInstalled()
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
    private var observerTokens: [NSObjectProtocol] = []

    /// The app's single live store. AppDelegate consults it for the quit
    /// confirmation (it has no other path to the store — the store is
    /// created by GlintApp as a @StateObject).
    static private(set) weak var current: WorkspaceStore?

    init() {
        let loaded = Persistence.load() ?? PersistedState.fresh
        self.workspaces = loaded.workspaces
        let shouldRestore = (UserDefaults.standard.object(forKey: "glint.restoreLastWorkspace") as? Bool) ?? true
        self.selectedWorkspaceID = shouldRestore
            ? (loaded.selectedWorkspaceID ?? loaded.workspaces.first?.id)
            : loaded.workspaces.first?.id
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
            Task { @MainActor in self?.captureCwdsFromLiveSurfaces() }
        }

        // Block-based observers hold their tokens in `observerTokens`; the
        // store currently lives as long as the app, but if it's ever torn
        // down (multi-window, tests) deinit removes them cleanly.

        // Final flush + save on app terminate.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureCwdsFromLiveSurfaces()
                self?.persist()
            }
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
        let paneKey = "\(workspaceID.uuidString):\(paneID.value)"
        let v = GhosttySurfaceView(
            frame: .zero,
            initialCwd: cwd,
            paneKey: paneKey,
            agentSocketPath: AgentBridge.shared.socketPath
        )
        surfaceViews[key] = v
        return v
    }

    /// Snapshot every live surface's cwd back into the workspace model and
    /// refresh the per-pane foreground process name. Called periodically, on
    /// app exit, and whenever ghostty pushes a PWD update via its action
    /// callback.
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
                name.contains("codex") ? .codex : nil
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
        let kind: PaneAgentKind = (agentStr == "codex") ? .codex : .claude

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
            // workspace — see `acknowledgeCompletionIfNeeded(for:)`. This is
            // an unread-style badge: switching to it clears it. We only skip
            // the badge when the user is actually watching: Glint frontmost
            // AND on this workspace. If Glint is hidden behind other apps,
            // leave the badge up so they see it on return.
            if NSApp.isActive && selectedWorkspaceID == key.workspace {
                state.status = .idle
            } else {
                state.status = .justCompleted
            }
        default: break
        }
        state.updatedAt = now
        paneAgentState[key] = state

        // Audio cues fire whenever the user is NOT actively watching this
        // pane — that means either Glint isn't the frontmost app, or it is
        // but the user is on a different workspace. If Glint has focus AND
        // they're already looking at this workspace, stay quiet.
        let userIsWatching = NSApp.isActive && (selectedWorkspaceID == key.workspace)
        if !userIsWatching && oldStatus != state.status {
            switch state.status {
            case .needsPermission where soundOnPermissionRequest:
                NSSound(named: "Funk")?.play()
            case .justCompleted where soundOnTurnComplete:
                NSSound(named: "Glass")?.play()
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
        case .idle, .justCompleted:
            // justCompleted is an unread badge — only viewing the
            // workspace clears it, not a stray Esc.
            break
        }
    }

    /// Clear any `.justCompleted` panes in `workspaceID` back to `.idle`.
    /// Called whenever the user selects a workspace — that act is treated
    /// as "I saw it finished".
    func acknowledgeCompletionIfNeeded(for workspaceID: UUID) {
        for (key, state) in paneAgentState where key.workspace == workspaceID && state.status == .justCompleted {
            paneAgentState[key]?.status = .idle
            paneAgentState[key]?.updatedAt = Date()
        }
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

    private var currentIndex: Int? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspaces.firstIndex { $0.id == id }
    }

    var currentRoot: SplitNode {
        selectedWorkspace?.root ?? .leaf(PaneID(value: 0))
    }

    var currentFocusedPane: PaneID {
        selectedWorkspace?.focusedPane ?? PaneID(value: 0)
    }

    var currentPanes: [PaneID: Pane] {
        selectedWorkspace?.panes ?? [:]
    }

    var focusedPaneValue: Pane? {
        selectedWorkspace?.panes[currentFocusedPane]
    }

    // MARK: pane operations on the current workspace

    func splitFocused(_ direction: SplitDirection) {
        guard let i = currentIndex else { return }
        let new = PaneID(value: workspaces[i].nextPaneSeq)
        workspaces[i].nextPaneSeq += 1
        workspaces[i].panes[new] = Pane(id: new, title: "zsh", workingDirectory: nil)
        workspaces[i].root = Self.splitLeaf(
            workspaces[i].root,
            target: workspaces[i].focusedPane,
            direction: direction,
            newID: new
        ) ?? workspaces[i].root
        workspaces[i].focusedPane = new
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
        guard let i = currentIndex else { return }
        guard workspaces[i].panes.count > 1 else {
            // The last pane can't be closed (a workspace is never empty).
            // Beep instead of a silent no-op so ⌘W at least acknowledges
            // the keypress.
            NSSound.beep()
            return
        }
        let target = workspaces[i].focusedPane
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
        let (newRoot, survivor) = Self.removeLeaf(workspaces[i].root, target: target)
        if let newRoot { workspaces[i].root = newRoot }
        workspaces[i].panes.removeValue(forKey: target)
        surfaceViews.removeValue(forKey: key)
        // Drop the non-persistent side state too, or closed panes linger as
        // ghost entries forever.
        paneAgentState.removeValue(forKey: key)
        paneProcesses.removeValue(forKey: key)
        workspaces[i].focusedPane = survivor
            ?? workspaces[i].panes.keys.sorted { $0.value < $1.value }.first
            ?? PaneID(value: 0)
    }

    func focusNext() {
        guard let i = currentIndex else { return }
        let leaves = Self.collectLeaves(workspaces[i].root).sorted { $0.value < $1.value }
        guard !leaves.isEmpty,
              let pos = leaves.firstIndex(of: workspaces[i].focusedPane) else { return }
        workspaces[i].focusedPane = leaves[(pos + 1) % leaves.count]
    }

    func focusPrevious() {
        guard let i = currentIndex else { return }
        let leaves = Self.collectLeaves(workspaces[i].root).sorted { $0.value < $1.value }
        guard !leaves.isEmpty,
              let pos = leaves.firstIndex(of: workspaces[i].focusedPane) else { return }
        workspaces[i].focusedPane = leaves[(pos - 1 + leaves.count) % leaves.count]
    }

    func focus(_ id: PaneID) {
        guard let i = currentIndex else { return }
        workspaces[i].focusedPane = id
    }

    func selectWorkspace(_ id: UUID) {
        selectedWorkspaceID = id
        acknowledgeCompletionIfNeeded(for: id)
    }

    /// Select the nth workspace in sidebar order (0-based). Used by the
    /// ⌘1…⌘9 menu shortcuts; out-of-range indices are ignored.
    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        selectWorkspace(workspaces[index].id)
    }

    /// Set the ratio of the split addressed by `path` in the current
    /// workspace's tree. `path` is the chain of branch choices walking down
    /// from the root (false = first child, true = second child); the empty
    /// path addresses the root split. Driven by divider drags in
    /// PaneTreeView; persisted with the rest of the tree.
    func setSplitRatio(path: [Bool], ratio: CGFloat) {
        guard let i = currentIndex else { return }
        let clamped = min(max(ratio, 0.1), 0.9)
        workspaces[i].root = Self.settingRatio(workspaces[i].root, path: path[...], ratio: clamped)
    }

    /// Cycle to the next workspace in sidebar order, wrapping at the end.
    /// Used by the ⌘⇧] menu command — paired with `selectPreviousWorkspace`
    /// so keyboard-only navigation has parity with clicking the sidebar.
    func selectNextWorkspace() {
        guard let id = selectedWorkspaceID,
              let idx = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces.isEmpty else { return }
        let next = (idx + 1) % workspaces.count
        selectWorkspace(workspaces[next].id)
    }

    func selectPreviousWorkspace() {
        guard let id = selectedWorkspaceID,
              let idx = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces.isEmpty else { return }
        let prev = (idx - 1 + workspaces.count) % workspaces.count
        selectWorkspace(workspaces[prev].id)
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

    private static func collectLeaves(_ node: SplitNode) -> [PaneID] {
        switch node {
        case .leaf(let id): return [id]
        case .split(_, _, let a, let b): return collectLeaves(a) + collectLeaves(b)
        }
    }
}

// MARK: - Workspace icon kind

enum WorkspaceIconKind {
    case shell      // zsh / bash / fish / sh / login (nothing special running)
    case claude
    case codex
    case ssh
    case vim
    case python
    case node
    case git
    case other(String)

    /// SF Symbol name. Returns nil for kinds we render as a text glyph.
    var sfSymbol: String? {
        switch self {
        case .shell:  return "terminal.fill"
        case .ssh:    return "network"
        case .vim:    return "text.cursor"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node:   return "hexagon.fill"
        case .git:    return "arrow.triangle.branch"
        case .claude, .codex, .other:
            return nil
        }
    }

    /// Short text glyph used when sfSymbol is nil.
    var letter: String {
        switch self {
        case .claude: return "✦"
        case .codex:  return "λ"
        case .other(let s):
            return s.first.map { String($0).uppercased() } ?? "?"
        default:
            return ""
        }
    }
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
            if let cur = best {
                let merged = mergeStatus(cur.0, entry.status)
                // Take the timestamp from whichever side won the merge.
                best = (merged, merged == cur.0 ? cur.1 : entry.updatedAt)
            } else {
                best = (entry.status, entry.updatedAt)
            }
        }
        return best
    }

    /// Attention ranking shared by the status merge and the icon pick.
    private func statusRank(_ s: PaneAgentStatus) -> Int {
        switch s {
        case .needsPermission: return 5
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

    /// Pick the most representative icon for a workspace based on what its
    /// panes are currently running. AI / SSH / dev tools beat plain shell.
    func iconKind(for workspace: Workspace) -> WorkspaceIconKind {
        // Agent push-state wins over pid polling — if any pane reported a
        // claude/codex hook in this workspace, surface that. With several
        // agent panes (e.g. claude + codex side by side) the busy one wins;
        // when all are equally busy/idle, the most recently active wins.
        // `panes` is a Dictionary, so without this ordering the icon would
        // be hash-order roulette.
        var bestAgent: PaneAgentState?
        for paneID in workspace.panes.keys {
            let key = WorkspacePaneKey(workspace: workspace.id, pane: paneID)
            guard let entry = paneAgentState[key] else { continue }
            guard let cur = bestAgent else { bestAgent = entry; continue }
            let (curRank, newRank) = (statusRank(cur.status), statusRank(entry.status))
            if newRank > curRank || (newRank == curRank && entry.updatedAt > cur.updatedAt) {
                bestAgent = entry
            }
        }
        if let bestAgent {
            return bestAgent.kind == .codex ? .codex : .claude
        }

        let names = workspace.panes.keys.compactMap {
            paneProcesses[WorkspacePaneKey(workspace: workspace.id, pane: $0)]?.lowercased()
        }

        // Priority: ssh > AI agents > editors > runtimes > shell.
        if names.contains(where: { $0 == "ssh" || $0 == "mosh" }) { return .ssh }
        if names.contains(where: { $0.contains("claude") })        { return .claude }
        if names.contains(where: { $0 == "codex" || $0.contains("codex") }) { return .codex }
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
