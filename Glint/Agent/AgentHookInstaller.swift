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
                if let out = try? JSONSerialization.data(
                    withJSONObject: root,
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
        // references it (Codex shares the same script).
        if !AgentHookInstaller.isInstalled() && !CodexHookInstaller.isInstalled() {
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
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
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
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: opts),
              let db = try? JSONSerialization.data(withJSONObject: b, options: opts) else {
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
    /// Stays cheap (single `nc` send, swallows stdin).
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
      | nc -U -w 1 "$GLINT_AGENT_SOCK" >/dev/null 2>&1 || true
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
                } else if let out = try? JSONSerialization.data(
                    withJSONObject: root,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ) {
                    let mode = posixPermissions(atPath: url.path)
                    try? out.write(to: url, options: [.atomic])
                    setPosixPermissions(mode, atPath: url.path)
                }
                NSLog("[glint] codex hooks removed from \(url.path)")
            }
        }
        // Only nuke the shared reporter if neither Claude nor Codex still
        // references it — otherwise Claude (or a future agent) would break.
        if !AgentHookInstaller.isInstalled() && !CodexHookInstaller.isInstalled() {
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
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
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
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: opts),
              let db = try? JSONSerialization.data(withJSONObject: b, options: opts) else {
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
