import SwiftUI

// Per-pane agent summary — the always-visible status-dot CLUSTER plus the
// hover GLASS POPOVER that lists every live agent pane in a tab / workspace.
// Both read off the same rank-sorted `WorkspaceStore.AgentPaneInfo` list, so
// the glance layer and the detail layer never disagree. Used by the tab chip,
// the tab-overflow rows, the sidebar workspace card, and the switcher rows.

extension PaneAgentKind {
    /// The chrome icon kind that renders this agent's brand mark.
    var iconKind: WorkspaceIconKind {
        switch self {
        case .claude:   return .claude
        case .codex:    return .codex
        case .opencode: return .opencode
        case .devin:    return .devin
        }
    }
}

/// Localized status label — mirrors the tab/sidebar secondary-line wording so
/// the popover never drifts from the rows it summarizes.
func agentStatusLabel(_ s: PaneAgentStatus) -> String {
    switch s {
    case .thinking, .tool: return String(localized: "running…")
    case .needsPermission: return String(localized: "needs approval")
    case .compacting:      return String(localized: "compacting…")
    case .justCompleted:   return String(localized: "✓ done")
    case .failed:          return String(localized: "error")
    case .idle:            return ""
    }
}

/// Status text color — same palette as the sidebar/switcher secondary line.
func agentStatusLabelColor(_ s: PaneAgentStatus) -> Color {
    switch s {
    // Match the cluster beacon's amber so the pill and the dot read as one.
    case .thinking, .tool:  return Color(red: 1.0, green: 0.74, blue: 0.18)
    case .needsPermission:  return Color(red: 1.0,  green: 0.45, blue: 0.42)
    case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
    case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
    case .failed:           return Color(red: 0.96, green: 0.36, blue: 0.34)
    case .idle:             return Theme.text4
    }
}

/// Compact mm:ss (then h:mm) elapsed label — identical formatting to the
/// sidebar card's turn timer.
func agentElapsedLabel(since start: Date, now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
    return "\(total / 3600)h\((total % 3600) / 60)m"
}

// MARK: - Cluster (always-visible glance layer)

/// Up to `cap` attention-sorted status dots — one per live agent pane. This
/// replaces the single status beacon when more than one agent runs in a tab /
/// workspace, so a glance shows "two blocked, one running" without hovering.
/// Capped (default 3) so a busy workspace can't widen the tab chip; the full
/// list lives in the hover popover.
struct AgentStatusCluster: View {
    let infos: [WorkspaceStore.AgentPaneInfo]   // already rank-sorted
    var cap: Int = 3
    var dotSize: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            ForEach(infos.prefix(cap)) { info in
                AgentStatusBeacon(status: info.status, size: dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        infos.map { "\(String(localized: "Pane")) \($0.number) \($0.kind.displayName) \(agentStatusLabel($0.status))" }
            .joined(separator: ", ")
    }
}

// MARK: - Inline rows (detail layer for surfaces already inside a popover)

/// Compact per-pane rows that expand *inline* beneath a dropdown row — used by
/// the tab-overflow and workspace-switcher rows, where a nested hover popover
/// would be fragile. Indented under the parent's label with a hairline spine,
/// one line per live agent pane: dot · "Pane N · Agent" · status.
struct PaneSummaryInlineRows: View {
    let infos: [WorkspaceStore.AgentPaneInfo]
    /// Leading inset so the rows line up under the parent row's title (past
    /// its icon well).
    var indent: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(infos) { info in
                HStack(spacing: 7) {
                    AgentStatusBeacon(status: info.status, size: 6)
                    Text(info.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                    Text(info.kind.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.text4)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Spacer(minLength: 8)
                    Text(agentStatusLabel(info.status))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(agentStatusLabelColor(info.status))
                        .fixedSize()
                }
            }
        }
        .padding(.leading, indent)
        .padding(.top, 4)
        .overlay(alignment: .leading) {
            // Hairline spine, aligned just left of the dots.
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .padding(.leading, indent - 9)
                .padding(.vertical, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(infos.map {
            "\(String(localized: "Pane")) \($0.number) \($0.kind.displayName) \(agentStatusLabel($0.status))"
        }.joined(separator: ", ")))
    }
}

// MARK: - Hover popover (detail layer)

/// One pane's row: brand icon · "Pane N · Agent" · status · elapsed.
private struct PaneSummaryRow: View {
    let info: WorkspaceStore.AgentPaneInfo

    var body: some View {
        let tint = agentStatusLabelColor(info.status)
        HStack(spacing: 9) {
            TabIcon(kind: info.kind.iconKind, size: 21, status: info.status)
                .frame(width: 24, height: 24)

            // Tab name (as the chip shows it) + agent, single line each so a
            // narrow popover never breaks the label across two lines.
            (Text(info.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.text1)
             + Text("  \(info.kind.displayName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.text3))
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 16)

            // Status as a tinted pill — gives the color structure and makes
            // the state scannable down the column.
            Text(agentStatusLabel(info.status))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous).fill(tint.opacity(0.15))
                )

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(agentElapsedLabel(since: info.since, now: ctx.date))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
    }
}

/// The hover popover content: one row per live agent pane, on the same tinted
/// glass as the tab-overflow / workspace-switcher dropdowns. No header — the
/// rows are the whole story.
struct PaneSummaryPopover: View {
    let infos: [WorkspaceStore.AgentPaneInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(infos) { PaneSummaryRow(info: $0) }
        }
        .padding(5)
        // Hug content (every row is single-line via fixedSize) but never get
        // uncomfortably narrow with one short-status pane.
        .frame(minWidth: 228, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
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
        )
    }
}

/// Hover-to-peek wiring: after a short dwell, show the per-pane popover below
/// the anchor. No-op when the scope has no live agent panes. The popover is a
/// read-only peek — moving the pointer off the anchor dismisses it.
private struct PaneSummaryHover: ViewModifier {
    let infos: [WorkspaceStore.AgentPaneInfo]
    let store: WorkspaceStore
    var arrowEdge: Edge = .bottom
    /// Set true while the anchor is being dragged (e.g. tab reorder). A
    /// transient `.popover` consumes the outside mouse-down that would start
    /// the drag, so it must be fully suppressed — not just visually hidden —
    /// for the duration of the gesture.
    var suppressed: Bool = false
    @State private var show = false
    @State private var hoverTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering && !infos.isEmpty && !suppressed {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled { show = true }
                    }
                } else {
                    show = false
                }
            }
            .onChange(of: infos.isEmpty) { _, empty in
                if empty { show = false }
            }
            .onChange(of: suppressed) { _, now in
                // Drag started — kill any pending/open popover so it can't
                // eat the drag's mouse-down.
                if now { hoverTask?.cancel(); show = false }
            }
            .popover(isPresented: $show, arrowEdge: arrowEdge) {
                PaneSummaryPopover(infos: infos)
                    .environmentObject(store)
            }
    }
}

extension View {
    /// Attach the per-pane summary popover, shown on hover when `infos` is
    /// non-empty. `store` is passed explicitly because `.popover` content does
    /// not inherit the presenter's `@EnvironmentObject`. Pass `suppressed:
    /// true` while the anchor is being dragged so the popover doesn't fight
    /// the drag gesture.
    func paneSummaryPopover(_ infos: [WorkspaceStore.AgentPaneInfo],
                            store: WorkspaceStore,
                            arrowEdge: Edge = .bottom,
                            suppressed: Bool = false) -> some View {
        modifier(PaneSummaryHover(infos: infos, store: store,
                                  arrowEdge: arrowEdge, suppressed: suppressed))
    }
}
