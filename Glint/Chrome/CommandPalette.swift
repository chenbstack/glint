import SwiftUI

/// Centered modal overlay summoned by ⌘K or the toolbar's ⌘ button.
/// Type to fuzzy-filter; ↑↓ to move selection; ⏎ to execute; ⎋ to close.
struct CommandPalette: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

    /// Why `selectedIndex` last changed. Only keyboard navigation may
    /// auto-scroll the selection into view: if hover-driven changes did
    /// too, pressing ↑↓ would scroll rows under the stationary cursor,
    /// hover would instantly re-steal the selection, and the highlight
    /// would jump around instead of following the arrows.
    private enum SelectionSource { case keyboard, pointer }
    @State private var selectionSource: SelectionSource = .keyboard

    var body: some View {
        ZStack {
            // Click-out catcher
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchField
                Divider().opacity(0.4)
                resultList
            }
            .frame(width: 520, height: 420)
            // Liquid Glass panel on macOS 26 — the palette floats over the
            // terminal in the same window, exactly the layering glass is
            // built to refract. Glass draws its own rim light, so the manual
            // hairline stroke lives only in the fallback.
            .liquidGlass(enabled: store.glassEffect, cornerRadius: 14,
                         tint: Theme.glassTint) {
                ZStack {
                    VisualEffectBackground(material: .menu)
                    LinearGradient(
                        colors: [
                            Theme.sidebarTintTop.opacity(0.96),
                            Theme.sidebarTintBottom.opacity(0.96),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
            .shadow(color: Color.black.opacity(0.5), radius: 30, y: 12)
            .padding(.top, -80) // bias slightly above center
        }
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in
            // Typing resets the selection to the top hit; treat it like
            // keyboard input so the list scrolls back up with it.
            selectionSource = .keyboard
            selectedIndex = 0
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text3)
            TextField("Type a command or workspace…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text1)
                .focused($queryFocused)
                .onSubmit { execute() }
                .onKeyPress(.upArrow) {
                    move(-1); return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1); return .handled
                }
                .onKeyPress(.escape) {
                    close(); return .handled
                }
            Text("ESC")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultList: some View {
        let items = filteredItems()
        return ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty {
                    noResultsPlaceholder
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            PaletteRow(
                                item: item,
                                selected: idx == selectedIndex
                            )
                            .id(idx)
                            .onTapGesture {
                                selectedIndex = idx
                                execute()
                            }
                            .onHover { hovering in
                                if hovering {
                                    selectionSource = .pointer
                                    selectedIndex = idx
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .onChange(of: selectedIndex) { _, idx in
                // Hover-driven selection must not auto-scroll — see
                // `SelectionSource` for the feedback loop it causes.
                guard selectionSource == .keyboard else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private var noResultsPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.text4)
            Text("No results")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - Items

    private func allItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        let actionTint = store.accent

        // Workspace jumpers — current workspace first and badged, so an
        // accidental ⏎ on an empty query is a harmless no-op (it just
        // re-selects the workspace you're already in).
        let currentID = store.selectedWorkspaceID
        let ordered = store.workspaces.filter { $0.id == currentID }
            + store.workspaces.filter { $0.id != currentID }
        for ws in ordered {
            let n = ws.panes.count
            let unit = String(localized: n == 1 ? "pane" : "panes")
            items.append(.workspace(
                title: ws.displayName,
                subtitle: "\(n) \(unit)",
                accent: ws.accent,
                isCurrent: ws.id == currentID,
                action: { store.selectWorkspace(ws.id) }
            ))
        }

        items.append(.action(
            title: "New Workspace",
            subtitle: "Create a fresh workspace",
            symbol: "plus.square",
            shortcut: "",
            tint: actionTint,
            action: { store.addWorkspace() }
        ))

        items.append(.action(
            title: "New Tab",
            subtitle: "Open a tab in this workspace",
            symbol: "plus.rectangle.on.rectangle",
            shortcut: "⌘T",
            tint: actionTint,
            action: { store.newTab() }
        ))
        // Naming note: the store's `.horizontal` means an HSplit — panes
        // side by side (see PaneTreeView) — which reads inverted as a
        // label. User-facing copy is direction-explicit instead; the enum
        // cases and shortcuts stay as-is (other files reference them).
        items.append(.action(
            title: "Split Right",
            subtitle: "Open a new pane on the right",
            symbol: "rectangle.split.2x1",
            shortcut: "⌘D",
            tint: actionTint,
            action: { store.splitFocused(.horizontal) }
        ))
        items.append(.action(
            title: "Split Down",
            subtitle: "Stack a new pane below",
            symbol: "rectangle.split.1x2",
            shortcut: "⌘⇧D",
            tint: actionTint,
            action: { store.splitFocused(.vertical) }
        ))
        items.append(.action(
            title: "Close Pane",
            subtitle: "Close the focused pane",
            symbol: "xmark.square",
            shortcut: "⌘W",
            tint: actionTint,
            action: { store.closeFocused() }
        ))
        items.append(.action(
            title: "Focus Next Pane",
            subtitle: "Cycle pane focus within this workspace",
            symbol: "arrow.triangle.2.circlepath",
            shortcut: "⌘]",
            tint: actionTint,
            action: { store.focusNext() }
        ))
        items.append(.action(
            title: "Toggle Sidebar",
            subtitle: "Show or hide the workspace sidebar",
            symbol: "sidebar.left",
            shortcut: "⌘/",
            tint: actionTint,
            action: { store.sidebarCollapsed.toggle() }
        ))

        return items
    }

    private func filteredItems() -> [PaletteItem] {
        let items = allItems()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        // Score, then sort best-first. Enumerate before sorting so equal
        // scores keep their original relative order regardless of
        // `sorted(by:)`'s stability guarantees.
        return items.enumerated()
            .compactMap { idx, item in
                item.score(query: q).map { (idx: idx, item: item, score: $0) }
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.idx < rhs.idx
            }
            .map(\.item)
    }

    // MARK: - Behavior

    private func move(_ delta: Int) {
        let items = filteredItems()
        guard !items.isEmpty else { return }
        selectionSource = .keyboard
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    private func execute() {
        let items = filteredItems()
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].action()
        close()
    }

    private func close() {
        store.commandPaletteOpen = false
        query = ""
        selectedIndex = 0
    }
}

// MARK: - Row + model

private struct PaletteRow: View {
    @EnvironmentObject var store: WorkspaceStore
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                // User content (workspace names) renders verbatim — through
                // LocalizedStringKey a name like "*foo*" would be parsed as
                // markdown and shown italicized.
                (item.userContent
                    ? Text(verbatim: item.title)
                    : Text(LocalizedStringKey(item.title)))
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                if let s = item.subtitle {
                    (item.userContent
                        ? Text(verbatim: s)
                        : Text(LocalizedStringKey(s)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text4)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(0.10) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(store.accent)
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .cornerRadius(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        switch item.icon {
        case .symbol(let name, let tint):
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)
        case .swatch(let color):
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "circle.grid.2x2.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                )
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.trailing {
        case .kbd(let s) where !s.isEmpty:
            Text(s)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                )
        case .kind(let label):
            Text(LocalizedStringKey(label))
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.text4)
        default:
            EmptyView()
        }
    }
}

private struct PaletteItem: Identifiable {
    enum Icon { case symbol(String, Color); case swatch(Color) }
    enum Trailing { case kbd(String); case kind(String); case none }
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: Icon
    let trailing: Trailing
    /// True when title/subtitle carry runtime user data (workspace names)
    /// rather than app copy — rows must render those verbatim, not as
    /// LocalizedStringKey (which would markdown-format names like "*foo*").
    let userContent: Bool
    let action: () -> Void

    /// Fuzzy relevance of this item for `query` (already lowercased).
    /// nil = no match. Title matches outrank any subtitle match.
    func score(query: String) -> Int? {
        if let t = Self.fuzzyScore(needle: query, haystack: title.lowercased()) {
            return t + 1_000
        }
        if let sub = subtitle,
           let s = Self.fuzzyScore(needle: query, haystack: sub.lowercased()) {
            return s
        }
        return nil
    }

    /// Subsequence fuzzy match with a simple additive score:
    /// exact prefix > word-boundary starts > contiguous runs > scattered
    /// characters. Returns nil when `needle` is not a subsequence of
    /// `haystack`. Pure; both inputs are expected pre-lowercased. Greedy
    /// left-to-right alignment — not optimal for every pathological
    /// input, but predictable and dependency-free.
    static func fuzzyScore(needle: String, haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let n = Array(needle)
        let h = Array(haystack)
        var score = 0
        var ni = 0
        var lastMatch = -2  // sentinel: not adjacent to index 0
        for (hi, ch) in h.enumerated() {
            guard ni < n.count, ch == n[ni] else { continue }
            if hi == 0 {
                score += 20                                    // start of string
            } else if hi == lastMatch + 1 {
                score += 10                                    // contiguous run
            } else if !h[hi - 1].isLetter && !h[hi - 1].isNumber {
                score += 15                                    // word boundary
            } else {
                score += 1                                     // scattered
            }
            lastMatch = hi
            ni += 1
        }
        guard ni == n.count else { return nil }                // not a subsequence
        if haystack.hasPrefix(needle) { score += 100 }         // prefix beats all
        return score
    }

    static func action(title: String, subtitle: String, symbol: String,
                       shortcut: String, tint: Color,
                       action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle,
                    icon: .symbol(symbol, tint),
                    trailing: shortcut.isEmpty ? .kind("ACTION") : .kbd(shortcut),
                    userContent: false,
                    action: action)
    }

    static func workspace(title: String, subtitle: String, accent: Color,
                          isCurrent: Bool,
                          action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle,
                    icon: .swatch(accent),
                    trailing: .kind(isCurrent ? "CURRENT" : "WORKSPACE"),
                    userContent: true,
                    action: action)
    }
}
