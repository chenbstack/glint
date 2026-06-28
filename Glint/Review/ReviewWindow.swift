import SwiftUI
import AppKit
import Combine

// Read-only Review window: a self-managed NSWindow (Glint is a single-WindowGroup
// app whose main window AppDelegate takes over, so a second editor window can't
// live in the WindowGroup) hosting a SwiftUI view. Left = changed-file list,
// right = unified diff with line-number gutter. Scope is switchable in-window
// between the working tree (vs HEAD, incl. untracked) and — for worktrees — the
// whole branch vs its base.

@MainActor
final class ReviewModel: ObservableObject {
    let repo: String
    let title: String
    /// Root-relative path to scope the file list to (current-directory review),
    /// or nil for the whole repo. See `reload`'s prefix filter.
    let subdir: String?
    let availableScopes: [DiffScope]

    @Published var scope: DiffScope { didSet { Task { await reload() } } }
    // Whitespace-only changes treated as non-changes (--ignore-all-space). A
    // load-time flag (changes what git returns), so toggling it re-fetches the
    // current file's diff rather than filtering at render time.
    @Published var ignoreWhitespace: Bool = false {
        didSet {
            guard oldValue != ignoreWhitespace, let s = selected else { return }
            Task { await select(s) }
        }
    }
    @Published var files: [GitFileChange] = []
    // Tree forest + dir-grouped list, rebuilt ONCE when `files` changes (in
    // reload). FileListView reads these instead of rebuilding/sorting on every
    // body evaluation (selection, collapse toggle, hover) — which on a large
    // diff was an O(n log n) tree build per render on the main actor.
    @Published private(set) var tree: [TreeNode] = []
    @Published private(set) var combined: [CombinedGroup] = []
    @Published var selected: GitFileChange?
    @Published var diffText: String = ""
    @Published var diff: DiffDocument = .empty   // parsed once per file, off-main
    @Published var loadingFiles = false
    @Published var loadingDiff = false

    private let git: GitService
    private var fileLoadToken = 0   // guards against out-of-order file-list loads
    private var diffLoadToken = 0   // guards against out-of-order diff loads

    init(repo: String, title: String, subdir: String? = nil, scopes: [DiffScope],
         runner: GitRunner = LocalGitRunner()) {
        self.repo = repo
        self.title = title
        self.subdir = subdir
        self.availableScopes = scopes.isEmpty ? [.workingTree] : scopes
        self.scope = scopes.first ?? .workingTree
        self.git = GitService(runner: runner)
    }

    func reload() async {
        // Guard against overlapping reloads (rapid scope toggles): a slower,
        // older fetch must not clobber the newer scope's file list.
        fileLoadToken += 1
        let token = fileLoadToken
        loadingFiles = true
        var fs = await git.changedFiles(repo: repo, scope: scope)
        guard token == fileLoadToken else { return }
        // Scope the file list to the focused pane's subtree when reviewing a
        // subdirectory. Git reports root-relative paths, so a prefix filter
        // (exact match for the dir itself, or "<subdir>/" for contents) is
        // exact and covers tracked + untracked alike. Applied before tree/
        // combined are built so all three list modes stay consistent. fileDiff
        // is unaffected — it still runs root-relative paths from `repo` (the
        // toplevel), which is what makes every diff resolve correctly.
        if let sub = subdir {
            fs = fs.filter { $0.path == sub || $0.path.hasPrefix(sub + "/") }
        }
        loadingFiles = false
        files = fs
        tree = TreeNode.build(fs)
        combined = Self.groupByDir(fs)
        // Keep the current file selected if it still exists, else fall back to
        // the first change so the diff pane is never blank when there's content.
        if let sel = selected, let still = fs.first(where: { $0.path == sel.path }) {
            await select(still)
        } else if let first = fs.first {
            await select(first)
        } else {
            selected = nil
            diffText = ""
            diff = .empty
            loadingDiff = false
        }
    }

    /// Files grouped by full parent directory, each group + the groups sorted —
    /// computed once per file-set change for the Combined list mode.
    static func groupByDir(_ files: [GitFileChange]) -> [CombinedGroup] {
        var map: [String: [GitFileChange]] = [:]
        for f in files {
            map[(f.path as NSString).deletingLastPathComponent, default: []].append(f)
        }
        return map
            .map { CombinedGroup(dir: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { l, r in
                if l.dir.isEmpty != r.dir.isEmpty { return l.dir.isEmpty }   // root files first
                return l.dir.localizedCaseInsensitiveCompare(r.dir) == .orderedAscending
            }
    }

    func select(_ f: GitFileChange) async {
        selected = f
        diffLoadToken += 1
        let token = diffLoadToken
        loadingDiff = true
        diffText = ""
        diff = .empty
        let text = await git.fileDiff(repo: repo, scope: scope, file: f, ignoreWhitespace: ignoreWhitespace)
        // A newer selection (or scope change) superseded this load — drop it.
        guard token == diffLoadToken else { return }
        // Parse off the main actor so a multi-thousand-line diff doesn't hitch
        // the UI; the result is cached so re-renders (splitter drags) don't reparse.
        let language = SyntaxLanguage.from(path: f.path)
        let doc = await Task.detached(priority: .userInitiated) {
            DiffDocument(text: text, language: language)
        }.value
        guard token == diffLoadToken else { return }
        diffText = text
        diff = doc
        loadingDiff = false
    }
}

// MARK: - Root view

// Settings-style chrome: a frosted-glass sidebar (file list) beside a solid
// bgPane content area (diff), inside a borderless dark window.
struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    // Observe the store so a theme switch (themeRevision bump) re-runs body —
    // that re-evaluates `.preferredColorScheme(Theme.colorScheme)` below, which
    // is what lets adaptive colors (Color.secondary) and Theme colors update
    // live instead of being frozen at open time.
    @EnvironmentObject var store: WorkspaceStore
    // Manual split: HSplitView ignores idealWidth and lands on a 50/50 default.
    // A self-managed divider gives a narrow persisted default that drags freely
    // up to 60% of the window.
    @AppStorage("glint.review.sidebarWidth") private var sidebarWidth: Double = 310
    // While dragging, the width lives here (pure in-memory @State). Writing
    // @AppStorage every frame syncs UserDefaults synchronously and re-evaluates
    // the whole GeometryReader → visible flicker. We commit to disk on release.
    @State private var liveWidth: Double?
    @State private var dragBase: Double?

    private static let minSidebar: Double = 160

    var body: some View {
        GeometryReader { geo in
            let maxSidebar = max(Self.minSidebar, Double(geo.size.width) * 0.6)
            let w = min(max(liveWidth ?? sidebarWidth, Self.minSidebar), maxSidebar)
            HStack(spacing: 0) {
                FileListView(model: model)
                    .frame(width: w)
                divider(maxSidebar: maxSidebar)
                DiffPaneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .background(Theme.bgWindow)
        .preferredColorScheme(Theme.colorScheme)
        .task { await model.reload() }
    }

    private func divider(maxSidebar: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(Rectangle().fill(Theme.overlay(0.045)).frame(width: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        // translation is cumulative from gesture start, so the
                        // base must stay fixed for the whole drag.
                        let base = dragBase ?? sidebarWidth
                        if dragBase == nil { dragBase = base }
                        liveWidth = min(max(Self.minSidebar, base + v.translation.width), maxSidebar)
                    }
                    .onEnded { _ in
                        if let lw = liveWidth { sidebarWidth = lw }
                        liveWidth = nil
                        dragBase = nil
                    }
            )
    }
}

// MARK: - File list

enum FileListMode: String { case tree, list, combined }

// Diff pane render mode: single unified column (default) or two-column split.
enum DiffMode: String { case unified, split }

private struct FileListView: View {
    @ObservedObject var model: ReviewModel
    @AppStorage("glint.review.fileListMode") private var modeRaw = FileListMode.tree.rawValue
    @AppStorage("glint.glassEffect") private var glass = true
    @State private var collapsed: Set<String> = []   // collapsed folder paths

    private var mode: FileListMode { FileListMode(rawValue: modeRaw) ?? .tree }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Rectangle().fill(Theme.overlay(0.05)).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.files.isEmpty && !model.loadingFiles {
                        Text("No changes")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    switch mode {
                    case .list:
                        ForEach(model.files) { f in fileRow(f, indent: 0, showDir: true) }
                    case .tree:
                        ForEach(visibleTreeRows) { r in treeRow(r) }
                    case .combined:
                        ForEach(model.combined) { g in combinedGroup(g) }
                    }
                }
                .padding(8)
            }
        }
        .background(sidebarBackground)
    }

    // Title / scope / counts at the sidebar top, under the traffic lights
    // (window is borderless + fullSizeContent), mirroring the Settings sidebar.
    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.cyan)
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                layoutMenu
            }

            if model.availableScopes.count > 1 {
                Picker("", selection: $model.scope) {
                    ForEach(model.availableScopes, id: \.self) { s in
                        Text(scopeLabel(s)).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text(fileCountText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text4)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Button { Task { await model.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help(Text("Refresh"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)        // clear the traffic lights now content fills under the titlebar
        .padding(.bottom, 11)
    }

    private var layoutMenu: some View {
        Menu {
            Button { modeRaw = FileListMode.tree.rawValue } label: {
                Label("View as Tree", systemImage: mode == .tree ? "checkmark" : "list.bullet.indent")
            }
            Button { modeRaw = FileListMode.list.rawValue } label: {
                Label("View as List", systemImage: mode == .list ? "checkmark" : "list.dash")
            }
            Button { modeRaw = FileListMode.combined.rawValue } label: {
                Label("View as Combined List", systemImage: mode == .combined ? "checkmark" : "rectangle.grid.1x2")
            }
        } label: {
            Image(systemName: mode == .tree ? "list.bullet.indent" : "list.dash")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Change file list layout"))
    }

    private var fileCountText: String {
        switch model.files.count {
        case 0:  return String(localized: "No changes")
        case 1:  return String(localized: "1 file")
        default: return String(localized: "\(model.files.count) files")
        }
    }

    private func scopeLabel(_ s: DiffScope) -> String {
        switch s {
        case .workingTree:      return String(localized: "Uncommitted")
        case .branch(let base): return String(localized: "Branch vs \(base)")
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if glass {
            ZStack {
                VisualEffectBackground(material: .sidebar)
                LinearGradient(colors: [Theme.sidebarTintTop, Theme.sidebarTintBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            Color(red: 0.094, green: 0.094, blue: 0.122)
        }
    }

    // MARK: tree

    // Cheap per-render flatten of the model's prebuilt tree against the current
    // collapse set — the expensive build/sort happened once in reload().
    private var visibleTreeRows: [TreeRow] {
        var rows: [TreeRow] = []
        flatten(model.tree, depth: 0, into: &rows)
        return rows
    }

    private func flatten(_ nodes: [TreeNode], depth: Int, into rows: inout [TreeRow]) {
        for n in nodes {
            rows.append(TreeRow(node: n, depth: depth))
            if n.isDir, !collapsed.contains(n.path) {
                flatten(n.children, depth: depth + 1, into: &rows)
            }
        }
    }

    @ViewBuilder
    private func treeRow(_ r: TreeRow) -> some View {
        if r.node.isDir {
            folderRow(r.node, depth: r.depth)
        } else if let f = r.node.file {
            fileRow(f, indent: CGFloat(r.depth) * 15, showDir: false)
        }
    }

    private func folderRow(_ node: TreeNode, depth: Int) -> some View {
        dirHeader(label: node.name, collapseKey: node.path, depth: depth)
    }

    // MARK: combined list (files grouped by full parent directory)

    @ViewBuilder
    private func combinedGroup(_ g: CombinedGroup) -> some View {
        let key = "combined:" + g.dir
        let hasHeader = !g.dir.isEmpty
        if hasHeader { dirHeader(label: g.dir, collapseKey: key, depth: 0) }
        if !hasHeader || !collapsed.contains(key) {
            ForEach(g.files) { f in fileRow(f, indent: hasHeader ? 15 : 0, showDir: false) }
        }
    }

    // Shared collapsible directory header (tree folder + combined-list group).
    // `label` is a path / component — data, so it stays a verbatim String.
    private func dirHeader(label: String, collapseKey: String, depth: Int) -> some View {
        let isCollapsed = collapsed.contains(collapseKey)
        return Button {
            if isCollapsed { collapsed.remove(collapseKey) } else { collapsed.insert(collapseKey) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.text4)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 15 + 8).padding(.trailing, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: shared file cell

    private func fileRow(_ file: GitFileChange, indent: CGFloat, showDir: Bool) -> some View {
        let selected = model.selected?.path == file.path
        return Button {
            Task { await model.select(file) }
        } label: {
            HStack(spacing: 9) {
                Text(Self.kindBadge(file.kind))
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Self.kindColor(file.kind))
                    .frame(width: 17, height: 17)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Self.kindColor(file.kind).opacity(0.16)))

                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1).truncationMode(.middle)
                    if showDir, let dir = dirName(file.path) {
                        Text(dir)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.text4)
                            .lineLimit(1).truncationMode(.head)
                    }
                }

                Spacer(minLength: 6)

                if file.isBinary {
                    Text("bin").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.text4)
                } else {
                    HStack(spacing: 5) {
                        if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(Theme.green) }
                        if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(Theme.pink) }
                    }
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
            }
            .padding(.leading, indent + 9).padding(.trailing, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.cyan.opacity(0.13) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.cyan.opacity(0.30) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dirName(_ path: String) -> String? {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? nil : d
    }

    static func kindBadge(_ k: GitFileChange.Kind) -> String {
        switch k {
        case .added:     return "A"
        case .modified:  return "M"
        case .deleted:   return "D"
        case .untracked: return "U"
        case .renamed:   return "R"
        }
    }
    static func kindColor(_ k: GitFileChange.Kind) -> Color {
        switch k {
        case .added, .untracked: return Theme.green
        case .deleted:           return Theme.pink
        case .renamed:           return Theme.cyan
        case .modified:          return Theme.orange
        }
    }
}

// MARK: - Tree model

private struct TreeRow: Identifiable {
    let node: TreeNode
    let depth: Int
    var id: String { (node.isDir ? "d:" : "f:") + node.path }
}

struct CombinedGroup: Identifiable {
    let dir: String
    let files: [GitFileChange]
    var id: String { dir }
}

final class TreeNode {
    let name: String
    let path: String
    let isDir: Bool
    var file: GitFileChange?
    var children: [TreeNode] = []

    init(name: String, path: String, isDir: Bool, file: GitFileChange? = nil) {
        self.name = name; self.path = path; self.isDir = isDir; self.file = file
    }

    /// Build a directory tree from flat file paths; folders first, then files,
    /// each level sorted case-insensitively.
    static func build(_ files: [GitFileChange]) -> [TreeNode] {
        let root = TreeNode(name: "", path: "", isDir: true)
        // Index each node by its accumulated path so revisiting a directory (the
        // common case — many files share a parent) is an O(1) lookup instead of a
        // linear scan over siblings. Without this, a single flat directory with N
        // files made build O(N²); this runs on the main actor inside reload(), so
        // a large-diff repo would hitch. A path in git diff output is unambiguously
        // a file (a reported change) or a directory (an implied parent) — never
        // both — so keying by path alone is an exact match for the old
        // `name == c && isDir == !isLeaf` test.
        var byPath: [String: TreeNode] = [:]
        for f in files {
            let comps = f.path.split(separator: "/").map(String.init)
            guard !comps.isEmpty else { continue }
            var cur = root
            var acc = ""
            for (i, c) in comps.enumerated() {
                acc = acc.isEmpty ? c : acc + "/" + c
                if let existing = byPath[acc] {
                    cur = existing
                } else {
                    let isLeaf = i == comps.count - 1
                    let node = TreeNode(name: c, path: acc, isDir: !isLeaf, file: isLeaf ? f : nil)
                    byPath[acc] = node
                    cur.children.append(node)
                    cur = node
                }
            }
        }
        sort(root)
        return root.children
    }

    private static func sort(_ node: TreeNode) {
        node.children.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }     // folders first
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        for c in node.children where c.isDir { sort(c) }
    }
}

// MARK: - Diff pane

// Plain icon button for the diff header and nav cluster — just a Theme.text3
// glyph (same color as the main toolbar's settings gear), no hover well.
private struct HeaderIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var size: CGFloat = 12.5
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .help(help)
    }
}

/// One radio item for `RadioHeaderMenu`.
private struct RadioOption<Value: Hashable> {
    let value: Value
    let title: LocalizedStringKey
    let icon: String   // SF symbol used when this option is NOT the current
}

/// Borderless-button Menu showing a single header glyph; opens a radio list of
/// `options`. The currently selected option's leading icon becomes a checkmark,
/// others show their `icon` SF symbol — empty-string systemImage drifts (drops
/// the leading column on some macOS builds), so requiring a real symbol keeps
/// the layout consistent across all toggle menus.
private struct RadioHeaderMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let headerIcon: String
    let options: [RadioOption<Value>]
    let help: LocalizedStringKey

    var body: some View {
        Menu {
            ForEach(0..<options.count, id: \.self) { i in
                let opt = options[i]
                Button { selection = opt.value } label: {
                    Label(opt.title,
                          systemImage: selection == opt.value ? "checkmark" : opt.icon)
                }
            }
        } label: {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

private struct DiffPaneView: View {
    @ObservedObject var model: ReviewModel
    @AppStorage("glint.review.diffMode") private var modeRaw = DiffMode.unified.rawValue
    @AppStorage("glint.review.diffShowContext") private var showContext = true
    // Context lines around each change, applied only in Changes Only mode
    // (showContext == false): 0 = pure changes only, N = N lines around each
    // change. Render-time over the whole-file load, so +/- is instant with no
    // git re-fetch. Persisted globally → carries across Review sessions.
    @AppStorage("glint.review.contextLines") private var contextLines = 0
    private var mode: DiffMode { DiffMode(rawValue: modeRaw) ?? .unified }

    var body: some View {
        VStack(spacing: 0) {
            if let f = model.selected {
                fileHeader(f)
                Rectangle().fill(Theme.overlay(0.05)).frame(height: 1)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPane)
    }

    @ViewBuilder
    private var content: some View {
        if model.loadingDiff && model.diffText.isEmpty {
            hint(String(localized: "Loading…"))
        } else if model.selected == nil {
            hint(String(localized: "No changes to review"))
        } else if model.selected?.isBinary == true {
            hint(String(localized: "Binary file — no text diff"))
        } else if model.diffText.isEmpty {
            hint(String(localized: "No diff for this file"))
        } else if model.diff.lines.isEmpty {
            // git emitted only headers (e.g., --ignore-all-space collapsed
            // every hunk to context for a whitespace-only diff); without this
            // branch DiffContentView would render an empty LazyVStack with no
            // indication that the filter is what hid everything.
            hint(String(localized: "No changes after filter"))
        } else {
            DiffContentView(doc: model.diff, mode: mode, showContext: showContext, contextLines: contextLines)
                // Re-mount on FILE or DATA change only (path / ignoreWhitespace
                // both change the underlying diff). Mode and showContext are
                // pure render filters on the same data — keep the view, reset
                // the nav cursor via .onChange inside, preserve scroll position
                // so toggling mode doesn't jump the user back to the top.
                .id("\(model.selected?.path ?? "")|\(model.ignoreWhitespace)")
        }
    }

    private func fileHeader(_ f: GitFileChange) -> some View {
        HStack(spacing: 8) {
            Text(f.path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            diffModeMenu
            contextLinesMenu
            if !showContext {
                contextStepper
            }
            ignoreWSMenu
            if !f.isBinary {
                if f.additions > 0 {
                    Text("+\(f.additions)").foregroundStyle(Theme.green)
                }
                if f.deletions > 0 {
                    Text("−\(f.deletions)").foregroundStyle(Theme.pink)
                }
            }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.bgPane)
    }

    // Tooltip names the state a click will switch TO.
    private var modeHelp: LocalizedStringKey { mode == .unified ? "Split" : "Unified" }
    private var contextHelp: LocalizedStringKey { showContext ? "Changes Only" : "Show All" }
    private var ignoreWSHelp: LocalizedStringKey { model.ignoreWhitespace ? "Show Whitespace" : "Ignore Whitespace" }

    // Click opens a dropdown of the two options (checkmark on the current).
    // Icon color/weight mirrors the main toolbar's settings gear (Theme.text3,
    // .medium), sized up from the original 11.5 so it reads as clearly.
    private var diffModeMenu: some View {
        RadioHeaderMenu(
            selection: $modeRaw,
            headerIcon: mode == .unified ? "text.alignleft" : "rectangle.split.2x1",
            options: [
                .init(value: DiffMode.unified.rawValue, title: "Unified", icon: "text.alignleft"),
                .init(value: DiffMode.split.rawValue, title: "Split", icon: "rectangle.split.2x1"),
            ],
            help: modeHelp
        )
    }

    private var contextLinesMenu: some View {
        RadioHeaderMenu(
            selection: $showContext,
            headerIcon: showContext ? "list.bullet" : "line.3.horizontal.decrease",
            options: [
                .init(value: true, title: "Show All", icon: "list.bullet"),
                .init(value: false, title: "Changes Only", icon: "line.3.horizontal.decrease"),
            ],
            help: contextHelp
        )
    }

    // Adjusts contextLines — the Changes-Only window size: 0 = pure changes, N =
    // N lines around each change. No upper bound; large N just converges toward
    // the whole file, which Show All covers explicitly. Hidden in Show All.
    private var contextLabel: String { "\(contextLines)" }
    private func stepContext(_ delta: Int) {
        contextLines = max(0, contextLines + delta)
    }

    private var contextStepper: some View {
        HStack(spacing: 1) {
            HeaderIconButton(symbol: "minus", help: "Fewer context lines", size: 10) { stepContext(-1) }
            Text(contextLabel)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.secondary)
                .frame(width: 30)
            HeaderIconButton(symbol: "plus", help: "More context lines", size: 10) { stepContext(1) }
        }
    }

    // Toggle --ignore-all-space (indentation/whitespace-only changes → context).
    private var ignoreWSMenu: some View {
        RadioHeaderMenu(
            selection: $model.ignoreWhitespace,
            headerIcon: model.ignoreWhitespace ? "eye.slash" : "eye",
            options: [
                .init(value: false, title: "Show Whitespace", icon: "eye"),
                .init(value: true, title: "Ignore Whitespace", icon: "eye.slash"),
            ],
            help: ignoreWSHelp
        )
    }

    private func hint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Parsed unified-diff line with gutter line numbers. Meta lines (diff --git,
// index, ---/+++ headers, mode/rename) are dropped — the file header above the
// pane already names the file, so they're noise here. Sendable so parsing can
// run off the main actor.
struct DiffLine: Identifiable, Sendable {
    enum Kind: Sendable { case hunk, context, add, del }
    let id: Int
    let kind: Kind
    let text: String
    /// Syntax-highlighted `text`. Token ranges carry `.foregroundColor`; the
    /// rest is left unattributed so the row's base `.foregroundStyle` (the
    /// add/del tint) still shows through on neutral text.
    let attributed: AttributedString
    let oldNum: Int?
    let newNum: Int?
}

// One side-by-side row. A hunk header spans both columns; a pair holds the
// optional old (left) and new (right) line — context lines mirror to both
// sides, dels land left-only, adds right-only, a del+add run pairs row-by-row.
// Built once per file load alongside DiffDocument.lines.
struct SplitRow: Identifiable, Sendable {
    enum Body: Sendable { case hunk(String); case pair(left: DiffLine?, right: DiffLine?) }
    let id: Int
    let body: Body
}

// A fully-parsed diff: the lines plus the two gutter column widths. Built once
// per file load (off-main) and cached in the model, so re-renders — e.g. every
// frame of a splitter drag — never reparse.
struct DiffDocument: Sendable {
    let lines: [DiffLine]
    let splitRows: [SplitRow]
    let oldWidth: CGFloat
    let newWidth: CGFloat

    static let empty = DiffDocument(lines: [], splitRows: [], oldWidth: 0, newWidth: 0)

    private init(lines: [DiffLine], splitRows: [SplitRow], oldWidth: CGFloat, newWidth: CGFloat) {
        self.lines = lines; self.splitRows = splitRows
        self.oldWidth = oldWidth; self.newWidth = newWidth
    }

    init(text: String, language: SyntaxLanguage? = nil) {
        let parsed = Self.parse(text, language: language)
        // Size each gutter column to its widest number; drop a column that's
        // empty for the whole diff (pure additions hide the old column, etc.).
        let maxOld = parsed.compactMap(\.oldNum).max() ?? 0
        let maxNew = parsed.compactMap(\.newNum).max() ?? 0
        self.init(lines: parsed,
                  splitRows: Self.pair(parsed),
                  oldWidth: maxOld > 0 ? Self.colWidth(maxOld) : 0,
                  newWidth: maxNew > 0 ? Self.colWidth(maxNew) : 0)
    }

    private static func colWidth(_ maxN: Int) -> CGFloat {
        let digits = max(2, String(maxN).count)
        return CGFloat(digits) * 6.6 + 12   // monospace digit ≈ 6.6pt at size 10 + padding
    }

    /// Walk the unified diff, tracking old/new line numbers from each `@@` hunk
    /// header and dropping file-level meta lines.
    static func parse(_ text: String, language: SyntaxLanguage? = nil) -> [DiffLine] {
        var out: [DiffLine] = []
        var oldLine = 0, newLine = 0
        var id = 0
        // TWO highlight states walk in parallel — one for the old-file timeline
        // (`-` lines + context), one for the new-file timeline (`+` lines +
        // context). A single shared state lets a multi-line construct opened
        // on a `-` line (e.g. removing `/* TODO`) tint the following `+` /
        // context lines as comment continuation even though those lines aren't
        // inside any comment in the new file — visually hiding real code under
        // gray. Mirror: a `+` opener bleeding into following `-` lines.
        // Context lines advance BOTH states (they exist in both versions) and
        // render through the NEW state, which is what the file looks like
        // post-diff and what the user is reviewing. Reset both at each @@.
        var oldState = SyntaxHighlighter.State()
        var newState = SyntaxHighlighter.State()
        // Normalize CRLF / lone CR to LF before splitting. Swift treats "\r\n" as
        // a single Character (extended grapheme cluster), so split(separator: "\n")
        // never matches it and silently merges every CRLF-terminated line into one
        // blob — a Windows-authored file (its diff body keeps the source's CRLF)
        // then parses as zero adds/dels, so nothing tints and the raw +/- markers
        // leak through as un-parsed text. Git's own meta lines are LF, so only the
        // diff body is affected (the file-list numstat, pure git output, is fine).
        let normed = text.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
        for raw in normed.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // The only truly-empty element is the trailing split artifact after
            // the diff's final newline; real blank context lines are " ".
            if line.isEmpty { continue }
            if line.hasPrefix("@@") {
                oldState = SyntaxHighlighter.State()   // new hunk → tint from a clean slate
                newState = SyntaxHighlighter.State()
                (oldLine, newLine) = parseHunk(line)
                out.append(DiffLine(id: id, kind: .hunk, text: line,
                                    attributed: AttributedString(line), oldNum: nil, newNum: nil)); id += 1
                continue
            }
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            // Unified-diff content is marked by a leading char: '+', '-', or
            // ' ' (context). File headers (+++/---, handled above) and every
            // git meta line (diff/index/old mode/rename/similarity/…/ "\ No
            // newline") start with something else — so classify by marker and
            // skip anything unrecognized, rather than maintain an allow-list
            // of meta prefixes that leaks a new header (e.g. "similarity
            // index") through as a tinted context line.
            // Strip the leading marker char so code columns align and the +/-
            // gutter clutter is gone — add/delete is shown via tint, not text.
            let body = String(line.dropFirst())
            if line.hasPrefix("+") {
                let attr = SyntaxHighlighter.highlight(body, language: language, state: &newState)
                out.append(DiffLine(id: id, kind: .add, text: body, attributed: attr, oldNum: nil, newNum: newLine)); id += 1
                newLine += 1
            } else if line.hasPrefix("-") {
                let attr = SyntaxHighlighter.highlight(body, language: language, state: &oldState)
                out.append(DiffLine(id: id, kind: .del, text: body, attributed: attr, oldNum: oldLine, newNum: nil)); id += 1
                oldLine += 1
            } else if line.hasPrefix(" ") {
                // Context exists in both versions: advance oldState too so a
                // subsequent `-` line sees the right state, but render through
                // newState (the post-diff view).
                var oldAdvance = oldState
                _ = SyntaxHighlighter.highlight(body, language: language, state: &oldAdvance)
                oldState = oldAdvance
                let attr = SyntaxHighlighter.highlight(body, language: language, state: &newState)
                out.append(DiffLine(id: id, kind: .context, text: body, attributed: attr, oldNum: oldLine, newNum: newLine)); id += 1
                oldLine += 1; newLine += 1
            }
            // else: a meta line (diff/index/mode/rename/…/\ No newline) — skip.
        }
        return out
    }

    /// Build side-by-side rows from the flat line list for split view.
    /// Context/hunk lines flush the pending change run; within one run
    /// (context/hunk-bounded) all dels pair against all adds row-by-row,
    /// leftover dels go left-only, leftover adds right-only. Greedy, not a
    /// Myers realign — good enough; upgrade if misalignment shows on real diffs.
    static func pair(_ lines: [DiffLine]) -> [SplitRow] {
        var out: [SplitRow] = []
        var id = 0
        var dels: [DiffLine] = []
        var adds: [DiffLine] = []

        func flush() {
            let paired = min(dels.count, adds.count)
            for i in 0..<paired {
                out.append(SplitRow(id: id, body: .pair(left: dels[i], right: adds[i]))); id += 1
            }
            for d in dels.dropFirst(paired) { out.append(SplitRow(id: id, body: .pair(left: d, right: nil))); id += 1 }
            for a in adds.dropFirst(paired) { out.append(SplitRow(id: id, body: .pair(left: nil, right: a))); id += 1 }
            dels.removeAll(); adds.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .hunk:
                flush()
                out.append(SplitRow(id: id, body: .hunk(line.text))); id += 1
            case .context:
                flush()
                out.append(SplitRow(id: id, body: .pair(left: line, right: line))); id += 1
            case .del:
                dels.append(line)
            case .add:
                adds.append(line)
            }
        }
        flush()
        return out
    }

    /// From a whole-file diff (`--unified=1000000`), keep each maximal change run
    /// plus up to `n` lines of context around it — a render-time re-derival of
    /// `git diff --unified=n` so adjusting n is instant (no re-fetch). `n < 0`
    /// returns everything (whole file); 0 drops all context (changes only). Runs
    /// whose context windows overlap merge into one visible block, matching git's
    /// own hunk merging; hunk headers are always kept.
    static func windowed(_ lines: [DiffLine], context n: Int) -> [DiffLine] {
        if n < 0 { return lines }
        let count = lines.count
        var keep = [Bool](repeating: false, count: count)
        var i = 0
        while i < count {
            if lines[i].kind == .add || lines[i].kind == .del {
                // Back-fill up to n context lines immediately before this run.
                var b = i - 1, back = n
                while b >= 0, back > 0, lines[b].kind == .context { keep[b] = true; b -= 1; back -= 1 }
                // Keep the whole contiguous change run, then up to n context after.
                var j = i
                while j < count, lines[j].kind == .add || lines[j].kind == .del { keep[j] = true; j += 1 }
                var f = j, fwd = n
                while f < count, fwd > 0, lines[f].kind == .context { keep[f] = true; f += 1; fwd -= 1 }
                i = f          // a following run's back-fill reclaims any gap, idempotently
            } else {
                i += 1
            }
        }
        var out: [DiffLine] = []
        out.reserveCapacity(count)
        for (idx, line) in lines.enumerated() where keep[idx] || line.kind == .hunk { out.append(line) }
        return out
    }

    /// `@@ -oldStart,oldCount +newStart,newCount @@ ...` → (oldStart, newStart).
    private static func parseHunk(_ line: String) -> (Int, Int) {
        var old = 0, new = 0
        var gotOld = false, gotNew = false
        // Take the FIRST `-`/`+` range. For a normal `@@ -a,b +c,d @@` this is the
        // only one; for a combined `@@@ -a,b -c,d +e,f @@@` (unmerged/conflict
        // files) it seeds from the first parent's old range instead of letting a
        // later token overwrite and mis-number the rest of the file.
        for p in line.split(separator: " ") {
            if !gotOld, p.hasPrefix("-") {
                old = Int(p.dropFirst().split(separator: ",").first ?? "") ?? 0; gotOld = true
            } else if !gotNew, p.hasPrefix("+") {
                new = Int(p.dropFirst().split(separator: ",").first ?? "") ?? 0; gotNew = true
            }
        }
        return (old, new)
    }
}

private struct DiffContentView: View {
    let doc: DiffDocument
    let mode: DiffMode
    let showContext: Bool
    let contextLines: Int
    private static let maxLines = 6000
    @State private var cursor = -1   // index into RenderPlan.anchors; -1 = not yet jumped

    var body: some View {
        ScrollViewReader { proxy in
            // Single source of truth — filter + cap + anchors + ids all walk
            // the same prefix-bounded list ONCE per body eval. Before this
            // unification, anchors/filteredIds scanned the FULL filtered doc
            // while the body only rendered prefix(maxLines), so changes past
            // row 6000 inflated the X/Y counter and silently no-op'd when
            // Opt+↑/↓ tried to scroll to a row id that was never realized.
            let plan = renderPlan
            ZStack(alignment: .bottomTrailing) {
                switch plan.kind {
                case .unified(let rows): unifiedBody(rows: rows, total: plan.totalCount)
                case .split(let rows):   splitBody(rows: rows, total: plan.totalCount)
                }
                // Next/prev only matters in Show All (Changes Only already lists
                // just changes), so hide the cluster — and its shortcuts — otherwise.
                if showContext, !plan.anchors.isEmpty {
                    navCluster(proxy: proxy, anchors: plan.anchors, ids: plan.ids)
                }
            }
            // Mode and showContext are render-only filters — keep the view
            // (preserves scroll position), but reset the cursor because the
            // anchor list changes shape and the previous index no longer maps
            // to the same change. File / ignoreWhitespace changes the data and
            // remounts via .id() at the call site, where @State already resets.
            .onChange(of: mode) { _, _ in cursor = -1 }
            .onChange(of: showContext) { _, _ in cursor = -1 }
        }
    }

    private struct RenderPlan {
        enum Kind {
            case unified(ArraySlice<DiffLine>)
            case split(ArraySlice<SplitRow>)
        }
        let kind: Kind
        let anchors: [Int]
        let ids: [Int]
        let totalCount: Int   // pre-cap, for "N more lines" truncation footer
    }

    private var renderPlan: RenderPlan {
        switch mode {
        case .unified:
            // Show All renders the whole file; Changes Only windows each change
            // run with `contextLines` of context (render-time, no re-fetch).
            let filtered = showContext ? doc.lines : DiffDocument.windowed(doc.lines, context: contextLines)
            let capped = filtered.prefix(Self.maxLines)
            var anchors: [Int] = []
            var ids: [Int] = []
            ids.reserveCapacity(capped.count)
            var prev = false
            for line in capped {
                ids.append(line.id)
                let c = line.kind == .add || line.kind == .del
                if c && !prev { anchors.append(line.id) }
                prev = c
            }
            return RenderPlan(kind: .unified(capped), anchors: anchors, ids: ids, totalCount: filtered.count)
        case .split:
            // windowed keeps a `[DiffLine]` mask, so re-pair after windowing in
            // Changes Only; Show All uses the pre-paired whole-file rows.
            let filtered = showContext
                ? doc.splitRows
                : DiffDocument.pair(DiffDocument.windowed(doc.lines, context: contextLines))
            let capped = filtered.prefix(Self.maxLines)
            var anchors: [Int] = []
            var ids: [Int] = []
            ids.reserveCapacity(capped.count)
            var prev = false
            for r in capped {
                ids.append(r.id)
                let c = Self.isChangeRow(r)
                if c && !prev { anchors.append(r.id) }
                prev = c
            }
            return RenderPlan(kind: .split(capped), anchors: anchors, ids: ids, totalCount: filtered.count)
        }
    }

    private static func isChangeRow(_ r: SplitRow) -> Bool {
        if case .pair(let l, let rg) = r.body {
            return (l?.kind == .add || l?.kind == .del) || (rg?.kind == .add || rg?.kind == .del)
        }
        return false
    }

    private func jump(proxy: ScrollViewProxy, anchors: [Int], ids: [Int], delta: Int) {
        guard !anchors.isEmpty else { return }
        // First press: wrap. Opt+↑ → last change, Opt+↓ → first. Old code
        // clamped to 0 on first press regardless of direction, so Opt+↑ also
        // landed on the first change — opposite of GitHub/VS Code's behavior.
        if cursor < 0 {
            cursor = delta < 0 ? anchors.count - 1 : 0
        } else {
            cursor = min(max(cursor + delta, 0), anchors.count - 1)
        }
        // Land ~2 lines above the change so it isn't flush against the top edge.
        let target = offsetTarget(for: anchors[cursor], in: ids, lead: 2)
        // Instant scroll (no withAnimation): an animated scrollTo over a
        // LazyVStack forces SwiftUI to realize every row between here and the
        // target each frame — on a whole-file diff (up to 6000 lines) that
        // hitched. Jump-nav is expected to snap, like VS Code's next-change.
        proxy.scrollTo(target, anchor: .top)
    }

    /// id of the row `lead` lines above `anchorId` in the rendered list, clamped
    /// to the top — so a jumped-to change shows a couple lines of lead context
    /// instead of sitting right at the viewport edge.
    private func offsetTarget(for anchorId: Int, in ids: [Int], lead: Int) -> Int {
        guard let pos = ids.firstIndex(of: anchorId) else { return anchorId }
        return ids[max(0, pos - lead)]
    }

    // Floating prev/next cluster, bottom-trailing — GitHub-style change navigation.
    private func navCluster(proxy: ScrollViewProxy, anchors: [Int], ids: [Int]) -> some View {
        let at = min(max(cursor, 0), anchors.count - 1) + 1
        return HStack(spacing: 2) {
            HeaderIconButton(symbol: "chevron.up", help: "Previous change", size: 11) {
                jump(proxy: proxy, anchors: anchors, ids: ids, delta: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: .option)
            Text("\(at)/\(anchors.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .frame(width: 34)
            HeaderIconButton(symbol: "chevron.down", help: "Next change", size: 11) {
                jump(proxy: proxy, anchors: anchors, ids: ids, delta: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: .option)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Capsule().fill(Theme.bgPane))
        .overlay(Capsule().stroke(Theme.overlay(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .padding(16)
    }

    // MARK: unified (single column)

    @ViewBuilder
    private func unifiedBody(rows: ArraySlice<DiffLine>, total: Int) -> some View {
        let oldW = doc.oldWidth, newW = doc.newWidth
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { line in
                    unifiedRow(line, oldW: oldW, newW: newW).id(line.id)
                }
                truncationLabel(total)
            }
        }
    }

    @ViewBuilder
    private func unifiedRow(_ line: DiffLine, oldW: CGFloat, newW: CGFloat) -> some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.overlay(0.05))
        } else {
            let c = Self.tint(line.kind)
            HStack(alignment: .top, spacing: 0) {
                // Gutter (old | new), tinted a touch darker than the code so it
                // reads as a Fork-style sidebar; stretches to full row height so
                // wrapped lines stay aligned. Empty columns collapse to width 0.
                HStack(spacing: 0) {
                    if oldW > 0 { num(line.oldNum, width: oldW) }
                    if newW > 0 { num(line.newNum, width: newW) }
                }
                .frame(maxHeight: .infinity)
                .background(c.gutter)

                Text(line.text.isEmpty ? AttributedString(" ") : line.attributed)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(c.fg)
                    .textSelection(.enabled)
                    .padding(.leading, 12).padding(.trailing, 12)
                    .padding(.vertical, 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(c.code)
            .overlay(alignment: .leading) {
                Rectangle().fill(c.strip).frame(width: 2)
            }
        }
    }

    // MARK: split (side-by-side)

    @ViewBuilder
    private func splitBody(rows: ArraySlice<SplitRow>, total: Int) -> some View {
        let oldW = doc.oldWidth, newW = doc.newWidth
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    splitRow(r, oldW: oldW, newW: newW).id(r.id)
                }
                truncationLabel(total)
            }
        }
    }

    @ViewBuilder
    private func splitRow(_ r: SplitRow, oldW: CGFloat, newW: CGFloat) -> some View {
        switch r.body {
        case .hunk(let text):
            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.overlay(0.05))
        case .pair(let left, let right):
            // The colored halves are painted as the row's background so each
            // fills the full row height (= max of the two sides) even when one
            // side wraps and the other doesn't — no per-cell height trick needed.
            let leftColor = left == nil ? Theme.overlay(0.025) : Self.tint(left!.kind).code
            let rightColor = right == nil ? Theme.overlay(0.025) : Self.tint(right!.kind).code
            HStack(alignment: .top, spacing: 0) {
                sideContent(left, lineNo: left?.oldNum, width: oldW).frame(maxWidth: .infinity)
                sideContent(right, lineNo: right?.newNum, width: newW).frame(maxWidth: .infinity)
            }
            .background(halfBackground(left: leftColor, right: rightColor))
        }
    }

    @ViewBuilder
    private func sideContent(_ line: DiffLine?, lineNo: Int?, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            num(lineNo, width: width)
            Text(line.map { $0.text.isEmpty ? AttributedString(" ") : $0.attributed } ?? AttributedString(" "))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(line == nil ? Theme.text4 : Self.tint(line!.kind).fg)
                .textSelection(.enabled)
                .padding(.leading, 10).padding(.trailing, 10)
                .padding(.vertical, 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Two equal-width color halves with a 1pt divider between, painted as the
    // row background so it spans the full row height; each side colors through
    // to its half of the divider.
    private func halfBackground(left: Color, right: Color) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(left).frame(maxWidth: .infinity)
            Rectangle().fill(Theme.overlay(0.05)).frame(width: 1)
            Rectangle().fill(right).frame(maxWidth: .infinity)
        }
    }

    // MARK: shared

    @ViewBuilder
    private func truncationLabel(_ total: Int) -> some View {
        if total > Self.maxLines {
            Text("Diff truncated — \(total - Self.maxLines) more lines")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func num(_ n: Int?, width: CGFloat) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.text4)
            .frame(width: width, alignment: .trailing)
            .padding(.vertical, 1.5)
    }

    // Neutral text on a faint background (not saturated text) so a large add
    // block doesn't become a wall of green; the gutter + left strip carry the
    // add/delete signal.
    private struct Tint { let fg: Color; let gutter: Color; let code: Color; let strip: Color }
    private static func tint(_ k: DiffLine.Kind) -> Tint {
        switch k {
        case .add:     return Tint(fg: Theme.text1, gutter: Theme.green.opacity(0.18),
                                   code: Theme.green.opacity(0.07), strip: Theme.green.opacity(0.75))
        case .del:     return Tint(fg: Theme.text1, gutter: Theme.pink.opacity(0.18),
                                   code: Theme.pink.opacity(0.07), strip: Theme.pink.opacity(0.75))
        case .context: return Tint(fg: Theme.text2, gutter: Theme.overlay(0.03),
                                   code: .clear, strip: .clear)
        case .hunk:    return Tint(fg: Theme.text3, gutter: .clear, code: .clear, strip: .clear)
        }
    }
}

// Hosting view that reports no safe-area inset, so content fills under the
// transparent full-size-content titlebar without SwiftUI re-coordinating the
// inset every layout pass (the source of resize flicker).
private final class NoSafeAreaHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    required init(rootView: Content) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Window controller

// The app-wide ⌘W is bound to "Close Pane" (a SwiftUI menu command in GlintApp
// whose closure fires regardless of key window — and AppDelegate.patchMainMenu
// strips ⌘W off the system Close item so that pane-close wins). From the Review
// window a plain ⌘W should just close this window (standard macOS key-window
// behavior), so swallow it here before it reaches the main menu.
private final class ReviewWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = ReviewWindowController()
    private static let frameAutosaveName = "GlintReviewWindow"

    private var window: NSWindow?
    private var model: ReviewModel?   // strong ref for the window's lifetime
    /// Lives for the duration the window is open. Re-applies NSWindow.appearance
    /// whenever the store bumps `themeRevision`, so a mid-session theme switch
    /// doesn't leave borderless-menu popups (rendered by AppKit, not SwiftUI)
    /// resolving label colors against the open-time appearance.
    private var themeCancellable: AnyCancellable?

    func present(repo: String, title: String, subdir: String? = nil,
                 scopes: [DiffScope], store: WorkspaceStore,
                 runner: GitRunner = LocalGitRunner()) {
        let model = ReviewModel(repo: repo, title: title, subdir: subdir, scopes: scopes, runner: runner)
        self.model = model
        let root = ReviewView(model: model)
            .frame(minWidth: 780, minHeight: 480)
            .environmentObject(store)

        let w = window ?? makeWindow()
        w.title = title
        // The sink fires synchronously with the current value on subscribe
        // (@Published behavior) — but only on `w`, the local NSWindow we just
        // created. Capture `w` directly in the closure so the synchronous
        // first fire applies the open-time appearance BEFORE `self.window`
        // has been assigned below. Previously this closed over `self?.window`
        // which was still nil on the first present() of the session, so the
        // initial open used AppKit's system appearance instead of the user's
        // Theme pick. Subsequent opens reused the cached `window` ivar and
        // looked correct, masking the bug.
        themeCancellable = store.$themeRevision.sink { [weak w] _ in
            w?.appearance = NSAppearance(named: Theme.current.isDark ? .darkAqua : .aqua)
        }
        // Zero the hosting view's safe-area at the AppKit layer instead of with
        // SwiftUI's `.ignoresSafeArea()`. The modifier makes SwiftUI re-coordinate
        // the titlebar inset on every layout pass, which flickers while resizing
        // (e.g. dragging the splitter); a static zero inset fills under the
        // titlebar with no per-frame recomputation.
        w.contentView = NoSafeAreaHostingView(rootView: root)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = ReviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden            // our sidebar carries the title
        w.titlebarSeparatorStyle = .none       // kill the hairline under the traffic lights
        // Not movable-by-background: it would steal the sidebar splitter drag
        // (and any future drag in content). The hidden-but-present titlebar strip
        // at the top still moves the window.
        w.isMovableByWindowBackground = false
        // Appearance is owned by themeCancellable in present() — don't seed
        // here, otherwise it'd flicker the wrong theme for one frame.
        w.isReleasedWhenClosed = false         // reuse the shell across opens
        // Persist & restore window position/size across launches. AppKit writes
        // the frame to UserDefaults whenever the window moves/resizes; on first
        // open we restore the saved frame, else center the default size.
        if !w.setFrameUsingName(Self.frameAutosaveName) { w.center() }
        w.setFrameAutosaveName(Self.frameAutosaveName)
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the model so its (now hidden) state isn't kept alive; the window
        // shell is reused on the next open. Drop the theme sink too — present()
        // resubscribes when the window comes back.
        model = nil
        themeCancellable = nil
    }
}
