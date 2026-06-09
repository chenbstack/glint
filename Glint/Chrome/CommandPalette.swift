import SwiftUI

/// Centered modal overlay summoned by ⌘K or the toolbar's ⌘ button.
/// Type to fuzzy-filter; ↑↓ to move selection; ⏎ to execute; ⎋ to close.
struct CommandPalette: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

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
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.clear)
                    .background(
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
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 30, y: 12)
            .padding(.top, -80) // bias slightly above center
        }
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
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
                            if hovering { selectedIndex = idx }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedIndex) { _, idx in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    // MARK: - Items

    private func allItems() -> [PaletteItem] {
        var items: [PaletteItem] = []

        // Workspace jumpers — current first so quick re-selection still works.
        for ws in store.workspaces {
            items.append(.workspace(
                title: ws.displayName,
                subtitle: "\(ws.panes.count) \(ws.panes.count == 1 ? "pane" : "panes")",
                accent: ws.accent,
                action: { store.selectWorkspace(ws.id) }
            ))
        }

        items.append(.action(
            title: "New Workspace",
            subtitle: "Create a fresh workspace",
            symbol: "plus.square",
            shortcut: "",
            action: { store.addWorkspace() }
        ))
        items.append(.action(
            title: "Split Horizontal",
            subtitle: "Stack a new pane below",
            symbol: "rectangle.split.1x2",
            shortcut: "⌘D",
            action: { store.splitFocused(.horizontal) }
        ))
        items.append(.action(
            title: "Split Vertical",
            subtitle: "Open a new pane on the right",
            symbol: "rectangle.split.2x1",
            shortcut: "⌘⇧D",
            action: { store.splitFocused(.vertical) }
        ))
        items.append(.action(
            title: "Close Pane",
            subtitle: "Close the focused pane",
            symbol: "xmark.square",
            shortcut: "⌘W",
            action: { store.closeFocused() }
        ))
        items.append(.action(
            title: "Focus Next Pane",
            subtitle: "Cycle pane focus within this workspace",
            symbol: "arrow.triangle.2.circlepath",
            shortcut: "⌘]",
            action: { store.focusNext() }
        ))
        items.append(.action(
            title: "Toggle Sidebar",
            subtitle: "Show or hide the workspace sidebar",
            symbol: "sidebar.left",
            shortcut: "⌘/",
            action: { store.sidebarCollapsed.toggle() }
        ))

        return items
    }

    private func filteredItems() -> [PaletteItem] {
        let items = allItems()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.matches(query: q) }
    }

    // MARK: - Behavior

    private func move(_ delta: Int) {
        let items = filteredItems()
        guard !items.isEmpty else { return }
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
                Text(LocalizedStringKey(item.title))
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                if let s = item.subtitle {
                    Text(LocalizedStringKey(s))
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
    let action: () -> Void

    func matches(query: String) -> Bool {
        title.lowercased().contains(query)
            || (subtitle?.lowercased().contains(query) ?? false)
    }

    static func action(title: String, subtitle: String, symbol: String,
                       shortcut: String, action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle,
                    icon: .symbol(symbol, Theme.accentBright),
                    trailing: shortcut.isEmpty ? .kind("ACTION") : .kbd(shortcut),
                    action: action)
    }

    static func workspace(title: String, subtitle: String, accent: Color,
                          action: @escaping () -> Void) -> PaletteItem {
        PaletteItem(title: title, subtitle: subtitle,
                    icon: .swatch(accent),
                    trailing: .kind("WORKSPACE"),
                    action: action)
    }
}
