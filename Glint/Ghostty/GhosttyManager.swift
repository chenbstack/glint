import Foundation
import AppKit
import GhosttyKit

/// Coalesces edge-like Ghostty wakeups without losing a wakeup that arrives
/// while the current tick is draining the mailbox.
final class GhosttyTickScheduler {
    typealias Enqueue = (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var scheduled = false
    private let enqueue: Enqueue

    init(enqueue: @escaping Enqueue = { DispatchQueue.main.async(execute: $0) }) {
        self.enqueue = enqueue
    }

    func schedule(_ tick: @escaping () -> Void) {
        lock.lock()
        guard !scheduled else {
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()

        enqueue { [self] in
            // Clear before ticking: a producer can enqueue after the mailbox has
            // drained, and that wakeup must be allowed to schedule another tick.
            lock.lock()
            scheduled = false
            lock.unlock()
            tick()
        }
    }
}

/// Owns the single `ghostty_app_t` for the process and drives its tick loop.
///
/// Lifecycle:
///   ghostty_init() → ghostty_config_new + load_default_files + finalize →
///   ghostty_app_new(runtime_config, config) → wakeup_cb dispatches
///   ghostty_app_tick on the main queue whenever ghostty has work pending
///   (PTY bytes, cursor blink, animation frames, etc.). Matches upstream
///   ghostty's macOS apprt — no standing main-queue timer competing with
///   keyDown dispatch.
final class GhosttyManager {
    static let shared = GhosttyManager()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var appearanceObservation: NSKeyValueObservation?
    private let tickScheduler = GhosttyTickScheduler()
    private var focusObservers: [NSObjectProtocol] = []

    /// `ghostty_surface_needs_confirm_quit` reports the cursor's prompt state
    /// only when confirm-close-surface is not disabled. With `false`, it always
    /// returns false and cannot safely drive automatic terminal offlining.
    var canReliablyDetectIdlePrompt: Bool {
        guard let config else { return false }
        let key = "confirm-close-surface"
        var mode: Int32 = 0
        return ghostty_config_get(config, &mode, key, UInt(key.utf8.count)) && mode != 0
    }

    private init() {
        bootstrap()
    }

    private func bootstrap() {
        // ghostty reads argv[0] to learn the executable path, so we must
        // pass the real process argv (lives for the whole process).
        let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if rc != 0 {
            NSLog("ghostty_init failed: \(rc)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            NSLog("ghostty_config_new returned nil")
            return
        }
        self.config = cfg
        ghostty_config_load_default_files(cfg)
        applyGlintTheme(cfg)
        ghostty_config_finalize(cfg)

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyManager.fromUD(ud)?.tickSoon() },
            action_cb: GhosttyManager.handleAction,
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: GhosttyManager.writeClipboard,
            close_surface_cb: GhosttyManager.closeSurface,
            // Embedded tmux control mode (cmux's fork API); Glint doesn't
            // consume these events.
            tmux_control_cb: nil
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("ghostty_app_new returned nil")
            return
        }
        self.app = app

        observeColorScheme()
        observeAppFocus()
    }

    /// Push the system Light/Dark setting into ghostty and re-push on
    /// every change. Terminal apps that read the appearance (e.g. for
    /// tmux status lines, neovim themes, claude's dim mode) will switch
    /// without a restart.
    private func observeColorScheme() {
        pushColorScheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.pushColorScheme()
        }
    }

    private func pushColorScheme() {
        guard let app else { return }
        let name = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        let scheme: ghostty_color_scheme_e = (name == .darkAqua)
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, scheme)
    }

    /// App focus is separate from a surface's first-responder state. AppKit
    /// keeps the first responder when the app resigns active, so mirror the
    /// lifecycle explicitly to stop cursor blink / render work in the background.
    private func observeAppFocus() {
        setAppFocus(NSApp.isActive)
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.setAppFocus(true)
        })
        focusObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.setAppFocus(false)
        })
    }

    private func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: transparency

    /// True when the user dialed terminal opacity below 1.0. Drives the AppKit
    /// side of transparency: the surface NSView, its backing layer, and the
    /// hosting container must all go non-opaque / clear so ghostty's own
    /// `background-opacity` (baked into the config) actually shows the desktop.
    /// (The Metal renderer already produces an alpha IOSurface; without these
    /// AppKit signals the compositor still draws an opaque backing behind it.)
    var terminalIsTransparent: Bool {
        let o = (UserDefaults.standard.object(forKey: "glint.terminalOpacity") as? Double) ?? 1.0
        return o < 1.0
    }

    /// Opaque flash-guard color for the surface/container layer in the NON
    /// transparent case — matches the active theme's terminal background so a
    /// freshly-minted pane doesn't flash before its first frame. Direct
    /// `NSColor(Color)` bridge (as used elsewhere, e.g. `NSColor(store.accent)`)
    /// — no Color→hex-string→UInt32→NSColor round-trip on this layer-backing
    /// path that `isOpaque`/`updateNSView` hit frequently.
    var currentBackgroundColor: NSColor {
        NSColor(ThemeProvider.shared.current.background)
    }

    /// Stamp the opaque/clear backing onto a layer behind (or hosting) the
    /// terminal surface. Single implementation shared by the surface view's
    /// IOSurfaceLayer and the pane container so the two can't diverge — clear +
    /// non-opaque when translucent, theme-bg + opaque otherwise.
    func applyTerminalBacking(to layer: CALayer?) {
        guard let layer else { return }
        let transparent = terminalIsTransparent
        layer.isOpaque = !transparent
        layer.backgroundColor = transparent ? NSColor.clear.cgColor
                                            : currentBackgroundColor.cgColor
    }

    /// Ask ghostty to install the NSVisualEffectView-backed window blur. This
    /// is a host responsibility in the embedded apprt — ghostty exports the
    /// call but never invokes it for us. Only meaningful when the terminal is
    /// translucent and a blur radius is set.
    func applyWindowEffects() {
        guard let app else { return }
        let blur = (UserDefaults.standard.object(forKey: "glint.backgroundBlur") as? Double) ?? 0
        guard terminalIsTransparent, blur > 0 else { return }
        for window in NSApp.windows {
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        }
    }

    /// Drive every window's NSAppearance from the active theme so AppKit
    /// vibrancy + Liquid Glass materials (header islands, command palette,
    /// sidebar) resolve light/dark to MATCH the theme. Without this the window
    /// is pinned to a hardcoded appearance, so a LIGHT theme still renders dark
    /// frosted glass (the islands "go black") no matter what tint we pass.
    func syncWindowAppearance() {
        let appearance = NSAppearance(named:
            ThemeProvider.shared.current.isDark ? .darkAqua : .aqua)
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    private func tickSoon() {
        tickScheduler.schedule { [weak self] in
            guard let app = self?.app else { return }
            ghostty_app_tick(app)
        }
    }

    static func fromUD(_ ud: UnsafeMutableRawPointer?) -> GhosttyManager? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyManager>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: clipboard / close stubs

    /// Inline overrides so ghostty's surface matches our chrome. User-tweakable
    /// fields (font family/size, cursor style/blink, scrollback) are read out
    /// of `UserDefaults` so we don't need a Combine subscription on the store
    /// inside this lower layer.
    private func applyGlintTheme(_ cfg: ghostty_config_t) {
        let defaults = UserDefaults.standard
        // ghostty config 是 key=value 的逐行格式;value 后续直到行尾都被吸进 value。
        // 字体家族名直接插值,因此任何嵌入的换行/回车都会把后面的行篡改成新指令。
        // 通常来源(下拉)永远不会带控制字符,但 UserDefaults 是用户可写的,所以
        // 在拼 config 前一律剥掉控制字符,堵住注入面。
        let family = sanitizeConfigValue(defaults.string(forKey: "glint.terminalFontFamily")) ?? "SF Mono"
        let size: Double = {
            let v = defaults.double(forKey: "glint.terminalFontSize")
            return v == 0 ? 13 : v
        }()
        let bold = (defaults.object(forKey: "glint.terminalFontBold") as? Bool) ?? false
        let cjkFamily = sanitizeConfigValue(defaults.string(forKey: "glint.terminalCJKFontFamily")) ?? ""
        // 三选一白名单 —— UserDefaults 是用户可写的,塞进去任意串都不能让我们
        // 写出畸形或被注入的 config 行。落回 "block" 比静默接受随机串更安全。
        let cursorStyleRaw = defaults.string(forKey: "glint.terminalCursorStyle") ?? "block"
        let cursorStyle = ["block", "bar", "underline"].contains(cursorStyleRaw) ? cursorStyleRaw : "block"
        let cursorBlink = (defaults.object(forKey: "glint.terminalCursorBlink") as? Bool) ?? true
        let accentHex = Theme.accent(named: defaults.string(forKey: "glint.accentName")).rgbHex
        let scrollbackLimitBytes: Int = {
            let choices = [5, 10, 25, 50, 100, 250].map { $0 * 1_000_000 }
            if let bytes = defaults.object(forKey: "glint.terminalScrollbackLimitBytes") as? Int,
               bytes > 0 {
                let normalized = choices.first { $0 >= bytes } ?? bytes
                if normalized != bytes {
                    defaults.set(normalized, forKey: "glint.terminalScrollbackLimitBytes")
                }
                return normalized
            }

            // Migration from the old Glint setting, which stored a row count.
            let oldRows = defaults.integer(forKey: "glint.terminalScrollback")
            let rows = oldRows == 0 ? 10_000 : oldRows
            let bytes = rows * 2_500
            let normalized = choices.first { $0 >= bytes } ?? bytes
            defaults.set(normalized, forKey: "glint.terminalScrollbackLimitBytes")
            return normalized
        }()
        // 透明度 / 模糊(与配色正交,follow 模式也注入)。默认 1.0 / 0 = 不透明无模糊。
        let termOpacity = (defaults.object(forKey: "glint.terminalOpacity") as? Double) ?? 1.0
        let blurRadius = Int((((defaults.object(forKey: "glint.backgroundBlur") as? Double) ?? 0)).rounded())

        // Note: the per-surface `viewport-top-offset` reserves an inset above
        // the grid that the renderer paints scrollback rows up into (instead
        // of the dead-padding behavior of `window-padding-y`). It's set in
        // GhosttySurfaceView.createSurface, not here, because only the
        // top-aligned pane needs the inset; split children don't.
        // 配色来自当前主题(§3.2);cursor/selection 仍由 accentName 驱动(accent 可覆盖主题默认)。
        // 布局(font/padding/cursor-style/scrollback)与主题正交,始终注入。
        // follow-ghostty 主题跳过配色块 → 终端配色交回用户的 ghostty config(字体仍由 Glint 注入)。
        let theme = ThemeProvider.shared.current
        var colorBlock = ""
        if theme.id != "follow-ghostty" {
            colorBlock = """
            background = \(theme.background.rgbHex)
            foreground = \(theme.foreground.rgbHex)
            cursor-color = \(accentHex)
            selection-background = \(accentHex)
            selection-foreground = \(theme.foreground.rgbHex)
            """
            for (i, c) in theme.palette.enumerated() {
                colorBlock += "\npalette = \(i)=#\(c.rgbHex)"
            }
            colorBlock += "\n"
        }
        // 开关打开时让常规槽位也取 Bold 命名风格 —— `font-style` 只在对应
        // `font-family` 已声明时生效(见 ghostty Config.zig 文档),上面那两行
        // `font-family` 已经满足前提;家族没有 Bold 切片时 ghostty 自动回落,不
        // 会偷偷换字体。
        let boldStyle = bold ? "\nfont-style = Bold" : ""
        // ghostty 把多行 `font-family` 当 fallback 链(声明序为优先级)。
        // 顺序:主字体 → 用户指定的 CJK 兜底(可空) → Menlo 终极兜底。
        let cjkLine = cjkFamily.isEmpty ? "" : "\nfont-family = \(cjkFamily)"
        let overrides = """
        \(colorBlock)cursor-style = \(cursorStyle)
        cursor-style-blink = \(cursorBlink)
        font-family = \(family)\(cjkLine)
        font-family = Menlo
        font-size = \(size)\(boldStyle)
        scrollback-limit = \(scrollbackLimitBytes)
        window-padding-x = 14
        window-padding-y = 12
        window-padding-balance = true
        adjust-cell-height = 10%
        macos-titlebar-style = hidden
        background-opacity = \(termOpacity)
        background-blur = \(blurRadius)
        """
        let source = "glint-inline"
        overrides.withCString { ovr in
            source.withCString { src in
                ghostty_config_load_string(cfg, ovr, UInt(strlen(ovr)), src)
            }
        }
    }

    /// Top inset (in points) reserved above the terminal grid for the
    /// floating Liquid Glass header islands. The ghostty fork extends the
    /// renderer's row data UP into this strip with real scrollback rows
    /// (see Ghostty.fork `viewport-top-offset`), so the chrome's glass
    /// blur shows actual scrolling content underneath instead of dead
    /// padding — Photos.app style.
    ///
    /// Returns nil when the floating chrome isn't active (glass off): the
    /// grid hugs `window-padding-y.top` like a regular terminal in that
    /// mode. Pre-26 still gets the inset because the floating layout runs
    /// on every macOS — `ContentView.floatingHeader` is driven purely by
    /// `glassEffect`, not the macOS version, and the in-house
    /// `GlassCapsuleFallback` carries the chrome below 26. Gating this
    /// helper on `#available(macOS 26.0, *)` previously dropped the inset
    /// on macOS 15.x and let the first terminal row sit under the islands.
    ///
    /// Applied PER-SURFACE in `GhosttySurfaceView.createSurface`; split
    /// children don't get the inset because they sit below the header.
    static func floatingHeaderInsetPt() -> UInt32? {
        guard (UserDefaults.standard.object(forKey: "glint.glassEffect") as? Bool) ?? true else {
            return nil
        }
        // ToolbarHeader is 52pt tall (Glint/Chrome/ContentView.swift); a
        // little less than that lets the terminal's first visible row sit
        // tight to the islands' lower edge without a wide gap.
        return 48
    }

    /// Rebuild the config from current user defaults and push it into the
    /// running ghostty_app. Existing surfaces pick up the new font / cursor /
    /// scrollback settings via ghostty's internal ConfigChange propagation —
    /// no surface recreation required.
    func reloadConfig() {
        guard let app else { return }
        guard let newCfg = ghostty_config_new() else {
            NSLog("ghostty_config_new returned nil during reload")
            return
        }
        ghostty_config_load_default_files(newCfg)
        applyGlintTheme(newCfg)
        ghostty_config_finalize(newCfg)
        ghostty_app_update_config(app, newCfg)
        let oldCfg = config
        self.config = newCfg
        // `ghostty_app_update_config` copies the configuration into the app and
        // surfaces; its API contract says caller-owned memory may be freed as
        // soon as the call returns.
        if let oldCfg { ghostty_config_free(oldCfg) }
        // Blur is a window-level effect ghostty won't (re)apply on its own —
        // re-assert it after the config swap so toggling opacity/blur live
        // takes hold without a relaunch.
        DispatchQueue.main.async { [weak self] in
            self?.applyWindowEffects()
        }
    }

    private static let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, contentPtr, count, _ in
        guard let contentPtr, count > 0 else { return }
        // `count` is the number of clipboard CONTENT ENTRIES, not a byte length:
        // ghostty hands us an array of `ghostty_clipboard_content_s`, each a
        // {mime, data} pair where `data` is a NUL-terminated C string (the
        // struct carries no length field). Earlier code mistook `count` for
        // `data`'s byte length — unlike OPEN_URL, which really does get an
        // explicit length — and decoded only the first `count` bytes of the
        // first entry, truncating any copied text to a single character.
        // Walk the entries preferring text/plain, like ghostty's own macOS app.
        var fallback: String?
        var plainText: String?
        for i in 0..<Int(count) {
            let item = contentPtr[i]
            guard let dataPtr = item.data else { continue }
            let data = String(cString: dataPtr)
            if fallback == nil { fallback = data }
            if let mimePtr = item.mime, String(cString: mimePtr) == "text/plain" {
                plainText = data
                break
            }
        }
        guard let s = plainText ?? fallback else { return }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    /// ghostty action dispatcher. Most actions we ignore (return true to say
    /// "handled"); we intercept a handful that need AppKit cooperation:
    ///   * PWD          → event-driven cwd updates instead of polling
    ///   * MOUSE_SHAPE  → swap NSCursor when ghostty hovers a link or
    ///                    enters mouse-mode rendering
    ///   * OPEN_URL     → forward to NSWorkspace so cmd-click on a URL
    ///                    actually opens it
    ///   * RING_BELL    → system beep (silent terminal bells were eating
    ///                    every shell `\a`)
    private static let handleAction: ghostty_runtime_action_cb = { _, target, action in
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            return true
        }
        let view: GhosttySurfaceView? = ghostty_surface_userdata(surface).map {
            Unmanaged<GhosttySurfaceView>.fromOpaque($0).takeUnretainedValue()
        }

        switch action.tag {
        case GHOSTTY_ACTION_PWD:
            if let pwdC = action.action.pwd.pwd, let view {
                let cwd = String(cString: pwdC)
                DispatchQueue.main.async {
                    view.cachedCwd = cwd
                    NotificationCenter.default.post(name: .ghosttyCwdChanged, object: view)
                }
            }

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            if let view {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .ghosttyCommandFinished, object: view)
                }
            }

        case GHOSTTY_ACTION_SET_TITLE:
            // ghostty forwards the shell's OSC 0/2 title verbatim and — unlike
            // OSC 7 — does NOT host-validate it, so a remote shell's
            // `user@host:path` title survives an SSH session. We don't use it
            // for window titling (Glint sets its own); we mine it for the
            // remote cwd that drives Review-over-SSH. `updateRemoteFromTitle`
            // is a no-op unless the foreground process is `ssh`, so local
            // titles can't pollute remote state.
            if let view, let cstr = action.action.set_title.title {
                let title = String(cString: cstr)
                DispatchQueue.main.async {
                    view.updateRemoteFromTitle(title)
                    NotificationCenter.default.post(name: .ghosttyRemoteTitleChanged, object: view)
                }
            }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view?.mouseShape = shape }

        case GHOSTTY_ACTION_OPEN_URL:
            let info = action.action.open_url
            guard let cstr = info.url, info.len > 0 else { break }
            // ghostty passes the URL as `const char*` with an explicit
            // length (not guaranteed to be nul-terminated). Reinterpret
            // the CChar buffer as UInt8 so String(decoding:as:) accepts it.
            let urlString = cstr.withMemoryRebound(to: UInt8.self, capacity: Int(info.len)) { bytes in
                String(decoding: UnsafeBufferPointer(start: bytes, count: Int(info.len)), as: UTF8.self)
            }
            DispatchQueue.main.async {
                guard let u = URL(string: urlString) else { return }
                // A `file://` URL points at local content — route it through
                // the same open-or-reveal guard as a ⌘-clicked text path, so a
                // hostile OSC-8 link (`file:///…/Evil.app`) can't launch code
                // just because it arrived as a URL rather than printable text.
                // Other schemes (http/https/mailto/…) open with their handler.
                if u.isFileURL {
                    GhosttySurfaceView.openOrReveal(u)
                } else {
                    NSWorkspace.shared.open(u)
                }
            }

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                NSSound.beep()
                // Also bounce the dock icon if we're not the active app —
                // a backgrounded build/test that beeps is exactly when
                // the user wants their attention pulled back.
                if !NSApp.isActive {
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }

        default:
            break
        }
        return true
    }

    private static let closeSurface: ghostty_runtime_close_surface_cb = { ud, _ in
        // Surface owner (PaneSurface) is who registered ud here.
        // We don't act here; the AppKit owner can poll surface state.
        _ = ud
    }
}

/// Strip 控制字符 + trim 后返回非空字符串;nil = 「视为未设置」。
/// 给 ghostty config(key=value 逐行)注入任何 UserDefaults 来源的 value 用 ——
/// 把嵌入换行/回车堵掉,避免被注成新的 `font-family =` / `font-size =` 行。
/// 字体家族、CJK 兜底等自由形态字段都要走这层。
private func sanitizeConfigValue(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let cleaned = raw.unicodeScalars
        .filter { !CharacterSet.controlCharacters.contains($0) }
    return String(String.UnicodeScalarView(cleaned)).nilIfBlank
}
