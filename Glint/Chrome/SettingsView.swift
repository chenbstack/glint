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
                    Rectangle().fill(Theme.overlay(0.045)).frame(width: 1)
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
                            Circle().fill(Theme.overlay(0.06))
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
        // Local builds carry the non-numeric placeholder "dev" (CI stamps the
        // real version at release) — a "v" prefix only makes sense on numbers.
        return v.first?.isNumber == true ? "v\(v)" : v
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
}

private struct SettingsCategoryRow: View {
    @EnvironmentObject var store: WorkspaceStore
    let category: SettingsCategory
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? store.accent.opacity(0.22) : Theme.overlay(0.05))
                    Image(systemName: category.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? store.accent : Theme.text3)
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
        if isSelected { return Theme.overlay(0.08) }
        if hover      { return Theme.overlay(0.03) }
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
                        .fill(Theme.overlay(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.overlay(0.05), lineWidth: 0.5)
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
            .fill(Theme.overlay(0.04))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

/// Compact key-cap pill, e.g. `⌘⇧P`, used in the shortcuts list and footers.
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
                    .fill(Theme.overlay(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.overlay(0.06), lineWidth: 0.5)
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
                GlintDropdown(selection: $store.preferredLanguage, items: [
                    (value: "system", label: "Follow system"),
                    (value: "en", label: "English"),
                    (value: "zh-Hans", label: "中文（简体）"),
                ], listWidth: 170)
            }
        }

        SettingsCard("Workspace") {
            SettingsRow("Restore last workspace",
                        subtitle: "Re-select the workspace you had focused when Glint last quit.") {
                Toggle("", isOn: $store.restoreLastWorkspace)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Restore terminal history",
                        subtitle: "Restore each pane's previous scrollback (with colors) on launch. Running processes don't resume — only the text is restored.") {
                Toggle("", isOn: $store.restoreTerminalScrollback)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Float just-completed to top",
                        subtitle: "Bubble workspaces whose agent just finished a turn to the top of the sidebar. Sinks back when you open it.") {
                Toggle("", isOn: $store.sortCompletedFirst)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        SettingsCard("Startup") {
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
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        SettingsCard("Updates",
                     footer: "Glint uses Sparkle to check the GitHub Releases feed and install updates in place.") {
            SettingsRow("Check for updates automatically",
                        subtitle: "Glint will look for new releases in the background.") {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Receive beta updates",
                        subtitle: "Get pre-release builds early. Beta builds ship new work before it has fully settled.") {
                Toggle("", isOn: $updater.receiveBetaUpdates)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Check now",
                        subtitle: "Manually look for a new release right now.") {
                Button("Check") {
                    // Sparkle attaches its update dialog to the key window.
                    // The Settings sheet keeps the main window non-key, so
                    // the dialog gets stuck behind it — dismiss the sheet
                    // first, then kick off the check on the next runloop
                    // tick so AppKit has unwound the sheet.
                    store.settingsOpen = false
                    DispatchQueue.main.async {
                        updater.checkForUpdates()
                    }
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

private struct AppearancePane: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var browsingThemes = false

    /// 设置里只展示精选 + 「跟随 Ghostty」,全量 502 套走浏览器(搜索 + 实时预览),
    /// 否则这个网格会塞进 503 张卡片。当前选中若是某套 catalog 主题,把它也临时
    /// 拉进网格,这样用户能看到自己选的是哪套、不必再开浏览器确认。
    private var featuredCards: [GlintTheme] {
        var cards = ThemeRegistry.featured + [ThemeRegistry.followGhostty]
        if !cards.contains(where: { $0.id == store.themeName }) {
            cards.append(ThemeRegistry.theme(id: store.themeName))
        }
        return cards
    }

    var body: some View {
        SettingsCard("Theme") {
            VStack(alignment: .leading, spacing: 8) {
                Text("终端与界面共用一套配色,一键换肤。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 12
                ) {
                    ForEach(featuredCards) { theme in
                        ThemePreviewCard(theme: theme,
                                         selected: store.themeName == theme.id,
                                         accent: store.accent)
                            .onTapGesture { store.themeName = theme.id }
                    }
                }
                Button {
                    browsingThemes = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 11, weight: .medium))
                        Text("浏览全部 \(ThemeRegistry.catalog.count + ThemeRegistry.featured.count) 套主题")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(store.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.overlay(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Theme.overlay(0.08), lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.vertical, 2)
            .sheet(isPresented: $browsingThemes) {
                ThemeBrowserSheet()
                    .environmentObject(store)
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
                                        opt.rawValue == store.accentName ? Color.white : Theme.overlay(0.15),
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
                     footer: "Turns vibrancy on or off for the sidebar and toolbar. On macOS 26 this also enables Liquid Glass for the command palette, tabs and toolbar. Off gives a flat look — useful on older Macs.") {
            SettingsRow("Enable glass effect", subtitle: nil) {
                Toggle("", isOn: $store.glassEffect)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        SettingsCard("透明度与模糊",
                     footer: "让桌面从背后透出 —— 终端区与侧栏/工具栏可分开调。背景模糊把透出的桌面磨砂虚化,终端文字更易读。注:macOS 原生全屏下系统会禁用窗口透明。") {
            SettingsRow("终端透明度") {
                OpacityControl(value: $store.terminalOpacity)
            }
            SettingsDivider()
            SettingsRow("界面透明度", subtitle: "侧栏与工具栏") {
                OpacityControl(value: $store.chromeOpacity)
            }
            SettingsDivider()
            SettingsRow("背景模糊") {
                HStack(spacing: 10) {
                    Slider(value: $store.backgroundBlur, in: 0...60)
                        .frame(width: 150)
                    Text("\(Int(store.backgroundBlur.rounded()))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }

        SettingsCard("应用图标",
                     footer: "切换程序坞（Dock）中的图标。「默认」在 macOS 26 上保留 Liquid Glass 玻璃图标；其余配色为静态图标。") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 14) {
                ForEach(AppIconPreset.allCases) { preset in
                    VStack(spacing: 5) {
                        Image(preset.previewAsset)
                            .resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 46, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(preset == store.appIconPreset ? Theme.overlay(0.16) : .clear)
                                    .padding(-5)
                            )
                            .scaleEffect(preset == store.appIconPreset ? 1.06 : 1.0)
                            .animation(.easeOut(duration: 0.15), value: store.appIconPreset)
                        Text(preset.displayName)
                            .font(.system(size: 9.5, weight: preset == store.appIconPreset ? .semibold : .regular))
                            .foregroundStyle(preset == store.appIconPreset ? Theme.text1 : Theme.text2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.appIconPreset = preset }
                }
            }
            .padding(.vertical, 4)
        }
    }

    enum AccentOption: String, CaseIterable, Identifiable {
        case indigo, cyan, pink, orange, green
        var id: String { rawValue }
        var color: Color { Theme.accent(named: rawValue) }
    }
}

/// 主题预览卡片:一个 mini 终端(主题真实背景 + 彩色示例 + 16 色 palette 条)+ 名字。
/// 让用户看着配色选,而不是只读主题名。
private struct ThemePreviewCard: View {
    let theme: GlintTheme
    let selected: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("~/glint").foregroundStyle(theme.palette[safe: 4] ?? theme.foreground)
                        Text("git").foregroundStyle(theme.palette[safe: 3] ?? theme.foreground)
                        Text("push").foregroundStyle(theme.foreground)
                    }
                    HStack(spacing: 4) {
                        Text("✓").foregroundStyle(theme.palette[safe: 2] ?? theme.foreground)
                        Text("main").foregroundStyle(theme.palette[safe: 5] ?? theme.foreground)
                        Text("→ origin").foregroundStyle(theme.foreground.opacity(0.85))
                    }
                    HStack(spacing: 2) {
                        ForEach(Array(theme.palette.enumerated()), id: \.offset) { pair in
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(pair.element)
                                .frame(height: 5)
                        }
                    }
                    .padding(.top, 3)
                }
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? accent : Theme.overlay(0.10),
                                      lineWidth: selected ? 2 : 1)
                )

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent)
                        .font(.system(size: 13))
                        .padding(7)
                }
            }
            Text(theme.name)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.text1 : Theme.text2)
                .lineLimit(1)
                .padding(.leading, 2)
        }
        .contentShape(Rectangle())
    }
}

/// 透明度滑块 + 百分比标签。范围下限 0.3,避免拖到全透导致界面不可用。
private struct OpacityControl: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: 0.3...1.0)
                .frame(width: 150)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - 主题浏览器(全量 502+ 套:搜索 + 点击选中预览 + 确认应用)
//
// 设置卡只放精选;全量配色塞不进网格,所以走这个 sheet。每行一个 mini 配色条 +
// 名字。**点击某行 = 选中并把那套套到整窗预览**(终端 + chrome 一起),底部「应用」
// 按钮才真正持久化。取消 / 直接关 sheet = 放弃,还原回原主题。鼠标悬停只高亮,不变样。
private struct ThemeBrowserSheet: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// 是否已点「应用」。未应用就关闭 → onDisappear 还原。
    @State private var applied = false
    /// 当前点选(预览中)的主题 id;初始 = 已应用的真值。
    @State private var selectedID: String = ""
    @FocusState private var searchFocused: Bool

    /// featured 在前,catalog(已剔除撞 id 的)在后 —— 精选浮在顶上。
    private var allThemes: [GlintTheme] { ThemeRegistry.featured + ThemeRegistry.catalog }

    private var filtered: [GlintTheme] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allThemes }
        return allThemes.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
    }

    /// 选中的主题和已应用的真值不同 → 「应用」可点。
    private var dirty: Bool { selectedID != store.themeName }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().overlay(Theme.overlay(0.06))
            list
            Divider().overlay(Theme.overlay(0.06))
            footer
        }
        .frame(width: 540, height: 600)
        .background(Theme.bgWindow)
        .onAppear {
            selectedID = store.themeName
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear {
            // 没点「应用」就关 → 还原到已应用的真值(themeName 全程没被动过)。
            if !applied { store.previewTheme(id: store.themeName) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text3)
            TextField("搜索主题…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text1)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text4)
                }
                .buttonStyle(.plain)
            }
            Text("\(filtered.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { theme in
                        ThemeBrowserRow(
                            theme: theme,
                            isSelected: selectedID == theme.id,
                            isCurrent: store.themeName == theme.id,
                            accent: store.accent,
                            onPick: { select(theme.id) }
                        )
                        .id(theme.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onAppear {
                // 打开时滚到当前选中那行,用户立刻看到自己用的是哪套。
                proxy.scrollTo(store.themeName, anchor: .center)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("取消") { dismiss() }       // applied 仍为 false → onDisappear 还原
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.overlay(0.05))
                )

            Button("应用") { apply() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dirty ? .white : Theme.text4)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(dirty ? store.accent : Theme.overlay(0.05))
                )
                .disabled(!dirty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 点击行:选中 + 整窗预览(不持久化)。
    private func select(_ id: String) {
        selectedID = id
        store.previewTheme(id: id)
    }

    /// 点「应用」:把选中的主题持久化并关闭。
    private func apply() {
        applied = true
        store.themeName = selectedID    // didSet 持久化 + 套用
        dismiss()
    }
}

/// 主题浏览器的一行:左侧 mini 配色块(背景 + "Aa" 前景示例)、中间名字 + 明暗标签、
/// 右侧 16 色 palette 细条,最右选中态指示。点击 = 选中预览;悬停只高亮。
private struct ThemeBrowserRow: View {
    let theme: GlintTheme
    /// 当前点选(预览中)的行 —— accent 高亮。
    let isSelected: Bool
    /// 已应用的真值那一行 —— 显示「当前」标记。
    let isCurrent: Bool
    let accent: Color
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                // mini 配色块:真实背景 + 前景色 "Aa"
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.background)
                    Text("Aa")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.foreground)
                }
                .frame(width: 46, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.overlay(0.10), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(theme.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                            .lineLimit(1)
                        if isCurrent {
                            Text("当前")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule(style: .continuous).fill(accent.opacity(0.15))
                                )
                        }
                    }
                    Text(theme.isDark ? "Dark" : "Light")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.text4)
                }

                Spacer(minLength: 8)

                // 16 色 palette 细条
                HStack(spacing: 0) {
                    ForEach(Array(theme.palette.enumerated()), id: \.offset) { pair in
                        Rectangle().fill(pair.element).frame(width: 7, height: 16)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Theme.overlay(0.08), lineWidth: 0.5)
                )

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .symbolRenderingMode(isSelected ? .palette : .monochrome)
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(Theme.overlay(0.15)))
                    .frame(width: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12)
                          : hovering ? Theme.overlay(0.05) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.55) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var shellKeybindsInstallFailed = false

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
                GlintDropdown(selection: $store.terminalFontFamily,
                              items: fontFamilies.map { (value: $0, label: $0) },
                              listWidth: 230)
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
                GlintDropdown(selection: $store.terminalCursorStyle, items: [
                    (value: "block", label: "Block"),
                    (value: "bar", label: "Bar"),
                    (value: "underline", label: "Underline"),
                ], listWidth: 150)
            }
            SettingsDivider()
            SettingsRow("Blink", subtitle: nil) {
                Toggle("", isOn: $store.terminalCursorBlink)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        SettingsCard("Buffer", footer: "Scrollback is kept per-pane. Increasing this raises memory usage.") {
            SettingsRow("Scrollback", subtitle: "Lines retained per pane.") {
                GlintDropdown(selection: $store.terminalScrollback,
                              items: scrollbackChoices.map { (value: $0, label: $0.formatted()) },
                              listWidth: 150)
            }
        }

        SettingsCard("Paste") {
            SettingsRow("Warn before pasting multi-line text",
                        subtitle: "Ask first when the clipboard contains newlines or control characters — a multi-line paste into a shell prompt runs each line immediately.") {
                Toggle("", isOn: $store.warnBeforeUnsafePaste)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        SettingsCard("Shell keybindings",
                     footer: "Writes the bindings to ~/.config/glint/ and adds a single source line to ~/.zshrc (and ~/.bashrc if present) so modified keys behave sensibly at the shell prompt instead of inserting a raw escape like ;2;13~ or 1;2C. Covers Shift/Ctrl+Enter, Shift/Ctrl/Alt + arrows, Home/End and Delete (Ctrl+←/→ jump by word). Off by default. Doesn't affect Claude/Codex panes, which use these keys themselves.") {
            SettingsRow("Normalize modified keys",
                        subtitle: shellKeybindsInstallFailed
                        ? "Install failed — check Console for [glint] logs."
                        : (store.shellKeybindsInstalled
                           ? "Installed — open a new shell for it to take effect."
                           : "Not installed.")) {
                HStack(spacing: 8) {
                    StatusPill(
                        label: store.shellKeybindsInstalled ? "Installed" : "Not installed",
                        tone: store.shellKeybindsInstalled ? .ok : .neutral
                    )
                    if store.shellKeybindsInstalled {
                        Button("Uninstall") {
                            store.uninstallShellKeybinds()
                            shellKeybindsInstallFailed = false
                        }
                            .controlSize(.small)
                    } else {
                        Button("Install") {
                            store.installShellKeybinds()
                            shellKeybindsInstallFailed = !store.shellKeybindsInstalled
                        }
                            .controlSize(.small)
                            .tint(store.accent)
                    }
                }
            }
        }

        SettingsCard("External control",
                     footer: "Exposes a local socket under ~/.glint/run/ so other apps on this Mac can focus panes and inject text/keys. Any process that can read the 0600 token file may drive your terminals — off by default. Toggling takes effect immediately.") {
            SettingsRow("Allow external control",
                        subtitle: store.externalControlEnabled
                        ? "Listening for external commands."
                        : "Off — no socket bound, no external access.") {
                Toggle("", isOn: $store.externalControlEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

private struct AgentsPane: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var usage: UsageStore
    @EnvironmentObject var codexHomes: CodexHomeStore
    @State private var claudeInstallFailed = false
    @State private var codexInstallFailed = false
    @State private var opencodeInstallFailed = false
    @State private var devinInstallFailed = false
    @State private var newCodexHomePath = ""
    @State private var newCodexHomeLabel = ""
    @State private var codexHomeErrors: [UUID: String] = [:]

    var body: some View {
        SettingsCard("Claude Code",
                     footer: "Glint offers to install a reporter into ~/.claude/settings.json on first launch. Existing hooks are preserved.") {
            SettingsRow("Status", subtitle: claudeInstallFailed
                        ? "Install failed — check Console for [glint] logs (often a malformed settings.json)."
                        : (store.claudeHooksInstalled
                           ? "Hooks merged into your Claude settings."
                           : (store.claudeDetected
                              ? "Claude Code detected — install the reporter to show its status."
                              : "Claude Code not detected on this Mac."))) {
                HStack(spacing: 8) {
                    StatusPill(
                        label: store.claudeHooksInstalled ? "Installed" : (store.claudeDetected ? "Not installed" : "Not detected"),
                        tone: store.claudeHooksInstalled ? .ok : .neutral
                    )
                    if store.claudeHooksInstalled {
                        Button("Uninstall") {
                            store.uninstallClaudeHooks()
                            claudeInstallFailed = false
                        }
                            .controlSize(.small)
                    } else {
                        Button("Install") {
                            store.installClaudeHooks()
                            claudeInstallFailed = !store.claudeHooksInstalled
                        }
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
            SettingsDivider()
            SettingsRow("Show usage in sidebar",
                        subtitle: "Display Claude's 5-hour and weekly limits in the sidebar. Requires reading the login keychain (macOS asks once).") {
                Toggle("", isOn: $usage.claudeEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Resume session on launch",
                        subtitle: "When Glint reopens, run `claude --continue` in any pane that was running Claude at last quit.") {
                Toggle("", isOn: $store.restoreClaudeSession)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Icon style",
                        subtitle: "How Claude panes are drawn in the sidebar and tabs.") {
                HStack(spacing: 8) {
                    ClaudeIconStyleSwatch(style: .mascot)
                    ClaudeIconStyleSwatch(style: .spark)
                }
            }
        }

        SettingsCard("Codex Home Directories",
                     footer: "Codex Home stores local auth, config, sessions, and hooks. Glint only installs its own hooks and reads status; Codex continues to manage authentication and configuration.") {
            ForEach(Array(codexHomes.homes.enumerated()), id: \.element.id) { index, home in
                CodexHomeSettingsRow(
                    home: home,
                    isDefault: codexHomes.isDefault(home),
                    status: status(for: home),
                    error: codexHomeErrors[home.id] ?? (
                        FileManager.default.fileExists(atPath: home.resolvedURL.path)
                        ? nil
                        : "Directory does not exist. Installing the hook will create it."
                    ),
                    accent: store.accent,
                    onToggle: { enabled in
                        codexHomes.setEnabled(enabled, for: home.id)
                        usage.refreshNow()
                    },
                    onInstall: { installHook(for: home) },
                    onUninstall: { uninstallHook(for: home) },
                    onOpen: { NSWorkspace.shared.open(home.resolvedURL) },
                    onRemove: { removeHome(home) }
                )
                if index < codexHomes.homes.count - 1 { SettingsDivider() }
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Label (optional)", text: $newCodexHomeLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    TextField("~/work/.codex", text: $newCodexHomePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addCodexHome() }
                        .controlSize(.small)
                        .tint(store.accent)
                        .disabled(newCodexHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if codexInstallFailed {
                    Text("That directory is already configured or the path is empty.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            SettingsDivider()
            SettingsRow("Show usage in sidebar",
                        subtitle: "Display the first available enabled Codex Home's 5-hour and weekly limits in the sidebar.") {
                Toggle("", isOn: $usage.codexEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Resume session on launch",
                        subtitle: "When Glint reopens, run `codex resume --last` in any pane that was running Codex at last quit.") {
                Toggle("", isOn: $store.restoreCodexSession)
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        SettingsCard("OpenCode",
                     footer: "Glint installs a global OpenCode plugin at ~/.config/opencode/plugins/glint-agent-bridge.js so OpenCode sessions can report status without being shown as Claude.") {
            SettingsRow("Status", subtitle: opencodeInstallFailed
                        ? "Install failed — check Console for [glint] logs."
                        : (store.opencodeHooksInstalled
                           ? "Plugin installed into your OpenCode plugins directory."
                           : (store.opencodeDetected
                              ? "OpenCode detected — install the plugin to show its status."
                              : "OpenCode not detected on this Mac."))) {
                HStack(spacing: 8) {
                    StatusPill(
                        label: store.opencodeHooksInstalled ? "Installed" : (store.opencodeDetected ? "Not installed" : "Not detected"),
                        tone: store.opencodeHooksInstalled ? .ok : .neutral
                    )
                    if store.opencodeHooksInstalled {
                        Button("Uninstall") {
                            store.uninstallOpenCodeHooks()
                            opencodeInstallFailed = false
                        }
                            .controlSize(.small)
                    } else {
                        Button("Install") {
                            store.installOpenCodeHooks()
                            opencodeInstallFailed = !store.opencodeHooksInstalled
                        }
                            .controlSize(.small)
                            .tint(store.accent)
                    }
                }
            }
            SettingsDivider()
            SettingsRow("Resume session on launch",
                        subtitle: "When Glint reopens, run `opencode --continue` in any pane that was running OpenCode at last quit.") {
                Toggle("", isOn: $store.restoreOpenCodeSession)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Plugin file",
                        subtitle: "Loaded by OpenCode automatically on startup; it only reports when Glint's pane environment variables are present.") {
                Text("~/.config/opencode/plugins/glint-agent-bridge.js")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }

        SettingsCard("Devin",
                     footer: "Glint merges its hook entries into ~/.config/devin/config.json so Devin CLI sessions surface the same status as Claude.") {
            SettingsRow("Status", subtitle: devinInstallFailed
                        ? "Install failed — check Console for [glint] logs."
                        : (store.devinHooksInstalled
                           ? "Hooks merged into your Devin config."
                           : (store.devinDetected
                              ? "Devin detected — install the reporter to show its status."
                              : "Devin not detected on this Mac."))) {
                HStack(spacing: 8) {
                    StatusPill(
                        label: store.devinHooksInstalled ? "Installed" : (store.devinDetected ? "Not installed" : "Not detected"),
                        tone: store.devinHooksInstalled ? .ok : .neutral
                    )
                    if store.devinHooksInstalled {
                        Button("Uninstall") {
                            store.uninstallDevinHooks()
                            devinInstallFailed = false
                        }
                            .controlSize(.small)
                    } else {
                        Button("Install") {
                            store.installDevinHooks()
                            devinInstallFailed = !store.devinHooksInstalled
                        }
                            .controlSize(.small)
                            .tint(store.accent)
                    }
                }
            }
            SettingsDivider()
            SettingsRow("Resume session on launch",
                        subtitle: "When Glint reopens, run `devin --continue` in any pane that was running Devin at last quit.") {
                Toggle("", isOn: $store.restoreDevinSession)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Hook config",
                        subtitle: "Hooks are stored in Devin's native user config alongside your existing settings.") {
                Text("~/.config/devin/config.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }

        SettingsCard("Notifications",
                     footer: "Dock badges and chimes only update for background workspaces — the one you're looking at stays quiet.") {
            SettingsRow("Show Dock badge for agent attention",
                        subtitle: "Count background panes that need approval, just finished, or failed.") {
                Toggle("", isOn: $store.dockBadgeOnAgentAttention)
                    .toggleStyle(.switch).labelsHidden()
            }
            SettingsDivider()
            SettingsRow("Sound on permission request",
                        subtitle: "Play a chime when an agent is waiting for your approval in a background workspace.") {
                HStack(spacing: 10) {
                    SoundPicker(selection: $store.soundPermissionName)
                        .disabled(!store.soundOnPermissionRequest)
                    Toggle("", isOn: $store.soundOnPermissionRequest)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsDivider()
            SettingsRow("Sound on turn complete",
                        subtitle: "Play a softer chime when a background agent finishes its turn.") {
                HStack(spacing: 10) {
                    SoundPicker(selection: $store.soundCompleteName)
                        .disabled(!store.soundOnTurnComplete)
                    Toggle("", isOn: $store.soundOnTurnComplete)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsDivider()
            SettingsRow("Sound on error",
                        subtitle: "Play an error tone when a background agent's turn ends in an API error.") {
                HStack(spacing: 10) {
                    SoundPicker(selection: $store.soundErrorName)
                        .disabled(!store.soundOnError)
                    Toggle("", isOn: $store.soundOnError)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private func status(for home: CodexHome) -> CodexHomeStatus {
        if let current = usage.codexHomeStatuses.first(where: { $0.id == home.id }) {
            return current
        }
        return CodexHomeStatus(
            home: home,
            resolvedURL: home.resolvedURL,
            hookStatus: CodexHookInstaller.status(in: home.resolvedURL),
            authStatus: CodexLiveReader.authStatus(from: home.resolvedURL),
            quotaStatus: usage.codexEnabled ? .loading : .unavailable("Usage off")
        )
    }

    private func addCodexHome() {
        let added = codexHomes.add(path: newCodexHomePath, label: newCodexHomeLabel)
        codexInstallFailed = !added
        guard added else { return }
        newCodexHomePath = ""
        newCodexHomeLabel = ""
        usage.refreshNow()
    }

    private func installHook(for home: CodexHome) {
        do {
            try CodexHookInstaller.install(in: home.resolvedURL)
            codexHomeErrors[home.id] = nil
        } catch {
            codexHomeErrors[home.id] = error.localizedDescription
        }
        store.codexHooksInstalled = CodexHookInstaller.isInstalled()
        usage.refreshNow()
    }

    private func uninstallHook(for home: CodexHome) {
        do {
            try CodexHookInstaller.uninstall(from: home.resolvedURL)
            codexHomeErrors[home.id] = nil
        } catch {
            codexHomeErrors[home.id] = error.localizedDescription
        }
        store.codexHooksInstalled = CodexHookInstaller.isInstalled()
        usage.refreshNow()
    }

    private func removeHome(_ home: CodexHome) {
        guard !codexHomes.isDefault(home) else { return }
        do {
            try CodexHookInstaller.uninstall(from: home.resolvedURL)
            _ = codexHomes.remove(id: home.id)
            codexHomeErrors[home.id] = nil
        } catch {
            codexHomeErrors[home.id] = error.localizedDescription
        }
        store.codexHooksInstalled = CodexHookInstaller.isInstalled()
        usage.refreshNow()
    }
}

private struct CodexHomeSettingsRow: View {
    let home: CodexHome
    let isDefault: Bool
    let status: CodexHomeStatus
    let error: String?
    let accent: Color
    let onToggle: (Bool) -> Void
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { home.isEnabled }, set: onToggle))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(home.label ?? home.resolvedURL.lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(home.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.text4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isDefault {
                    Text("Default")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Spacer()
                Button("Open") { onOpen() }
                    .controlSize(.mini)
                    .disabled(!FileManager.default.fileExists(atPath: home.resolvedURL.path))
                if case .installed = status.hookStatus {
                    Button("Remove Hook") { onUninstall() }.controlSize(.mini)
                } else {
                    Button("Install Hook") { onInstall() }.controlSize(.mini).tint(accent)
                }
                if !isDefault {
                    Button(role: .destructive) { onRemove() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this Codex Home from Glint")
                }
            }
            HStack(spacing: 12) {
                statusLabel("Hook", hookText)
                statusLabel("Auth", authText)
                statusLabel("Quota", quotaText)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(home.isEnabled ? 1 : 0.62)
    }

    private func statusLabel(_ name: String, _ value: String) -> some View {
        Text("\(name): \(value)")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text3)
    }

    private var hookText: String {
        switch status.hookStatus {
        case .installed: return "Installed"
        case .notInstalled: return "Not installed"
        case .error(let message): return message
        }
    }

    private var authText: String {
        switch status.authStatus {
        case .found: return "Found"
        case .missing: return "Missing"
        case .invalid(let message): return message
        }
    }

    private var quotaText: String {
        switch status.quotaStatus {
        case .available(let quota): return "\(Int(quota.sessionPercent.rounded()))% used"
        case .unavailable(let message): return message
        case .loading: return "Loading…"
        }
    }
}

/// Custom replacement for the native menu Picker, matching the glass
/// dropdown language shared by the sound picker and the header's tab/
/// workspace popovers. Items are (value, label) pairs; labels run through
/// the string catalog (font names and numbers simply pass through
/// verbatim when no entry exists).
private struct GlintDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, label: String)]
    /// Width of the popover list; the trigger button sizes to its content.
    var listWidth: CGFloat = 180

    @State private var isOpen = false
    @State private var hover = false

    private var selectedLabel: String {
        items.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(selectedLabel))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.overlay(hover || isOpen ? 0.09 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.overlay(0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: isOpen)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items, id: \.value) { item in
                        GlintDropdownRow(label: item.label,
                                         isSelected: item.value == selection) {
                            selection = item.value
                            isOpen = false
                        }
                    }
                }
                .padding(6)
            }
            .frame(width: listWidth)
            .frame(maxHeight: 300)
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
}

private struct GlintDropdownRow: View {
    @EnvironmentObject var store: WorkspaceStore
    let label: String
    let isSelected: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(store.accent)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 12)
            Text(LocalizedStringKey(label))
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.text1 : Theme.text2)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover ? Theme.overlay(0.07) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }
}

/// Custom dropdown of the macOS system alert sounds for one of the
/// notification cues, styled like the header's tab/workspace popovers
/// (tinted glass, caption header, hover rows). Each row carries its own
/// play button so any sound can be auditioned without selecting it;
/// clicking the row itself selects and plays once as confirmation. Sound
/// names are macOS proper names ("Glass", "Funk", …) and are deliberately
/// not localized — the Sound preference pane shows them in English too.
private struct SoundPicker: View {
    @Binding var selection: String
    @State private var isOpen = false
    @State private var hover = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.text3)
                Text(selection)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.overlay(hover || isOpen ? 0.09 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.overlay(0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: isOpen)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SoundPickerList(selection: $selection) { isOpen = false }
        }
    }
}

private struct SoundPickerList: View {
    @Binding var selection: String
    let dismiss: () -> Void
    /// Name of the sound currently auditioning — its row shows an accent
    /// speaker glyph for the sound's typical duration.
    @State private var playing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(NSLocalizedString("Sound", comment: "").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1.1)
                    .foregroundStyle(Theme.text4)
                Spacer()
                Text("\(WorkspaceStore.systemSoundNames.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(WorkspaceStore.systemSoundNames, id: \.self) { name in
                        SoundPickerRow(
                            name: name,
                            isSelected: name == selection,
                            isPlaying: playing == name,
                            preview: { preview(name) },
                            select: {
                                selection = name
                                NSSound(named: name)?.play()
                                dismiss()
                            }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 210)
        .background(
            ZStack {
                // Same tinted glass as the header's tab/workspace popovers
                // so every dropdown in the app feels like one surface.
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

    private func preview(_ name: String) {
        NSSound(named: name)?.play()
        playing = name
        Task {
            try? await Task.sleep(for: .seconds(1))
            if playing == name { playing = nil }
        }
    }
}

/// One sound in the picker popover: select-on-click row with a trailing
/// speaker button that just previews the sound, leaving the selection
/// (and the popover) untouched.
private struct SoundPickerRow: View {
    @EnvironmentObject var store: WorkspaceStore
    let name: String
    let isSelected: Bool
    let isPlaying: Bool
    let preview: () -> Void
    let select: () -> Void
    @State private var hover = false
    @State private var playHover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(store.accent)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 12)
            Text(name)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.text1 : Theme.text2)
            Spacer(minLength: 12)
            Button(action: preview) {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                    .font(.system(size: isPlaying ? 10 : 12))
                    .foregroundStyle(isPlaying ? store.accent
                                     : (playHover ? Theme.text1 : Theme.text3))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(Theme.overlay(playHover ? 0.10 : 0))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { playHover = $0 }
            .opacity(hover || isPlaying || isSelected ? 1 : 0.45)
            .help(Text("Preview"))
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover ? Theme.overlay(0.07) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }
}

/// One selectable preview tile in the Claude "Icon style" row: a still of
/// the icon family, ringed with the accent color when chosen. No caption —
/// the art is the label. Stills only; settings shouldn't loop animations
/// just for a picker.
private struct ClaudeIconStyleSwatch: View {
    @EnvironmentObject var store: WorkspaceStore
    let style: ClaudeIconStyle

    private var isSelected: Bool { store.claudeIconStyle == style }

    var body: some View {
        Button {
            store.claudeIconStyle = style
        } label: {
            Group {
                switch style {
                case .mascot:
                    // First frame of the idle gif — the exact art the
                    // sidebar shows, frozen.
                    AnimatedGIFView(assetName: "ClaudeIdle", animates: false)
                        .frame(width: 38, height: 38)
                case .spark:
                    Image("ClaudeSpark")
                        .resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 38, height: 38)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? store.accent.opacity(0.12) : Theme.overlay(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? store.accent.opacity(0.85) : Theme.overlay(0.08),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        SettingsCard("Workspace",
                     footer: "⌘↑ / ⌘↓ and ⌘F are intentionally unbound — they pass through to the terminal.") {
            shortcutRow("New Workspace", keys: ["⌘", "N"])
            SettingsDivider()
            shortcutRow("Next Workspace", keys: ["⌘", "⇧", "]"])
            SettingsDivider()
            shortcutRow("Previous Workspace", keys: ["⌘", "⇧", "["])
            SettingsDivider()
            shortcutRow("Workspace 1…9", keys: ["⌘", "1…9"])
        }
        SettingsCard("Panes") {
            shortcutRow("Split Right", keys: ["⌘", "D"])
            SettingsDivider()
            shortcutRow("Split Down", keys: ["⌘", "⇧", "D"])
            SettingsDivider()
            shortcutRow("Close Pane", keys: ["⌘", "W"])
            SettingsDivider()
            shortcutRow("Focus Next Pane", keys: ["⌘", "]"])
            SettingsDivider()
            shortcutRow("Focus Previous Pane", keys: ["⌘", "["])
        }
        SettingsCard("Window") {
            shortcutRow("Toggle Sidebar", keys: ["⌘", "/"])
            SettingsDivider()
            shortcutRow("Command Palette", keys: ["⌘", "⇧", "P"])
            SettingsDivider()
            shortcutRow("Find in Sidebar", keys: ["⌥", "⌘", "F"])
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
    @EnvironmentObject var updater: UpdaterController
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                Image(store.appIconPreset.headerLogoAsset)
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
                    .fill(Theme.overlay(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.overlay(0.05), lineWidth: 0.5)
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
                SettingsRow("Build channel", subtitle: nil) {
                    StatusPill(label: buildChannelLabel, tone: buildChannelTone)
                }
                SettingsDivider()
                SettingsRow("Update channel", subtitle: nil) {
                    StatusPill(label: updateChannelLabel, tone: updateChannelTone)
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
        let display = v.first?.isNumber == true ? "v\(v)" : v
        return "\(display) (\(b))"
    }
    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "app.glint.Glint"
    }

    private enum BuildChannel {
        case localDev
        case beta
        case stable
    }

    /// Release builds stamp CFBundleVersion with a 12-digit YYYYMMDDHHmm
    /// timestamp via the CI workflow; locally-built debug bundles inherit
    /// the project's default "1" / Xcode-generated value. Use that shape
    /// as a fast proxy for "is this a released build."
    private var isReleaseBuild: Bool {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        return build.count >= 10 && build.allSatisfy(\.isNumber)
    }

    private var buildChannel: BuildChannel {
        guard isReleaseBuild else { return .localDev }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        return version.contains("-") ? .beta : .stable
    }

    private var buildChannelLabel: String {
        switch buildChannel {
        case .localDev: return "Local Dev"
        case .beta: return "Beta"
        case .stable: return "Stable"
        }
    }

    private var buildChannelTone: StatusPill.Tone {
        switch buildChannel {
        case .localDev: return .neutral
        case .beta: return .warn
        case .stable: return .ok
        }
    }

    private var updateChannelLabel: String {
        updater.receiveBetaUpdates ? "Beta" : "Stable"
    }

    private var updateChannelTone: StatusPill.Tone {
        updater.receiveBetaUpdates ? .warn : .ok
    }
}
