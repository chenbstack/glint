import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var usage: UsageStore
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    /// UUID of the workspace card currently mid-drag. Set by the dragged
    /// card's preview onAppear and cleared on the preview's onDisappear,
    /// so every sibling can render its insertion indicator relative to it.
    @State private var draggingWorkspaceID: UUID?
    /// Live frame (in the `kSidebarReorderSpace` coordinate space) of every
    /// rendered card, keyed by workspace id. Populated via a preference from
    /// each card's background GeometryReader. The reorder hit-tests the drag
    /// pointer against these frames — a deterministic "which card is the
    /// cursor over" that the flaky `.dropDestination`/`isTargeted` callbacks
    /// never gave us.
    @State private var cardFrames: [UUID: CGRect] = [:]
    /// Traffic lights vanish in full screen, so the reserved strip above
    /// the search field must vanish with them (same fix as ToolbarHeader's
    /// 78pt gutter).
    @State private var isFullscreen = false
    @State private var newWorkspaceHovered = false
    /// Tracks whether ⌘ is held so the cards can reveal their ⌘1…⌘9
    /// switch shortcuts (Spotlight-style modifier HUD).
    @StateObject private var cmdKey = CommandKeyObserver()

    var body: some View {
        VStack(spacing: 0) {
            // top spacer for traffic-light area (NSWindow draws them automatically here).
            // This strip is the sidebar's only window-drag handle.
            Color.clear.frame(height: isFullscreen ? 8 : 38)
                .background(WindowDragSurface())
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willEnterFullScreenNotification)) { _ in
                    isFullscreen = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willExitFullScreenNotification)) { _ in
                    isFullscreen = false
                }

            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .onChange(of: store.sidebarSearchFocusTick) { _, _ in
                        searchFocused = true
                    }

                ScrollView {
                    VStack(spacing: 0) {
                        workspacesSectionHeader(activeCount: filteredActiveWorkspaces.count,
                                                archivedCount: filteredArchivedWorkspaces.count)
                        VStack(spacing: 6) {
                            ForEach(filteredActiveWorkspaces) { ws in
                                WorkspaceCard(ws: ws,
                                              isDragging: draggingWorkspaceID == ws.id,
                                              shortcutBadge: cmdKey.commandHeld ? shortcutNumber(for: ws) : nil,
                                              onReorderChange: { pointerY in handleReorderDrag(id: ws.id, pointerY: pointerY) },
                                              onReorderEnd: { handleReorderEnd() })
                                    .background(
                                        GeometryReader { gp in
                                            Color.clear.preference(
                                                key: CardFrameKey.self,
                                                value: [ws.id: gp.frame(in: .named(kSidebarReorderSpace))])
                                        }
                                    )
                                    .zIndex(draggingWorkspaceID == ws.id ? 1 : 0)
                            }
                            // Archived list: same card style (variant B), no
                            // separator — just continues the scroll flow, so
                            // unarchiving feels like lifting an item back into
                            // the same list it already belongs to.
                            if store.archiveExpanded {
                                ForEach(filteredArchivedWorkspaces) { ws in
                                    WorkspaceCard(ws: ws, archived: true)
                                }
                            }
                        }
                        .coordinateSpace(name: kSidebarReorderSpace)
                        .onPreferenceChange(CardFrameKey.self) { cardFrames = $0 }
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                                   value: filteredActiveWorkspaces.map(\.id))
                        .animation(.easeInOut(duration: 0.18), value: store.archiveExpanded)
                    }
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)

                VStack(spacing: 0) {
                    QuotaSection(claude: usage.claude, codexHomes: usage.codexSidebarQuotas)
                    newWorkspaceCard
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
            }
            // From the search field down, empty stretches must NOT drag the
            // window (isMovableByWindowBackground would otherwise grab every
            // gap between cards).
            .background(NoDragSurface())
        }
        // Drag a folder from Finder onto the sidebar → open it as a workspace,
        // the same path as dropping it on the dock icon (WorkspaceStore.openURL
        // → openFolder). Files are ignored: drop a file on the terminal pane to
        // paste its path instead. The sidebar's internal reorder is a SwiftUI
        // DragGesture, not system drag-and-drop, so this doesn't clash with it.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadObject(ofClass: NSURL.self) { obj, _ in
                    guard let url = obj as? URL, Self.isDirectory(url) else { return }
                    DispatchQueue.main.async { store.openURL(url) }
                }
            }
            // Accept iff at least one provider can yield a file URL, so a
            // non-file drag (text, the sidebar's own cards) isn't swallowed.
            return providers.contains { $0.canLoadObject(ofClass: NSURL.self) }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: drag-to-reorder (manual gesture, deterministic pointer hit-test)

    /// A reorder drag moved: mark the source as dragging and slide it into
    /// whichever card the pointer is currently over. Driven by the card's
    /// `DragGesture.onChanged`, so it fires on *pointer* movement — layout
    /// shifts under a stationary pointer never trigger a phantom move (the
    /// fatal flaw of the `.dropDestination` approach).
    private func handleReorderDrag(id: UUID, pointerY: CGFloat) {
        if draggingWorkspaceID != id { draggingWorkspaceID = id }
        guard let targetID = cardID(atPointerY: pointerY),
              targetID != id,
              let targetIdx = store.workspaces.firstIndex(where: { $0.id == targetID })
        else { return }
        store.moveWorkspace(id: id, to: targetIdx)
    }

    private func handleReorderEnd() {
        draggingWorkspaceID = nil
    }

    /// The workspace whose measured card frame the pointer is over, clamped
    /// to the first/last card when the pointer is above/below the stack.
    private func cardID(atPointerY y: CGFloat) -> UUID? {
        let ordered = cardFrames.sorted { $0.value.midY < $1.value.midY }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        if y <= first.value.midY { return first.key }
        if y >= last.value.midY { return last.key }
        if let hit = ordered.first(where: { y >= $0.value.minY && y <= $0.value.maxY }) {
            return hit.key
        }
        // Pointer fell in an inter-card gap — snap to the nearest midpoint.
        return ordered.min(by: { abs($0.value.midY - y) < abs($1.value.midY - y) })?.key
    }

    /// The ⌘n shortcut that would select this workspace, or nil past ⌘9.
    /// Indexed against `store.activeWorkspaces` (the order ⌘1…⌘9 actually
    /// use — archived workspaces are skipped), NOT the filtered/sorted
    /// display order. Returns nil for archived workspaces so their cards
    /// never show a ⌘ badge while held.
    private func shortcutNumber(for ws: Workspace) -> Int? {
        guard let idx = store.activeWorkspaces.firstIndex(where: { $0.id == ws.id }),
              idx < 9 else { return nil }
        return idx + 1
    }

    private var filteredActiveWorkspaces: [Workspace] {
        filteredWorkspaces(from: store.activeWorkspaces, applySort: true)
    }

    private var filteredArchivedWorkspaces: [Workspace] {
        // Archived list: same search filter applies (so a query hides both
        // active and archived non-matches), but the "completed first" sort
        // doesn't — parked workspaces aren't running anything.
        filteredWorkspaces(from: store.archivedWorkspaces, applySort: false)
    }

    private func filteredWorkspaces(from source: [Workspace], applySort: Bool) -> [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Workspace]
        if query.isEmpty {
            base = source
        } else {
            base = source.filter { ws in
                ws.displayName.lowercased().contains(query)
                    || ws.name.lowercased().contains(query)
            }
        }
        guard applySort, store.sortCompletedFirst else { return base }
        // Stable 3-tier partition, preserving the user's drag-assigned order
        // within each tier. enumerated() + offset tiebreaker keeps the sort
        // deterministic regardless of `sorted(by:)` stability guarantees. The
        // ranking itself is shared with ⌘⇧A via `PaneAgentStatus.attentionRank`,
        // so the sidebar sort and the jump-to-attention target always agree.
        func rank(_ ws: Workspace) -> Int {
            store.agentSummary(for: ws)?.status.attentionRank ?? PaneAgentStatus.sinkAttentionRank
        }
        return base.enumerated().sorted { lhs, rhs in
            let lr = rank(lhs.element), rr = rank(rhs.element)
            if lr != rr { return lr < rr }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var newWorkspaceCard: some View {
        Button {
            store.requestNewWorkspace()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(store.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(store.accent.opacity(newWorkspaceHovered ? 0.30 : 0.18))
                    )
                Text("New Workspace")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(newWorkspaceHovered ? Theme.text1 : Theme.text2)
                Spacer()
            }
            .padding(8)
            // Bare row like the workspace list above: the accent "+" well
            // is the CTA anchor; hover gets the same faint wash as the
            // rows instead of a box + border.
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.overlay(newWorkspaceHovered ? 0.04 : 0))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text1)
                .focused($searchFocused)
                .overlay(alignment: .leading) {
                    // 自绘占位符:系统 placeholder 由 tertiaryLabel 渲染,亮色下偏淡
                    // 且不可控;用 Theme.text3 让明暗两侧都清晰。
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .allowsHitTesting(false)
                    }
                }
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
                .fill(Theme.overlay(searchFocused ? 0.09 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(searchFocused ? store.accent.opacity(0.5) : Theme.border, lineWidth: 1)
                )
        )
        // Make the entire pill hit-testable so clicking anywhere (the
        // magnifying glass, the empty padding, the trailing key hint) hands
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

    /// Workspaces header with an inline "已归档" text toggle on the right
    /// when there's at least one archived workspace (variant B from the
    /// archive prototypes). Active count sits in the usual mono slot, the
    /// toggle replaces what would normally be that count when archived
    /// exists — keeps the row a single line of chrome instead of stacking
    /// a second "ARCHIVED" header below.
    @ViewBuilder
    private func workspacesSectionHeader(activeCount: Int, archivedCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey("Workspaces"))
                .textCase(.uppercase)
                .font(.glintSection)
                .kerning(0.8)
                .foregroundStyle(Theme.text4)
            Spacer()
            Text("\(activeCount)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
            if archivedCount > 0 {
                archiveToggleButton(count: archivedCount)
            }
        }
        // Symmetric breathing room: search has 4pt below, so 6pt above the
        // label = 10pt search→label gap. 8pt below + the cards container's
        // 2pt top pad = 10pt label→cards gap, centering the label between
        // the two. Both archived states resolve to the same natural text
        // height so toggling Archived doesn't reflow anything.
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func archiveToggleButton(count: Int) -> some View {
        Button {
            store.archiveExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Archived")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(store.archiveExpanded ? Theme.text2 : Theme.text4)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(store.archiveExpanded ? Theme.text2 : Theme.text4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(store.archiveExpanded ? Theme.text2 : Theme.text4)
                    .rotationEffect(.degrees(store.archiveExpanded ? 0 : -90))
            }
            // Horizontal-only padding for click slack — vertical padding
            // would stretch the header row taller than the no-archive case
            // and reflow the list below it.
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Archived workspaces"))
        .accessibilityValue(Text("\(count)"))
    }

}

/// Bottom-of-sidebar usage readout (above New Workspace). One row per agent
/// that currently has data: a name column, then one or two source-defined
/// window tracks, each captioned with its percent and a compact reset countdown.
/// Renders nothing when no agent has data, so the divider+New Workspace sit
/// flush as before.
private struct QuotaSection: View {
    @EnvironmentObject var store: WorkspaceStore
    let claude: AgentQuota?
    let codexHomes: [CodexSidebarQuota]

    /// Brand fills, matching the sidebar mascot shadows.
    private static let claudeColor = Color(red: 235/255, green: 140/255, blue: 82/255)
    private static let codexColor = Color(red: 82/255, green: 97/255, blue: 255/255)
    private static let warnColor = Color(red: 1.0, green: 0.745, blue: 0.18) // #FFBE2E

    var body: some View {
        if claude == nil && codexHomes.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                if let claude {
                    QuotaRow(name: "Claude",
                             iconAsset: MascotAsset.claude(for: nil,
                                                           isSpark: store.claudeIconStyle == .spark),
                             quota: claude,
                             color: Self.claudeColor, warn: Self.warnColor)
                }
                ForEach(codexHomes) { item in
                    QuotaRow(name: item.name,
                             iconAsset: MascotAsset.codex(for: nil),
                             quota: item.quota,
                             color: Self.codexColor, warn: Self.warnColor)
                }
            }
            // Bare rows on the shared surface — the divider above the
            // bottom section already separates this block; a box around
            // read-only telemetry was chrome for chrome's sake.
            .padding(8)
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
    }
}

private struct QuotaRow: View {
    /// Used as the accessibility label + tooltip — the small mascot icon
    /// alone is enough visual ID, but VoiceOver still needs the agent name.
    let name: String
    /// Asset name for a static (animates:false) mascot GIF — same family
    /// the sidebar cards/tab chips use, just shrunk to a 18pt slot to free
    /// up the ~22pt the old "Claude"/"Codex" text labels were eating.
    let iconAsset: String
    let quota: AgentQuota
    let color: Color
    let warn: Color

    var body: some View {
        HStack(spacing: 12) {
            AnimatedGIFView(assetName: iconAsset, animates: false)
                // Mascot gifs have transparent margin around the figure; render
                // oversize then clip back so the figure itself fills the slot.
                .frame(width: 20, height: 20)
                .frame(width: 14, height: 14)
                .help(name)
                .accessibilityLabel(Text(verbatim: name))

            // Recompute the reset countdowns every minute even between store
            // polls so "48m" visibly ticks down.
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                HStack(spacing: 8) {
                    QuotaColumn(
                        kind: quota.primaryWindowLabel,
                        percent: quota.sessionPercent,
                        resetsAt: quota.sessionResetsAt,
                        now: ctx.date,
                        fill: color,
                        warn: quota.sessionIsWarn ? warn : nil
                    )
                    if quota.weeklyPercent != nil {
                        QuotaColumn(
                            kind: quota.secondaryWindowLabel,
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
}

/// One window track: caption (`5h 62% · 2h14m`) over a thin progress bar.
/// A nil percent degrades to a muted "—" with an empty track.
private struct QuotaColumn: View {
    let kind: String
    let percent: Double?
    let resetsAt: Date?
    let now: Date
    let fill: Color
    /// Non-nil → tint the percent + reset readout (approaching the limit).
    let warn: Color?

    /// Last line of defence against a non-finite percent reaching `Int(_:)`
    /// (a hard crash) — the store sanitizes upstream, but the renderer must
    /// never trust it. A NaN/Inf reading degrades to the muted "—" track.
    private var safePercent: Double? {
        guard let percent, percent.isFinite else { return nil }
        return percent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(kind)
                    .foregroundStyle(Color(red: 0.365, green: 0.380, blue: 0.459)) // #5D6175
                Spacer(minLength: 2)
                if let percent = safePercent {
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
                    Capsule().fill(Theme.overlay(0.09))
                    Capsule().fill(warn ?? fill)
                        .frame(width: geo.size.width * CGFloat(min(max((safePercent ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    /// Compact "time until reset": `6d8h` ≥1 day, `2h14m` ≥1 hour, else `48m`.
    private var resetText: String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        guard interval > 0 else { return "now" }
        // Clamp before the Int cast: an absurd-but-finite reset timestamp would
        // otherwise overflow `Int(_:)` and crash, same failure mode as the percent.
        // Bound well inside Int's range (Double(Int.max) rounds to 2^63, which
        // is itself untrappable-into-Int) — 1e12 s is ~31,000 years, plenty.
        let secs = Int(min(interval, 1e12))
        let d = secs / 86_400
        let h = (secs % 86_400) / 3_600
        let m = (secs % 3_600) / 60
        if d >= 1 { return "\(d)d\(h)h" }
        if h >= 1 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}

/// Publishes whether the Command key is currently held. Local monitor only —
/// fires while the app is active; deactivation force-clears the flag so a
/// ⌘Tab away never strands the badges on screen.
private final class CommandKeyObserver: ObservableObject {
    @Published var commandHeld = false
    private var monitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.commandHeld = event.modifierFlags.contains(.command)
            return event
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.commandHeld = false
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }
}

/// "⌘n" pill shown in a card's top-right corner while ⌘ is held.
private struct ShortcutBadge: View {
    let number: Int
    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "command")
                .font(.system(size: 8.5, weight: .semibold))
            Text("\(number)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        // Adaptive chip: a hardcoded black fill read as a muddy dark pill on a
        // light theme. Theme.overlay lightens on dark themes / darkens on light
        // ones, so the badge stays a subtle recessed chip in both — matching
        // the command-palette kbd style.
        .background(Capsule().fill(Theme.overlay(0.10)))
        .overlay(Capsule().stroke(Theme.overlay(0.08), lineWidth: 1))
    }
}

/// Coordinate space the reorder gesture and card-frame measurements share,
/// so a `DragGesture` location and a card's `frame(in:)` use the same origin.
private let kSidebarReorderSpace = "sidebarReorder"

/// Collects every rendered card's frame, keyed by workspace id.
private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct WorkspaceCard: View {
    @EnvironmentObject var store: WorkspaceStore
    /// System "Reduce Motion" — when on, the looping decorations (border
    /// glow, pulsing dots/borders, mascot animation) render as static states.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ws: Workspace
    /// When true the card renders the archived variant: same chrome, "已归档"
    /// badge in the secondary row instead of tab/pane counts, no ⌘ shortcut
    /// badge, no reorder gesture, and the context menu offers Unarchive
    /// instead of Archive. Defaults to false so the active-list call sites
    /// don't need to change.
    var archived: Bool = false
    /// True while this card is the one being dragged (drives the lift).
    var isDragging: Bool = false
    /// When non-nil, the card shows its ⌘n switch shortcut in the top-right
    /// corner (driven by the sidebar's ⌘-held observer).
    var shortcutBadge: Int? = nil
    /// Reorder gesture callbacks (owned by `SidebarView`): the pointer's
    /// y in `kSidebarReorderSpace` on every change, and a drag-ended signal.
    var onReorderChange: (CGFloat) -> Void = { _ in }
    var onReorderEnd: () -> Void = {}

    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
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
        // Per-pane cluster + hover popover only when more than one agent runs
        // here — a single agent's status is already on the icon + secondary row.
        let allPanes = store.workspacePaneSummary(ws)
        let multiInfos = allPanes.count >= 2 ? allPanes : []
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
                            store.isRenaming = focused
                            if !focused && isEditing { commitRename() }
                        }
                        // 兜底:WorkspaceCard 在 isEditing=true 时被外部操作(如
                        // contextMenu 的 Close Workspace / sidebar 刷新重 id)直接
                        // 销毁,@FocusState 的 onChange 不一定派发 false。漏掉就
                        // 让 store.isRenaming 卡 true,ContentView 的 click 监视
                        // 器会把无关 TextField(侧栏搜索等)的焦点也吹走。
                        .onDisappear { store.isRenaming = false }
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
            Spacer(minLength: 4)
            if !multiInfos.isEmpty {
                AgentStatusCluster(infos: multiInfos)
                    .accessibilityHidden(true)
            }
        }
        .padding(8)
        .background(cardBackground(active: active))
        // Flash/pulse overlays are decorative — hide from VoiceOver
        // so the combined element doesn't pick up phantom children.
        .overlay(completionFlashOverlay.accessibilityHidden(true))
        .overlay(permissionPulseOverlay(status: status).accessibilityHidden(true))
        .overlay(alignment: .leading) {
            workingBeaconOverlay(status: status).accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) {
            if let n = shortcutBadge {
                ShortcutBadge(number: n)
                    .padding(4)
                    .accessibilityHidden(true)
            } else if archived {
                archivedCornerMarker
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(isHovered ? 1.005 : 1.0, anchor: .center)
        .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0),
                radius: isHovered ? 6 : 0,
                y: isHovered ? 2 : 0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .paneSummaryPopover(multiInfos, store: store, arrowEdge: .trailing)
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
            if archived {
                Button("Unarchive") { store.unarchiveWorkspace(ws.id) }
                Button("Rename") { startEditing() }
                Divider()
                Button("Delete Workspace", role: .destructive) {
                    store.deleteWorkspace(ws.id)
                }
            } else {
                Button("Rename") { startEditing() }
                Button("New Workspace") { store.requestNewWorkspace() }
                Button("New Worktree from Here…") {
                    store.openNewWorkspace(repoHint: wsRepoHint)
                }
                if ws.source.isWorktree {
                    Button("Reveal Worktree in Finder") { store.revealWorktreeInFinder(ws.id) }
                }
                Divider()
                Button("Archive") { store.archiveWorkspace(ws.id) }
                if ws.source.isWorktree {
                    Button("Delete Worktree…", role: .destructive) { store.pendingWorktreeDelete = ws.id }
                }
                Button("Close Workspace", role: .destructive) {
                    store.deleteWorkspace(ws.id)
                }
            }
        }
        // VoiceOver: the card is one tappable button. Name = workspace
        // name (verbatim — user data); value = the same status line the
        // card renders visually, with the elapsed time spelled out.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: ws.displayName))
        .accessibilityValue(Text(verbatim: archived
                                 ? String(localized: "Archived")
                                 : accessibilityStatus(summary: summary)))
        // Lift the dragged card above its neighbours.
        .scaleEffect(isDragging ? 1.03 : 1.0, anchor: .center)
        .shadow(color: Color.black.opacity(isDragging ? 0.35 : 0),
                radius: isDragging ? 12 : 0, y: isDragging ? 5 : 0)
        .animation(.easeOut(duration: 0.14), value: isDragging)
        // Manual drag-to-reorder. We drive the whole interaction from the
        // pointer's absolute position (via the shared coordinate space)
        // instead of the system drag-and-drop's `.dropDestination`/
        // `isTargeted` callbacks, whose start/end timing on macOS was
        // unreliable (stale drag state → phantom moves). `minimumDistance`
        // keeps plain clicks (select) from starting a drag.
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(kSidebarReorderSpace))
                .onChanged { value in onReorderChange(value.location.y) }
                .onEnded { _ in onReorderEnd() },
            // Archived cards don't participate in the sidebar reorder (they
            // sit in a separate group below). Disable the gesture rather
            // than removing it so the call-site stays a single chain.
            including: archived ? .subviews : .all
        )
    }

    private func startEditing() {
        draftName = ws.userNamed ? ws.name : ""
        isEditing = true
    }

    /// Repo to pre-fill the New Worktree sheet with when launched from this card.
    private var wsRepoHint: String? {
        ws.source.repoRoot
            ?? (ws.selectedTab?.focusedPane).flatMap { ws.panes[$0]?.workingDirectory }
            ?? ws.panes.values.compactMap(\.workingDirectory).first
    }


    private func commitRename() {
        store.renameWorkspace(ws.id, to: draftName)
        isEditing = false
        store.isRenaming = false
    }

    private func cancelRename() {
        isEditing = false
        store.isRenaming = false
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
        let isOpenCode: Bool = {
            if case .opencode = kind { return true }
            return false
        }()
        let isDevin: Bool = {
            if case .devin = kind { return true }
            return false
        }()
        return Group {
            if isClaude {
                ClaudeMascotIcon(status: status)
            } else if isCodex {
                CodexMascotIcon(status: status)
            } else if isOpenCode {
                OpenCodeMascotIcon(status: status)
            } else if isDevin {
                DevinMascotIcon(status: status)
            } else if let sf = kind.sfSymbol {
                // No squircle container — a bit larger so the bare glyph
                // holds the same visual weight as the mascots.
                Image(systemName: sf)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text2)
            } else {
                Text(kind.letter)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(alignment: .bottomTrailing) {
            if !isOpenCode && !isDevin {
                AgentStatusDot(status: status)
                    .offset(x: 3, y: 3)
            }
        }
        .shadow(
            color: active
                ? (isClaude
                    ? Color(red: 0.92, green: 0.55, blue: 0.32).opacity(0.5)
                    : isCodex
                        ? Color(red: 0.32, green: 0.38, blue: 1.0).opacity(0.5)
                        : isOpenCode
                            ? Color(red: 0.95, green: 0.94, blue: 0.90).opacity(0.32)
                            : isDevin
                                ? Color(red: 0.16, green: 0.43, blue: 0.81).opacity(0.5)
                                : store.accent.opacity(0.5))
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
                workspaceMetadataRow(active: active)
            }
        }
        // Pin a constant row height so the card doesn't shrink ~1.5pt when the
        // metadata badges (idle) are replaced by the plain status line
        // (running). 16 ≥ the taller branch (the 9.5pt capsule badges), so the
        // idle height stays the reference and the running state grows to match.
        .frame(minHeight: 16, alignment: .leading)
        .id(key)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: key)
    }

    /// Top-right corner marker for archived cards — icon only, sits in the
    /// same slot as `ShortcutBadge` (archived workspaces are skipped by
    /// ⌘1…⌘9 so the two never collide). Replaces the old "Archived" capsule
    /// in the secondary row; the row itself is omitted for archived cards
    /// so they read as visually parked.
    private var archivedCornerMarker: some View {
        HStack(spacing: 3) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("Archived")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Theme.text2)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.overlay(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Theme.overlay(0.16), lineWidth: 0.5)
        )
    }

    private func workspaceMetadataRow(active: Bool) -> some View {
        HStack(spacing: 5) {
            if ws.source.isWorktree {
                tintedBadge("WT", fg: Color.black.opacity(0.82), bg: Theme.orange)
                if let branch = ws.source.branch {
                    let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
                    metadataBadge(leaf, active: active)
                }
                if let st = store.gitStatus(for: ws.id), st.dirtyCount > 0 {
                    tintedBadge("+\(st.dirtyCount)", fg: Color.black.opacity(0.82), bg: Theme.orange.opacity(0.8))
                }
            } else {
                if let tabs = tabCountText {
                    metadataBadge(tabs, active: active)
                }
                metadataBadge(paneCountText, active: active)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tintedBadge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(fg)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(bg))
    }

    private func metadataBadge(_ text: String, active: Bool) -> some View {
        // 选中:accent tinted,与卡片背景同语言 —— chip 跟着染色,但描边降到 0
        // 让它"融"在 card 里,不抢戏。
        // 未选:Codex 风的低噪 chip —— 极淡中性底 + 无描边,只读文字本身。
        // 之前 0.07 + stroke 在亮色下显得"工业塑料感",收掉就干净。
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(active ? AnyShapeStyle(store.accent) : AnyShapeStyle(Theme.text3))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? AnyShapeStyle(store.accent.opacity(0.14))
                                 : AnyShapeStyle(Theme.overlay(0.05)))
            )
    }

    /// Stable identity for the secondary row — bucket `idle` and `nil`
    /// together (both render the metadata row), and each real status keeps
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
            // 选中态只用 accent wash,不再叠左侧 indicator 条 —— wash 在浅色下
            // 微弱但仍可读,加竖条反而抢戏。idle 裸,hover 极淡黑/白 wash。
            if active { return store.accent.opacity(0.10) }
            if isHovered { return Theme.overlay(0.04) }
            return .clear
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
                color: NSColor(store.accent),
                cornerRadius: 9,
                lineWidth: 1.4,
                // Reduce Motion: hold the border at full strength instead
                // of breathing — still unmistakably "needs attention".
                animates: !reduceMotion
            )
            .allowsHitTesting(false)
        }
    }

    /// While a turn is running, a small accent bar breathes on the card's
    /// left edge — the busy signal lives there instead of the border.
    @ViewBuilder
    private func workingBeaconOverlay(status: PaneAgentStatus?) -> some View {
        if let status, isWorking(status) {
            EdgeBeacon(
                color: NSColor(store.accent),
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
        // Surface the tab count only once it's meaningful (>1), so single-tab
        // workspaces read exactly as before.
        if let tabs = tabCountText {
            return "\(tabs) · \(paneCountText)"
        }
        return paneCountText
    }

    private var paneCountText: String {
        let n = ws.panes.count
        let unit = String(localized: n == 1 ? "pane" : "panes")
        return "\(n) \(unit)"
    }

    private var tabCountText: String? {
        let n = ws.tabs.count
        guard n > 1 else { return nil }
        let unit = String(localized: "tabs")
        return "\(n) \(unit)"
    }

    /// Spoken description for VoiceOver: the agent-status text the card
    /// already renders, plus a spelled-out elapsed time ("1 minute, 24
    /// seconds") when the visual row shows a timer. Idle cards read the
    /// same metadata line they display.
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

}

/// Official Claude mark, bundled as an asset (`Claude.imageset`). Clipped
/// to the same squircle as the other workspace icons so it sits flush in
/// the sidebar row.
/// Status → Assets.xcassets Data Set name for the brand mascots. Shared by
/// the sidebar cards (ClaudeMascotIcon/CodexMascotIcon) and the header tab
/// chips (TabIcon) so both pick the same per-status animation from one place.
enum MascotAsset {
    /// Idle covers the "nothing's happening" cases (including the post-turn
    /// justCompleted window — the card already flashes and the celebrate
    /// scale pops, the gif staying idle keeps the moment readable). The
    /// spark family simply prefixes its datasets with "ClaudeSpark".
    static func claude(for s: PaneAgentStatus?, isSpark: Bool) -> String {
        let prefix = isSpark ? "ClaudeSpark" : "Claude"
        switch s {
        case .none, .some(.idle), .some(.needsPermission), .some(.justCompleted), .some(.failed):
            return prefix + "Idle"
        case .some(.thinking):   return prefix + "Thinking"
        case .some(.tool):       return prefix + "ToolCall"
        case .some(.compacting): return prefix + "Compressing"
        }
    }

    static func codex(for s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle), .some(.needsPermission), .some(.justCompleted), .some(.failed):
            return "CodexIdle"
        case .some(.thinking), .some(.compacting): return "CodexThinking"
        case .some(.tool):       return "CodexWorking"
        }
    }

    static func opencode(for s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle): return "OpenCodeIdle"
        case .some(.thinking): return "OpenCodeThinking"
        case .some(.tool): return "OpenCodeToolCall"
        case .some(.compacting): return "OpenCodeCompressing"
        case .some(.needsPermission): return "OpenCodeNeedsPermission"
        case .some(.justCompleted): return "OpenCodeDone"
        case .some(.failed): return "OpenCodeFailed"
        }
    }

    static func devin(for s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle): return "DevinIdle"
        case .some(.thinking): return "DevinThinking"
        case .some(.tool): return "DevinToolCall"
        case .some(.compacting): return "DevinCompressing"
        case .some(.needsPermission): return "DevinNeedsPermission"
        case .some(.justCompleted): return "DevinDone"
        case .some(.failed): return "DevinFailed"
        }
    }
}

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
        AnimatedGIFView(assetName: MascotAsset.claude(for: status, isSpark: isSpark),
                        animates: !reduceMotion)
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
        AnimatedGIFView(assetName: MascotAsset.codex(for: status), animates: !reduceMotion)
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
}

/// OpenCode's official aperture mark adapted to Glint's dark chrome. The
/// PNG/APNG assets keep the canvas transparent and carry state internally,
/// so the icon does not need a corner badge or extra frame.
private struct OpenCodeMascotIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus?
    @State private var celebrateScale: CGFloat = 1.0
    @State private var tapScale: CGFloat = 1.0

    var body: some View {
        AnimatedGIFView(assetName: MascotAsset.opencode(for: status), animates: !reduceMotion)
            .frame(width: 34, height: 34)
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
}

/// Devin's hexagonal logo, rendered per-status as tinted static PNGs —
/// same pattern as OpenCode: the per-status tint carries the state cue, so
/// the corner status dot is suppressed for Devin in `WorkspaceCard` (see the
/// `!isOpenCode && !isDevin` guard) rather than double-encoding the state.
private struct DevinMascotIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus?
    @State private var celebrateScale: CGFloat = 1.0
    @State private var tapScale: CGFloat = 1.0

    var body: some View {
        AnimatedGIFView(assetName: MascotAsset.devin(for: status), animates: !reduceMotion)
            .frame(width: 34, height: 34)
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
/// The status badge on a workspace card's icon: the same single breathing
/// dot the tab chips use (AgentStatusBeacon), so card and tab read as one
/// system. Replaced the old three-light traffic pill.
private struct AgentStatusDot: View {
    let status: PaneAgentStatus?

    var body: some View {
        if let status, status != .idle {
            AgentStatusBeacon(status: status)
        }
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
