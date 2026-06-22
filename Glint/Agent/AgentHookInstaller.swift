import Foundation

/// `Data.write(options: .atomic)` replaces the target inode with a fresh
/// temp file owned by the process umask (0644 by default), silently widening
/// a mode the user may have tightened. The agent configs we rewrite
/// (`~/.claude/settings.json`, `~/.codex/hooks.json`) can hold sensitive
/// config, so every rewrite captures the original POSIX mode first and
/// re-asserts it afterwards — including on the `.glint-backup`/`.glint-prev`
/// copies, which must never be more readable than the original. Files we
/// create from scratch default to 0600.
private func posixPermissions(atPath path: String) -> Int {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue else {
        return 0o600
    }
    return mode
}

private func setPosixPermissions(_ mode: Int, atPath path: String) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

/// Best-effort detection of whether a CLI agent is actually present on this
/// Mac. Used to avoid offering (or auto-installing) hooks for agents the
/// user doesn't have. We trust the agent's config/state directory first —
/// it's the strongest signal that they actually use it — and fall back to
/// probing common executable locations, because a GUI app launched from
/// Finder doesn't inherit the login shell's `PATH`, so `PATH` alone misses
/// most installs.
enum AgentPresence {
    static func directoryExists(_ relativeToHome: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeToHome)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func fileExists(_ relativeToHome: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeToHome)
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func commandExists(_ name: String) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/bin",
            "\(home)/.bun/bin", "\(home)/.deno/bin",
            "\(home)/.npm-global/bin", "\(home)/.opencode/bin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs where fm.isExecutableFile(atPath: "\(dir)/\(name)") {
            return true
        }
        return false
    }
}

/// Drops the Claude Code hook script onto disk and merges its hook entries
/// into `~/.claude/settings.json`. The merge is idempotent: existing Glint
/// entries (recognized by command path) are replaced, everything else is
/// left alone. If the file isn't valid JSON we back it up and skip rather
/// than risk corrupting the user's config.
enum AgentHookInstaller {
    /// Events we register. Order doesn't matter; matters that it covers
    /// every transition the status machine cares about.
    private static let hookEvents: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "PermissionRequest",
        "PreCompact",
        "Stop",
        // Claude fires StopFailure (NOT Stop) when a turn dies on an API/
        // transport error — socket closed, rate-limit, auth, overload. Without
        // it a failed turn never reports an end and the pane stays stuck on
        // `.thinking`. It's side-effect-only (can't block the turn), which is
        // exactly what we need: just report the error end.
        "StopFailure",
    ]

    /// True if any hook bucket in `~/.claude/settings.json` already references
    /// our reporter script. Used by the Settings UI to flip between
    /// "Install" and "Uninstall" actions.
    static func isInstalled() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        for (_, bucket) in hooks {
            guard let arr = bucket as? [Any] else { continue }
            for entry in arr {
                guard let group = entry as? [String: Any],
                      let inner = group["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String)?.contains("glint-report.sh") == true }) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether Claude Code itself looks installed on this Mac, independent of
    /// whether Glint's hooks are registered yet.
    static func isAgentPresent() -> Bool {
        AgentPresence.directoryExists(".claude")
            || AgentPresence.fileExists(".claude.json")
            || AgentPresence.commandExists("claude")
    }

    /// Strip Glint's hook entries from `~/.claude/settings.json` and delete
    /// the reporter script. Other tools' hook entries are preserved; empty
    /// buckets are removed; an empty `hooks` map is removed entirely.
    static func uninstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            var touched = false
            for (event, bucket) in hooks {
                guard let arr = bucket as? [Any] else { continue }
                let filtered = arr.filter { entry in
                    guard let group = entry as? [String: Any],
                          let inner = group["hooks"] as? [[String: Any]] else { return true }
                    return !inner.contains { ($0["command"] as? String)?.contains("glint-report.sh") == true }
                }
                if filtered.count != arr.count {
                    touched = true
                    if filtered.isEmpty {
                        hooks.removeValue(forKey: event)
                    } else {
                        hooks[event] = filtered
                    }
                }
            }
            if touched {
                if hooks.isEmpty {
                    root.removeValue(forKey: "hooks")
                } else {
                    root["hooks"] = hooks
                }
                if let out = SafeJSON.data(
                    root,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ) {
                    let mode = posixPermissions(atPath: settingsURL.path)
                    try? out.write(to: settingsURL, options: [.atomic])
                    setPosixPermissions(mode, atPath: settingsURL.path)
                    NSLog("[glint] claude hooks removed from \(settingsURL.path)")
                }
            }
        }
        // Only nuke the shared reporter if no other installed agent still
        // references it (Codex and Devin share the same script).
        if !AgentHookInstaller.isInstalled() && !CodexHookInstaller.isInstalled()
            && !DevinHookInstaller.isInstalled() {
            let script = home.appendingPathComponent(".glint/hooks/glint-report.sh")
            try? FileManager.default.removeItem(at: script)
        }
    }

    static func installIfNeeded(socketPath: String) {
        guard let scriptPath = ensureReporterScript() else { return }
        mergeClaudeSettings(scriptPath: scriptPath)
        _ = socketPath  // path is baked into the script via $GLINT_AGENT_SOCK at runtime
    }

    /// Drop the shared reporter script (used by both Claude and Codex) into
    /// `~/.glint/hooks/glint-report.sh` and chmod +x. Idempotent: re-runs
    /// only rewrite the file if the body changed. Returns the absolute path
    /// to the script, or nil if the directory couldn't be created.
    static func ensureReporterScript() -> String? {
        guard let dir = ensureHookDir() else { return nil }
        let scriptURL = dir.appendingPathComponent("glint-report.sh")
        let body = Self.scriptBody
        let needsWrite: Bool = {
            guard let existing = try? String(contentsOf: scriptURL) else { return true }
            return existing != body
        }()
        if needsWrite {
            do {
                try body.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: scriptURL.path
                )
            } catch {
                NSLog("[glint] hook script write failed: \(error)")
                return nil
            }
        }
        return scriptURL.path
    }

    // MARK: settings.json merge

    /// Atomically merge our 6 hook entries into `~/.claude/settings.json`.
    /// Stable: re-runs after a path change will replace stale entries, not
    /// duplicate them.
    private static func mergeClaudeSettings(scriptPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[glint] couldn't create ~/.claude: \(error)")
            return
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                // Don't trust the file — back it up and bail. User can resolve.
                let backup = settingsURL.appendingPathExtension("glint-backup")
                try? FileManager.default.copyItem(at: settingsURL, to: backup)
                setPosixPermissions(posixPermissions(atPath: settingsURL.path), atPath: backup.path)
                NSLog("[glint] ~/.claude/settings.json isn't a JSON object; backed up to \(backup.lastPathComponent), skipping merge")
                return
            }
            root = dict
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var changed = false

        for event in hookEvents {
            var bucket = (hooks[event] as? [Any]) ?? []
            // Drop any prior Glint entry — recognised by `glint-report.sh`
            // appearing anywhere in the command. The filename is the marker
            // so old entries from moved/renamed paths still get cleaned up.
            let filtered = bucket.filter { entry in
                guard let group = entry as? [String: Any],
                      let inner = group["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains { ($0["command"] as? String)?.contains("glint-report.sh") == true }
            }
            let ours: [String: Any] = [
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptPath) \(event)",
                ]],
            ]
            bucket = filtered + [ours]
            if !equalsJSON(hooks[event], bucket) {
                hooks[event] = bucket
                changed = true
            }
        }

        if !changed { return }

        root["hooks"] = hooks
        guard let data = SafeJSON.data(
            root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            NSLog("[glint] ~/.claude/settings.json: hook tree not serializable, skipping write")
            return
        }
        do {
            // Capture the original mode before the atomic write swaps the
            // inode out from under it (0600 when the file is new).
            let mode = posixPermissions(atPath: settingsURL.path)
            // Belt-and-suspenders: keep one .glint-prev next to the file the
            // first time we touch it, so the user can always roll back.
            let prev = settingsURL.appendingPathExtension("glint-prev")
            if FileManager.default.fileExists(atPath: settingsURL.path),
               !FileManager.default.fileExists(atPath: prev.path) {
                try? FileManager.default.copyItem(at: settingsURL, to: prev)
                setPosixPermissions(mode, atPath: prev.path)
            }
            try data.write(to: settingsURL, options: [.atomic])
            setPosixPermissions(mode, atPath: settingsURL.path)
            NSLog("[glint] claude hooks merged into \(settingsURL.path)")
        } catch {
            NSLog("[glint] writing ~/.claude/settings.json failed: \(error)")
        }
    }

    /// Cheap structural equality via JSON round-trip. Used to skip writes
    /// when nothing actually changed.
    private static func equalsJSON(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let da = SafeJSON.data(a, options: opts),
              let db = SafeJSON.data(b, options: opts) else {
            return false
        }
        return da == db
    }

    /// Drop hooks under `~/.glint/hooks/` rather than `~/Library/Application Support/Glint/`.
    /// claude code passes the `command` field to a POSIX shell, so an unquoted
    /// path containing spaces ("Application Support") gets word-split and the
    /// hook fails to launch. The dotfile path sidesteps that entirely.
    static func ensureHookDir() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".glint", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            NSLog("[glint] hook dir create failed: \(error)")
            return nil
        }
    }

    /// Pure POSIX sh — runs inside the pty so `$GLINT_PANE_ID` resolves.
    /// Stays cheap (single send, swallows stdin).
    ///
    /// Uses `/usr/bin/nc` (absolute) not bare `nc`: Homebrew's GNU netcat
    /// (`/opt/homebrew/bin/nc`, netcat 0.7.1) shadows it and rejects `-U`
    /// (`nc: invalid option -- U`), so every report failed silently and the
    /// pane never entered a busy state. macOS always ships BSD nc at
    /// `/usr/bin/nc` with Unix-domain socket support.
    ///
    /// Argv[1] = hook event name (e.g. "PostToolUse").
    /// Argv[2] = agent kind ("claude" or "codex"); defaults to "claude" so
    /// existing Claude installs keep working without a script rewrite.
    static let scriptBody: String = """
    #!/bin/sh
    # Glint CLI-agent hook reporter. Argv[1] = hook event, argv[2] = agent kind.
    [ -z "$GLINT_PANE_ID" ] && exit 0
    [ -z "$GLINT_AGENT_SOCK" ] && exit 0
    [ ! -S "$GLINT_AGENT_SOCK" ] && exit 0

    HOOK="${1:-Unknown}"
    AGENT="${2:-claude}"
    # Drain stdin (claude/codex pass the hook payload there). We ignore it for
    # now — only the hook name + agent are needed to drive pane state.
    cat >/dev/null 2>&1

    printf '{"pane":"%s","hook":"%s","agent":"%s"}\\n' "$GLINT_PANE_ID" "$HOOK" "$AGENT" \\
      | /usr/bin/nc -U -w 1 "$GLINT_AGENT_SOCK" >/dev/null 2>&1 || true
    exit 0
    """

}

/// Same idea as `AgentHookInstaller`, but writes Codex CLI's hook config
/// to `~/.codex/hooks.json`. The on-disk schema is structurally identical
/// to Claude's settings.json hooks subtree:
///
///     {
///       "hooks": {
///         "<EventName>": [
///           { "matcher": "*", "hooks": [{ "type": "command", "command": "…" }] }
///         ]
///       }
///     }
///
/// Codex passes the entire hook payload on stdin, same as Claude — the
/// shared `glint-report.sh` swallows it and only forwards the event name
/// plus the agent kind ("codex") to Glint's local socket.
enum CodexHookInstaller {
    /// Events Glint reacts to. Codex has no Notification event, but it does
    /// expose tool boundaries; PreToolUse is important for clearing a pending
    /// permission prompt once the approved tool actually starts.
    private static let hookEvents: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PreCompact",
        "Stop",
        "StopFailure",
    ]

    static func isInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        for (_, bucket) in hooks {
            guard let arr = bucket as? [Any] else { continue }
            for entry in arr {
                guard let group = entry as? [String: Any],
                      let inner = group["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String)?.contains("glint-report.sh") == true }) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether the Codex CLI itself looks installed on this Mac.
    static func isAgentPresent() -> Bool {
        AgentPresence.directoryExists(".codex")
            || AgentPresence.commandExists("codex")
    }

    static func installIfNeeded(socketPath: String) {
        guard let scriptPath = AgentHookInstaller.ensureReporterScript() else { return }
        mergeCodexHooks(scriptPath: scriptPath)
        _ = socketPath
    }

    /// Remove Glint's entries from `~/.codex/hooks.json`. The reporter script
    /// itself is shared with Claude, so we only delete it when neither agent
    /// still references it.
    static func uninstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/hooks.json")
        if let data = try? Data(contentsOf: url),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            var touched = false
            for (event, bucket) in hooks {
                guard let arr = bucket as? [Any] else { continue }
                let filtered = arr.filter { entry in
                    guard let group = entry as? [String: Any],
                          let inner = group["hooks"] as? [[String: Any]] else { return true }
                    return !inner.contains { ($0["command"] as? String)?.contains("glint-report.sh") == true }
                }
                if filtered.count != arr.count {
                    touched = true
                    if filtered.isEmpty {
                        hooks.removeValue(forKey: event)
                    } else {
                        hooks[event] = filtered
                    }
                }
            }
            if touched {
                if hooks.isEmpty {
                    root.removeValue(forKey: "hooks")
                } else {
                    root["hooks"] = hooks
                }
                if root.isEmpty {
                    // Whole file was just our hooks → remove it cleanly.
                    try? FileManager.default.removeItem(at: url)
                } else if let out = SafeJSON.data(
                    root,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ) {
                    let mode = posixPermissions(atPath: url.path)
                    try? out.write(to: url, options: [.atomic])
                    setPosixPermissions(mode, atPath: url.path)
                }
                NSLog("[glint] codex hooks removed from \(url.path)")
            }
        }
        // Only nuke the shared reporter if no other installed agent still
        // references it — Claude, Codex, and Devin all share the same script.
        if !AgentHookInstaller.isInstalled() && !CodexHookInstaller.isInstalled()
            && !DevinHookInstaller.isInstalled() {
            let script = home.appendingPathComponent(".glint/hooks/glint-report.sh")
            try? FileManager.default.removeItem(at: script)
        }
    }

    private static func mergeCodexHooks(scriptPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let url = codexDir.appendingPathComponent("hooks.json")
        do {
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[glint] couldn't create ~/.codex: \(error)")
            return
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                let backup = url.appendingPathExtension("glint-backup")
                try? FileManager.default.copyItem(at: url, to: backup)
                setPosixPermissions(posixPermissions(atPath: url.path), atPath: backup.path)
                NSLog("[glint] ~/.codex/hooks.json isn't a JSON object; backed up to \(backup.lastPathComponent), skipping merge")
                return
            }
            root = dict
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        for event in hookEvents {
            var bucket = (hooks[event] as? [Any]) ?? []
            let filtered = bucket.filter { entry in
                guard let group = entry as? [String: Any],
                      let inner = group["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains { ($0["command"] as? String)?.contains("glint-report.sh") == true }
            }
            let ours: [String: Any] = [
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptPath) \(event) codex",
                ]],
            ]
            bucket = filtered + [ours]
            if !equalsJSON(hooks[event], bucket) {
                hooks[event] = bucket
                changed = true
            }
        }

        if !changed { return }
        root["hooks"] = hooks
        guard let data = SafeJSON.data(
            root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            NSLog("[glint] ~/.codex/hooks.json: hook tree not serializable, skipping write")
            return
        }
        do {
            // Same mode-preservation dance as the Claude merge above.
            let mode = posixPermissions(atPath: url.path)
            let prev = url.appendingPathExtension("glint-prev")
            if FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.fileExists(atPath: prev.path) {
                try? FileManager.default.copyItem(at: url, to: prev)
                setPosixPermissions(mode, atPath: prev.path)
            }
            try data.write(to: url, options: [.atomic])
            setPosixPermissions(mode, atPath: url.path)
            NSLog("[glint] codex hooks merged into \(url.path)")
        } catch {
            NSLog("[glint] writing ~/.codex/hooks.json failed: \(error)")
        }
    }

    private static func equalsJSON(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let da = SafeJSON.data(a, options: opts),
              let db = SafeJSON.data(b, options: opts) else {
            return false
        }
        return da == db
    }
}

/// Installs a global OpenCode plugin that forwards OpenCode lifecycle events
/// to Glint's local agent socket.
///
/// OpenCode auto-loads JavaScript/TypeScript files from
/// `~/.config/opencode/plugins/`, so unlike Claude/Codex we do not need to
/// edit a JSON config file.
enum OpenCodeHookInstaller {
    private static let pluginFileName = "glint-agent-bridge.js"
    private static let marker = "Glint OpenCode plugin"

    static func isInstalled() -> Bool {
        guard let body = try? String(contentsOf: pluginURL) else { return false }
        return body.contains(marker)
    }

    /// Whether OpenCode itself looks installed on this Mac.
    static func isAgentPresent() -> Bool {
        AgentPresence.directoryExists(".config/opencode")
            || AgentPresence.commandExists("opencode")
    }

    static func installIfNeeded(socketPath: String) {
        do {
            try FileManager.default.createDirectory(
                at: pluginDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let body = pluginBody
            let needsWrite = (try? String(contentsOf: pluginURL)) != body
            if needsWrite {
                try body.write(to: pluginURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: pluginURL.path
                )
            }
        } catch {
            NSLog("[glint] opencode plugin install failed: \(error)")
        }
        _ = socketPath
    }

    static func uninstall() {
        do {
            if isInstalled() {
                try FileManager.default.removeItem(at: pluginURL)
                NSLog("[glint] opencode plugin removed from \(pluginURL.path)")
            }
        } catch {
            NSLog("[glint] opencode plugin uninstall failed: \(error)")
        }
    }

    private static var pluginDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
    }

    private static var pluginURL: URL {
        pluginDirectory.appendingPathComponent(pluginFileName)
    }

    private static let pluginBody: String = """
    // \(marker). Auto-generated by Glint; remove from Settings -> Agents.
    import net from "node:net"
    import { existsSync } from "node:fs"

    const AGENT = "opencode"

    const send = async (hook) => {
      const pane = process.env.GLINT_PANE_ID
      const sock = process.env.GLINT_AGENT_SOCK
      if (!pane || !sock || !existsSync(sock)) return

      const line = JSON.stringify({ pane, hook, agent: AGENT }) + "\\n"
      await new Promise((resolve) => {
        let done = false
        let timer
        const finish = () => {
          if (done) return
          done = true
          clearTimeout(timer)
          resolve()
        }

        const client = net.createConnection(sock, () => client.end(line))
        timer = setTimeout(() => {
          client.destroy()
          finish()
        }, 1000)
        timer.unref?.()

        client.on("error", finish)
        client.on("close", finish)
      })
    }

    export const GlintPlugin = async () => {
      return {
        event: async ({ event }) => {
          switch (event.type) {
            case "session.created":
              await send("SessionStart")
              break
            case "session.status": {
              const status = event.properties?.status?.type ?? event.properties?.status
              if (status === "busy" || status === "running") await send("UserPromptSubmit")
              if (status === "idle") await send("Stop")
              break
            }
            case "session.idle":
              await send("Stop")
              break
            case "session.error":
              await send("StopFailure")
              break
            case "session.compacted":
              await send("PreCompact")
              break
            case "permission.asked":
              await send("PermissionRequest")
              break
            case "permission.replied":
              await send("PreToolUse")
              break
          }
        },
        "tool.execute.before": async () => {
          await send("PreToolUse")
        },
        "tool.execute.after": async () => {
          await send("PostToolUse")
        },
      }
    }
    """
}

/// Opt-in shell keybindings that make modified-Enter chords behave like a
/// plain Enter at the prompt.
///
/// Modern terminals (ghostty, kitty, foot, …) encode Shift+Enter / Ctrl+Enter
/// as extended-key escapes (e.g. `\u{1b}[27;2;13~`) so apps can tell them
/// apart from Enter. A bare shell that hasn't bound those sequences echoes the
/// printable tail (`;2;13~`) into the command line. This installs a small,
/// clearly-delimited, removable block into the user's shell rc that binds the
/// common modified-Enter sequences to `accept-line` — matching Terminal.app's
/// "Shift+Enter == Enter" behavior. The binding is keyed to escapes that only
/// these terminals emit, so it's inert elsewhere (Terminal.app, iTerm).
///
/// Off by default and never touched by the first-launch hook prompt; the user
/// turns it on/off in Settings → Terminal.
enum ShellKeybindInstaller {
    private static let beginMarker = "# >>> glint shell keybindings >>>"
    private static let endMarker = "# <<< glint shell keybindings <<<"

    private struct Target {
        let rcPath: String          // rc file, relative to home (e.g. ".zshrc")
        let payloadPath: String     // sourced script, relative to home
        let payloadBody: String     // the script's contents
        let wantedWhenMissing: Bool // create the rc if it doesn't exist yet?
    }

    // Sequences ghostty/kitty-family terminals emit for modified keys that a
    // bare shell doesn't bind, so they leak (e.g. Shift+Enter → `;2;13~`,
    // Shift+→ → `1;2C`) or no-op. We bind the common ones to sensible widgets.
    // The bindings live in their own file under ~/.config/glint so the rc only
    // gains a one-line `source`. Modifier digit: 2=Shift, 3=Alt, 5=Ctrl,
    // 6=Ctrl+Shift. (Backspace is deliberately left alone — ghostty sends
    // ^H / ^[^? which shells already handle, and rebinding ^H hijacks Ctrl+H.)
    private static let zshPayload = """
    # Glint shell keybindings — managed by Glint (Settings → Terminal).
    # Makes modified keys behave sensibly at the prompt instead of leaving raw
    # terminal escapes (e.g. Shift+Enter → ;2;13~, Shift+Right → 1;2C).
    # Regenerated on install, removed on uninstall — don't edit by hand.
    if [ -n "${ZSH_VERSION:-}" ]; then
      # Modified Enter → act like Enter
      bindkey '^[[27;2;13~' accept-line          # Shift+Enter
      bindkey '^[[27;5;13~' accept-line          # Ctrl+Enter
      bindkey '^[[27;6;13~' accept-line          # Ctrl+Shift+Enter
      # Left/Right: Shift = by char, Ctrl/Alt = by word
      bindkey '^[[1;2D' backward-char            # Shift+Left
      bindkey '^[[1;2C' forward-char             # Shift+Right
      bindkey '^[[1;5D' backward-word            # Ctrl+Left
      bindkey '^[[1;5C' forward-word             # Ctrl+Right
      bindkey '^[[1;3D' backward-word            # Alt+Left
      bindkey '^[[1;3C' forward-word             # Alt+Right
      # Up/Down (any modifier) → history, like the plain arrows
      bindkey '^[[1;2A' up-line-or-history       # Shift+Up
      bindkey '^[[1;2B' down-line-or-history     # Shift+Down
      bindkey '^[[1;5A' up-line-or-history       # Ctrl+Up
      bindkey '^[[1;5B' down-line-or-history     # Ctrl+Down
      bindkey '^[[1;3A' up-line-or-history       # Alt+Up
      bindkey '^[[1;3B' down-line-or-history     # Alt+Down
      # Home/End (any modifier) → start/end of line
      bindkey '^[[1;2H' beginning-of-line        # Shift+Home
      bindkey '^[[1;2F' end-of-line              # Shift+End
      bindkey '^[[1;5H' beginning-of-line        # Ctrl+Home
      bindkey '^[[1;5F' end-of-line              # Ctrl+End
      bindkey '^[[1;3H' beginning-of-line        # Alt+Home
      bindkey '^[[1;3F' end-of-line              # Alt+End
      # Delete: Shift = one char, Ctrl/Alt = word
      bindkey '^[[3;2~' delete-char              # Shift+Delete
      bindkey '^[[3;5~' kill-word                # Ctrl+Delete
      bindkey '^[[3;3~' kill-word                # Alt+Delete
    fi
    """

    private static let bashPayload = """
    # Glint shell keybindings — managed by Glint (Settings → Terminal).
    # Regenerated on install, removed on uninstall — don't edit by hand.
    if [ -n "${BASH_VERSION:-}" ]; then
      bind '"\\e[27;2;13~": accept-line' 2>/dev/null   # Shift+Enter
      bind '"\\e[27;5;13~": accept-line' 2>/dev/null   # Ctrl+Enter
      bind '"\\e[27;6;13~": accept-line' 2>/dev/null   # Ctrl+Shift+Enter
      bind '"\\e[1;2D": backward-char' 2>/dev/null     # Shift+Left
      bind '"\\e[1;2C": forward-char' 2>/dev/null      # Shift+Right
      bind '"\\e[1;5D": backward-word' 2>/dev/null     # Ctrl+Left
      bind '"\\e[1;5C": forward-word' 2>/dev/null      # Ctrl+Right
      bind '"\\e[1;3D": backward-word' 2>/dev/null     # Alt+Left
      bind '"\\e[1;3C": forward-word' 2>/dev/null      # Alt+Right
      bind '"\\e[1;2A": previous-history' 2>/dev/null  # Shift+Up
      bind '"\\e[1;2B": next-history' 2>/dev/null      # Shift+Down
      bind '"\\e[1;5A": previous-history' 2>/dev/null  # Ctrl+Up
      bind '"\\e[1;5B": next-history' 2>/dev/null      # Ctrl+Down
      bind '"\\e[1;3A": previous-history' 2>/dev/null  # Alt+Up
      bind '"\\e[1;3B": next-history' 2>/dev/null      # Alt+Down
      bind '"\\e[1;2H": beginning-of-line' 2>/dev/null # Shift+Home
      bind '"\\e[1;2F": end-of-line' 2>/dev/null       # Shift+End
      bind '"\\e[1;5H": beginning-of-line' 2>/dev/null # Ctrl+Home
      bind '"\\e[1;5F": end-of-line' 2>/dev/null       # Ctrl+End
      bind '"\\e[1;3H": beginning-of-line' 2>/dev/null # Alt+Home
      bind '"\\e[1;3F": end-of-line' 2>/dev/null       # Alt+End
      bind '"\\e[3;2~": delete-char' 2>/dev/null       # Shift+Delete
      bind '"\\e[3;5~": kill-word' 2>/dev/null         # Ctrl+Delete
      bind '"\\e[3;3~": kill-word' 2>/dev/null         # Alt+Delete
    fi
    """

    /// The marker block written into the rc: just sources the payload file.
    private static func sourceBlock(_ payloadPath: String) -> String {
        """
        \(beginMarker)
        [ -r "$HOME/\(payloadPath)" ] && source "$HOME/\(payloadPath)"
        \(endMarker)
        """
    }

    private static var targets: [Target] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return [
            Target(rcPath: ".zshrc",
                   payloadPath: ".config/glint/keybindings.zsh",
                   payloadBody: zshPayload,
                   wantedWhenMissing: shell.contains("zsh")),
            Target(rcPath: ".bashrc",
                   payloadPath: ".config/glint/keybindings.bash",
                   payloadBody: bashPayload,
                   wantedWhenMissing: shell.contains("bash")),
        ]
    }

    private static func url(_ rcPath: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rcPath)
    }

    /// Installed if any target rc already carries our source block.
    static func isInstalled() -> Bool {
        for t in targets {
            if let body = try? String(contentsOf: url(t.rcPath), encoding: .utf8),
               body.contains(beginMarker) {
                return true
            }
        }
        return false
    }

    static func install() {
        for t in targets {
            let rcURL = url(t.rcPath)
            let exists = FileManager.default.fileExists(atPath: rcURL.path)
            guard exists || t.wantedWhenMissing else { continue }
            // 1) (re)write the payload file the rc will source.
            writePayload(t.payloadBody, to: url(t.payloadPath))
            // 2) upsert the one-line source block into the rc.
            let current = (try? String(contentsOf: rcURL, encoding: .utf8)) ?? ""
            let updated = upsertBlock(in: current, block: sourceBlock(t.payloadPath))
            guard updated != current else { continue }
            write(updated, to: rcURL, created: !exists)
        }
    }

    static func uninstall() {
        for t in targets {
            let rcURL = url(t.rcPath)
            if let current = try? String(contentsOf: rcURL, encoding: .utf8),
               current.contains(beginMarker) {
                let stripped = removeBlock(from: current)
                if stripped != current { write(stripped, to: rcURL, created: false) }
            }
            try? FileManager.default.removeItem(at: url(t.payloadPath))
        }
        // Drop ~/.config/glint if it's now empty (ignore if it isn't).
        let dir = url(".config/glint")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           entries.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Write a sourced script, creating ~/.config/glint as needed.
    private static func writePayload(_ text: String, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let created = !FileManager.default.fileExists(atPath: fileURL.path)
            let mode = created ? 0o600 : posixPermissions(atPath: fileURL.path)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            setPosixPermissions(mode, atPath: fileURL.path)
        } catch {
            NSLog("[glint] shell keybind payload write failed for \(fileURL.path): \(error)")
        }
    }

    private static func write(_ text: String, to fileURL: URL, created: Bool) {
        do {
            // New file → 0600; existing file → preserve its mode across the
            // atomic replace (which would otherwise reset to the umask).
            let mode = created ? 0o600 : posixPermissions(atPath: fileURL.path)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            setPosixPermissions(mode, atPath: fileURL.path)
        } catch {
            NSLog("[glint] shell keybind write failed for \(fileURL.path): \(error)")
        }
    }

    private static func upsertBlock(in text: String, block: String) -> String {
        if let range = markerRange(in: text) {
            var out = text
            out.replaceSubrange(range, with: block)
            return out
        }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        return out + block + "\n"
    }

    private static func removeBlock(from text: String) -> String {
        guard let range = markerRange(in: text) else { return text }
        var out = text
        out.removeSubrange(range)
        // Trim a leading blank line we may have left where the block sat.
        if out.hasPrefix("\n") { out.removeFirst() }
        return out
    }

    /// Span covering the marker block plus its trailing newline, so removing
    /// it doesn't leave a dangling blank line.
    private static func markerRange(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker),
              begin.lowerBound < end.upperBound else { return nil }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" {
            upper = text.index(after: upper)
        }
        return begin.lowerBound..<upper
    }
}

/// Installs Glint hook entries into Devin CLI's user-level config at
/// `~/.config/devin/config.json` under the `"hooks"` key.
///
/// Devin CLI uses a Claude-compatible hook format — same JSON schema and a
/// subset of the same event names. The shared `glint-report.sh` script handles
/// the reporting; Devin's entries pass `devin` as the agent kind argument
/// so the pane is correctly attributed.
///
/// Unlike Claude/Codex, Devin's config file may contain non-hook keys
/// (`version`, `agent`, `permissions`, …) which must be preserved.
enum DevinHookInstaller {
    /// Events Glint reacts to *and* Devin actually emits. Per Devin's hook
    /// docs the supported events are SessionStart, SessionEnd, UserPromptSubmit,
    /// PreToolUse, PostToolUse, PermissionRequest and Stop — a subset of
    /// Claude's that omits PreCompact and StopFailure, so neither is registered
    /// here. SessionEnd is Devin-only but Glint doesn't react to it, so it's
    /// skipped too. (Internal, not private, so tests can assert the exact set.)
    static let hookEvents: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
    ]

    /// Devin CLI's user-level config. Injectable so unit tests can point the
    /// installer at a temp file instead of the developer's real `~/.config`.
    static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/devin/config.json")
    }

    static func isInstalled(configURL: URL = DevinHookInstaller.defaultConfigURL()) -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        for (_, bucket) in hooks {
            guard let arr = bucket as? [Any] else { continue }
            for entry in arr {
                guard let group = entry as? [String: Any],
                      let inner = group["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String)?.contains("glint-report.sh") == true }) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether Devin CLI itself looks installed on this Mac.
    static func isAgentPresent() -> Bool {
        AgentPresence.directoryExists(".config/devin")
            || AgentPresence.commandExists("devin")
    }

    static func installIfNeeded(socketPath: String) {
        guard let scriptPath = AgentHookInstaller.ensureReporterScript() else { return }
        mergeDevinHooks(scriptPath: scriptPath)
        _ = socketPath
    }

    // NOTE: `mergeDevinHooks` / `isInstalled` / `uninstall` take an injectable
    // `configURL` (default = real Devin config) so unit tests round-trip
    // against a temp file without touching the developer's `~/.config/devin`.

    /// Remove Glint's entries from `~/.config/devin/config.json`. The reporter
    /// script is shared with Claude and Codex (OpenCode uses its own JS plugin,
    /// not this script), so it's only deleted when none of those agents still
    /// references it.
    static func uninstall(configURL: URL = DevinHookInstaller.defaultConfigURL()) {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            var touched = false
            for (event, bucket) in hooks {
                guard let arr = bucket as? [Any] else { continue }
                let filtered = arr.filter { entry in
                    guard let group = entry as? [String: Any],
                          let inner = group["hooks"] as? [[String: Any]] else { return true }
                    return !inner.contains { ($0["command"] as? String)?.contains("glint-report.sh") == true }
                }
                if filtered.count != arr.count {
                    touched = true
                    if filtered.isEmpty {
                        hooks.removeValue(forKey: event)
                    } else {
                        hooks[event] = filtered
                    }
                }
            }
            if touched {
                if hooks.isEmpty {
                    root.removeValue(forKey: "hooks")
                } else {
                    root["hooks"] = hooks
                }
                if let out = SafeJSON.data(
                    root,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ) {
                    let mode = posixPermissions(atPath: url.path)
                    try? out.write(to: url, options: [.atomic])
                    setPosixPermissions(mode, atPath: url.path)
                }
                NSLog("[glint] devin hooks removed from \(url.path)")
            }
        }
        // Only nuke the shared reporter if no other agent still references it.
        // Skipped for an injected (test) config path so unit tests never touch
        // the real ~/.glint reporter script.
        if url == DevinHookInstaller.defaultConfigURL(),
           !AgentHookInstaller.isInstalled()
            && !CodexHookInstaller.isInstalled()
            && !DevinHookInstaller.isInstalled() {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let script = home.appendingPathComponent(".glint/hooks/glint-report.sh")
            try? FileManager.default.removeItem(at: script)
        }
    }

    static func mergeDevinHooks(scriptPath: String,
                                configURL: URL = DevinHookInstaller.defaultConfigURL()) {
        let url = configURL
        let devinDir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: devinDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[glint] couldn't create ~/.config/devin: \(error)")
            return
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                let backup = url.appendingPathExtension("glint-backup")
                try? FileManager.default.copyItem(at: url, to: backup)
                setPosixPermissions(posixPermissions(atPath: url.path), atPath: backup.path)
                NSLog("[glint] ~/.config/devin/config.json isn't a JSON object; backed up to \(backup.lastPathComponent), skipping merge")
                return
            }
            root = dict
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        for event in hookEvents {
            var bucket = (hooks[event] as? [Any]) ?? []
            let filtered = bucket.filter { entry in
                guard let group = entry as? [String: Any],
                      let inner = group["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains { ($0["command"] as? String)?.contains("glint-report.sh") == true }
            }
            let ours: [String: Any] = [
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptPath) \(event) devin",
                ]],
            ]
            bucket = filtered + [ours]
            if !equalsJSON(hooks[event], bucket) {
                hooks[event] = bucket
                changed = true
            }
        }

        if !changed { return }
        root["hooks"] = hooks
        guard let data = SafeJSON.data(
            root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            NSLog("[glint] ~/.config/devin/config.json: hook tree not serializable, skipping write")
            return
        }
        do {
            let mode = posixPermissions(atPath: url.path)
            let prev = url.appendingPathExtension("glint-prev")
            if FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.fileExists(atPath: prev.path) {
                try? FileManager.default.copyItem(at: url, to: prev)
                setPosixPermissions(mode, atPath: prev.path)
            }
            try data.write(to: url, options: [.atomic])
            setPosixPermissions(mode, atPath: url.path)
            NSLog("[glint] devin hooks merged into \(url.path)")
        } catch {
            NSLog("[glint] writing ~/.config/devin/config.json failed: \(error)")
        }
    }

    private static func equalsJSON(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let da = SafeJSON.data(a, options: opts),
              let db = SafeJSON.data(b, options: opts) else {
            return false
        }
        return da == db
    }
}
