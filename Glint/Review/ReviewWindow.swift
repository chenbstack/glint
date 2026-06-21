import SwiftUI
import AppKit

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
    let availableScopes: [DiffScope]

    @Published var scope: DiffScope { didSet { Task { await reload() } } }
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

    private let git = GitService()
    private var loadToken = 0   // guards against out-of-order diff/file loads

    init(repo: String, title: String, scopes: [DiffScope]) {
        self.repo = repo
        self.title = title
        self.availableScopes = scopes.isEmpty ? [.workingTree] : scopes
        self.scope = scopes.first ?? .workingTree
    }

    func reload() async {
        // Guard against overlapping reloads (rapid scope toggles): a slower,
        // older fetch must not clobber the newer scope's file list. select()
        // bumps the same token, so a stale fetch returning after a new select
        // also drops.
        loadToken += 1
        let token = loadToken
        loadingFiles = true
        let fs = await git.changedFiles(repo: repo, scope: scope)
        guard token == loadToken else { return }
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
        loadToken += 1
        let token = loadToken
        loadingDiff = true
        let text = await git.fileDiff(repo: repo, scope: scope, file: f)
        // A newer selection (or scope change) superseded this load — drop it.
        guard token == loadToken else { return }
        // Parse off the main actor so a multi-thousand-line diff doesn't hitch
        // the UI; the result is cached so re-renders (splitter drags) don't reparse.
        let doc = await Task.detached(priority: .userInitiated) { DiffDocument(text: text) }.value
        guard token == loadToken else { return }
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

private struct DiffPaneView: View {
    @ObservedObject var model: ReviewModel

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
        } else {
            DiffContentView(doc: model.diff)
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
    let oldNum: Int?
    let newNum: Int?
}

// A fully-parsed diff: the lines plus the two gutter column widths. Built once
// per file load (off-main) and cached in the model, so re-renders — e.g. every
// frame of a splitter drag — never reparse.
struct DiffDocument: Sendable {
    let lines: [DiffLine]
    let oldWidth: CGFloat
    let newWidth: CGFloat

    static let empty = DiffDocument(lines: [], oldWidth: 0, newWidth: 0)

    private init(lines: [DiffLine], oldWidth: CGFloat, newWidth: CGFloat) {
        self.lines = lines; self.oldWidth = oldWidth; self.newWidth = newWidth
    }

    init(text: String) {
        let parsed = Self.parse(text)
        // Size each gutter column to its widest number; drop a column that's
        // empty for the whole diff (pure additions hide the old column, etc.).
        let maxOld = parsed.compactMap(\.oldNum).max() ?? 0
        let maxNew = parsed.compactMap(\.newNum).max() ?? 0
        self.init(lines: parsed,
                  oldWidth: maxOld > 0 ? Self.colWidth(maxOld) : 0,
                  newWidth: maxNew > 0 ? Self.colWidth(maxNew) : 0)
    }

    private static func colWidth(_ maxN: Int) -> CGFloat {
        let digits = max(2, String(maxN).count)
        return CGFloat(digits) * 6.6 + 12   // monospace digit ≈ 6.6pt at size 10 + padding
    }

    /// Walk the unified diff, tracking old/new line numbers from each `@@` hunk
    /// header and dropping file-level meta lines.
    static func parse(_ text: String) -> [DiffLine] {
        var out: [DiffLine] = []
        var oldLine = 0, newLine = 0
        var id = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // The only truly-empty element is the trailing split artifact after
            // the diff's final newline; real blank context lines are " ".
            if line.isEmpty { continue }
            if line.hasPrefix("@@") {
                (oldLine, newLine) = parseHunk(line)
                out.append(DiffLine(id: id, kind: .hunk, text: line, oldNum: nil, newNum: nil)); id += 1
                continue
            }
            if line.hasPrefix("+++") || line.hasPrefix("---")
                || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("rename ") || line.hasPrefix("similarity")
                || line.hasPrefix("copy ") || line.hasPrefix("Binary files")
                || line.hasPrefix("\\ ") {       // "\ No newline at end of file"
                continue
            }
            // Strip the leading marker char so code columns align and the +/-
            // gutter clutter is gone — add/delete is shown via tint, not text.
            let body = String(line.dropFirst())
            if line.hasPrefix("+") {
                out.append(DiffLine(id: id, kind: .add, text: body, oldNum: nil, newNum: newLine)); id += 1
                newLine += 1
            } else if line.hasPrefix("-") {
                out.append(DiffLine(id: id, kind: .del, text: body, oldNum: oldLine, newNum: nil)); id += 1
                oldLine += 1
            } else {
                out.append(DiffLine(id: id, kind: .context, text: body, oldNum: oldLine, newNum: newLine)); id += 1
                oldLine += 1; newLine += 1
            }
        }
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
    private static let maxLines = 6000

    var body: some View {
        let shown = doc.lines.prefix(Self.maxLines)
        let oldW = doc.oldWidth, newW = doc.newWidth
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { line in
                    row(line, oldW: oldW, newW: newW)
                }
                if doc.lines.count > Self.maxLines {
                    Text("Diff truncated — \(doc.lines.count - Self.maxLines) more lines")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: DiffLine, oldW: CGFloat, newW: CGFloat) -> some View {
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

                Text(line.text.isEmpty ? " " : line.text)
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

@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = ReviewWindowController()
    private static let frameAutosaveName = "GlintReviewWindow"

    private var window: NSWindow?
    private var model: ReviewModel?   // strong ref for the window's lifetime

    func present(repo: String, title: String, scopes: [DiffScope]) {
        let model = ReviewModel(repo: repo, title: title, scopes: scopes)
        self.model = model
        let root = ReviewView(model: model)
            .frame(minWidth: 780, minHeight: 480)
            .preferredColorScheme(.dark)

        let w = window ?? makeWindow()
        w.title = title
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
        let w = NSWindow(
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
        w.appearance = NSAppearance(named: .darkAqua)
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
        // shell is reused on the next open.
        model = nil
    }
}
