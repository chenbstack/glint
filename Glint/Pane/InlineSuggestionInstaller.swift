import Foundation

/// Installs and removes the zsh-side inline-suggestion integration. The
/// integration is a vendored copy of `zsh-autosuggestions.zsh` (sourced from
/// `~/.config/glint/`) plus a small wrapper snippet, hooked into the user's
/// shell by appending a fenced block to `~/.zshrc`.
///
/// Why this shape:
///   - Glint can't render ghost text in SwiftUI overlays that visually match
///     ghostty's rasterization (font fallback, cell-height adjustment,
///     baseline metrics never line up perfectly). zsh-autosuggestions emits
///     the ghost as real ANSI cells, which ghostty paints with the actual
///     terminal font — so alignment is trivially exact.
///   - We considered swapping ZDOTDIR like the reverted beta.4/5 attempt
///     (commit 0503062). That broke .zprofile / .zlogin chains and confused
///     Prezto / oh-my-zsh / starship (all of which probe $ZDOTDIR for their
///     own config). Appending a tiny fenced block to the existing .zshrc
///     avoids that maintenance surface: the user's rc files keep their
///     normal resolution paths.
///   - The fenced block is idempotent (rewrites in place when found) and
///     reversible (toggle off → strip the block). Same pattern nvm /
///     rbenv / pyenv installers use. The block-management math lives in
///     `ShellRcBlock` and is shared with `ShellKeybindInstaller`.
///
/// Newly spawned zsh sessions pick this up; already-running shells keep
/// their pre-toggle behavior until they're restarted. Bash / fish panes are
/// unaffected (the block lives in .zshrc only).
///
/// Debug builds are no-ops: dev iteration of Glint-Dev must not mutate the
/// user's production `~/.zshrc` (same isolation principle as `SupportDir`
/// in `Persistence.swift`).
enum InlineSuggestionInstaller {

    /// Sentinels are LITERAL strings, not regexes, and `ShellRcBlock` only
    /// matches them at the start of a line, so a user pasting the literal
    /// sentinel text into a comment can't trick the installer into eating
    /// surrounding content. Kept identical across all Glint versions so a
    /// future Glint can manage a block written by an older one.
    private static let beginSentinel = "# >>> glint inline suggestions >>>"
    private static let endSentinel   = "# <<< glint inline suggestions <<<"

    /// Serial queue: all filesystem work happens off the main thread, and
    /// rapid toggling can't interleave reads/writes against itself.
    private static let queue = DispatchQueue(label: "app.glint.inlineSuggestion.installer",
                                             qos: .utility)

    /// Apply the current enabled state to the user's shell config. Returns
    /// immediately; actual disk I/O runs on a private serial queue.
    static func apply(enabled: Bool) {
        #if DEBUG
        // Glint-Dev shares the user's real home dir but lives in its own
        // bundle id + Application Support subdir (see SupportDir). Mutating
        // ~/.zshrc / ~/.config/glint from a Debug build would step on the
        // production install and surprise the user during dev iteration.
        return
        #else
        queue.async { performApply(enabled: enabled) }
        #endif
    }

    private static func performApply(enabled: Bool) {
        if enabled {
            do {
                try copyBundledScriptIfNeeded()
                try writeSnippet()
                try ensureZshrcBlock()
            } catch {
                NSLog("[glint.inlineSuggestion] install failed: \(error)")
            }
        } else {
            do {
                try removeZshrcBlock()
            } catch {
                NSLog("[glint.inlineSuggestion] uninstall failed: \(error)")
            }
            // Intentionally leave the scripts in ~/.config/glint behind —
            // re-enabling later costs zero re-copy, and the files are tiny.
        }
    }

    // MARK: - Paths

    private static var configDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/glint", isDirectory: true)
    }

    private static var installedScriptURL: URL {
        configDir.appendingPathComponent("zsh-autosuggestions.zsh", isDirectory: false)
    }

    /// Sidecar that records the bundled script's mtime at install time, so
    /// we can decide whether to re-copy by stat-ing one file instead of
    /// reading two 27KB scripts and comparing them byte-for-byte.
    private static var stampURL: URL {
        configDir.appendingPathComponent("zsh-autosuggestions.stamp", isDirectory: false)
    }

    private static var snippetURL: URL {
        configDir.appendingPathComponent("inline-suggestions.zsh", isDirectory: false)
    }

    private static var zshrcURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zshrc", isDirectory: false)
    }

    // MARK: - Installation steps

    /// Copy the bundled `zsh-autosuggestions.zsh` (vendored from
    /// zsh-users/zsh-autosuggestions) into `~/.config/glint/`. Skips when
    /// the stamp file already records the bundled script's current mtime
    /// (the common path on every launch after the first install / upgrade).
    private static func copyBundledScriptIfNeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.url(forResource: "zsh-autosuggestions",
                                            withExtension: "zsh") else {
            throw NSError(domain: "glint.inlineSuggestion", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled zsh-autosuggestions.zsh missing"])
        }
        let stamp = bundledStamp(for: bundled)
        if fm.fileExists(atPath: installedScriptURL.path),
           let prior = try? String(contentsOf: stampURL, encoding: .utf8),
           prior == stamp {
            return
        }
        let bundledData = try Data(contentsOf: bundled)
        try bundledData.write(to: installedScriptURL, options: [.atomic])
        try? stamp.data(using: .utf8)?.write(to: stampURL, options: [.atomic])
    }

    /// `mtime:size` of the bundled script. Both change atomically when the
    /// app ships a newer vendored zsh-autosuggestions, so the pair is a
    /// cheap, accurate fingerprint without hashing the file.
    private static func bundledStamp(for url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        return "\(mtime):\(size)"
    }

    /// Write the small wrapper snippet that the .zshrc block sources. Keeps
    /// the .zshrc block itself a single line — easier for users to read /
    /// audit / delete if they want out without using our toggle.
    private static func writeSnippet() throws {
        let content = """
        # Glint inline suggestions — sourced via the fenced block in ~/.zshrc.
        # Skip if the user already has zsh-autosuggestions loaded by their own
        # config (oh-my-zsh / prezto users): we respect their setup.
        if [[ -z ${ZSH_AUTOSUGGEST_VERSION-} ]]; then
            ZSH_AUTOSUGGEST_STRATEGY=(history)
            : ${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:='fg=8'}
            : ${ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE:=200}
            if [[ -r "$HOME/.config/glint/zsh-autosuggestions.zsh" ]]; then
                source "$HOME/.config/glint/zsh-autosuggestions.zsh"
                # → and End accept the full suggestion. Tab stays as zsh's
                # native completion (don't repurpose it).
                bindkey '^[[C' autosuggest-accept 2>/dev/null
                bindkey '^E'   autosuggest-accept 2>/dev/null
            fi
        fi
        """
        let data = Data(content.utf8)
        if let existing = try? Data(contentsOf: snippetURL), existing == data { return }
        try data.write(to: snippetURL, options: [.atomic])
    }

    /// Make sure `~/.zshrc` contains exactly one fenced block. Creates the
    /// file if missing; rewrites the block in place when found; appends a
    /// fresh block otherwise. Throws (and leaves the file alone) if the
    /// file exists but can't be read as UTF-8 — overwriting an unreadable
    /// file with just our block would silently destroy the user's config.
    private static func ensureZshrcBlock() throws {
        let block = """
        \(beginSentinel)
        # Managed by Glint. Toggle in Settings → Terminal → Command suggestions.
        # To opt out manually, delete this whole block.
        [ -f "$HOME/.config/glint/inline-suggestions.zsh" ] && source "$HOME/.config/glint/inline-suggestions.zsh"
        \(endSentinel)
        """
        let existing = try readZshrcOrEmpty()
        let updated = ShellRcBlock.upsert(in: existing,
                                          begin: beginSentinel,
                                          end: endSentinel,
                                          block: block)
        guard updated != existing else { return }
        try Data(updated.utf8).write(to: zshrcURL, options: [.atomic])
    }

    /// Strip a previously-installed block, if any. Leaves `~/.zshrc`
    /// untouched when no block is present, and throws (without writing)
    /// when the file exists but can't be read — same data-safety rule as
    /// `ensureZshrcBlock`.
    private static func removeZshrcBlock() throws {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return }
        let existing = try readZshrcOrEmpty()
        let updated = ShellRcBlock.remove(from: existing,
                                          begin: beginSentinel,
                                          end: endSentinel)
        guard updated != existing else { return }
        try Data(updated.utf8).write(to: zshrcURL, options: [.atomic])
    }

    /// Read `~/.zshrc` as UTF-8. Returns "" when the file is absent.
    /// Throws when the file exists but the read fails — callers MUST treat
    /// that as "don't overwrite this file" rather than as "file is empty",
    /// otherwise a transient read error (non-UTF-8 encoding, I/O glitch)
    /// would wipe the user's shell config.
    private static func readZshrcOrEmpty() throws -> String {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return "" }
        return try String(contentsOf: zshrcURL, encoding: .utf8)
    }
}
