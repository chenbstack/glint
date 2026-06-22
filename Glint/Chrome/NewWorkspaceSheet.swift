import SwiftUI
import AppKit

// New Worktree sheet — a single-purpose window (hosted in the main window like
// Settings, not a separate scene) that cuts an isolated branch + worktree off an
// existing repo. Plain / local-repo workspaces are created elsewhere (the "+"
// button / ⌘N / the agent chooser); this window does worktrees only.
// All git work goes through `store.git` (Plan B: out-of-band subprocess).

struct NewWorkspaceSheet: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        WorktreePane()
            .frame(width: 520, height: 540)
            .background(Theme.bgPane)
            .preferredColorScheme(.dark)
            .closeOnCmdW()
    }
}

// MARK: - Worktree pane (the only flow)

private struct WorktreePane: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var codexHomes: CodexHomeStore

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
    @State private var carryDirty = false   // bring base's uncommitted changes along
    @State private var agentID: String = AgentChoice.claude.id
    @State private var creating = false
    @State private var errorText: String?
    @State private var showAdvanced = false
    @FocusState private var branchFocused: Bool

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
                    branchField
                    agentChips
                    advancedSection
                    if baseDirty > 0 {
                        dirtyChoice
                    }
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
        .onAppear {
            initialDetect()
            // Land the cursor in "New branch" — the one field the user always
            // fills in (repo + base + path auto-derive). Deferred so it wins
            // over the sheet's default first-responder assignment.
            DispatchQueue.main.async { branchFocused = true }
        }
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

    // Typed as LocalizedStringKey so the literals localize: a `Text(cond ? "a" :
    // "b")` ternary infers `String` and hits the verbatim overload, silently
    // skipping the catalog even though both keys are translated.
    private var carrySubtitle: LocalizedStringKey {
        carryDirty ? "Copied in; your original checkout keeps them too."
                   : "Left in your original checkout; the worktree starts clean at base's HEAD."
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
            PlainField(text: $branch, mono: true, placeholder: "you/feature",
                       focus: $branchFocused)
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
        AgentChips(items: AgentLaunchItem.all(codexHomes: codexHomes.homes),
                   selection: $agentID, accent: store.accent)
    }

    /// Base has uncommitted work — hand the call to the user instead of silently
    /// leaving it behind. Off (default) keeps the old behavior: the worktree
    /// starts clean at base's HEAD. On copies the changes in (originals stay).
    private var dirtyChoice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bring these changes into the new worktree")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text1)
                Text(verbatim: String(localized: "Uncommitted changes in base: \(baseDirty)."))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                Text(carrySubtitle)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $carryDirty)
                .toggleStyle(.switch).labelsHidden()
                .tint(store.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.orange.opacity(0.22), lineWidth: 1))
    }

    /// Base branch + worktree location — both auto-derived (base = repo's
    /// current branch, path = ~/glint/worktrees/<repo>/<branch>), so they're
    /// tucked behind a disclosure to keep the default flow to repo + branch +
    /// agent. Expand only to override.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("Advanced")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Theme.text3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAdvanced {
                LabeledField(label: "Start from (base)", text: $baseBranch, mono: true,
                             placeholder: "main")
                pathField
            }
        }
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
        let items = AgentLaunchItem.all(codexHomes: codexHomes.homes)
        let cmd = (items.first { $0.id == agentID } ?? items.first)?.command
        let carry = carryDirty
        Task {
            do {
                try await store.createWorktreeWorkspace(
                    repoRoot: root, baseBranch: base, branch: b,
                    worktreePath: path, createBranch: true,
                    carryUncommitted: carry, agentCommand: cmd)
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

/// Flat dark text field (no system rounded-border chrome, no blue focus
/// ring) shared by the New Workspace sheet and the Settings panes.
struct PlainField: View {
    @Binding var text: String
    var mono = false
    var placeholder: LocalizedStringKey = ""
    /// Optional external focus binding so a parent can drive the cursor here.
    var focus: FocusState<Bool>.Binding? = nil
    var body: some View {
        let field = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.overlay(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        if let focus {
            field.focused(focus)
        } else {
            field
        }
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

/// "Open with" row of agent chips — picks which agent (if any) the new
/// worktree's pane starts running. Codex fans out into one chip per enabled
/// Codex Home (see `AgentLaunchItem`), so the chips wrap onto multiple lines.
private struct AgentChips: View {
    let items: [AgentLaunchItem]
    @Binding var selection: String   // AgentLaunchItem.id
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Open with")
            FlowLayout(spacing: 7, lineSpacing: 7) {
                ForEach(items) { item in
                    let on = item.id == selection
                    Button { selection = item.id } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: item.title)
                                .foregroundStyle(on ? Theme.text1 : Theme.text2)
                            if let tag = item.tag {
                                Text(verbatim: tag).foregroundStyle(Theme.text4)
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(on ? accent.opacity(0.18) : Theme.overlay(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(on ? accent.opacity(0.4) : Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Minimal wrapping row layout — lays subviews left-to-right, wrapping to a new
/// line when the next would overflow the proposed width. Used by `AgentChips`
/// so a growing list of Codex Homes flows onto multiple lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > bounds.width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                    anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
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
