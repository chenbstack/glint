import SwiftUI
import AppKit

// MARK: - GlintTheme:统一主题 model
//
// 一整套主题同时定义「终端配色(注入 ghostty)」和「chrome 配色(SwiftUI 界面)」。
// 终端层是数据源;chrome 层默认从终端层派生(见下方 derived extension),个别色可用
// ChromeOverrides 手调。完整设计见 docs/theme-system-design.md。
//
// 第 1 步(本文件)只建 model + glint-dark(chrome 用 override 1:1 锁现状)+
// Provider/Registry 地基,暂不接入 Theme.swift / applyGlintTheme —— 所以视觉零变化。

struct GlintTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool

    // ── 终端层(注入 ghostty 的真值)──────────────
    let background: Color
    let foreground: Color
    let cursor: Color
    let selectionBg: Color
    let selectionFg: Color
    let palette: [Color]          // ANSI 0..15,恰好 16 个

    // ── chrome 覆盖(nil = 从终端层派生)──────────
    var accentOverride: Color? = nil
    var chrome: ChromeOverrides? = nil
}

struct ChromeOverrides: Equatable {
    var accent: Color? = nil
    var bgWindow: Color? = nil
    var bgPane: Color? = nil
    var text1: Color? = nil
    var text2: Color? = nil
    var text3: Color? = nil
    var text4: Color? = nil
    var sidebarTintTop: Color? = nil
    var sidebarTintBottom: Color? = nil
    var toolbarTint: Color? = nil
    var glassTint: Color? = nil
    var divider: Color? = nil
    var border: Color? = nil
}

// MARK: - chrome 派生(默认行为;被 chrome override 逐项覆盖)
//
// 派生系数是初版,需在 Preview 里对 catalog 主题做视觉调校。glint-dark 走全 override,
// 不受这里影响 —— 派生只服务于第 4 步接入的全量 502 套。

extension GlintTheme {
    var accent: Color {
        accentOverride ?? chrome?.accent
            ?? (palette.indices.contains(4) ? palette[4] : foreground)
    }

    // 背景:pane = 终端背景本身;window 比 pane 再暗一档
    var bgWindow: Color { chrome?.bgWindow ?? background.darkened(0.30) }
    var bgPane:   Color { chrome?.bgPane   ?? background }

    // 文本层级:前景色朝背景做明度阶梯
    var text1: Color { chrome?.text1 ?? foreground }
    var text2: Color { chrome?.text2 ?? foreground.mixed(into: background, 0.22) }
    var text3: Color { chrome?.text3 ?? foreground.mixed(into: background, 0.45) }
    var text4: Color { chrome?.text4 ?? foreground.mixed(into: background, 0.58) }

    // vibrancy tint:背景 + 一点 accent 微染
    var sidebarTintTop:    Color { chrome?.sidebarTintTop    ?? background.mixed(into: accent, 0.06).opacity(0.86) }
    var sidebarTintBottom: Color { chrome?.sidebarTintBottom ?? background.mixed(into: accent, 0.03).opacity(0.90) }
    var toolbarTint:       Color { chrome?.toolbarTint       ?? background.mixed(into: accent, 0.05).opacity(0.86) }
    var glassTint:         Color { chrome?.glassTint         ?? background.mixed(into: accent, 0.06).opacity(0.50) }

    var divider: Color { chrome?.divider ?? foreground.opacity(isDark ? 0.045 : 0.08) }
    var border:  Color { chrome?.border  ?? foreground.opacity(isDark ? 0.07  : 0.12) }
}

// MARK: - 内置主题

extension GlintTheme {
    /// 现状紫黑。chrome 全部用 override **1:1 锁定**现有 Theme.swift 的色值(浮点字面量
    /// 逐位照抄,零舍入差),保证第 2 步接入后视觉零变化。palette 暂用 ghostty 默认 16 色
    /// (= 现状终端就吃的那套),第 4 步再换成与紫黑更搭的一套。
    static let glintDark = GlintTheme(
        id: "glint-dark",
        name: "Glint Dark",
        isDark: true,
        background:  Color(red: 0.043, green: 0.039, blue: 0.078),   // #0B0A14(= applyGlintTheme background)
        foreground:  Color(red: 0.925, green: 0.929, blue: 0.949),   // #ECEDF2
        cursor:      Color(red: 0.549, green: 0.549, blue: 1.000),   // accentBright #8C8CFF
        selectionBg: Color(red: 0.549, green: 0.549, blue: 1.000),   // accentBright
        selectionFg: Color(red: 0.925, green: 0.929, blue: 0.949),   // #ECEDF2
        palette: GlintTheme.ghosttyDefaultPalette,
        accentOverride: Color(red: 0.549, green: 0.549, blue: 1.000),
        chrome: ChromeOverrides(
            bgWindow:          Color(red: 0.039, green: 0.043, blue: 0.063),            // #0A0B10
            bgPane:            Color(red: 0.043, green: 0.039, blue: 0.078),            // #0B0A14
            text1:             Color(red: 0.925, green: 0.929, blue: 0.949),            // #ECEDF2
            text2:             Color(red: 0.717, green: 0.725, blue: 0.784),            // #B7B9C8
            text3:             Color(red: 0.494, green: 0.510, blue: 0.565),            // #7E8290
            text4:             Color(red: 0.459, green: 0.478, blue: 0.569),            // #757A91
            sidebarTintTop:    Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.86),
            sidebarTintBottom: Color(red: 0.045, green: 0.038, blue: 0.085).opacity(0.90),
            toolbarTint:       Color(red: 0.060, green: 0.052, blue: 0.095).opacity(0.86),
            glassTint:         Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.50),
            divider:           Color.white.opacity(0.045),
            border:            Color.white.opacity(0.07)
        )
    )

    /// 跟随 Ghostty 配置(= 原 #18):终端配色交回用户 ghostty config,Glint 只管布局。
    /// chrome 先复用 glint-dark 作占位 —— follow 模式下 Swift 拿不到 ghostty 的真实配色,
    /// 无法派生,follow 态的 chrome 策略留到第 3/4 步定。
    static let followGhostty = GlintTheme(
        id: "follow-ghostty",
        name: "Follow Ghostty Config",
        isDark: true,
        background: glintDark.background,
        foreground: glintDark.foreground,
        cursor: glintDark.cursor,
        selectionBg: glintDark.selectionBg,
        selectionFg: glintDark.selectionFg,
        palette: glintDark.palette,
        accentOverride: glintDark.accentOverride,
        chrome: glintDark.chrome
    )

    /// Catppuccin Mocha(featured 精调候选)。配色取自 ghostty 主题文件;chrome 走纯派生,
    /// 用来验证派生算法在一套高人气暗色上的效果。
    static let catppuccinMocha = GlintTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        isDark: true,
        background:  rgb(0x1E1E2E),
        foreground:  rgb(0xCDD6F4),
        cursor:      rgb(0xF5E0DC),
        selectionBg: rgb(0x585B70),
        selectionFg: rgb(0xCDD6F4),
        palette: [
            rgb(0x45475A), rgb(0xF38BA8), rgb(0xA6E3A1), rgb(0xF9E2AF),
            rgb(0x89B4FA), rgb(0xF5C2E7), rgb(0x94E2D5), rgb(0xBAC2DE),
            rgb(0x585B70), rgb(0xF38BA8), rgb(0xA6E3A1), rgb(0xF9E2AF),
            rgb(0x89B4FA), rgb(0xF5C2E7), rgb(0x94E2D5), rgb(0xA6ADC8),
        ]
    )

    /// ghostty 内置默认 16 色(src/terminal/color.zig)。glint-dark 暂借它,
    /// 确保第 3 步注入终端时配色 = 现状(现在终端就是吃 ghostty 默认 palette)。
    static let ghosttyDefaultPalette: [Color] = [
        rgb(0x1D1F21), rgb(0xCC6666), rgb(0xB5BD68), rgb(0xF0C674),
        rgb(0x81A2BE), rgb(0xB294BB), rgb(0x8ABEB7), rgb(0xC5C8C6),
        rgb(0x666666), rgb(0xD54E53), rgb(0xB9CA4A), rgb(0xE7C547),
        rgb(0x7AA6DA), rgb(0xC397D8), rgb(0x70C0B1), rgb(0xEAEAEA),
    ]
}

// MARK: - Provider + Registry

/// 全局当前主题持有者。`Theme.current`(第 2 步接入)读它;主题切换时由
/// WorkspaceStore.themeName 的 didSet 更新 current 并触发 chrome 整树刷新。
final class ThemeProvider {
    static let shared = ThemeProvider()
    var current: GlintTheme

    private init() {
        current = ThemeRegistry.theme(id: UserDefaults.standard.string(forKey: "glint.themeName"))
    }
}

/// 主题目录:featured(精调,Swift 内置)+ catalog(全量 502,从打包的 themes.json
/// 解析)+ follow-ghostty。撞 id 时 featured 优先(featured 的 id 从 catalog 里剔除)。
enum ThemeRegistry {
    static let featured: [GlintTheme] = [.glintDark, .catppuccinMocha]
    static let followGhostty: GlintTheme = .followGhostty

    /// 全量 502 套(纯派生 chrome),去掉与 featured 撞 id 的(如 catppuccin-mocha)。
    /// lazy:首次访问时解析一次 themes.json,之后缓存。
    static let catalog: [GlintTheme] = {
        let featuredIDs = Set(featured.map(\.id))
        return ThemeCatalog.all.filter { !featuredIDs.contains($0.id) }
    }()

    static var all: [GlintTheme] { featured + catalog + [followGhostty] }

    static func theme(id: String?) -> GlintTheme {
        featured.first { $0.id == id }
            ?? catalog.first { $0.id == id }
            ?? (id == followGhostty.id ? followGhostty : .glintDark)
    }
}

// MARK: - ThemeCatalog:从打包的 themes.json 解析全量 502 套
//
// themes.json 由 scripts/gen_themes.py 从 ghostty 的 502 套主题文件预解析而成
// (只存终端层:bg/fg/cursor/selection/palette[16];chrome 全靠派生)。运行时一次
// JSONDecode → [GlintTheme],按需 lazy(见 ThemeRegistry.catalog)。

enum ThemeCatalog {
    /// themes.json 的一条记录。字段名压到最短以缩小打包体积(~140KB)。
    private struct Entry: Decodable {
        let id: String
        let name: String
        let dark: Bool
        let bg, fg, cur, sb, sf: String
        let pal: [String]
    }

    static let all: [GlintTheme] = load()

    private static func load() -> [GlintTheme] {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            assertionFailure("themes.json 缺失或无法解析 —— catalog 将为空")
            return []
        }
        return entries.map { e in
            GlintTheme(
                id: e.id, name: e.name, isDark: e.dark,
                background:  rgb(hex: e.bg),
                foreground:  rgb(hex: e.fg),
                cursor:      rgb(hex: e.cur),
                selectionBg: rgb(hex: e.sb),
                selectionFg: rgb(hex: e.sf),
                palette:     e.pal.map { rgb(hex: $0) }
            )
        }
    }
}

// MARK: - 文件内 helper

/// 从 0xRRGGBB 构造 sRGB Color。避开与 WorkspaceStore 的 failable `Color(hex:)`
/// 在 macOS 26 SDK 下的重载歧义,且十六进制整数比字符串更省解析。
private func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB,
          red:   Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue:  Double(hex & 0xFF) / 255,
          opacity: 1)
}

/// 从 6 位 hex 字符串("RRGGBB",无 #)构造 sRGB Color。themes.json 已规范化为
/// 小写 6 位,这里只做容错解析,坏值回退黑色(catalog 解析不应崩 app)。
private func rgb(hex s: String) -> Color {
    let v = UInt32(s, radix: 16) ?? 0
    return rgb(v)
}

// MARK: - Color 工具(sRGB 线性混合)

extension Color {
    /// 朝黑色压暗 amount(0…1)。
    func darkened(_ amount: Double) -> Color { mixed(into: .black, amount) }

    /// 朝 other 线性混合 amount(0 = self,1 = other),保留 self 的 alpha。
    func mixed(into other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let b = NSColor(other).usingColorSpace(.sRGB) ?? NSColor(other)
        let t = CGFloat(max(0, min(1, amount)))
        return Color(.sRGB,
                     red:     Double(a.redComponent   + (b.redComponent   - a.redComponent)   * t),
                     green:   Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue:    Double(a.blueComponent  + (b.blueComponent  - a.blueComponent)  * t),
                     opacity: Double(a.alphaComponent))
    }
}

// MARK: - Collection 安全下标

extension Collection {
    /// 越界返回 nil 而非崩溃。主题 palette 理论上恒为 16 色,但 catalog 解析的主题
    /// 万一缺色时用它兜底。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
