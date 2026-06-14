import Foundation
import AppKit
import GhosttyKit

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

    private func tickSoon() {
        DispatchQueue.main.async { [weak self] in
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
        let family = defaults.string(forKey: "glint.terminalFontFamily") ?? "SF Mono"
        let size: Double = {
            let v = defaults.double(forKey: "glint.terminalFontSize")
            return v == 0 ? 13 : v
        }()
        let cursorStyle = defaults.string(forKey: "glint.terminalCursorStyle") ?? "block"
        let cursorBlink = (defaults.object(forKey: "glint.terminalCursorBlink") as? Bool) ?? true
        let scrollback: Int = {
            let v = defaults.integer(forKey: "glint.terminalScrollback")
            return v == 0 ? 10_000 : v
        }()

        // NOTE: an asymmetric `window-padding-y = 52,12` was tried for the
        // floating header and rejected — padding never renders scrollback,
        // so it kills the content-under-glass effect (and balance must be
        // off for it to even apply; renderer/size.zig balancePadding
        // replaces explicit values). Fresh-prompt visibility is handled by
        // the padded shell launcher below instead.
        let overrides = """
        background = 0B0A14
        foreground = ECEDF2
        cursor-color = 5E5CE6
        cursor-style = \(cursorStyle)
        cursor-style-blink = \(cursorBlink)
        selection-background = 5E5CE6
        selection-foreground = ECEDF2
        font-family = \(family)
        font-family = Menlo
        font-size = \(size)
        scrollback-limit = \(scrollback)
        window-padding-x = 14
        window-padding-y = 12
        window-padding-balance = true
        adjust-cell-height = 10%
        macos-titlebar-style = hidden
        """
        let source = "glint-inline"
        overrides.withCString { ovr in
            source.withCString { src in
                ghostty_config_load_string(cfg, ovr, UInt(strlen(ovr)), src)
            }
        }
    }

    /// With the floating Liquid Glass header (macOS 26 + glass on), the grid
    /// deliberately overlaps the islands so scrolled content refracts through
    /// them — but a fresh shell's prompt would be born on row 0, under the
    /// glass. Wrap the login shell in a launcher that (1) clears the screen,
    /// erasing login(1)'s "Last login:" banner that would otherwise peek out
    /// between the islands, and (2) prints a few blank lines so the prompt
    /// starts below the strip. The blanks are real grid rows that scroll away
    /// like any other content — deliberately NOT ghostty padding, which never
    /// renders scrollback and would kill the under-glass effect.
    ///
    /// Applied PER-SURFACE (`ghostty_surface_config_s.command`) by
    /// `GhosttySurfaceView.createSurface`, not via the global config: panes
    /// that restore a scrollback snapshot must keep the plain shell — the
    /// launcher's clear-screen would wipe the restored viewport, leaving the
    /// prompt at the top with history hidden in scrollback.
    ///
    /// The launcher lives at a space-free path (~/.config/glint) because
    /// ghostty's `command` value is split on whitespace.
    static func paddedShellLauncherPath() -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        guard (UserDefaults.standard.object(forKey: "glint.glassEffect") as? Bool) ?? true else {
            return nil
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/glint", isDirectory: true)
        let url = dir.appendingPathComponent("padded-shell.sh")
        let script = """
        #!/bin/sh
        # Written by Glint at launch (and overwritten on every start): clears
        # the login banner and pads the top of a fresh terminal so the prompt
        # starts below the floating glass header. The blank rows scroll away
        # like normal content.
        printf '\\033[2J\\033[H\\n\\n\\n'
        exec '\(shell)' -l
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != script {
                try script.write(to: url, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
            return url.path
        } catch {
            NSLog("Glint: failed to write padded shell launcher: \(error)")
            return nil
        }
    }

    /// Sync Glint's zsh-init dir at ~/.config/glint/zsh-init and return its
    /// path, for use as `ZDOTDIR` when spawning a surface's shell. Two files
    /// land there:
    ///   * `.zshrc` — sources the user's real .zshrc first (zero-break), then
    ///     layers per-pane `HISTFILE` and ghost-text completion on top.
    ///   * `zsh-autosuggestions.zsh` — vendored upstream v0.7.1, MIT.
    ///
    /// Returns nil when the feature is disabled or the bundle resources can't
    /// be located, in which case the caller skips ZDOTDIR injection entirely
    /// and the shell behaves like before.
    ///
    /// ghostty's own zsh integration (which itself swaps `ZDOTDIR` to its
    /// resources dir and saves the user's original to `GHOSTTY_ZSH_ZDOTDIR`)
    /// cooperates here: it treats our path as the "user's" ZDOTDIR, restores
    /// it before invoking the rcs, then `.zshrc` from THIS dir gets sourced.
    /// When the padded launcher is used instead, ghostty's shell-integration
    /// is bypassed (the launcher binary isn't a known shell) and our ZDOTDIR
    /// propagates directly to the `exec`'d zsh.
    static func glintShellInitDirPath() -> String? {
        guard (UserDefaults.standard.object(forKey: "glint.perPaneHistory") as? Bool) ?? true else {
            return nil
        }
        // xcodegen flattens loose files from `resources: - Glint/Resources`
        // into the bundle's top-level Contents/Resources/, so we look up by
        // unique name rather than subdirectory.
        guard let bundleZshrc = Bundle.main.url(
            forResource: "glint", withExtension: "zshrc"),
              let bundleAutosuggest = Bundle.main.url(
            forResource: "zsh-autosuggestions", withExtension: "zsh") else {
            NSLog("Glint: ShellIntegration resources not found in bundle")
            return nil
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/glint/zsh-init", isDirectory: true)
        let zshrcOut = dir.appendingPathComponent(".zshrc")
        let autosuggestOut = dir.appendingPathComponent("zsh-autosuggestions.zsh")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Re-copy only when content differs — Sparkle-style updates land
            // the new bundle, our next surface picks up the refreshed rc, but
            // already-running shells keep what they sourced at startup.
            try syncBundleFile(from: bundleZshrc, to: zshrcOut)
            try syncBundleFile(from: bundleAutosuggest, to: autosuggestOut)
            return dir.path
        } catch {
            NSLog("Glint: failed to write zsh-init dir: \(error)")
            return nil
        }
    }

    private static func syncBundleFile(from src: URL, to dst: URL) throws {
        let srcData = try Data(contentsOf: src)
        if let existing = try? Data(contentsOf: dst), existing == srcData {
            return
        }
        try srcData.write(to: dst, options: .atomic)
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
        // ghostty takes the config from here. We keep a reference for parity
        // with bootstrap; we don't free the previous one because ghostty may
        // still be holding it during in-flight reload propagation. The few
        // extra config objects accumulated over a session are bounded by how
        // often a user changes settings (~tens of bytes per knob).
        self.config = newCfg
    }

    private static let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, contentPtr, count, _ in
        guard let contentPtr, count > 0 else { return }
        let content = contentPtr.pointee
        guard let cstr = content.data else { return }
        let s = String(cString: cstr)
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
                if let u = URL(string: urlString) {
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
