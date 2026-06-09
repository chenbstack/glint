import SwiftUI

/// Settings window. Split into a left category sidebar and a right
/// scroll-content pane, mirroring glint's main chrome (tinted glass
/// sidebar + dark content). Controls live inside grouped cards with a
/// shared `SettingsCard` / `SettingsRow` / `SettingsDivider` vocabulary.
struct GlintSettingsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(
                    Group {
                        if store.glassEffect {
                            ZStack {
                                VisualEffectBackground(material: .sidebar)
                                LinearGradient(
                                    colors: [Theme.sidebarTintTop, Theme.sidebarTintBottom],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            }
                        } else {
                            Color(red: 0.094, green: 0.094, blue: 0.122)
                        }
                    }
                )
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.white.opacity(0.045)).frame(width: 1)
                }

            content
                .background(Theme.bgPane)
        }
        .frame(width: 760, height: 540)
        .background(Theme.bgWindow)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                GlintBrandMark()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 4)

            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.0)
                .foregroundStyle(Theme.text4)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { cat in
                    SettingsCategoryRow(
                        category: cat,
                        isSelected: cat == selected,
                        onSelect: { selected = cat }
                    )
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            HStack(spacing: 6) {
                Text("Glint")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text4)
                Text(versionLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(LocalizedStringKey(selected.title))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                if let subtitle = selected.subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text4)
                        .padding(.leading, 4)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (Esc)")
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selected {
                    case .general:    GeneralPane()
                    case .appearance: AppearancePane()
                    case .terminal:   TerminalPane()
                    case .agents:     AgentsPane()
                    case .shortcuts:  ShortcutsPane()
                    case .about:      AboutPane()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "v\(v)"
    }
}

// MARK: - Category model

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, terminal, agents, shortcuts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .terminal:   return "Terminal"
        case .agents:     return "Agents"
        case .shortcuts:  return "Shortcuts"
        case .about:      return "About"
        }
    }
    var subtitle: String? {
        switch self {
        case .general:    return "Startup, layout, updates"
        case .appearance: return "Theme, accent, glass"
        case .terminal:   return "Font, cursor, scrollback"
        case .agents:     return "Claude Code, Codex, hook routing"
        case .shortcuts:  return "Keyboard reference"
        case .about:      return nil
        }
    }
    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintbrush"
        case .terminal:   return "terminal"
        case .agents:     return "sparkle"
        case .shortcuts:  return "command"
        case .about:      return "info.circle"
        }
    }
    /// Accent for the icon chip when this row is selected. Cycles through
    /// the system palette so each category reads as its own destination.
    var tint: Color {
        switch self {
        case .general:    return Theme.accentBright
        case .appearance: return Color(red: 1.0, green: 0.55, blue: 0.55)
        case .terminal:   return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .agents:     return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .shortcuts:  return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .about:      return Theme.text3
        }
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? category.tint.opacity(0.22) : Color.white.opacity(0.05))
                    Image(systemName: category.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? category.tint : Theme.text3)
                }
                .frame(width: 22, height: 22)

                Text(LocalizedStringKey(category.title))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.text1 : Theme.text2)

                Spacer()
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
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var rowBg: Color {
        if isSelected { return Color.white.opacity(0.08) }
        if hover      { return Color.white.opacity(0.03) }
        return .clear
    }
}

// MARK: - Shared layout primitives

/// Grouped card with a section label above and a tinted glass body. Rows
/// inside are stacked vertically and separated by `SettingsDivider`.
struct SettingsCard<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "").uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(Theme.text4)

            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                        )
                )

            if let footer {
                Text(LocalizedStringKey(footer))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text4)
                    .padding(.leading, 2)
                    .padding(.top, 2)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let wip: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, wip: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.wip = wip
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text1)
                    if wip {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.35, blue: 0.35))
                            .frame(width: 6, height: 6)
                            .help("Not implemented yet")
                    }
                }
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

/// Compact key-cap pill, e.g. `⌘K`, used in the shortcuts list and footers.
struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
    }
}

/// Soft pill that conveys binary status (installed / not wired etc.).
struct StatusPill: View {
    enum Tone { case ok, neutral, warn }
    let label: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
    }

    private var color: Color {
        switch tone {
        case .ok:      return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .neutral: return Theme.text3
        case .warn:    return Color(red: 1.0, green: 0.74, blue: 0.32)
        }
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        SettingsCard("Language") {
            SettingsRow("Language",
                        subtitle: "Display language for Glint's UI.") {
                Picker("", selection: $store.preferredLanguage) {
                    Text("Follow system").tag("system")
                    Divider()
                    Text("English").tag("en")
                    Text("中文（简体）").tag("zh-Hans")
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsCard("Startup") {
            SettingsRow("Restore last workspace",
                        subtitle: "Re-select the workspace you had focused when Glint last quit.") {
                Toggle("", isOn: $store.restoreLastWorkspace)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Collapse sidebar on launch",
                        subtitle: "Start with the sidebar hidden. ⌘/ to toggle.") {
                Toggle("", isOn: $store.sidebarCollapsed)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        UpdatesCard()
    }
}

private struct UpdatesCard: View {
    @EnvironmentObject var updater: UpdaterController

    var body: some View {
        SettingsCard("Updates",
                     footer: "Glint uses Sparkle to check the GitHub Releases feed and install updates in place.") {
            SettingsRow("Check for updates automatically",
                        subtitle: "Glint will look for new releases in the background.") {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Check now",
                        subtitle: "Manually look for a new release right now.") {
                Button("Check") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

private struct AppearancePane: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        SettingsCard("Theme") {
            SettingsRow("Color scheme",
                        subtitle: "Glint is dark-mode only for now.") {
                StatusPill(label: "Dark", tone: .neutral)
            }
            SettingsDivider()
            SettingsRow("Accent",
                        subtitle: "Sets the highlight color across selection, focus rings, and active states.") {
                HStack(spacing: 6) {
                    ForEach(AccentOption.allCases) { opt in
                        Circle()
                            .fill(opt.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        opt.rawValue == store.accentName ? Color.white : Color.white.opacity(0.15),
                                        lineWidth: opt.rawValue == store.accentName ? 1.5 : 0.5
                                    )
                            )
                            .scaleEffect(opt.rawValue == store.accentName ? 1.1 : 1.0)
                            .animation(.easeOut(duration: 0.15), value: store.accentName)
                            .onTapGesture { store.accentName = opt.rawValue }
                    }
                }
            }
        }

        SettingsCard("Glass effect",
                     footer: "Turns vibrancy on or off for the sidebar and toolbar. Off gives a flat look — useful on older Macs.") {
            SettingsRow("Enable glass effect", subtitle: nil) {
                Toggle("", isOn: $store.glassEffect)
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    enum AccentOption: String, CaseIterable, Identifiable {
        case indigo, cyan, pink, orange, green
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .indigo: return Theme.accentBright
            case .cyan:   return Theme.cyan
            case .pink:   return Theme.pink
            case .orange: return Theme.orange
            case .green:  return Theme.green
            }
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject var store: WorkspaceStore

    /// Curated list of monospaced families we know ghostty can resolve.
    /// Extra families fall back to Menlo via the second `font-family` line
    /// in `applyGlintTheme`.
    private let fontFamilies = [
        "SF Mono", "Menlo", "Monaco", "Courier New",
        "JetBrains Mono", "Fira Code", "IBM Plex Mono",
    ]

    private let scrollbackChoices: [Int] = [1_000, 5_000, 10_000, 50_000, 100_000]

    var body: some View {
        SettingsCard("Font") {
            SettingsRow("Family", subtitle: "Used for all panes. Falls back to Menlo if missing.") {
                Picker("", selection: $store.terminalFontFamily) {
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow("Size", subtitle: "\(Int(store.terminalFontSize))pt") {
                HStack(spacing: 10) {
                    Slider(value: $store.terminalFontSize, in: 10...20, step: 1)
                        .frame(width: 160)
                    Text("\(Int(store.terminalFontSize))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }

        SettingsCard("Cursor") {
            SettingsRow("Style", subtitle: nil) {
                Picker("", selection: $store.terminalCursorStyle) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow("Blink", subtitle: nil) {
                Toggle("", isOn: $store.terminalCursorBlink)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        SettingsCard("Buffer", footer: "Scrollback is kept per-pane. Increasing this raises memory usage.") {
            SettingsRow("Scrollback", subtitle: "Lines retained per pane.") {
                Picker("", selection: $store.terminalScrollback) {
                    ForEach(scrollbackChoices, id: \.self) { n in
                        Text(n.formatted()).tag(n)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct AgentsPane: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        SettingsCard("Claude Code",
                     footer: "Glint auto-installs a reporter into ~/.claude/settings.json on launch. Existing hooks are preserved.") {
            SettingsRow("Status", subtitle: "Hooks merged into your Claude settings.") {
                HStack(spacing: 8) {
                    StatusPill(
                        label: store.claudeHooksInstalled ? "Installed" : "Not installed",
                        tone: store.claudeHooksInstalled ? .ok : .neutral
                    )
                    if store.claudeHooksInstalled {
                        Button("Uninstall") { store.uninstallClaudeHooks() }
                            .controlSize(.small)
                    } else {
                        Button("Install") { store.installClaudeHooks() }
                            .controlSize(.small)
                            .tint(store.accent)
                    }
                }
            }
            SettingsDivider()
            SettingsRow("Hook script",
                        subtitle: "Path of the bash reporter that posts to Glint's local socket.") {
                Text("~/.glint/hooks/glint-report.sh")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }

        SettingsCard("Codex",
                     footer: "Glint writes its hook entries into ~/.codex/hooks.json so codex sessions surface the same status as Claude.") {
            SettingsRow("Status", subtitle: "Hooks merged into your Codex config.") {
                HStack(spacing: 8) {
                    StatusPill(
                        label: store.codexHooksInstalled ? "Installed" : "Not installed",
                        tone: store.codexHooksInstalled ? .ok : .neutral
                    )
                    if store.codexHooksInstalled {
                        Button("Uninstall") { store.uninstallCodexHooks() }
                            .controlSize(.small)
                    } else {
                        Button("Install") { store.installCodexHooks() }
                            .controlSize(.small)
                            .tint(store.accent)
                    }
                }
            }
        }

        SettingsCard("Notifications",
                     footer: "Chimes only fire for background workspaces — the one you're looking at stays quiet.") {
            SettingsRow("Sound on permission request",
                        subtitle: "Play a chime when an agent is waiting for your approval in a background workspace.") {
                Toggle("", isOn: $store.soundOnPermissionRequest)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Sound on turn complete",
                        subtitle: "Play a softer chime when a background agent finishes its turn.") {
                Toggle("", isOn: $store.soundOnTurnComplete)
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        SettingsCard("Workspace") {
            shortcutRow("New Workspace", keys: ["⌘", "N"])
            SettingsDivider()
            shortcutRow("Next Workspace", keys: ["⌘", "↓"])
            SettingsDivider()
            shortcutRow("Previous Workspace", keys: ["⌘", "↑"])
        }
        SettingsCard("Panes") {
            shortcutRow("Split Horizontal", keys: ["⌘", "D"])
            SettingsDivider()
            shortcutRow("Split Vertical", keys: ["⌘", "⇧", "D"])
            SettingsDivider()
            shortcutRow("Close Pane", keys: ["⌘", "W"])
            SettingsDivider()
            shortcutRow("Focus Next Pane", keys: ["⌘", "]"])
        }
        SettingsCard("Window") {
            shortcutRow("Toggle Sidebar", keys: ["⌘", "/"])
            SettingsDivider()
            shortcutRow("Command Palette", keys: ["⌘", "K"])
            SettingsDivider()
            shortcutRow("Find in Sidebar", keys: ["⌘", "F"])
            SettingsDivider()
            shortcutRow("Settings", keys: ["⌘", ","])
            SettingsDivider()
            shortcutRow("Minimize", keys: ["⌘", "M"])
            SettingsDivider()
            shortcutRow("Hide Glint", keys: ["⌘", "H"])
            SettingsDivider()
            shortcutRow("Quit Glint", keys: ["⌘", "Q"])
        }
        SettingsCard("In Command Palette",
                     footer: "Visible only when the palette is open.") {
            shortcutRow("Move Selection Up", keys: ["↑"])
            SettingsDivider()
            shortcutRow("Move Selection Down", keys: ["↓"])
            SettingsDivider()
            shortcutRow("Run Selection", keys: ["⏎"])
            SettingsDivider()
            shortcutRow("Close Palette", keys: ["⎋"])
        }
    }

    private func shortcutRow(_ name: String, keys: [String]) -> some View {
        SettingsRow(name, subtitle: nil) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                    KeyCap(label: k)
                }
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                Image("GlintLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .shadow(color: Color(red: 0.95, green: 0.30, blue: 0.55).opacity(0.45),
                            radius: 18, y: 4)
                VStack(spacing: 4) {
                    Text("Glint")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(versionLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                    Text("A native mac terminal made for AI agents.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text4)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                    )
            )

            SettingsCard("Build") {
                SettingsRow("Version", subtitle: nil) {
                    Text(versionLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                }
                SettingsDivider()
                SettingsRow("Bundle ID", subtitle: nil) {
                    Text(bundleID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                }
                SettingsDivider()
                SettingsRow("Channel", subtitle: nil) {
                    StatusPill(label: channelLabel, tone: channelTone)
                }
                SettingsDivider()
                SettingsRow("Auto-update", subtitle: nil) {
                    StatusPill(label: "Sparkle 2.6", tone: .ok)
                }
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }
    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "app.glint.Glint"
    }

    /// Release builds stamp CFBundleVersion with a 12-digit YYYYMMDDHHmm
    /// timestamp via the CI workflow; locally-built debug bundles inherit
    /// the project's default "1" / Xcode-generated value. Use that shape
    /// as a fast proxy for "is this a released build."
    private var isReleaseBuild: Bool {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        return build.count >= 10 && build.allSatisfy(\.isNumber)
    }
    private var channelLabel: String { isReleaseBuild ? "Stable" : "Local Dev" }
    private var channelTone: StatusPill.Tone { isReleaseBuild ? .ok : .neutral }
}
