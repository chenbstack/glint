import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // top spacer for traffic-light area (NSWindow draws them automatically here)
            Color.clear.frame(height: 38)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onChange(of: store.sidebarSearchFocusTick) { _, _ in
                    searchFocused = true
                }

            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("Workspaces", count: filteredWorkspaces.count)
                    VStack(spacing: 6) {
                        ForEach(filteredWorkspaces) { ws in
                            WorkspaceCard(ws: ws)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                }
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)

            newWorkspaceCard
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
        }
    }

    private var filteredWorkspaces: [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.workspaces }
        return store.workspaces.filter { ws in
            ws.displayName.lowercased().contains(query)
                || ws.name.lowercased().contains(query)
        }
    }

    private var newWorkspaceCard: some View {
        Button {
            store.addWorkspace()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
                Text("New Workspace")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text4)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    searchText = ""
                    searchFocused = false
                    return .handled
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(searchFocused ? 0.08 : 0.04))
        )
        // Make the entire pill hit-testable so clicking anywhere (the
        // magnifying glass, the empty padding, the trailing ⌘K tag) hands
        // focus to the TextField. Without contentShape SwiftUI only routes
        // hits that land directly on the TextField's text baseline.
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .textCase(.uppercase)
                .font(.glintSection)
                .kerning(0.8)
                .foregroundStyle(Theme.text4)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

}

private struct WorkspaceCard: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace

    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let active = store.selectedWorkspaceID == ws.id
        let summary = store.agentSummary(for: ws)
        let status = summary?.status
        HStack(alignment: .center, spacing: 10) {
            workspaceIcon(active: active, status: status)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(Theme.text1)
                        .focused($nameFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                        .onAppear {
                            // When editing, start with the underlying user name
                            // (not the auto-derived display name).
                            draftName = ws.userNamed ? ws.name : ""
                            DispatchQueue.main.async { nameFieldFocused = true }
                        }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused && isEditing { commitRename() }
                        }
                } else {
                    Text(ws.displayName)
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Theme.text1 : Theme.text2)
                        .italic(!ws.userNamed)
                }
                secondaryRow(summary: summary, active: active)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Color.white.opacity(0.09) : Color.white.opacity(0.03))
        )
        .overlay(cardBorder(active: active, status: status))
        .contentShape(Rectangle())
        .onTapGesture {
            // Single-tap only — double-tap-to-rename used to live here but
            // forced SwiftUI to wait the system double-click window before
            // committing the single tap, making workspace switching feel
            // sluggish. Rename now goes through the right-click menu.
            if !isEditing { store.selectWorkspace(ws.id) }
        }
        .contextMenu {
            Button("Rename") { startEditing() }
            Button("New Workspace") { store.addWorkspace() }
            Divider()
            Button("Delete Workspace", role: .destructive) {
                store.deleteWorkspace(ws.id)
            }
        }
    }

    private func startEditing() {
        draftName = ws.userNamed ? ws.name : ""
        isEditing = true
    }

    private func commitRename() {
        store.renameWorkspace(ws.id, to: draftName)
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }

    private func workspaceIcon(active: Bool, status: PaneAgentStatus?) -> some View {
        let kind = store.iconKind(for: ws)
        let isClaude: Bool = {
            if case .claude = kind { return true }
            return false
        }()
        return Group {
            if isClaude {
                ClaudeMascotIcon()
            } else if let sf = kind.sfSymbol {
                Image(systemName: sf)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(kind.letter)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isClaude ? Color.clear : ws.accent)
                if active && !isClaude {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            AgentStatusDot(status: status)
                .offset(x: 3, y: 3)
        }
        .shadow(color: active ? (isClaude ? Color(red: 0.92, green: 0.55, blue: 0.32).opacity(0.5) : ws.accent.opacity(0.5)) : .clear, radius: 8)
    }

    @ViewBuilder
    private func secondaryRow(summary: (status: PaneAgentStatus, since: Date)?, active: Bool) -> some View {
        if let summary, summary.status != .idle {
            HStack(spacing: 4) {
                Text(statusText(summary.status))
                    .foregroundStyle(statusTextColor(summary.status))
                    .fontWeight(.medium)
                if showsTimer(summary.status) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("· \(elapsedString(since: summary.since, now: ctx.date))")
                            .foregroundStyle(active ? Theme.text3 : Theme.text4)
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
        } else {
            Text(cwdLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(active ? Theme.text3 : Theme.text4)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func showsTimer(_ s: PaneAgentStatus) -> Bool {
        switch s {
        case .thinking, .tool, .compacting, .needsPermission: return true
        case .justCompleted, .idle:                           return false
        }
    }

    /// Compact mm:ss for the first hour, then h:mm. Most turns end inside a
    /// minute so we want second-precision early; long-running tools care
    /// about the gross magnitude, not seconds.
    private func elapsedString(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        if total < 3600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h\(m)m"
    }

    @ViewBuilder
    private func cardBorder(active: Bool, status: PaneAgentStatus?) -> some View {
        if let status, isWorking(status) {
            // Active turn: the comet replaces the static colored border and
            // makes it obvious from across the sidebar that something's
            // running. Compaction uses dual comets to look distinct.
            CardBorderTraveler(
                color: borderTravelerColor(status),
                cornerRadius: 9,
                dual: status == .compacting
            )
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    cardBorderColor(active: active, status: status),
                    lineWidth: cardBorderWidth(status: status)
                )
        }
    }

    private func isWorking(_ s: PaneAgentStatus) -> Bool {
        s == .thinking || s == .tool || s == .compacting
    }

    private func borderTravelerColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool: return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .compacting:      return Color(red: 0.43, green: 0.72, blue: 0.86)
        default:               return Color.white.opacity(0.2)
        }
    }

    private var cwdLine: String {
        let n = ws.panes.count
        let unit = String(localized: n == 1 ? "pane" : "panes")
        let focused = ws.panes[ws.focusedPane]?.workingDirectory
        let firstCwd = ws.panes.values.compactMap(\.workingDirectory).first
        let cwd = focused ?? firstCwd
        let shortCwd = cwd.map(prettyCwd) ?? String(localized: "no cwd")
        return "\(n) \(unit) · \(shortCwd)"
    }

    private func statusText(_ s: PaneAgentStatus) -> LocalizedStringKey {
        switch s {
        case .thinking:        return LocalizedStringKey("thinking…")
        case .tool:            return LocalizedStringKey("running tool")
        case .needsPermission: return LocalizedStringKey("needs approval")
        case .compacting:      return LocalizedStringKey("compacting…")
        case .justCompleted:   return LocalizedStringKey("✓ done")
        case .idle:            return LocalizedStringKey("")
        }
    }

    private func statusTextColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .needsPermission:  return Color(red: 1.0, green: 0.45, blue: 0.42)
        case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .idle:             return Theme.text4
        }
    }

    private func cardBorderColor(active: Bool, status: PaneAgentStatus?) -> Color {
        if let status, status != .idle {
            switch status {
            case .needsPermission:  return Color(red: 1.0, green: 0.32, blue: 0.29).opacity(0.85)
            case .justCompleted:    return Color(red: 0.30, green: 0.82, blue: 0.50).opacity(0.85)
            case .thinking, .tool:  return Color(red: 0.55, green: 0.50, blue: 0.95).opacity(0.55)
            case .compacting:       return Color(red: 0.35, green: 0.66, blue: 0.82).opacity(0.6)
            case .idle:             break
            }
        }
        return active ? ws.accent.opacity(0.45) : Color.white.opacity(0.04)
    }

    private func cardBorderWidth(status: PaneAgentStatus?) -> CGFloat {
        switch status {
        case .needsPermission, .justCompleted: return 1.5
        default:                                return 1
        }
    }

    private func prettyCwd(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Official Claude mark, bundled as an asset (`Claude.imageset`). Clipped
/// to the same squircle as the other workspace icons so it sits flush in
/// the sidebar row.
private struct ClaudeMascotIcon: View {
    var body: some View {
        Image("Claude")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Tiny circle in the squircle's corner reflecting the agent's mood:
///   thinking/tool → pulsing purple
///   waiting       → amber
///   needsPerm     → red
///   idle / nil    → invisible
private struct AgentStatusDot: View {
    let status: PaneAgentStatus?
    @State private var pulse = false

    var body: some View {
        Group {
            if let status, status != .idle {
                ZStack {
                    Circle()
                        .fill(color(for: status))
                        .overlay(
                            Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 1)
                        )
                    if status == .justCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 10, height: 10)
                .scaleEffect(needsPulse(status) && pulse ? 1.18 : 1.0)
                .opacity(needsPulse(status) && pulse ? 0.75 : 1.0)
                .animation(
                    needsPulse(status)
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear { pulse = true }
            }
        }
    }

    private func color(for s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .needsPermission:  return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .compacting:       return Color(red: 0.35, green: 0.66, blue: 0.82)
        case .justCompleted:    return Color(red: 0.30, green: 0.78, blue: 0.46)
        case .idle:             return .clear
        }
    }

    private func needsPulse(_ s: PaneAgentStatus) -> Bool {
        s == .thinking || s == .tool || s == .needsPermission || s == .compacting
    }
}

/// A comet of accent color orbits the workspace card border to indicate
/// indeterminate progress. Compaction passes `dual: true` so two opposing
/// spots travel together — visually distinct from a normal thinking turn.
private struct CardBorderTraveler: View {
    let color: Color
    let cornerRadius: CGFloat
    let dual: Bool
    @State private var angle: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: stops),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 1.2
            )
            .onAppear {
                withAnimation(.linear(duration: dual ? 1.4 : 2.0)
                    .repeatForever(autoreverses: false)) {
                        angle = 360
                    }
            }
    }

    private var stops: [Gradient.Stop] {
        if dual {
            return [
                .init(color: color.opacity(0.20), location: 0.00),
                .init(color: color.opacity(0.95), location: 0.10),
                .init(color: color.opacity(0.20), location: 0.30),
                .init(color: color.opacity(0.20), location: 0.55),
                .init(color: color.opacity(0.95), location: 0.72),
                .init(color: color.opacity(0.20), location: 0.88),
                .init(color: color.opacity(0.20), location: 1.00),
            ]
        }
        return [
            .init(color: color.opacity(0.18), location: 0.00),
            .init(color: color.opacity(0.18), location: 0.55),
            .init(color: color.opacity(0.95), location: 0.72),
            .init(color: color.opacity(0.18), location: 0.88),
            .init(color: color.opacity(0.18), location: 1.00),
        ]
    }
}
