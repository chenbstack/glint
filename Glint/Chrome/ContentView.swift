import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: WorkspaceStore

    /// Photos-style chrome (glass on): no header band — the terminal runs to
    /// the top of the window and the toolbar floats over it as glass islands.
    /// On macOS 26+ the islands use real Liquid Glass; pre-26 they use the
    /// in-house `GlassCapsuleFallback`. Glass off → stacked band layout.
    private var floatingHeader: Bool { store.glassEffect }

    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarCollapsed {
                // Exactly the pane area's color: ghostty paints an opaque
                // `background = 0B0A14` (= Theme.bgPane), so a flat fill
                // makes the two surfaces read as one, split only by the
                // hairline. (A Tahoe floating glass sidebar was tried and
                // rejected: with nothing but flat near-black behind it,
                // glass has nothing to refract and reads as a gray slab.)
                SidebarView()
                    .frame(width: 244)
                    .background(Theme.bgPane)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.white.opacity(0.045)).frame(width: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                if !floatingHeader {
                    ToolbarHeader()
                }
                PaneTreeView(node: store.currentRoot, workspaceID: store.selectedWorkspaceID)
                    // Floating mode overlaps the islands with the grid on
                    // purpose — scrollback passing under the glass is the
                    // effect. Fresh prompts are kept out from under the
                    // islands by the padded shell launcher (see
                    // GhosttyManager.paddedShellLauncherPath), not by
                    // insetting the layout.
                    .background(Theme.bgPane)
            }
            .background(Theme.bgPane)
            // Floating mode: the terminal owns the full height and the
            // toolbar's glass islands ride on top of it. The strip itself
            // is an invisible window-drag handle (see ToolbarHeader).
            .overlay(alignment: .top) {
                if floatingHeader {
                    ToolbarHeader()
                }
            }
        }
        .ignoresSafeArea()
        .background(Theme.bgWindow)
        .animation(.easeOut(duration: 0.18), value: store.sidebarCollapsed)
        .overlay {
            if store.commandPaletteOpen {
                CommandPalette()
                    .transition(
                        .asymmetric(
                            // In: fade + scale + 8pt Y drop, all on a
                            // springy curve so the panel feels weighted
                            // rather than snapping in. Out: simpler so it
                            // gets out of the way fast.
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.97))
                                .combined(with: .offset(y: -8)),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82),
                   value: store.commandPaletteOpen)
        .sheet(isPresented: $store.settingsOpen) {
            GlintSettingsView()
                .environmentObject(store)
        }
    }
}

// MARK: - Custom toolbar (in-content, not NSToolbar)

struct ToolbarHeader: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Traffic lights disappear in full screen, so the 78pt gutter we
    /// reserve for them (when the sidebar is collapsed) must collapse too
    /// or the toolbar starts with a dead zone.
    @State private var isFullscreen = false

    /// Photos-style floating chrome — same condition as
    /// `ContentView.floatingHeader`: islands of glass instead of a band.
    private var floating: Bool { store.glassEffect }

    var body: some View {
        HStack(spacing: 10) {
            // Leading island: sidebar toggle + wordmark share one glass
            // capsule (Photos' leading-cluster pattern). A bare wordmark
            // over the terminal is unreadable — text on text — so the brand
            // always needs glass between itself and the grid.
            HStack(spacing: 4) {
                ToolbarIconButton(
                    symbol: store.sidebarCollapsed ? "sidebar.left" : "sidebar.leading",
                    help: store.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar",
                    fontSize: 16
                ) {
                    store.sidebarCollapsed.toggle()
                }
                .keyboardShortcut("/", modifiers: .command)

                GlintBrandMark()
                    .padding(.trailing, 10)

                // With the sidebar collapsed the workspace switcher joins
                // the leading capsule (Photos-style cluster) instead of
                // floating as its own island; a hairline seam separates it
                // from the brand.
                if store.sidebarCollapsed {
                    if floating {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 1, height: 16)
                    }
                    WorkspaceSwitcher()
                        .padding(.leading, floating ? 0 : 6)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .liquidGlass(enabled: floating, cornerRadius: 19)
            .arrowPointer()

            // Tabs ride in the otherwise-empty middle of the header, centered
            // between the brand group and the trailing buttons. TabBar owns
            // the whole flexible middle (it needs to know its width to decide
            // how far to degrade chips), but renders nothing for a single-tab
            // workspace, so the header looks exactly as before until you open
            // a second tab. Empty space falls through to the header's drag
            // strip, so window drag keeps working.
            TabBar()
                .padding(.horizontal, 12)
            HStack(spacing: 4) {
                ToolbarIconButton(symbol: "command", help: "Command Palette (⌘K)") {
                    store.commandPaletteOpen = true
                }
                ToolbarIconButton(symbol: "gearshape", help: "Settings (⌘,)") {
                    store.settingsOpen = true
                }
            }
            // Tahoe-style grouped toolbar cluster: the two trailing buttons
            // share one resting glass capsule (38pt tall → radius 19). Pre-26
            // or glass-off, the buttons stay bare as before.
            .liquidGlass(enabled: store.glassEffect, cornerRadius: 19)
            .arrowPointer()
        }
        // Traffic lights take ~78pt when sidebar is collapsed; otherwise the
        // sidebar reserves that gutter for us. In full screen there are no
        // traffic lights at all.
        .padding(.leading, store.sidebarCollapsed && !isFullscreen ? 78 : 12)
        .padding(.trailing, 14)
        .frame(height: 52)
        // Invisible drag strip across the whole header: buttons and tabs
        // still win the click (they sit above), but every empty stretch —
        // including the gaps between floating islands — drags the window.
        // This trades away click-through to the terminal's top 52pt, which
        // only ever showed scrollback passing under the glass.
        .background(WindowDragSurface())
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        .background(
            // Floating mode draws no band at all — the islands carry their
            // own glass and the gaps stay click-through to the terminal.
            Group {
                if !floating {
                    if store.glassEffect {
                        ZStack {
                            VisualEffectBackground(material: .titlebar, allowsWindowDrag: true)
                            Theme.toolbarTint
                        }
                    } else {
                        // Flat — slightly lighter than sidebar so toolbar
                        // still reads as its own band.
                        Color(red: 0.118, green: 0.118, blue: 0.149)
                    }
                }
            }
        )
        .overlay(alignment: .bottom) {
            if !floating {
                Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
            }
        }
    }

}

// MARK: - Tabs (in-header, variant B: centered chips)

/// The centered cluster of tab chips that lives in the middle of the header.
/// Renders nothing until the current workspace has ≥2 tabs, so single-tab
/// users never see a lone chip — they open a second tab with ⌘T (or the
/// command palette), at which point the cluster appears with a "+" affordance.
///
/// When the middle of the header can't hold every chip at full size,
/// trailing chips fold into a "+N" capsule whose popover lists them in the
/// same style language as the workspace switcher. The active tab is never
/// folded away.
struct TabBar: View {
    @EnvironmentObject var store: WorkspaceStore
    /// TabID of the chip currently mid-drag (nil otherwise). Used to lift
    /// the dragged chip above its neighbours and skip it in the pointer
    /// hit-test below.
    @State private var draggingTabID: TabID?
    /// Live frame of every visible chip in `kTabReorderSpace`, populated
    /// from each chip's background GeometryReader. Same shape as the
    /// sidebar's reorder map but keyed by TabID and hit-tested on X.
    @State private var chipFrames: [TabID: CGRect] = [:]

    var body: some View {
        GeometryReader { geo in
            Group {
                if let ws = store.selectedWorkspace, ws.tabs.count >= 2 {
                    chips(ws: ws, available: geo.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Photos-style: the whole chip cluster shares one glass capsule (the
    /// active chip's accent fill reads as the selected segment).
    private var glassCluster: Bool { store.glassEffect }

    private func chips(ws: Workspace, available: CGFloat) -> some View {
        let plan = TabBarPlan(
            tabs: ws.tabs,
            activeID: ws.selectedTabID,
            names: ws.tabs.map { ws.tabDisplayName($0) },
            // The capsule's own padding eats into the strip.
            available: available - (glassCluster ? 8 : 0)
        )
        return HStack(spacing: 5) {
            ForEach(ws.tabs) { tab in
                if !plan.overflowed.contains(tab.id) {
                    TabChip(ws: ws, tab: tab,
                            isActive: tab.id == ws.selectedTabID,
                            isDragging: draggingTabID == tab.id,
                            onReorderChange: { pointerX in
                                handleReorderDrag(id: tab.id, pointerX: pointerX)
                            },
                            onReorderEnd: { handleReorderEnd() })
                        .background(
                            GeometryReader { gp in
                                Color.clear.preference(
                                    key: ChipFrameKey.self,
                                    value: [tab.id: gp.frame(in: .named(kTabReorderSpace))])
                            }
                        )
                        .zIndex(draggingTabID == tab.id ? 1 : 0)
                }
            }
            if !plan.overflowed.isEmpty {
                TabOverflowChip(
                    ws: ws,
                    tabs: ws.tabs.filter { plan.overflowed.contains($0.id) }
                )
            }
            NewTabButton { store.newTab() }
        }
        .coordinateSpace(name: kTabReorderSpace)
        .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
        // Uniform 4pt inset: 30pt chips → a 38pt capsule, the same height
        // and radius as the leading/trailing islands, with the chip pills
        // (radius 15) concentric to the capsule's 19.
        .padding(glassCluster ? 4 : 0)
        .liquidGlass(enabled: glassCluster, cornerRadius: 19)
        .arrowPointer()
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: plan)
        // Match the sidebar's reorder spring so chips slide into their
        // new slot the same way workspace cards do — keyed on the tab id
        // order so only an actual swap fires it.
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: ws.tabs.map(\.id))
    }

    /// Same shape as `SidebarView.handleReorderDrag`, just in 1D: ask the
    /// hit-test (which includes the dragged chip itself) for the nearest
    /// chip to the pointer, then let the `targetID != id` guard short-
    /// circuit when the pointer is still over the source. Excluding the
    /// source from the hit-test would trigger a premature swap the moment
    /// the drag started — the pointer would instantly map to a neighbour.
    private func handleReorderDrag(id: TabID, pointerX: CGFloat) {
        if draggingTabID != id { draggingTabID = id }
        guard let targetID = chipID(atPointerX: pointerX),
              targetID != id,
              let ws = store.selectedWorkspace,
              let targetIdx = ws.tabs.firstIndex(where: { $0.id == targetID })
        else { return }
        store.moveTab(id: id, to: targetIdx)
    }

    private func handleReorderEnd() {
        draggingTabID = nil
    }

    /// The visible chip whose measured frame the pointer X is over, clamped
    /// to the first/last when the pointer is past either edge.
    private func chipID(atPointerX x: CGFloat) -> TabID? {
        let ordered = chipFrames.sorted { $0.value.midX < $1.value.midX }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        if x <= first.value.midX { return first.key }
        if x >= last.value.midX { return last.key }
        // Pointer fell in an inter-chip gap — snap to the nearest midpoint.
        return ordered.min(by: { abs($0.value.midX - x) < abs($1.value.midX - x) })?.key
    }
}

private let kTabReorderSpace = "tabReorder"

/// Collects every rendered tab chip's frame, keyed by TabID.
private struct ChipFrameKey: PreferenceKey {
    static var defaultValue: [TabID: CGRect] = [:]
    static func reduce(value: inout [TabID: CGRect], nextValue: () -> [TabID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// "+" with a circular hover well, matching the toolbar icons' shape
/// language inside the glass capsule.
private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text3)
        .help("New Tab (⌘T)")
        .onHover { hovering = $0 }
    }
}

/// Decides, for a given available width, which tabs render as chips and
/// which fold into the "+N" overflow capsule.
///
/// Widths are estimated up front from the chip's known paddings plus a
/// measured (and cached) text width — the chips themselves stay `fixedSize`,
/// so the estimate only picks what overflows, it never squeezes a rendered
/// chip. Overflow always eats trailing tabs first and never touches the
/// active tab, so leading tabs stay readable.
private struct TabBarPlan: Equatable {
    var overflowed: Set<TabID> = []

    // Chip metrics that must mirror TabChip's layout: 9pt leading pad +
    // 15pt icon + 7pt gaps + 15pt trailing slot + 8pt trailing pad.
    private static let fullChrome: CGFloat = 61
    private static let chipGap: CGFloat = 5
    private static let newTabWidth: CGFloat = 26
    private static let overflowCapsuleWidth: CGFloat = 48

    init(tabs: [WorkspaceTab], activeID: TabID?, names: [String],
         available: CGFloat) {
        let n = tabs.count
        let activeIdx = tabs.firstIndex { $0.id == activeID } ?? 0
        let fullW: [CGFloat] = names.map { Self.fullChrome + Self.textWidth($0) }

        var hide = [Bool](repeating: false, count: n)
        func required() -> CGFloat {
            var sum: CGFloat = 0
            var visible = 0
            for i in 0..<n where !hide[i] {
                sum += fullW[i]
                visible += 1
            }
            var total = sum + CGFloat(max(visible - 1, 0)) * Self.chipGap
                + Self.chipGap + Self.newTabWidth
            if visible < n { total += Self.chipGap + Self.overflowCapsuleWidth }
            return total
        }

        // Few-pixel slack so a measurement that runs slightly long of
        // SwiftUI's own text layout can't leave a chip clipped at the edge.
        let budget = max(available - 4, 0)
        if required() > budget {
            for i in stride(from: n - 1, through: 0, by: -1) where i != activeIdx {
                hide[i] = true
                if required() <= budget { break }
            }
        }
        for i in 0..<n where hide[i] {
            overflowed.insert(tabs[i].id)
        }
    }

    /// AppKit-measured width of a chip label, capped to the chip's 150pt
    /// text limit. Cached: tab names change rarely, layout runs per frame
    /// during window resizes.
    private static var textWidthCache: [String: CGFloat] = [:]
    private static func textWidth(_ s: String) -> CGFloat {
        if let w = textWidthCache[s] { return w }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = min(ceil((s as NSString).size(withAttributes: [.font: font]).width), 150)
        textWidthCache[s] = w
        return w
    }
}

/// A single tab chip: agent/process icon + cwd-derived label + a trailing slot
/// that shows the agent status dot, swapping to a close (×) button on hover
/// (Safari-style). Active chips get a faint fill and an accent underline.
private struct TabChip: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    let tab: WorkspaceTab
    let isActive: Bool
    /// True while this chip is the one being dragged (drives the lift).
    var isDragging: Bool = false
    /// Reorder gesture callbacks (owned by `TabBar`): pointer X in
    /// `kTabReorderSpace` on every change, and a drag-ended signal.
    var onReorderChange: (CGFloat) -> Void = { _ in }
    var onReorderEnd: () -> Void = {}
    @State private var hovering = false
    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let kind = store.tabIconKind(tab, in: ws)
        let status = store.tabAgentStatus(tab, in: ws)
        HStack(spacing: 4) {
            TabIcon(kind: kind, size: 18, status: status)
                // Unselected tabs recede to bare dimmed text+icon in the
                // glass cluster, so the accent pill is the only chrome.
                .opacity(isActive || !inGlassCluster ? 1 : 0.7)
            if isEditing {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .frame(maxWidth: 150)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onAppear {
                        // Start the field with the user's current override
                        // (empty if the tab is still auto-named) — so empty-
                        // submit reverts to auto, matching renameTab.
                        draftName = tab.name ?? ""
                        DispatchQueue.main.async { nameFieldFocused = true }
                    }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused && isEditing { commitRename() }
                    }
            } else {
                Text(ws.tabDisplayName(tab))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? Theme.text1 : Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }
            trailingSlot(status: status)
        }
        .padding(.leading, 4)
        .padding(.trailing, 5)
        .frame(height: 30)
        .background {
            if inGlassCluster {
                // The selected tab is a muted accent-tinted capsule: hue
                // still carries selection (luminance alone turns to mud
                // on dark glass) but stays quiet — a solid bright pill
                // pulled the eye away from the terminal. Unselected tabs
                // are bare text that gains a faint capsule on hover.
                Capsule(style: .continuous)
                    .fill(chipFill)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(chipFill)
            }
        }
        .overlay(alignment: .bottom) {
            // Segmented-pill style carries selection in the fill; the
            // accent underline only belongs to the band layout.
            if isActive && !inGlassCluster {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(store.accent.opacity(0.9))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: ws.tabDisplayName(tab)))
        .onTapGesture {
            // Single-tap selects the tab. During edit the tap is the user
            // clicking into the field — don't steal the focus to selectTab.
            if !isEditing { store.selectTab(tab.id) }
        }
        .onHover { hovering = $0 && !isEditing }
        .help(ws.tabDisplayName(tab))
        .contextMenu {
            Button("Rename") { startEditing() }
        }
        // Lift the dragged chip above its neighbours — same shape as the
        // sidebar's WorkspaceCard, scaled down a touch since chips are
        // smaller and the header is shallow.
        .scaleEffect(isDragging ? 1.04 : 1.0, anchor: .center)
        .shadow(color: Color.black.opacity(isDragging ? 0.28 : 0),
                radius: isDragging ? 6 : 0, y: isDragging ? 2 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.14), value: isDragging)
        // Same manual reorder pattern as WorkspaceCard — pointer hit-test
        // against measured frames, driven by a min-distance drag so plain
        // clicks still select.
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(kTabReorderSpace))
                .onChanged { value in onReorderChange(value.location.x) }
                .onEnded { _ in onReorderEnd() }
        )
    }

    private func startEditing() {
        draftName = tab.name ?? ""
        isEditing = true
    }

    private func commitRename() {
        store.renameTab(tab.id, to: draftName)
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }

    /// Same condition as TabBar.glassCluster — chips restyle as segments
    /// when they live inside the glass capsule.
    private var inGlassCluster: Bool { store.glassEffect }

    private var chipFill: Color {
        // Slightly translucent so the glass still refracts through the
        // accent pill.
        if isActive { return inGlassCluster ? store.accent.opacity(0.28)
                                            : Color.white.opacity(0.08) }
        if hovering { return Color.white.opacity(inGlassCluster ? 0.07 : 0.04) }
        return .clear
    }

    /// Fixed-width trailing slot so the chip doesn't resize when the close
    /// button replaces the status dot on hover.
    @ViewBuilder
    private func trailingSlot(status: PaneAgentStatus?) -> some View {
        ZStack {
            if hovering {
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 15, height: 15)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.001)) // keep hit area
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? Theme.text2 : Theme.text3)
            } else if let status, status != .idle {
                AgentStatusBeacon(status: status)
            }
        }
        .frame(width: 15, height: 15)
    }
}

/// The agent status beacon: a single breathing dot shared by tab chips,
/// the overflow popover's rows, and the sidebar cards' icon badge, so all
/// three read as one system (macOS window-button palette):
///   red    → needsPermission / failed (blocked on the user)
///   yellow → thinking / tool / compacting (busy)
///   green  → justCompleted
/// Busy and blocked states breathe; green holds a steady glow.
struct AgentStatusBeacon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus

    var body: some View {
        StatusBeaconDot(
            color: Self.nsColor(status),
            // Reduce Motion: hold steady; the color carries the status.
            pulsing: !reduceMotion && Self.pulses(status),
            fast: status == .compacting
        )
        .frame(width: 7, height: 7)
    }

    /// Mirrors AgentStatusDot.needsPulse: anything that wants the user's
    /// eye — busy or blocked — breathes; terminal states don't.
    private static func pulses(_ s: PaneAgentStatus) -> Bool {
        s == .thinking || s == .tool || s == .needsPermission || s == .compacting
    }

    /// The macOS window-button palette's base colors.
    private static func nsColor(_ s: PaneAgentStatus) -> NSColor {
        switch s {
        case .needsPermission, .failed:
            return NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
        case .thinking, .tool, .compacting:
            return NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1)
        case .justCompleted:
            return NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)
        case .idle:
            return .clear
        }
    }
}

/// A glowing dot whose breath runs as a `CABasicAnimation` on the render
/// server — same rationale as SidebarView's EdgeBeacon: a SwiftUI
/// `repeatForever` re-resolves the view graph every frame on the main
/// thread, which starves ghostty's frame presentation.
private struct StatusBeaconDot: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool
    /// Compaction breathes quicker so it reads as a distinct, busier state
    /// (mirrors EdgeBeacon's fast mode).
    let fast: Bool

    func makeNSView(context: Context) -> DotLayerView {
        let view = DotLayerView()
        view.apply(color: color, pulsing: pulsing, fast: fast)
        return view
    }

    func updateNSView(_ view: DotLayerView, context: Context) {
        view.apply(color: color, pulsing: pulsing, fast: fast)
    }

    final class DotLayerView: NSView {
        private static let breathKey = "glint.tabdot.breath"
        private let dot = CALayer()
        private var color: NSColor = .clear
        private var pulsing = false
        private var fast = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dot.shadowOffset = .zero
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Always reconfigures, even when nothing changed: configuration is
        /// cheap and idempotent (the breath dedupes on duration), and SwiftUI
        /// hosting can hand the view a fresh backing layer without a
        /// window-move callback — re-asserting on every update is what keeps
        /// the animation from silently dropping.
        func apply(color: NSColor, pulsing: Bool, fast: Bool) {
            self.color = color
            self.pulsing = pulsing
            self.fast = fast
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
            if dot.superlayer !== layer { layer.addSublayer(dot) }
            dot.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
            dot.backgroundColor = color.cgColor
            // The glow is the dot's own shadow, so animating the layer's
            // opacity breathes the dot and its halo in lockstep.
            dot.shadowColor = color.cgColor
            dot.shadowOpacity = 0.65
            dot.shadowRadius = 3
            CATransaction.commit()

            guard pulsing else {
                dot.removeAnimation(forKey: Self.breathKey)
                return
            }
            // The design mockup's pulse, verbatim: `pulse 1.6s ease-in-out
            // infinite` with opacity 1 → 0.35 → 1. An autoreversing 0.8s
            // half-cycle is exactly that curve. Fast mode (compacting)
            // halves the cycle so it reads busier.
            let duration: CFTimeInterval = fast ? 0.4 : 0.8
            if let existing = dot.animation(forKey: Self.breathKey),
               existing.duration == duration { return }
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 1.0
            breath.toValue = 0.35
            breath.duration = duration
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.isRemovedOnCompletion = false
            dot.add(breath, forKey: Self.breathKey)
        }
    }
}

/// The little icon at the leading edge of a tab chip. Shares the sidebar's
/// animated brand mascots (`AnimatedGIFView` + `MascotAsset`) so a busy tab
/// loops the same thinking/tool-call motion its workspace card does. When the
/// agent is idle the GIF is frozen on its first frame (`animates: false`),
/// which is visually identical to the old static mark and costs nothing per
/// frame — only running tabs animate. Falls back to an SF Symbol / glyph for
/// plain shells and other tools.
private struct TabIcon: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: WorkspaceIconKind
    let size: CGFloat
    var status: PaneAgentStatus? = nil

    /// The mascot GIF canvases pad the figure with transparent margin (room
    /// for the motion), so drawn at `size` they read noticeably smaller than
    /// an SF Symbol at the same frame. Render them oversized inside the same
    /// `size` layout footprint — mirroring the sidebar's per-family ratios —
    /// so brand and glyph icons look optically equal.
    private var isSpark: Bool { store.claudeIconStyle == .spark }
    /// Only animate while the agent is actually busy; an idle tab freezes on
    /// the first frame so it stays as cheap as the old static icon.
    private var isBusy: Bool {
        switch status {
        case .some(.thinking), .some(.tool), .some(.compacting): return true
        default: return false
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .claude:
                AnimatedGIFView(assetName: MascotAsset.claude(for: status, isSpark: isSpark),
                                animates: !reduceMotion && isBusy)
                    .frame(width: size * (isSpark ? 1.21 : 1.43),
                           height: size * (isSpark ? 1.21 : 1.43))
            case .codex:
                AnimatedGIFView(assetName: MascotAsset.codex(for: status),
                                animates: !reduceMotion && isBusy)
                    .frame(width: size * 1.07, height: size * 1.07)
            default:
                if let sf = kind.sfSymbol {
                    Image(systemName: sf)
                        .font(.system(size: size * 0.82, weight: .medium))
                        .foregroundStyle(Theme.text2)
                } else {
                    Text(kind.letter)
                        .font(.system(size: size * 0.8, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The "+N" capsule that absorbs tabs the header can't fit even icon-only.
/// Clicking opens a popover listing the folded tabs — same glass styling as
/// the workspace switcher's dropdown, with select-on-click and hover-close.
private struct TabOverflowChip: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    let tabs: [WorkspaceTab]
    @State private var isOpen = false
    @State private var hover = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text("+\(tabs.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: inGlassCluster ? 12 : 6,
                                 style: .continuous)
                    .fill(capsuleFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(tabs.count) more tabs")
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.15), value: isOpen)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            TabOverflowPopover(ws: ws, tabs: tabs) { isOpen = false }
                .environmentObject(store)
        }
    }

    private var inGlassCluster: Bool { store.glassEffect }

    private var capsuleFill: Color {
        if isOpen { return Color.white.opacity(0.10) }
        if hover  { return Color.white.opacity(0.07) }
        return Color.white.opacity(0.04)
    }
}

private struct TabOverflowPopover: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    let tabs: [WorkspaceTab]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        TabOverflowRow(ws: ws, tab: tab) {
                            store.selectTab(tab.id)
                            dismiss()
                        }
                        .environmentObject(store)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 320)

            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)

            newTabRow
        }
        .frame(width: 260)
        .background(
            ZStack {
                // Tinted glass matching the workspace switcher popover so
                // both header dropdowns feel like the same surface.
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

    private var header: some View {
        HStack {
            Text("TABS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(Theme.text4)
            Spacer()
            Text("\(tabs.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Footer mirroring the workspace switcher's "New Workspace" row, so the
    /// two header dropdowns close on the same affordance.
    private var newTabRow: some View {
        Button {
            store.newTab()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.divider,
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .frame(width: 24, height: 24)
                Text("New Tab")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("⌘T")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}

/// A folded tab's row: icon in a soft squircle well, name over a live status
/// line (colored like the workspace switcher's rows), and a trailing slot
/// that swaps the breathing status dot for a close (×) on hover.
private struct TabOverflowRow: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    let tab: WorkspaceTab
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        let status = store.tabAgentStatus(tab, in: ws)
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    TabIcon(kind: store.tabIconKind(tab, in: ws), size: 15, status: status)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.tabDisplayName(tab))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(hover ? Theme.text1 : Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(secondaryText(status))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(status.flatMap(secondaryColor) ?? Theme.text4)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                trailingSlot(status: status)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Color.white.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    /// Fixed-size slot mirroring TabChip's: status dot at rest, close (×)
    /// on hover, so rows don't shift as the pointer moves down the list.
    @ViewBuilder
    private func trailingSlot(status: PaneAgentStatus?) -> some View {
        ZStack {
            if hover {
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
            } else if let status, status != .idle {
                AgentStatusBeacon(status: status)
            }
        }
        .frame(width: 16, height: 16)
    }

    /// Same vocabulary as the workspace switcher rows: a live status phrase
    /// while an agent is busy, otherwise the tab's pane count.
    private func secondaryText(_ status: PaneAgentStatus?) -> String {
        if let status, status != .idle {
            switch status {
            case .thinking, .tool: return String(localized: "running…")
            case .needsPermission: return String(localized: "needs approval")
            case .compacting:      return String(localized: "compacting…")
            case .justCompleted:   return String(localized: "✓ done")
            case .failed:          return String(localized: "error")
            case .idle:            break
            }
        }
        let n = tab.root.leaves.count
        return "\(n) \(String(localized: n == 1 ? "pane" : "panes"))"
    }

    private func secondaryColor(_ s: PaneAgentStatus) -> Color? {
        switch s {
        case .thinking, .tool:  return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .needsPermission:  return Color(red: 1.0, green: 0.45, blue: 0.42)
        case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .failed:           return Color(red: 0.96, green: 0.36, blue: 0.34)
        case .idle:             return nil
        }
    }
}

// MARK: - Brand mark

/// Glint wordmark: a custom-drawn four-point spark with an asymmetric long
/// Header toolbar icon button. The full square is hit-testable (via
/// `.contentShape(Rectangle())`) so a click that lands on padding still
/// fires — without it, `.buttonStyle(.plain)` lets the Image be the only
/// hit target and a 13pt SF Symbol leaves a lot of dead space inside the
/// button's frame.
private struct ToolbarIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var fontSize: CGFloat = 15
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .medium))
                .frame(width: 38, height: 38)
                .background(
                    // Circular hover well, inset so it always stays inside
                    // the surrounding glass capsule — a rounded square's
                    // corners poke past the capsule's end-cap curve and
                    // read as a misaligned dark blob over the terminal.
                    Circle()
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                        .padding(2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text3)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// vertical axis (the "glint" of light on a surface), set next to the
/// "Glint" wordmark in SF Pro semibold. The spark carries a cool gradient
/// + soft halo so it reads as the app's signature without needing an asset.
struct GlintBrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image("GlintLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .shadow(color: Color(red: 0.95, green: 0.30, blue: 0.55).opacity(0.35),
                        radius: 6, y: 0)
            Text("Glint")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .kerning(-0.2)
            #if DEBUG
            DevBadge()
            #endif
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Glint")
    }
}

#if DEBUG
private struct DevBadge: View {
    var body: some View {
        Text("DEV")
            .font(.system(size: 9, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.95, green: 0.30, blue: 0.55),
                                 Color(red: 0.55, green: 0.30, blue: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color(red: 0.95, green: 0.30, blue: 0.55).opacity(0.35),
                    radius: 4, y: 0)
            .accessibilityLabel("Development build")
    }
}
#endif

/// Asymmetric four-point spark — vertical arms are longer than horizontal,
/// matching the cliché "twinkle" silhouette without using SF Symbol's
/// `sparkle` (which is too generic and too AI-buzzword-y on its own).
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX, cy = rect.midY
        let vOuter = rect.height / 2
        let hOuter = rect.width / 2 * 0.72
        let vInner = rect.height * 0.14
        let hInner = rect.width * 0.14
        // top
        p.move(to: CGPoint(x: cx, y: cy - vOuter))
        // → right inner
        p.addQuadCurve(to: CGPoint(x: cx + hOuter, y: cy),
                       control: CGPoint(x: cx + hInner, y: cy - vInner))
        // → bottom
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + vOuter),
                       control: CGPoint(x: cx + hInner, y: cy + vInner))
        // → left
        p.addQuadCurve(to: CGPoint(x: cx - hOuter, y: cy),
                       control: CGPoint(x: cx - hInner, y: cy + vInner))
        // → close to top
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - vOuter),
                       control: CGPoint(x: cx - hInner, y: cy - vInner))
        p.closeSubpath()
        return p
    }
}

// MARK: - Workspace switcher (shown when sidebar is collapsed)

/// Replaces SwiftUI's `Menu` with a custom dark-mode popover so the dropdown
/// matches the rest of glint's chrome: tinted glass background, workspace
/// icons in the rows, status pulse dot per workspace, hover highlight, and
/// a chevron that animates between closed/open.
private struct WorkspaceSwitcher: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var isOpen = false
    @State private var hover = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 7) {
                if let ws = store.selectedWorkspace {
                    WorkspaceMicroIcon(ws: ws, kind: store.iconKind(for: ws), size: 16)
                }
                Text(currentName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.leading, glassPill ? 8 : 5)
            .padding(.trailing, glassPill ? 12 : 8)
            .padding(.vertical, glassPill ? 0 : 4)
            .frame(height: glassPill ? 38 : nil)
            .background {
                if glassPill {
                    // Lives inside the leading glass capsule (no glass of
                    // its own); this well only adds hover/open feedback,
                    // inset to match the buttons' circular wells.
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isOpen ? 0.10 : hover ? 0.06 : 0))
                        .padding(2)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(pillFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(pillStroke, lineWidth: 0.5)
                        )
                }
            }
            .animation(.easeOut(duration: 0.15), value: isOpen)
            .animation(.easeOut(duration: 0.12), value: hover)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            WorkspaceSwitcherPopover { isOpen = false }
                .environmentObject(store)
        }
    }

    /// Same condition as the other header islands — the pill restyles as a
    /// full-height glass capsule when the floating chrome is active.
    private var glassPill: Bool { store.glassEffect }

    private var pillFill: Color {
        if isOpen { return Color.white.opacity(0.10) }
        if hover  { return Color.white.opacity(0.07) }
        return Color.white.opacity(0.04)
    }
    private var pillStroke: Color {
        isOpen ? Color.white.opacity(0.14) : Color.white.opacity(0.06)
    }

    private var currentName: String {
        store.selectedWorkspace?.displayName ?? "Workspace"
    }
}

private struct WorkspaceSwitcherPopover: View {
    @EnvironmentObject var store: WorkspaceStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(store.workspaces) { ws in
                        WorkspaceSwitcherRow(
                            ws: ws,
                            isCurrent: ws.id == store.selectedWorkspaceID,
                            onSelect: {
                                store.selectWorkspace(ws.id)
                                dismiss()
                            }
                        )
                        .environmentObject(store)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 360)

            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)

            newWorkspaceRow
        }
        .frame(width: 280)
        .background(
            ZStack {
                // Tinted glass that matches the sidebar so the popover feels
                // like a free-floating extension of the same surface.
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

    private var header: some View {
        HStack {
            Text("WORKSPACES")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(Theme.text4)
            Spacer()
            Text("\(store.workspaces.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var newWorkspaceRow: some View {
        Button {
            store.addWorkspace()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.divider,
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .frame(width: 24, height: 24)
                Text("New Workspace")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("⌘N")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}

private struct WorkspaceSwitcherRow: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    let isCurrent: Bool
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        let kind = store.iconKind(for: ws)
        let summary = store.agentSummary(for: ws)
        Button(action: onSelect) {
            HStack(spacing: 10) {
                WorkspaceMicroIcon(ws: ws, kind: kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.displayName)
                        .font(.system(size: 13,
                                      weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Theme.text1 : Theme.text2)
                        .italic(!ws.userNamed)
                        .lineLimit(1)
                    Text(secondaryText(summary: summary))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(
                            (summary?.status).flatMap(secondaryColor)
                                ?? Theme.text4
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                trailingBadge(summary: summary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(rowBg)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private func trailingBadge(summary: (status: PaneAgentStatus, since: Date)?) -> some View {
        if isCurrent {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.accent)
        } else if let s = summary?.status, s != .idle {
            Circle()
                .fill(statusDotColor(s))
                .frame(width: 7, height: 7)
                .shadow(color: statusDotColor(s).opacity(0.6), radius: 3)
        }
    }

    private var rowBg: Color {
        if isCurrent { return Color.white.opacity(0.08) }
        if hover     { return Color.white.opacity(0.04) }
        return .clear
    }

    private func secondaryText(summary: (status: PaneAgentStatus, since: Date)?) -> String {
        if let s = summary, s.status != .idle {
            switch s.status {
            case .thinking, .tool: return String(localized: "running…")
            case .needsPermission: return String(localized: "needs approval")
            case .compacting:      return String(localized: "compacting…")
            case .justCompleted:   return String(localized: "✓ done")
            case .failed:          return String(localized: "error")
            case .idle:            break
            }
        }
        let n = ws.panes.count
        let unit = String(localized: n == 1 ? "pane" : "panes")
        let tabN = ws.tabs.count
        if tabN > 1 {
            return "\(tabN) \(String(localized: "tabs")) · \(n) \(unit)"
        }
        return "\(n) \(unit)"
    }

    private func secondaryColor(_ s: PaneAgentStatus) -> Color? {
        switch s {
        case .thinking, .tool:  return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .needsPermission:  return Color(red: 1.0, green: 0.45, blue: 0.42)
        case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .failed:           return Color(red: 0.96, green: 0.36, blue: 0.34)
        case .idle:             return nil
        }
    }

    private func statusDotColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .needsPermission:  return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .compacting:       return Color(red: 0.35, green: 0.66, blue: 0.82)
        case .justCompleted:    return Color(red: 0.30, green: 0.78, blue: 0.46)
        case .failed:           return Color(red: 0.90, green: 0.28, blue: 0.26)
        case .idle:             return .clear
        }
    }
}

/// Compact squircle that draws the workspace's icon kind (Claude mascot
/// asset, SF Symbol, or text glyph) at an arbitrary size. Used by the
/// switcher's pill (16pt) and popover rows (26pt).
private struct WorkspaceMicroIcon: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    let kind: WorkspaceIconKind
    let size: CGFloat

    var body: some View {
        let isClaude: Bool = {
            if case .claude = kind { return true }
            return false
        }()
        Group {
            if isClaude {
                Image(store.claudeIconStyle == .spark ? "ClaudeSpark" : "Claude")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let sf = kind.sfSymbol {
                Image(systemName: sf)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(kind.letter)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        // Bare glyphs, same as the sidebar cards (see workspaceIcon).
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}
