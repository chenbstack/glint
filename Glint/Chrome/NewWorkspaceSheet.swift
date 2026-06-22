import SwiftUI
import AppKit

// New Workspace sheet — source picker hosted in the main window (like Settings),
// not a separate scene, so it inherits workspace context. Plain stays one-click
// (default tab, ⏎ creates); worktree/repo only show their machinery when chosen.
// All git work goes through `store.git` (Plan B: out-of-band subprocess).

struct NewWorkspaceSheet: View {
    @EnvironmentObject var store: WorkspaceStore

    enum SourceTab: String, CaseIterable, Identifiable {
        case plain, repo, worktree, ssh
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .plain: return "Plain Terminal"
            case .repo: return "Local Repo"
            case .worktree: return "Local Worktree"
            case .ssh: return "SSH Project"
            }
        }
        var sub: LocalizedStringKey {
            switch self {
            case .plain: return "Fastest · no repo"
            case .repo: return "Open a checkout"
            case .worktree: return "Isolated branch"
            case .ssh: return "Phase 2"
            }
        }
        var icon: String {
            switch self {
            case .plain: return "terminal"
            case .repo: return "arrow.triangle.branch"
            case .worktree: return "square.on.square.dashed"
            case .ssh: return "network"
            }
        }
    }

    @State private var selected: SourceTab = .plain

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(navBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.overlay(0.045)).frame(width: 1)
                }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.bgPane)
        }
        .frame(width: 760, height: 540)
        .background(Theme.bgWindow)
        .preferredColorScheme(.dark)
        .onAppear {
            // Clamp to an ENABLED tab: an unknown rawValue OR the disabled `.ssh`
            // (Phase 2) would otherwise land on a blank EmptyView with no nav out.
            let t = SourceTab(rawValue: store.newWorkspaceSheetTab) ?? .plain
            selected = (t == .ssh) ? .plain : t
        }
    }

    @ViewBuilder private var navBackground: some View {
        if store.glassEffect {
            ZStack {
                VisualEffectBackground(material: .sidebar)
                LinearGradient(colors: [Theme.sidebarTintTop, Theme.sidebarTintBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            Color(red: 0.094, green: 0.094, blue: 0.122)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { GlintBrandMark(); Spacer() }
                .padding(.horizontal, 14).padding(.top, 20).padding(.bottom, 4)
            Text("New Workspace")
                .font(.system(size: 11, weight: .semibold)).kerning(1.0)
                .foregroundStyle(Theme.text4)
                .padding(.horizontal, 14).padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SourceTab.allCases) { tab in
                    NavRow(tab: tab, isSelected: tab == selected,
                           disabled: tab == .ssh, accent: store.accent) {
                        if tab != .ssh { selected = tab }
                    }
                }
            }
            .padding(.horizontal, 8)
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        switch selected {
        case .plain:    PlainPane()
        case .repo:     RepoPane()
        case .worktree: WorktreePane()
        case .ssh:      EmptyView()
        }
    }

    // MARK: nav row

    private struct NavRow: View {
        let tab: SourceTab
        let isSelected: Bool
        let disabled: Bool
        let accent: Color
        let onTap: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.22) : Theme.overlay(0.05))
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? accent : Theme.text3)
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.text1 : Theme.text2)
                        Text(tab.sub)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.text4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.overlay(0.08) : (hover ? Theme.overlay(0.03) : .clear)))
                .contentShape(Rectangle())
                .opacity(disabled ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

// MARK: - Plain pane

private struct PlainPane: View {
    @EnvironmentObject var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Plain Terminal",
                        subtitle: "Keep Glint's speed — no repo, no branch, just a shell.")
            VStack(alignment: .leading, spacing: 14) {
                Callout(icon: "bolt.fill", tint: Theme.cyan,
                        "Need parallel agents that don't touch your checkout? Use Local Worktree instead.")
                Spacer()
            }
            .padding(20)
            SheetFooter(note: "No repo binding. Fastest path.",
                        primary: "Create Workspace", primaryEnabled: true, busy: false) {
                store.addWorkspace()
                store.newWorkspaceSheetOpen = false
            }
        }
    }
}

// MARK: - Local repo pane

private struct RepoPane: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var repo = ""
    @State private var repoRoot: String?       // confirmed top-level, or nil
    @State private var detecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Local Repo",
                        subtitle: "Open a workspace on an existing checkout (not isolated).")
            VStack(alignment: .leading, spacing: 14) {
                repoField
                Callout(icon: "arrow.triangle.branch", tint: Theme.accentBright,
                        "Opens directly on the current checkout. For isolation across parallel agents, choose Local Worktree.")
                Spacer()
            }
            .padding(20)
            // Gate Open on a CONFIRMED repo (mirrors the Worktree pane): a non-git
            // path would otherwise silently open as a plain shell with no feedback.
            SheetFooter(note: repoRoot == nil ? "Pick a git repository to continue."
                                              : "Uses the existing checkout in place.",
                        primary: "Open Workspace",
                        primaryEnabled: repoRoot != nil,
                        busy: false) {
                store.openDirectoryWorkspace(repoRoot ?? repo)
                store.newWorkspaceSheetOpen = false
            }
            .onAppear {
                if repo.isEmpty { repo = store.currentRepoGuess() ?? "" }
                if !repo.isEmpty { detect() }
            }
        }
    }

    private var repoField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldLabel("Repository")
                Spacer()
                if detecting {
                    ProgressView().controlSize(.mini)
                } else if repoRoot != nil {
                    Label("repo detected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.green)
                } else if !repo.isEmpty {
                    Label("not a git repo", systemImage: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.pink)
                }
            }
            HStack(spacing: 8) {
                PlainField(text: $repo, mono: true, placeholder: "/path/to/repo")
                    .onSubmit(detect)
                    // Editing invalidates the previous detection (no per-keystroke
                    // subprocess); the user re-confirms with ⏎ or Browse.
                    .onChange(of: repo) { repoRoot = nil }
                Button("Browse…") { browse() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.overlay(0.06)))
            }
        }
    }

    private func detect() {
        let target = (repo as NSString).expandingTildeInPath
        guard !target.isEmpty else { repoRoot = nil; return }
        detecting = true
        Task {
            let root = await store.git.repoRoot(at: target)
            await MainActor.run { repoRoot = root; detecting = false }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { repo = url.path; detect() }
    }
}

// MARK: - Worktree pane (the main flow)

private struct WorktreePane: View {
    @EnvironmentObject var store: WorkspaceStore

    @State private var repo = ""
    @State private var repoRoot: String?
    @State private var detecting = false
    @State private var baseBranch = "main"
    @State private var branch = ""
    @State private var worktreePath = ""
    @State private var pathEdited = false
    @State private var branchAvailable: Bool? = nil   // nil = unknown / pending / empty
    @State private var branchInvalid = false          // syntactically illegal git ref name
    @State private var baseDirty = 0
    @State private var agent: AgentChoice = .claude
    @State private var creating = false
    @State private var errorText: String?

    enum AgentChoice: String, CaseIterable, Identifiable {
        case claude = "Claude Code", codex = "Codex", opencode = "OpenCode", devin = "Devin", shell = "Shell only"
        /// Chip / preview label. Product names stay verbatim; only "Shell only"
        /// is UI copy, so it (and only it) is routed through the string catalog.
        /// `rawValue` is a String, so `Text(choice.rawValue)` would hit the
        /// verbatim overload and never localize — read this instead.
        var displayName: String { self == .shell ? String(localized: "Shell only") : rawValue }
        var id: String { rawValue }
        var command: String? {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .opencode: return "opencode"
            case .devin: return "devin"
            case .shell: return nil
            }
        }
    }

    private var canCreate: Bool {
        repoRoot != nil
            && !branch.trimmingCharacters(in: .whitespaces).isEmpty
            && !worktreePath.trimmingCharacters(in: .whitespaces).isEmpty
            && branchAvailable == true   // nil while the async check is pending → disabled
            && !creating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "New Local Worktree",
                        subtitle: "Cut an isolated branch + worktree off an existing repo. Your original checkout is untouched.")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    repoField
                    HStack(alignment: .top, spacing: 12) {
                        LabeledField(label: "Start from (base)", text: $baseBranch, mono: true,
                                     placeholder: "main")
                        branchField
                    }
                    pathField
                    agentChips
                    if baseDirty > 0 {
                        Callout(icon: "exclamationmark.triangle.fill", tint: Theme.orange,
                                verbatim: String(localized: "Uncommitted changes in base: \(baseDirty). The worktree is cut from the base's HEAD — those changes stay in your original checkout and won't carry over."))
                    }
                    summary
                    if let errorText {
                        Callout(icon: "xmark.octagon.fill", tint: Theme.pink, verbatim: errorText)
                    }
                }
                .padding(20)
            }
            SheetFooter(note: footNote,
                        primary: creating ? "Creating…" : "Create Worktree",
                        primaryEnabled: canCreate, busy: creating,
                        disabledHint: createHint, action: create)
        }
        .onAppear(perform: initialDetect)
    }

    // Why the Create button is disabled — surfaced as its tooltip so a greyed
    // button isn't a dead end. Ordered by what the user fills in top-to-bottom.
    private var createHint: LocalizedStringKey {
        if repoRoot == nil { return "Pick a git repository first." }
        if branch.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name for the new branch." }
        if branchInvalid { return "That branch name isn’t a valid git ref." }
        if branchAvailable == false { return "That branch already exists — choose another name." }
        if branchAvailable == nil { return "Checking the branch name…" }
        return ""
    }

    private var footNote: LocalizedStringKey {
        repoRoot == nil ? "Pick a git repository to continue."
                        : "Creates branch + worktree; original checkout stays put."
    }

    private var repoField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldLabel("Repository")
                Spacer()
                if detecting {
                    ProgressView().controlSize(.mini)
                } else if repoRoot != nil {
                    Label("repo detected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.green)
                } else if !repo.isEmpty {
                    Label("not a git repo", systemImage: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.pink)
                }
            }
            HStack(spacing: 8) {
                PlainField(text: $repo, mono: true, placeholder: "/path/to/repo")
                    .onSubmit(detect)
                Button("Browse…") { browse() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.overlay(0.06)))
            }
        }
    }

    private var branchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldLabel("New branch")
                Spacer()
                if !branch.isEmpty {
                    if branchInvalid {
                        Text("✗ invalid name")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.pink)
                    } else if let ok = branchAvailable {
                        Text(ok ? "✓ available" : "✗ exists")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ok ? Theme.green : Theme.pink)
                    }
                }
            }
            PlainField(text: $branch, mono: true, placeholder: "you/feature")
                .onChange(of: branch) { _ in branchChanged() }
        }
    }

    private var pathField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Worktree location")
            PlainField(text: $worktreePath, mono: true, placeholder: "~/glint/worktrees/…")
                .onChange(of: worktreePath) { _ in pathEdited = true }
            Text("Default: ~/glint/worktrees/<repo>/<branch-slug> — discoverable in Finder.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text4)
        }
    }

    private var agentChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Open with")
            HStack(spacing: 7) {
                ForEach(AgentChoice.allCases) { choice in
                    let on = choice == agent
                    Button { agent = choice } label: {
                        Text(verbatim: choice.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(on ? Theme.text1 : Theme.text2)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(on ? store.accent.opacity(0.18) : Theme.overlay(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(on ? store.accent.opacity(0.4) : Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            summaryRow("Path", worktreePath.isEmpty ? "—" : worktreePath)
            summaryRow("Command", commandPreview)
            summaryRow("Card", cardPreview)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(store.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(store.accent.opacity(0.22), lineWidth: 1))
    }

    private func summaryRow(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).textCase(.uppercase).font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.text4).frame(width: 64, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text1).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandPreview: String {
        let b = branch.isEmpty ? "<branch>" : branch
        let p = worktreePath.isEmpty ? "<path>" : worktreePath
        return "git worktree add -b \(b) \(p) \(baseBranch)"
    }
    private var cardPreview: String {
        let repoName = repoRoot.map { ($0 as NSString).lastPathComponent } ?? "repo"
        let leaf = branch.split(separator: "/").last.map(String.init) ?? "branch"
        return "\(repoName) · \(leaf) · WT · \(agent.displayName)"
    }

    // MARK: actions

    private func initialDetect() {
        if repo.isEmpty { repo = store.newWorkspaceRepoHint ?? store.currentRepoGuess() ?? "" }
        if !repo.isEmpty { detect() }
    }

    private func detect() {
        let target = (repo as NSString).expandingTildeInPath
        guard !target.isEmpty else { repoRoot = nil; return }
        detecting = true
        Task {
            let root = await store.git.repoRoot(at: target)
            await MainActor.run { repoRoot = root; detecting = false }
            if let root {
                let cur = await store.git.currentBranch(at: root)
                let st = try? await store.git.status(at: root)
                await MainActor.run {
                    if let cur { baseBranch = cur }
                    baseDirty = st?.dirtyCount ?? 0
                    if !pathEdited { recomputePath() }
                    branchChanged()
                }
            }
        }
    }

    private func branchChanged() {
        if !pathEdited { recomputePath() }
        let name = branch.trimmingCharacters(in: .whitespaces)
        // Reset to "pending" so Create is disabled until the async check resolves
        // — otherwise pressing ⏎ right after typing fires against the previous
        // name's stale availability.
        branchAvailable = nil
        branchInvalid = false
        guard !name.isEmpty, let root = repoRoot else { return }
        Task {
            let valid = await store.git.isValidBranchName(name, repo: root)
            var exists = false
            if valid { exists = await store.git.localBranchExists(repo: root, name: name) }
            await MainActor.run {
                // Ignore a result that arrived after the field changed again.
                guard branch.trimmingCharacters(in: .whitespaces) == name else { return }
                branchInvalid = !valid
                branchAvailable = valid && !exists
            }
        }
    }

    private func recomputePath() {
        guard let root = repoRoot else { return }
        worktreePath = GitService.suggestedWorktreePath(repoRoot: root, branch: branch)
        pathEdited = false   // recompute doesn't count as a manual edit
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            repo = url.path
            detect()
        }
    }

    private func create() {
        guard let root = repoRoot, canCreate else { return }
        creating = true; errorText = nil
        let b = branch.trimmingCharacters(in: .whitespaces)
        let path = worktreePath
        let base = baseBranch
        let cmd = agent.command
        Task {
            do {
                try await store.createWorktreeWorkspace(
                    repoRoot: root, baseBranch: base, branch: b,
                    worktreePath: path, createBranch: true, agentCommand: cmd)
                await MainActor.run { creating = false; store.newWorkspaceSheetOpen = false }
            } catch {
                await MainActor.run { creating = false; errorText = error.localizedDescription }
            }
        }
    }
}

// MARK: - Shared sheet chrome

private struct SheetHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text1)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct SheetFooter: View {
    @EnvironmentObject var store: WorkspaceStore
    let note: LocalizedStringKey
    let primary: LocalizedStringKey
    let primaryEnabled: Bool
    let busy: Bool
    /// Shown as a tooltip on the (disabled) primary button explaining what's
    /// missing. Ignored while the button is enabled.
    var disabledHint: LocalizedStringKey? = nil
    let action: () -> Void
    var body: some View {
        HStack {
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.text4)
            Spacer()
            Button("Cancel") { store.newWorkspaceSheetOpen = false }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.overlay(0.06)))
            Button(action: action) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(primary)
                }
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(store.accent))
                .opacity(primaryEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .keyboardShortcut(.return, modifiers: [])
            // Tooltip only while disabled — explains what's still missing.
            .help(primaryEnabled ? "" : (disabledHint ?? ""))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct FieldLabel: View {
    let text: LocalizedStringKey
    init(_ t: LocalizedStringKey) { text = t }
    var body: some View {
        Text(text).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .foregroundStyle(Theme.text4)
    }
}

private struct PlainField: View {
    @Binding var text: String
    var mono = false
    var placeholder: LocalizedStringKey = ""
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.overlay(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

private struct LabeledField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var mono = false
    var placeholder: LocalizedStringKey = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            PlainField(text: $text, mono: mono, placeholder: placeholder)
        }
    }
}

private struct Callout: View {
    let icon: String
    let tint: Color
    let content: Text
    /// Static message — goes through the string catalog.
    init(icon: String, tint: Color, _ message: LocalizedStringKey) {
        self.icon = icon; self.tint = tint; self.content = Text(message)
    }
    /// Runtime text (a git error, a pre-localized count sentence) — shown
    /// verbatim; it's data, not a translatable literal.
    init(icon: String, tint: Color, verbatim: String) {
        self.icon = icon; self.tint = tint; self.content = Text(verbatim)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            content.font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.22), lineWidth: 1))
    }
}
