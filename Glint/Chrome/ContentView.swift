import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarCollapsed {
                SidebarView()
                    .frame(width: 244)
                    .background(
                        Group {
                            if store.glassEffect {
                                ZStack {
                                    VisualEffectBackground(material: .sidebar)
                                    LinearGradient(
                                        colors: [Theme.sidebarTintTop, Theme.sidebarTintBottom],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing)
                                }
                            } else {
                                // Fully opaque flat surface — no vibrancy
                                // pass-through, no semi-transparent overlay.
                                Color(red: 0.094, green: 0.094, blue: 0.122)
                            }
                        }
                    )
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.white.opacity(0.045)).frame(width: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                ToolbarHeader()
                PaneTreeView(node: store.currentRoot)
                    .background(Theme.bgPane)
            }
            .background(Theme.bgPane)
        }
        .ignoresSafeArea()
        .background(Theme.bgWindow)
        .animation(.easeOut(duration: 0.18), value: store.sidebarCollapsed)
        .overlay {
            if store.commandPaletteOpen {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.commandPaletteOpen)
        .sheet(isPresented: $store.settingsOpen) {
            GlintSettingsView()
                .environmentObject(store)
        }
    }
}

// MARK: - Custom toolbar (in-content, not NSToolbar)

struct ToolbarHeader: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.sidebarCollapsed.toggle()
            } label: {
                Image(systemName: store.sidebarCollapsed
                      ? "sidebar.left"
                      : "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text3)
            .help(store.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
            .keyboardShortcut("/", modifiers: .command)

            GlintBrandMark()

            if store.sidebarCollapsed {
                WorkspaceSwitcher()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ToolbarIconButton(symbol: "command", help: "Command Palette (⌘K)") {
                    store.commandPaletteOpen = true
                }
                ToolbarIconButton(symbol: "gearshape", help: "Settings (⌘,)") {
                    store.settingsOpen = true
                }
            }
        }
        // Traffic lights take ~78pt when sidebar is collapsed; otherwise the
        // sidebar reserves that gutter for us.
        .padding(.leading, store.sidebarCollapsed ? 78 : 12)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(
            Group {
                if store.glassEffect {
                    ZStack {
                        VisualEffectBackground(material: .titlebar, allowsWindowDrag: true)
                        Theme.toolbarTint
                    }
                } else {
                    // Flat — slightly lighter than sidebar so toolbar still
                    // reads as its own band.
                    Color(red: 0.118, green: 0.118, blue: 0.149)
                }
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
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
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(pillFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(pillStroke, lineWidth: 0.5)
                    )
            )
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
            case .thinking:        return String(localized: "thinking…")
            case .tool:            return String(localized: "running tool")
            case .needsPermission: return String(localized: "needs approval")
            case .compacting:      return String(localized: "compacting…")
            case .justCompleted:   return String(localized: "✓ done")
            case .idle:            break
            }
        }
        let n = ws.panes.count
        let unit = String(localized: n == 1 ? "pane" : "panes")
        return "\(n) \(unit)"
    }

    private func secondaryColor(_ s: PaneAgentStatus) -> Color? {
        switch s {
        case .thinking, .tool:  return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .needsPermission:  return Color(red: 1.0, green: 0.45, blue: 0.42)
        case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .idle:             return nil
        }
    }

    private func statusDotColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .needsPermission:  return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .compacting:       return Color(red: 0.35, green: 0.66, blue: 0.82)
        case .justCompleted:    return Color(red: 0.30, green: 0.78, blue: 0.46)
        case .idle:             return .clear
        }
    }
}

/// Compact squircle that draws the workspace's icon kind (Claude mascot
/// asset, SF Symbol, or text glyph) at an arbitrary size. Used by the
/// switcher's pill (16pt) and popover rows (26pt).
private struct WorkspaceMicroIcon: View {
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
                Image("Claude")
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
        .background(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(isClaude ? Color.clear : ws.accent)
        )
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}
