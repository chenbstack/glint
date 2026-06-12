import SwiftUI
import AppKit
import ImageIO

struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var usage: UsageStore
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    /// UUID of the workspace card currently mid-drag. Set by the dragged
    /// card's preview onAppear and cleared on the preview's onDisappear,
    /// so every sibling can render its insertion indicator relative to it.
    @State private var draggingWorkspaceID: UUID?
    /// Traffic lights vanish in full screen, so the reserved strip above
    /// the search field must vanish with them (same fix as ToolbarHeader's
    /// 78pt gutter).
    @State private var isFullscreen = false
    @State private var newWorkspaceHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // top spacer for traffic-light area (NSWindow draws them automatically here)
            Color.clear.frame(height: isFullscreen ? 8 : 38)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willEnterFullScreenNotification)) { _ in
                    isFullscreen = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willExitFullScreenNotification)) { _ in
                    isFullscreen = false
                }

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
                            WorkspaceCard(ws: ws, draggingID: $draggingWorkspaceID)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .animation(.spring(response: 0.32, dampingFraction: 0.85),
                               value: filteredWorkspaces.map(\.id))
                }
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)

            VStack(spacing: 0) {
                QuotaSection(claude: usage.claude, codex: usage.codex)
                newWorkspaceCard
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
        }
    }

    private var filteredWorkspaces: [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Workspace]
        if query.isEmpty {
            base = store.workspaces
        } else {
            base = store.workspaces.filter { ws in
                ws.displayName.lowercased().contains(query)
                    || ws.name.lowercased().contains(query)
            }
        }
        guard store.sortCompletedFirst else { return base }
        // Stable partition: `.justCompleted` first, preserving the user's
        // drag-assigned order within each group. Using enumerated() +
        // offset as the tiebreaker keeps the sort deterministic regardless
        // of `sorted(by:)` stability guarantees.
        func attention(_ e: Workspace) -> Bool {
            let s = store.agentSummary(for: e)?.status
            return s == .justCompleted || s == .failed   // both float: finished or errored
        }
        return base.enumerated().sorted { lhs, rhs in
            let lhsDone = attention(lhs.element)
            let rhsDone = attention(rhs.element)
            if lhsDone != rhsDone { return lhsDone }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var newWorkspaceCard: some View {
        Button {
            store.addWorkspace()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentBright)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent.opacity(newWorkspaceHovered ? 0.30 : 0.18))
                    )
                Text("New Workspace")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(newWorkspaceHovered ? Theme.text1 : Theme.text2)
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(newWorkspaceHovered ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        newWorkspaceHovered
                            ? Theme.accent.opacity(0.45)
                            : Theme.border
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newWorkspaceHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: newWorkspaceHovered)
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

/// Bottom-of-sidebar usage readout (above New Workspace). One row per agent
/// that currently has data: a name column, then two equal-width tracks — the
/// rolling session (5h) window and the weekly (7d) window — each captioned
/// with its percent and a compact reset countdown. Renders nothing when no
/// agent has data, so the divider+New Workspace sit flush as before.
private struct QuotaSection: View {
    let claude: AgentQuota?
    let codex: AgentQuota?

    /// Brand fills, matching the sidebar mascot shadows.
    private static let claudeColor = Color(red: 235/255, green: 140/255, blue: 82/255)
    private static let codexColor = Color(red: 82/255, green: 97/255, blue: 255/255)
    private static let warnColor = Color(red: 1.0, green: 0.745, blue: 0.18) // #FFBE2E

    var body: some View {
        if claude == nil && codex == nil {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                if let claude {
                    QuotaRow(name: "Claude", quota: claude,
                             color: Self.claudeColor, warn: Self.warnColor)
                }
                if let codex {
                    QuotaRow(name: "Codex", quota: codex,
                             color: Self.codexColor, warn: Self.warnColor)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.04))
                    )
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
    }
}

private struct QuotaRow: View {
    let name: String
    let quota: AgentQuota
    let color: Color
    let warn: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 40, alignment: .leading)

            // Recompute the reset countdowns every minute even between store
            // polls so "48m" visibly ticks down.
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                HStack(spacing: 8) {
                    QuotaColumn(
                        kind: "5h",
                        percent: quota.sessionPercent,
                        resetsAt: quota.sessionResetsAt,
                        now: ctx.date,
                        fill: color,
                        warn: quota.sessionIsWarn ? warn : nil
                    )
                    QuotaColumn(
                        kind: "7d",
                        percent: quota.weeklyPercent,
                        resetsAt: quota.weeklyResetsAt,
                        now: ctx.date,
                        fill: color.opacity(0.45),
                        warn: nil
                    )
                }
            }
        }
    }
}

/// One window track: caption (`5h 62% · 2h14m`) over a thin progress bar. A
/// nil percent renders a muted "—" with an empty track so a single-window
/// source still lines up under the other agent's two columns.
private struct QuotaColumn: View {
    let kind: String
    let percent: Double?
    let resetsAt: Date?
    let now: Date
    let fill: Color
    /// Non-nil → tint the percent + reset readout (approaching the limit).
    let warn: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(kind)
                    .foregroundStyle(Color(red: 0.365, green: 0.380, blue: 0.459)) // #5D6175
                Spacer(minLength: 2)
                if let percent {
                    Text("\(Int(percent.rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundStyle(warn ?? Theme.text2)
                    if let reset = resetText {
                        Text(reset)
                            .foregroundStyle(warn ?? Theme.text4)
                    }
                } else {
                    Text("—").foregroundStyle(Theme.text4)
                }
            }
            .font(.system(size: 9.5, design: .monospaced))
            .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(warn ?? fill)
                        .frame(width: geo.size.width * CGFloat(min(max((percent ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    /// Compact "time until reset": `6d8h` ≥1 day, `2h14m` ≥1 hour, else `48m`.
    private var resetText: String? {
        guard let resetsAt else { return nil }
        let secs = Int(resetsAt.timeIntervalSince(now))
        guard secs > 0 else { return "now" }
        let d = secs / 86_400
        let h = (secs % 86_400) / 3_600
        let m = (secs % 3_600) / 60
        if d >= 1 { return "\(d)d\(h)h" }
        if h >= 1 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}

private struct WorkspaceCard: View {
    @EnvironmentObject var store: WorkspaceStore
    /// System "Reduce Motion" — when on, the looping decorations (border
    /// glow, pulsing dots/borders, mascot animation) render as static states.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ws: Workspace
    @Binding var draggingID: UUID?

    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    /// Timestamp of the last reorder this card was the *target* of. Used
    /// to swallow the spring-animation sweep: after we swap, the target
    /// card slides under the cursor again mid-animation and SwiftUI re-
    /// fires `isTargeted`, which would bounce the dragged card back. A
    /// short cooldown matched to the spring response kills the oscillation
    /// without affecting genuine user-intent swaps onto a different card.
    @State private var lastTargetedAt: Date = .distantPast
    /// Hover affordance — drives the 1pt scale + soft shadow that makes
    /// cards feel "liftable" without being a heavy hover state. Driven
    /// by `.onHover`; doesn't touch ghostty.
    @State private var isHovered: Bool = false
    /// One-shot intensity for the green celebration when an agent's
    /// `.justCompleted` arrives: blooms 0 → 1 in ~0.12s, then exhales back
    /// to 0 over ~0.95s (the halo drifts outward as it fades). Re-armed
    /// only on a fresh transition into `.justCompleted`, so a re-render
    /// while the status is sticky doesn't re-fire.
    @State private var justCompletedFlash: Double = 0
    var body: some View {
        let active = store.selectedWorkspaceID == ws.id
        let summary = store.agentSummary(for: ws)
        let status = summary?.status
        HStack(alignment: .center, spacing: 10) {
            // Purely decorative for VoiceOver — the icon (incl. mascot GIF
            // and status dot) repeats what label/value below already say.
            workspaceIcon(active: active, status: status)
                .accessibilityHidden(true)
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                secondaryRow(summary: summary, active: active)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(cardBackground(active: active))
        // Border/flash/pulse overlays are decorative — hide from VoiceOver
        // so the combined element doesn't pick up phantom children.
        .overlay(cardBorder(active: active, status: status).accessibilityHidden(true))
        .overlay(completionFlashOverlay.accessibilityHidden(true))
        .overlay(permissionPulseOverlay(status: status).accessibilityHidden(true))
        .overlay(alignment: .leading) {
            workingBeaconOverlay(status: status).accessibilityHidden(true)
        }
        .scaleEffect(isHovered ? 1.005 : 1.0, anchor: .center)
        .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0),
                radius: isHovered ? 6 : 0,
                y: isHovered ? 2 : 0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering && !isEditing
        }
        .onChange(of: status) { oldStatus, newStatus in
            // One-shot green celebration on transition into .justCompleted.
            // Guard against re-rendering while the status is sticky —
            // we only want the flash on the actual edge. Two chained
            // animations on the same value: a fast bloom in, then a slow
            // exhale out — a hard 0→1 jump read as flicker, not as a glow.
            if newStatus == .justCompleted && oldStatus != .justCompleted {
                withAnimation(.easeIn(duration: 0.12)) {
                    justCompletedFlash = 1
                }
                withAnimation(.easeOut(duration: 0.95).delay(0.12)) {
                    justCompletedFlash = 0
                }
            }
        }
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
        // VoiceOver: the card is one tappable button. Name = workspace
        // name (verbatim — user data); value = the same status line the
        // card renders visually, with the elapsed time spelled out.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: ws.displayName))
        .accessibilityValue(Text(verbatim: accessibilityStatus(summary: summary)))
        .draggable(ws.id.uuidString) {
            // The preview view's lifecycle is the cleanest drag-lifecycle
            // signal SwiftUI exposes for `.draggable` — onAppear when the
            // drag session starts, onDisappear when it ends (drop OR
            // cancel). We use it to drive `draggingID` so sibling cards
            // can render their insert indicator and fade the source.
            dragPreview
                .onAppear { draggingID = ws.id }
                .onDisappear {
                    if draggingID == ws.id { draggingID = nil }
                }
        }
        .dropDestination(for: String.self) { items, _ in
            // The actual reorder already happened while hovering — see the
            // `isTargeted` branch below. Returning true just confirms the
            // drop so SwiftUI doesn't snap the preview back.
            guard let raw = items.first,
                  let sourceID = UUID(uuidString: raw),
                  sourceID != ws.id
            else { return false }
            return true
        } isTargeted: { targeted in
            // Real-time reorder: as soon as the cursor enters another card,
            // slide the dragged workspace into that slot. The ForEach's
            // spring animation handles the visual rearrangement.
            guard targeted,
                  let draggingID,
                  draggingID != ws.id,
                  let targetIdx = store.workspaces.firstIndex(where: { $0.id == ws.id })
            else { return }
            // Spring-sweep guard: after we swap, this same card animates
            // back under the cursor and `isTargeted` re-fires, which would
            // bounce the row back. Spring response is 0.32s; 0.35s
            // covers settling without blocking the user from dragging
            // onto a *different* card (each card has its own timestamp).
            let now = Date()
            if now.timeIntervalSince(lastTargetedAt) < 0.35 { return }
            lastTargetedAt = now
            store.moveWorkspace(id: draggingID, to: targetIdx)
        }
    }

    /// Invisible drag preview — we only need the view's lifecycle hooks to
    /// drive `draggingID`. The row reorders live under the cursor, so a
    /// floating ghost above the cursor just adds visual noise.
    private var dragPreview: some View {
        Color.clear.frame(width: 1, height: 1)
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
        let isCodex: Bool = {
            if case .codex = kind { return true }
            return false
        }()
        return Group {
            if isClaude {
                ClaudeMascotIcon(status: status)
            } else if isCodex {
                CodexMascotIcon(status: status)
            } else if let sf = kind.sfSymbol {
                // No squircle container — a bit larger so the bare glyph
                // holds the same visual weight as the mascots.
                Image(systemName: sf)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Text(kind.letter)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 28, height: 28)
        .overlay(alignment: .bottomTrailing) {
            AgentStatusDot(status: status)
                .offset(x: 3, y: 3)
        }
        .shadow(
            color: active
                ? (isClaude
                    ? Color(red: 0.92, green: 0.55, blue: 0.32).opacity(0.5)
                    : isCodex
                        ? Color(red: 0.32, green: 0.38, blue: 1.0).opacity(0.5)
                        : Theme.accent.opacity(0.5))
                : .clear,
            radius: 8
        )
    }

    @ViewBuilder
    private func secondaryRow(summary: (status: PaneAgentStatus, since: Date)?, active: Bool) -> some View {
        // Wrap the two branches in a single Group keyed off the row's
        // logical identity so SwiftUI treats a status flip as a view
        // replacement and the `.transition(.opacity)` actually fires.
        // Without the `.id(...)`, SwiftUI sees the same Text view with
        // changed text and snaps without crossfading.
        let key = secondaryRowKey(summary?.status)
        Group {
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
        .id(key)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: key)
    }

    /// Stable identity for the secondary row — bucket `idle` and `nil`
    /// together (both render the cwd line), and each real status keeps
    /// its own key so transitions between e.g. thinking → tool also
    /// crossfade rather than snapping mid-word.
    private func secondaryRowKey(_ s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle):       return "cwd"
        // Same key for thinking/tool → no pointless crossfade between two
        // identical "running…" labels when the agent flips between them.
        case .some(.thinking), .some(.tool): return "running"
        case .some(.needsPermission):   return "permission"
        case .some(.compacting):        return "compacting"
        case .some(.justCompleted):     return "done"
        case .some(.failed):            return "failed"
        }
    }

    private func showsTimer(_ s: PaneAgentStatus) -> Bool {
        switch s {
        case .thinking, .tool, .compacting, .needsPermission: return true
        case .justCompleted, .failed, .idle:                  return false
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

    /// Card surface fill — extracted so the body's modifier chain stays
    /// inside SwiftUI's type-inference budget. Three states: selected,
    /// hovered, idle; transitions are animated via the bound `value:`
    /// keys so they don't fight with the unrelated reorder spring on
    /// the parent VStack.
    private func cardBackground(active: Bool) -> some View {
        let fill: Color = {
            if active { return Color.white.opacity(0.09) }
            if isHovered { return Color.white.opacity(0.055) }
            return Color.white.opacity(0.03)
        }()
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: active)
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    /// One-shot green celebration driven by `justCompletedFlash`: a faint
    /// wash over the card fill, a crisp 1pt ring, and a soft halo that
    /// drifts outward as everything fades — light "exhaling" off the card
    /// rather than a flat blink. Decoupled from the regular static border
    /// so the celebration doesn't fight with the border color crossfade.
    /// Reduce Motion drops the drift and keeps the pure fade.
    private var completionFlashOverlay: some View {
        let green = Color(red: 0.40, green: 0.90, blue: 0.55)
        // flash 1 → 0 maps to scale 1.0 → 1.02: imperceptible during the
        // fast bloom, a visible outward drift across the slow exhale.
        let drift = reduceMotion ? 1.0 : 1.0 + (1.0 - justCompletedFlash) * 0.02
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(green.opacity(0.08))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(green.opacity(0.9), lineWidth: 1)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(green, lineWidth: 2)
                .blur(radius: 5)
                .scaleEffect(drift)
        }
        .opacity(justCompletedFlash)
        .allowsHitTesting(false)
    }

    /// While the agent is `.needsPermission`, render a soft amber border
    /// that breathes between 0.25 and 0.85 alpha on a 1.2s cycle. The
    /// breathing is a Core Animation opacity loop on the render server —
    /// a SwiftUI `repeatForever` here re-renders the card every frame on
    /// the main thread (see EdgeBeacon).
    @ViewBuilder
    private func permissionPulseOverlay(status: PaneAgentStatus?) -> some View {
        if status == .needsPermission {
            BreathingBorder(
                color: NSColor(Theme.accentBright),
                cornerRadius: 9,
                lineWidth: 1.4,
                // Reduce Motion: hold the border at full strength instead
                // of breathing — still unmistakably "needs attention".
                animates: !reduceMotion
            )
            .allowsHitTesting(false)
        }
    }

    private func cardBorder(active: Bool, status: PaneAgentStatus?) -> some View {
        // Running turns leave the border alone — the edge beacon and the
        // traffic-light pill carry "busy". The border only marks selection
        // and the permission state (done relies on its one-shot flash, not a
        // persistent border).
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(
                cardBorderColor(active: active, status: status),
                lineWidth: 1
            )
    }

    /// While a turn is running, a small accent bar breathes on the card's
    /// left edge — the busy signal lives there instead of the border.
    @ViewBuilder
    private func workingBeaconOverlay(status: PaneAgentStatus?) -> some View {
        if let status, isWorking(status) {
            EdgeBeacon(
                color: NSColor(Theme.accentBright),
                fast: status == .compacting,
                animates: !reduceMotion
            )
            .frame(width: 3, height: 30)
            .offset(x: -1)
            .allowsHitTesting(false)
        }
    }

    private func isWorking(_ s: PaneAgentStatus) -> Bool {
        s == .thinking || s == .tool || s == .compacting
    }

    private var cwdLine: String {
        let n = ws.panes.count
        let unit = String(localized: n == 1 ? "pane" : "panes")
        let focused = (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
        let firstCwd = ws.panes.values.compactMap(\.workingDirectory).first
        let cwd = focused ?? firstCwd
        let shortCwd = cwd.map(prettyCwd) ?? String(localized: "no cwd")
        // Surface the tab count only once it's meaningful (>1), so single-tab
        // workspaces read exactly as before.
        let tabN = ws.tabs.count
        if tabN > 1 {
            let tabUnit = String(localized: "tabs")
            return "\(tabN) \(tabUnit) · \(n) \(unit) · \(shortCwd)"
        }
        return "\(n) \(unit) · \(shortCwd)"
    }

    /// Spoken description for VoiceOver: the agent-status text the card
    /// already renders, plus a spelled-out elapsed time ("1 minute, 24
    /// seconds") when the visual row shows a timer. Idle cards read the
    /// same pane-count/cwd line they display.
    private func accessibilityStatus(summary: (status: PaneAgentStatus, since: Date)?) -> String {
        guard let summary, summary.status != .idle else { return cwdLine }
        var parts = [plainStatusText(summary.status)]
        if showsTimer(summary.status),
           let spoken = Self.spokenDurationFormatter.string(
               from: max(0, Date().timeIntervalSince(summary.since))) {
            parts.append(spoken)
        }
        return parts.joined(separator: ", ")
    }

    /// Plain-String twin of `statusText` — accessibilityValue needs a
    /// String, not a LocalizedStringKey.
    private func plainStatusText(_ s: PaneAgentStatus) -> String {
        switch s {
        case .thinking, .tool: return String(localized: "running…")
        case .needsPermission: return String(localized: "needs approval")
        case .compacting:      return String(localized: "compacting…")
        case .justCompleted:   return String(localized: "done")
        case .failed:          return String(localized: "error")
        case .idle:            return ""
        }
    }

    private static let spokenDurationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .full
        return f
    }()

    private func statusText(_ s: PaneAgentStatus) -> LocalizedStringKey {
        switch s {
        // thinking, tool and the post-tool output phase all read as one state —
        // the agent is busy. Showing distinct "thinking"/"running tool" labels
        // mislabeled output generation as "thinking", so they share one text.
        case .thinking, .tool: return LocalizedStringKey("running…")
        case .needsPermission: return LocalizedStringKey("needs approval")
        case .compacting:      return LocalizedStringKey("compacting…")
        case .justCompleted:   return LocalizedStringKey("✓ done")
        case .failed:          return LocalizedStringKey("error")
        case .idle:            return LocalizedStringKey("")
        }
    }

    private func statusTextColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .needsPermission:  return Color(red: 1.0, green: 0.45, blue: 0.42)
        case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .failed:           return Color(red: 0.96, green: 0.36, blue: 0.34)
        case .idle:             return Theme.text4
        }
    }

    /// One hue for every border: status semantics live in the traffic-light
    /// pill, the edge beacon, and (for done) the one-shot completion flash —
    /// so a persistent border only marks the one state that stays blocked on
    /// the user (permission), plus the current selection. A just-completed
    /// card draws no border of its own; selecting it shows the selection
    /// border like any other card.
    private func cardBorderColor(active: Bool, status: PaneAgentStatus?) -> Color {
        // Only the selected card shows a resting border; every other card is
        // borderless. Status-specific attention still comes through elsewhere:
        // needsPermission keeps its breathing pulse overlay, `.justCompleted`
        // its one-shot green flash, `.failed` its red traffic light + text.
        _ = status
        return active ? Theme.accent.opacity(0.45) : Color.clear
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
/// Animated Claude mascot driven by per-status GIFs (idle / thinking /
/// tool-call / working). The GIF carries the bulk of the motion; we
/// keep two extra interaction beats on top:
///   • Celebrate bounce — one-shot spring scale pop on the transition
///     into `.justCompleted`, pairs with the card's green halo flash.
///   • Tap squish — scale dip + spring rebound when the icon is clicked.
private struct ClaudeMascotIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: WorkspaceStore
    let status: PaneAgentStatus?
    @State private var celebrateScale: CGFloat = 1.0
    @State private var tapScale: CGFloat = 1.0

    /// The spark canvas (96px) has less padding than the mascot's 128px one
    /// (the spark fills ~80% vs the robot's ~55%), so each family gets its
    /// own oversize factor to land at the same visual icon size.
    private var isSpark: Bool { store.claudeIconStyle == .spark }

    var body: some View {
        // Reduce Motion: freeze the GIF on its first frame — the mascot
        // stays as the workspace icon, just without the looping animation.
        AnimatedGIFView(assetName: gifAssetName(for: status), animates: !reduceMotion)
            // The gif canvas pads the figure with transparent margin (room
            // for bounce/glow frames), so render bigger than the 28pt
            // layout slot to keep the figure itself at icon size; the
            // background is transparent so no clip.
            .frame(width: isSpark ? 34 : 40, height: isSpark ? 34 : 40)
            .frame(width: 28, height: 28)
            .scaleEffect(celebrateScale * tapScale, anchor: .bottom)
            .onChange(of: status) { oldStatus, newStatus in
                if newStatus == .justCompleted && oldStatus != .justCompleted {
                    celebrateScale = 1.22
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                        celebrateScale = 1.0
                    }
                }
            }
            .onTapGesture {
                tapScale = 0.85
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) {
                    tapScale = 1.0
                }
            }
    }

    /// Map the agent's status to the right Data Set in Assets.xcassets.
    /// Idle covers the "nothing's happening" cases (including the post-
    /// turn justCompleted window — the card already flashes green and
    /// the celebrate scale pops, the gif staying idle keeps the moment
    /// readable). Both icon families share the same state mapping; the
    /// spark family simply prefixes its datasets with "ClaudeSpark".
    private func gifAssetName(for s: PaneAgentStatus?) -> String {
        let prefix = isSpark ? "ClaudeSpark" : "Claude"
        switch s {
        case .none, .some(.idle), .some(.needsPermission), .some(.justCompleted), .some(.failed):
            return prefix + "Idle"
        case .some(.thinking):
            return prefix + "Thinking"
        case .some(.tool):
            return prefix + "ToolCall"
        case .some(.compacting):
            return prefix + "Compressing"
        }
    }
}

/// Codex's gradient-cloud mark (generate_codex_action_gifs.py), animated
/// per agent status the same way ClaudeMascotIcon is: working = blinking
/// cursor, thinking = sway + cursor fade, everything else = the static
/// idle frame. Done shares idle by design — the celebrate scale pop and
/// the corner badge's green light carry the moment.
private struct CodexMascotIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus?
    @State private var celebrateScale: CGFloat = 1.0
    @State private var tapScale: CGFloat = 1.0

    var body: some View {
        AnimatedGIFView(assetName: gifAssetName(for: status), animates: !reduceMotion)
            // The blob fills ~80% of the 128px canvas (the margin is
            // sway headroom), so 30pt renders the mark itself at ~24pt —
            // same visual size as the static CodexMark it replaced.
            .frame(width: 30, height: 30)
            .frame(width: 28, height: 28)
            .scaleEffect(celebrateScale * tapScale, anchor: .bottom)
            .onChange(of: status) { oldStatus, newStatus in
                if newStatus == .justCompleted && oldStatus != .justCompleted {
                    celebrateScale = 1.22
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                        celebrateScale = 1.0
                    }
                }
            }
            .onTapGesture {
                tapScale = 0.85
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) {
                    tapScale = 1.0
                }
            }
    }

    private func gifAssetName(for s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle), .some(.needsPermission), .some(.justCompleted), .some(.failed):
            return "CodexIdle"
        case .some(.thinking), .some(.compacting):
            return "CodexThinking"
        case .some(.tool):
            return "CodexWorking"
        }
    }
}

/// SwiftUI host for an animated GIF from Assets.xcassets (Data Set).
///
/// Playback deliberately does NOT use `NSImageView.animates`: that path
/// re-decodes the GIF on the main thread for every animation tick (ImageIO
/// shows up hot in samples) and dirties layout/display each frame — with a
/// few mascots looping, that alone held the whole app at ~15-20% CPU.
/// Instead each asset is decoded ONCE (cached for the app's lifetime, the
/// bitmaps are 128×128 so this is a few hundred KB) and played back by a
/// repeating `CAKeyframeAnimation` on the layer's `contents`, which runs
/// entirely in the render server — zero per-frame work in this process.
/// Internal (not private): SettingsView's icon-style picker reuses it for
/// its mascot preview swatch.
struct AnimatedGIFView: NSViewRepresentable {
    let assetName: String
    /// false (Reduce Motion) shows the GIF's first frame statically.
    var animates: Bool = true

    func makeNSView(context: Context) -> GIFLayerView {
        let view = GIFLayerView()
        view.apply(assetName: assetName, animates: animates)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GIFLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 28, height: 28))
    }

    func updateNSView(_ view: GIFLayerView, context: Context) {
        view.apply(assetName: assetName, animates: animates)
    }

    final class GIFLayerView: NSView {
        private static let animationKey = "glint.gif.contents"
        private var currentAsset: String?
        private var currentlyAnimating = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.minificationFilter = .trilinear
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(assetName: String, animates: Bool) {
            // No-op on SwiftUI's frequent re-renders with unchanged inputs,
            // so the loop isn't restarted mid-cycle every second.
            guard assetName != currentAsset || animates != currentlyAnimating else { return }
            currentAsset = assetName
            currentlyAnimating = animates
            applyToLayer()
        }

        /// Layer-backed views can be handed a fresh layer when re-parented
        /// or moved between windows, dropping our animation — re-apply.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToLayer()
        }

        private func applyToLayer() {
            guard let layer, let asset = currentAsset,
                  let gif = GIFFrameCache.shared.gif(named: asset) else { return }
            layer.removeAnimation(forKey: Self.animationKey)
            layer.contents = gif.frames.first
            guard currentlyAnimating, gif.frames.count > 1 else { return }
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.calculationMode = .discrete
            anim.values = gif.frames
            anim.keyTimes = gif.keyTimes
            anim.duration = gif.duration
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: Self.animationKey)
        }
    }
}

/// Decodes each GIF asset exactly once per app run. Main-thread only
/// (always reached via SwiftUI view updates).
private final class GIFFrameCache {
    static let shared = GIFFrameCache()

    struct DecodedGIF {
        let frames: [CGImage]
        /// `.discrete` keyframe timing: frames.count + 1 entries in 0…1;
        /// frame i is visible from keyTimes[i] to keyTimes[i+1].
        let keyTimes: [NSNumber]
        let duration: Double
    }

    private var cache: [String: DecodedGIF] = [:]

    func gif(named assetName: String) -> DecodedGIF? {
        if let hit = cache[assetName] { return hit }
        guard let data = NSDataAsset(name: assetName)?.data,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(src) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            delays.append(Self.frameDelay(src, i))
        }
        guard !frames.isEmpty else { return nil }
        let duration = max(delays.reduce(0, +), 0.01)
        var acc = 0.0
        var keyTimes: [NSNumber] = [0]
        for d in delays {
            acc += d
            keyTimes.append(NSNumber(value: acc / duration))
        }
        let gif = DecodedGIF(frames: frames, keyTimes: keyTimes, duration: duration)
        cache[assetName] = gif
        return gif
    }

    private static func frameDelay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        var unclamped = 0.0
        var clamped = 0.1
        if let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
            clamped = gifProps[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        } else if let pngProps = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            // APNG (the Codex icons): GIF transparency is 1-bit, so any
            // asset whose animation needs real alpha ships as APNG instead.
            unclamped = pngProps[kCGImagePropertyAPNGUnclampedDelayTime] as? Double ?? 0
            clamped = pngProps[kCGImagePropertyAPNGDelayTime] as? Double ?? 0.1
        }
        // Browsers clamp tiny delays to ~100ms; honor the unclamped value
        // when present but never spin faster than 50fps.
        return max(unclamped > 0 ? unclamped : clamped, 0.02)
    }
}

/// Traffic-light pill in the squircle's corner reflecting the agent's
/// mood: three lights in a dark capsule, the current one lit.
///   red    → needsPermission (blocked on the user)
///   yellow → thinking / tool / compacting (busy)
///   green  → justCompleted
///   idle / nil → invisible
private struct AgentStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus?

    var body: some View {
        Group {
            if let status, status != .idle {
                // The lit light's pulse runs as a Core Animation loop on
                // the render server — a SwiftUI `repeatForever` here
                // re-renders every frame on the main thread (see
                // EdgeBeacon).
                TrafficLightPill(
                    activeLight: light(for: status),
                    pulsing: needsPulse(status)
                )
                .frame(width: 20, height: 11)
            }
        }
    }

    private func light(for s: PaneAgentStatus) -> TrafficLightPill.Light {
        switch s {
        case .needsPermission, .failed:     return .red
        case .thinking, .tool, .compacting: return .yellow
        case .justCompleted, .idle:         return .green
        }
    }

    private func needsPulse(_ s: PaneAgentStatus) -> Bool {
        // Reduce Motion: render the light steady at full opacity — the
        // color alone carries the status.
        guard !reduceMotion else { return false }
        return s == .thinking || s == .tool || s == .needsPermission || s == .compacting
    }
}

/// A small accent bar breathing on the card's left edge indicates a
/// running turn (the Linear/Arc-style side beacon) — the card border
/// itself stays quiet while the agent works. `fast: true` (compaction)
/// breathes noticeably quicker so it reads as a distinct, busier state.
///
/// The breath is a `CABasicAnimation` looping the bar's opacity on the
/// render server. A SwiftUI `repeatForever` here is NOT offloaded to
/// Core Animation: the view graph re-resolves the display list every
/// frame on the main thread (~15% CPU with one spinner), starving the
/// main thread ghostty needs for frame presentation and tick processing.
private struct EdgeBeacon: NSViewRepresentable {
    let color: NSColor
    let fast: Bool
    /// false (Reduce Motion) holds the bar steady at full strength.
    let animates: Bool

    func makeNSView(context: Context) -> BeaconLayerView {
        let view = BeaconLayerView()
        view.apply(color: color, fast: fast, animates: animates)
        return view
    }

    func updateNSView(_ view: BeaconLayerView, context: Context) {
        view.apply(color: color, fast: fast, animates: animates)
    }

    final class BeaconLayerView: NSView {
        private static let breathKey = "glint.beacon.breath"
        private let bar = CALayer()
        private var color: NSColor = .clear
        private var fast = false
        private var animates = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.shadowOffset = .zero
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(color: NSColor, fast: Bool, animates: Bool) {
            guard color != self.color || fast != self.fast
                || animates != self.animates else { return }
            self.color = color
            self.fast = fast
            self.animates = animates
            configureLayers()
        }

        /// Layer-backed views can be handed a fresh layer when re-parented
        /// or moved between windows, dropping sublayers/animations.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLayers()
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            guard let layer, bounds.width > 1, bounds.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if bar.superlayer !== layer { layer.addSublayer(bar) }
            bar.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            bar.position = CGPoint(x: bounds.midX, y: bounds.midY)
            bar.cornerRadius = bounds.width / 2
            bar.backgroundColor = color.cgColor
            // The halo is the bar's own shadow, so animating the layer's
            // opacity breathes the bar and its glow in lockstep.
            bar.shadowColor = color.cgColor
            bar.shadowOpacity = 0.6
            bar.shadowRadius = 3
            CATransaction.commit()

            guard animates else {
                bar.removeAnimation(forKey: Self.breathKey)
                return
            }
            let duration: CFTimeInterval = fast ? 1.0 : 2.2
            if let existing = bar.animation(forKey: Self.breathKey),
               existing.duration == duration { return }
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.40
            breath.toValue = 1.0
            breath.duration = duration
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.isRemovedOnCompletion = false
            bar.add(breath, forKey: Self.breathKey)
        }
    }
}

/// The traffic-light status pill: a dark capsule with red/yellow/green
/// lights, the active one lit with a radial highlight + glow, the rest
/// dimmed. The busy-state pulse runs as a Core Animation scale/opacity
/// loop on the render server.
private struct TrafficLightPill: NSViewRepresentable {
    enum Light: Int {
        case red = 0, yellow = 1, green = 2

        /// (base, highlight) — macOS window-button palette.
        var colors: (CGColor, CGColor) {
            switch self {
            case .red:
                return (CGColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1),
                        CGColor(red: 1.00, green: 0.60, blue: 0.58, alpha: 1))
            case .yellow:
                return (CGColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1),
                        CGColor(red: 1.00, green: 0.87, blue: 0.54, alpha: 1))
            case .green:
                return (CGColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1),
                        CGColor(red: 0.49, green: 0.91, blue: 0.57, alpha: 1))
            }
        }
    }

    let activeLight: Light
    let pulsing: Bool

    func makeNSView(context: Context) -> PillLayerView {
        let view = PillLayerView()
        view.apply(activeLight: activeLight, pulsing: pulsing)
        return view
    }

    func updateNSView(_ view: PillLayerView, context: Context) {
        view.apply(activeLight: activeLight, pulsing: pulsing)
    }

    final class PillLayerView: NSView {
        private static let pulseKey = "glint.trafficlight.pulse"
        private let pill = CALayer()
        private let gloss = CAGradientLayer()
        private let lights = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]
        private var activeLight: Light = .yellow
        private var pulsing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for light in lights {
                light.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                light.type = .radial
                light.startPoint = CGPoint(x: 0.35, y: 0.65)
                light.endPoint = CGPoint(x: 1.0, y: 0.0)
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(activeLight: Light, pulsing: Bool) {
            guard activeLight != self.activeLight || pulsing != self.pulsing else { return }
            self.activeLight = activeLight
            self.pulsing = pulsing
            configureLayers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLayers()
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            guard let layer, bounds.width > 1, bounds.height > 1 else { return }
            // Gradient layers rasterize at contentsScale (default 1.0) —
            // without matching the backing scale the lights blur on Retina.
            let scaleFactor = window?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Near-black indigo capsule (the sidebar palette), separated
            // from whatever it overlaps by a drop shadow instead of a
            // solid cutout ring — adapts to icon and card alike.
            if pill.superlayer !== layer { layer.addSublayer(pill) }
            pill.frame = bounds
            pill.cornerRadius = bounds.height / 2
            pill.backgroundColor = CGColor(red: 0.055, green: 0.055, blue: 0.090, alpha: 1)
            pill.borderColor = CGColor(gray: 1.0, alpha: 0.10)
            pill.borderWidth = 0.5
            pill.shadowColor = CGColor(gray: 0, alpha: 1)
            pill.shadowOpacity = 0.55
            pill.shadowRadius = 2.5
            pill.shadowOffset = CGSize(width: 0, height: -0.5)
            pill.contentsScale = scaleFactor
            // Faint top-edge gloss so the capsule reads as a rounded body,
            // not a flat sticker.
            if gloss.superlayer !== layer { layer.addSublayer(gloss) }
            gloss.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
            gloss.cornerRadius = gloss.frame.height / 2
            gloss.colors = [CGColor(gray: 1.0, alpha: 0.07), CGColor(gray: 1.0, alpha: 0.0)]
            gloss.startPoint = CGPoint(x: 0.5, y: 1.0)
            gloss.endPoint = CGPoint(x: 0.5, y: 0.55)
            gloss.contentsScale = scaleFactor

            let pitch = bounds.width / 3.7
            for (i, light) in lights.enumerated() {
                if light.superlayer !== layer { layer.addSublayer(light) }
                let on = i == activeLight.rawValue
                let d: CGFloat = on ? 4.4 : 3.4
                light.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                light.position = CGPoint(x: bounds.midX + CGFloat(i - 1) * pitch, y: bounds.midY)
                light.cornerRadius = d / 2
                light.contentsScale = scaleFactor
                if on {
                    let (base, hi) = activeLight.colors
                    light.colors = [hi, base]
                    light.borderColor = CGColor(gray: 1.0, alpha: 0.22)
                    light.borderWidth = 0.5
                    light.shadowColor = base
                    light.shadowOpacity = 0.7
                    light.shadowRadius = 1.6
                    light.shadowOffset = .zero
                } else {
                    // Unlit sockets: visible enough that the three-light
                    // layout reads, dim enough not to compete with the lit one.
                    let dim = CGColor(gray: 1.0, alpha: 0.17)
                    light.colors = [dim, dim]
                    light.borderColor = CGColor(gray: 1.0, alpha: 0.10)
                    light.borderWidth = 0.5
                    light.shadowOpacity = 0
                }
            }
            CATransaction.commit()

            let active = lights[activeLight.rawValue]
            for light in lights where light !== active {
                light.removeAnimation(forKey: Self.pulseKey)
            }
            if pulsing {
                guard active.animation(forKey: Self.pulseKey) == nil else { return }
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0
                scale.toValue = 1.12
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.65
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 0.9
                group.autoreverses = true
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.isRemovedOnCompletion = false
                active.add(group, forKey: Self.pulseKey)
            } else {
                active.removeAnimation(forKey: Self.pulseKey)
            }
        }
    }
}

/// Amber "needs permission" border, breathing via a Core Animation
/// opacity loop on the render server. `animates: false` (Reduce Motion)
/// holds it steady at full strength.
private struct BreathingBorder: NSViewRepresentable {
    let color: NSColor
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> BorderLayerView {
        let view = BorderLayerView()
        view.apply(color: color, cornerRadius: cornerRadius,
                   lineWidth: lineWidth, animates: animates)
        return view
    }

    func updateNSView(_ view: BorderLayerView, context: Context) {
        view.apply(color: color, cornerRadius: cornerRadius,
                   lineWidth: lineWidth, animates: animates)
    }

    final class BorderLayerView: NSView {
        private static let breatheKey = "glint.permission.breathe"
        private let border = CAShapeLayer()
        private var color: NSColor = .clear
        private var cornerRadius: CGFloat = 9
        private var lineWidth: CGFloat = 1.5
        private var animates = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            border.fillColor = nil
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(color: NSColor, cornerRadius: CGFloat,
                   lineWidth: CGFloat, animates: Bool) {
            guard color != self.color || cornerRadius != self.cornerRadius
                || lineWidth != self.lineWidth || animates != self.animates
            else { return }
            self.color = color
            self.cornerRadius = cornerRadius
            self.lineWidth = lineWidth
            self.animates = animates
            configureLayers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLayers()
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            guard let layer, bounds.width > 1, bounds.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if border.superlayer !== layer {
                layer.addSublayer(border)
            }
            border.frame = bounds
            border.path = strokeBorderPath(in: bounds, cornerRadius: cornerRadius,
                                           lineWidth: lineWidth)
            border.strokeColor = color.cgColor
            border.lineWidth = lineWidth
            border.opacity = 0.85
            CATransaction.commit()
            if animates {
                guard border.animation(forKey: Self.breatheKey) == nil else { return }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.85
                breathe.toValue = 0.25
                breathe.duration = 1.2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breathe.isRemovedOnCompletion = false
                border.add(breathe, forKey: Self.breatheKey)
            } else {
                border.removeAnimation(forKey: Self.breatheKey)
            }
        }
    }
}

/// Path for a stroke that hugs the inside of `rect` (the CAShapeLayer
/// equivalent of SwiftUI's `strokeBorder`): inset by half the line width
/// so the stroke's outer edge lands exactly on the rect's edge.
private func strokeBorderPath(in rect: CGRect, cornerRadius: CGFloat,
                              lineWidth: CGFloat) -> CGPath {
    let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let radius = max(cornerRadius - lineWidth / 2, 0)
    return CGPath(roundedRect: inset, cornerWidth: radius,
                  cornerHeight: radius, transform: nil)
}

