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
            "\(home)/.grok/bin",
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

    /// Installers whose hooks reference the shared `~/.glint/hooks/glint-report.sh`
    /// reporter. The single source of truth consulted by
    /// `removeReporterScriptIfUnused` — adding a new agent that adopts the
    /// shared reporter is a one-line change here, not an edit to every
    /// uninstall path.
    private static let reporterSharingInstallers: [() -> Bool] = [
        { AgentHookInstaller.isInstalled() },
        { CodexHookInstaller.isInstalled() },
        { DevinHookInstaller.isInstalled() },
        { GrokHookInstaller.isInstalled() },
    ]

    /// Delete the shared reporter script iff no installed agent still
    /// references it. Callers that run under an injected (test) config path
    /// must gate the call themselves so unit tests never delete the real
    /// `~/.glint` reporter (see DevinHookInstaller.uninstall).
    static func removeReporterScriptIfUnused() {
        guard !reporterSharingInstallers.contains(where: { $0() }) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent(".glint/hooks/glint-report.sh")
        try? FileManager.default.removeItem(at: script)
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
        removeReporterScriptIfUnused()
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

    /// Pure POSIX sh. Every agent (Claude, Codex, OpenCode, Devin) inherits
    /// `$GLINT_PANE_ID` and `$GLINT_AGENT_SOCK` from the pane environment and
    /// uses them to address Glint directly. Codex 0.142.0 verified via env
    /// dump (`ps eww`) — hook subprocesses keep both vars.
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
    ///
    /// We also pull `session_id` from the JSON payload on stdin and forward
    /// it as `session_b64`, so restore-on-launch can use `--resume <id>`
    /// instead of `--continue` (issue #45). When extraction fails (older CLI,
    /// non-JSON payload) the field is omitted; the receiver tells "no id
    /// captured" apart from "captured but empty".
    /// Codex PermissionRequest events also forward transcript_path + turn_id;
    /// AgentBridge uses that pair to resolve the effective approvals reviewer.
    static let scriptBody: String = """
    #!/bin/sh
    # Glint CLI-agent hook reporter. argv: event, agent kind.
    HOOK="${1:-Unknown}"
    AGENT="${2:-claude}"
    PANE="${GLINT_PANE_ID:-}"
    SOCK="${GLINT_AGENT_SOCK:-}"

    # Grok injects GROK_SESSION_ID on every hook process and, by default, also
    # loads ~/.claude/settings.json hooks for Claude Code compatibility. That
    # dual-fires Glint's Claude entry (agent defaults to "claude", no ask
    # remap) alongside ~/.grok/hooks/glint.json (agent=grok). Last writer wins
    # in WorkspaceStore and can wipe NeedsReply / mis-key session ids under
    # "claude". Skip non-grok reports when this env is set so only the
    # dedicated Grok hook owns the pane state.
    if [ -n "${GROK_SESSION_ID:-}" ] && [ "$AGENT" != "grok" ]; then
      cat >/dev/null 2>&1
      exit 0
    fi

    # Always exits 0 — a missing pane/socket or a `nc` failure is silently
    # swallowed so a transient bridge outage can never block an agent hook.
    if [ -z "$PANE" ] || [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
      cat >/dev/null 2>&1
      exit 0
    fi

    umask 077
    # The temp file is only needed to extract the OPTIONAL session_id (plutil
    # reads a file). If mktemp fails (rare: TMPDIR gone / full), drain stdin
    # but STILL deliver the event without a session id — the event drives pane
    # state (idle/thinking/stop/permission), while the id only optimizes #45
    # resume. Dropping the whole event (the old `exit 0`) stalled the pane
    # silently until mktemp recovered.
    SESSION=""
    TRANSCRIPT=""
    TURN=""
    if TMP=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/glint-hook.XXXXXX"); then
      trap '/bin/rm -f "$TMP"' EXIT HUP INT TERM
      cat >"$TMP"
      # Claude/Codex use snake_case; Grok's hook payload uses camelCase
      # `sessionId`. Try both, then fall back to GROK_SESSION_ID env (set on
      # every Grok hook process).
      SESSION=$(/usr/bin/plutil -extract session_id raw -o - "$TMP" 2>/dev/null || true)
      if [ -z "$SESSION" ]; then
        SESSION=$(/usr/bin/plutil -extract sessionId raw -o - "$TMP" 2>/dev/null || true)
      fi
      if [ -z "$SESSION" ] && [ -n "${GROK_SESSION_ID:-}" ]; then
        SESSION="$GROK_SESSION_ID"
      fi
      # Grok's ask_user_question (and exit_plan_mode plan approval) block the
      # turn waiting for the user — same semantics as OMP's `ask` tool. Remap
      # PreToolUse → NeedsReply so the sidebar shows "awaiting reply".
      if [ "$HOOK" = "PreToolUse" ] && [ "$AGENT" = "grok" ]; then
        TOOL=$(/usr/bin/plutil -extract toolName raw -o - "$TMP" 2>/dev/null || true)
        case "$TOOL" in
          ask_user_question|exit_plan_mode) HOOK="NeedsReply" ;;
        esac
      fi
      if [ "$HOOK" = "PermissionRequest" ] && [ "$AGENT" = "codex" ]; then
        TRANSCRIPT=$(/usr/bin/plutil -extract transcript_path raw -o - "$TMP" 2>/dev/null || true)
        TURN=$(/usr/bin/plutil -extract turn_id raw -o - "$TMP" 2>/dev/null || true)
      fi
      /bin/rm -f "$TMP"
      trap - EXIT HUP INT TERM
    else
      cat >/dev/null 2>&1
    fi

    APPROVAL_META=""
    if [ -n "$TRANSCRIPT" ] && [ -n "$TURN" ]; then
      TRANSCRIPT_B64=$(printf '%s' "$TRANSCRIPT" | /usr/bin/base64 | /usr/bin/tr -d '\\r\\n')
      TURN_B64=$(printf '%s' "$TURN" | /usr/bin/base64 | /usr/bin/tr -d '\\r\\n')
      APPROVAL_META=$(printf ',"transcript_b64":"%s","turn_b64":"%s"' \\
        "$TRANSCRIPT_B64" "$TURN_B64")
    fi

    if [ -n "$SESSION" ]; then
      SESSION_B64=$(printf '%s' "$SESSION" | /usr/bin/base64 | /usr/bin/tr -d '\\r\\n')
      printf '{"pane":"%s","hook":"%s","agent":"%s","session_b64":"%s"%s}\\n' \\
        "$PANE" "$HOOK" "$AGENT" "$SESSION_B64" "$APPROVAL_META" \\
        | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1 || true
    else
      printf '{"pane":"%s","hook":"%s","agent":"%s"%s}\\n' \\
        "$PANE" "$HOOK" "$AGENT" "$APPROVAL_META" \\
        | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1 || true
    fi
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
/// Codex passes the entire hook payload on stdin, same as Claude. The shared
/// reporter pulls `session_id` out for restore-on-launch (#45), adds the
/// approval context needed for Codex PermissionRequest events, and forwards
/// the event to Glint's local socket using the pane env vars.
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
        CodexHomeStore.configuredHomes().contains { isInstalled(in: $0.resolvedURL) }
    }

    static func isInstalled(in codexHome: URL) -> Bool {
        let url = codexHome.appendingPathComponent("hooks.json")
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

    static func status(in codexHome: URL) -> CodexHookStatus {
        let url = codexHome.appendingPathComponent("hooks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .notInstalled }
        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return .error(String(localized: "Invalid hooks.json"))
        }
        return isInstalled(in: codexHome) ? .installed : .notInstalled
    }

    /// Whether the Codex CLI itself looks installed on this Mac.
    static func isAgentPresent() -> Bool {
        AgentPresence.directoryExists(".codex")
            || AgentPresence.commandExists("codex")
    }

    static func installIfNeeded(socketPath: String) {
        guard let scriptPath = AgentHookInstaller.ensureReporterScript() else { return }
        for home in CodexHomeStore.configuredHomes().filter(\.isEnabled) {
            do {
                try mergeCodexHooks(scriptPath: scriptPath, codexHome: home.resolvedURL)
            } catch {
                NSLog("[glint] codex hook install failed for \(home.resolvedURL.path): \(error)")
            }
        }
        _ = socketPath
    }

    static func install(in codexHome: URL) throws {
        guard let scriptPath = AgentHookInstaller.ensureReporterScript() else {
            throw CodexHookInstallerError.reporterUnavailable
        }
        try mergeCodexHooks(scriptPath: scriptPath, codexHome: codexHome)
    }

    /// Remove Glint's entries from `~/.codex/hooks.json`. The reporter script
    /// itself is shared with Claude, so we only delete it when neither agent
    /// still references it.
    static func uninstall() {
        for home in CodexHomeStore.configuredHomes() {
            try? uninstall(from: home.resolvedURL)
        }
        AgentHookInstaller.removeReporterScriptIfUnused()
    }

    static func uninstall(from codexHome: URL) throws {
        let url = codexHome.appendingPathComponent("hooks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexHookInstallerError.readFailed(error.localizedDescription)
        }
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHookInstallerError.invalidHooksJSON
        }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var touched = false
        for (event, bucket) in Array(hooks) {
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
                try FileManager.default.removeItem(at: url)
            } else if let out = SafeJSON.data(
                root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) {
                let mode = posixPermissions(atPath: url.path)
                try out.write(to: url, options: [.atomic])
                setPosixPermissions(mode, atPath: url.path)
            }
            NSLog("[glint] codex hooks removed from \(url.path)")
        }
    }

    static func mergeCodexHooks(scriptPath: String, codexHome: URL) throws {
        let codexDir = codexHome.standardizedFileURL
        let url = codexDir.appendingPathComponent("hooks.json")
        do {
            try FileManager.default.createDirectory(
                at: codexDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CodexHookInstallerError.cannotCreateHome(error.localizedDescription)
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                let backup = url.appendingPathExtension("glint-backup")
                try? FileManager.default.copyItem(at: url, to: backup)
                setPosixPermissions(posixPermissions(atPath: url.path), atPath: backup.path)
                throw CodexHookInstallerError.invalidHooksJSON
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
            throw CodexHookInstallerError.invalidHookTree
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
            throw CodexHookInstallerError.writeFailed(error.localizedDescription)
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

enum CodexHookInstallerError: LocalizedError, Equatable {
    case reporterUnavailable
    case cannotCreateHome(String)
    case invalidHooksJSON
    case invalidHookTree
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .reporterUnavailable: return String(localized: "Could not create the Glint reporter script.")
        case .cannotCreateHome(let detail): return String(localized: "Could not create the Codex Home directory: \(detail)")
        case .invalidHooksJSON: return String(localized: "Invalid hooks.json. The file was not modified.")
        case .invalidHookTree: return String(localized: "The hook configuration cannot be encoded as JSON.")
        case .readFailed(let detail): return String(localized: "Could not read hooks.json: \(detail)")
        case .writeFailed(let detail): return String(localized: "Could not write hooks.json: \(detail)")
        }
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

    // Pluck a session id from any of the spots OpenCode events stash it at.
    // OpenCode uses both `sessionID` and `sessionId` in different payloads
    // (verified against the bundled CLI binary), and may nest the value under
    // a `session` or `info` sub-object. Returning the first hit means a future
    // event-shape tweak only loses the field, never crashes the plugin.
    // Same charset/length whitelist Swift's `PaneAgentKind.isValid(sessionId:)`
    // enforces — the alphabet and max length below are interpolated FROM Swift
    // at template-build time, so widening one side automatically widens the
    // other and the two validators can't drift.
    const SESSION_ID_RE = /^\(PaneAgentKind.sessionIdCharsetClass){1,\(PaneAgentKind.sessionIdMaxLength)}$/
    const pickSessionId = (event) => {
      const candidates = [
        event?.properties?.sessionID,
        event?.properties?.sessionId,
        event?.properties?.session?.id,
        event?.properties?.session?.sessionID,
        event?.properties?.info?.id,
        event?.properties?.info?.sessionID,
        event?.sessionID,
        event?.sessionId,
      ]
      for (const c of candidates) {
        if (typeof c === "string" && SESSION_ID_RE.test(c)) return c
      }
      return null
    }

    const send = async (hook, sessionId) => {
      const pane = process.env.GLINT_PANE_ID
      const sock = process.env.GLINT_AGENT_SOCK
      if (!pane || !sock || !existsSync(sock)) return

      // session_b64 mirrors the protocol the shell reporter uses for Claude/
      // Codex — AgentBridge decodes the same field regardless of agent. Send
      // it only when we actually have an id so the receiver doesn't waste
      // cycles decoding empty payloads.
      const payload = { pane, hook, agent: AGENT }
      if (sessionId) {
        payload.session_b64 = Buffer.from(sessionId, "utf8").toString("base64")
      }
      const line = JSON.stringify(payload) + "\\n"
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
          const sid = pickSessionId(event)
          switch (event.type) {
            case "session.created":
              await send("SessionStart", sid)
              break
            case "session.status": {
              const status = event.properties?.status?.type ?? event.properties?.status
              if (status === "busy" || status === "running") await send("UserPromptSubmit", sid)
              if (status === "idle") await send("Stop", sid)
              break
            }
            case "session.idle":
              await send("Stop", sid)
              break
            case "session.error":
              await send("StopFailure", sid)
              break
            case "session.compacted":
              await send("PreCompact", sid)
              break
            case "permission.asked":
              await send("PermissionRequest", sid)
              break
            case "permission.replied":
              await send("PreToolUse", sid)
              break
          }
        },
        // OpenCode passes the tool-call context to these handlers; we don't
        // know the exact shape per version, but `pickSessionId` walks the
        // usual hiding spots defensively and returns null when it strikes
        // out — so a stale schema just drops the id, never throws.
        "tool.execute.before": async (ctx) => {
          await send("PreToolUse", pickSessionId(ctx))
        },
        "tool.execute.after": async (ctx) => {
          await send("PostToolUse", pickSessionId(ctx))
        },
      }
    }
    """
}

/// Installs a TypeScript extension that forwards Oh My Pi (omp) lifecycle
/// events to Glint's local agent socket.
///
/// Portable across machines (no absolute home paths, no host-specific layout):
///   1. Writes the module to `~/.glint/hooks/omp-agent-bridge.ts` — under
///      Glint's own dot-dir, so OMP's agent-dir gitignore cannot hide it.
///   2. Registers the portable tilde path `~/.glint/hooks/omp-agent-bridge.ts`
///      in `~/.omp/agent/settings.json` → `extensions` (OMP expands `~` and
///      configured paths bypass the gitignore filter that applies to
///      auto-discovery of `~/.omp/agent/extensions/`).
///
/// Why not only drop into `~/.omp/agent/extensions/`? OMP's native scan of
/// that directory uses `gitignore: true`. Users who keep `~/.omp/agent` as a
/// git-synced config repo with a whitelist ignore (`*`) would get a silent
/// no-op install — Settings would say "Installed" but OMP never loads the
/// file. The settings.json registration works for every install layout.
///
/// The extension maps OMP's `pi.on(...)` events onto the same Claude-
/// compatible hook names `WorkspaceStore.handleAgentEvent` already understands.
enum OmpHookInstaller {
    private static let extensionFileName = "omp-agent-bridge.ts"
    /// Marker string embedded in the generated extension body — `isInstalled`
    /// keys off it so a hand-written file in the same path isn't treated as
    /// Glint-managed, and so reinstalls can rewrite our own copy safely.
    static let marker = "Glint OMP extension"

    /// Tilde-form path written into settings.json so the entry stays portable
    /// across machines / home-dir renames. OMP expands `~` for configured paths.
    static let settingsExtensionRef = "~/.glint/hooks/\(extensionFileName)"

    /// Real paths. Injectable so unit tests never write into the developer's
    /// home directory.
    static func defaultExtensionURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".glint/hooks", isDirectory: true)
            .appendingPathComponent(extensionFileName)
    }

    static func defaultSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/settings.json")
    }

    /// Absolute path variants of `settingsExtensionRef` that may already live
    /// in a settings.json from an earlier install — treated as ours on uninstall.
    private static func knownExtensionRefs(extensionURL: URL) -> Set<String> {
        [settingsExtensionRef, extensionURL.path, (extensionURL.path as NSString).expandingTildeInPath]
    }

    static func isInstalled(extensionURL: URL = OmpHookInstaller.defaultExtensionURL(),
                            settingsURL: URL = OmpHookInstaller.defaultSettingsURL()) -> Bool {
        guard let body = try? String(contentsOf: extensionURL), body.contains(marker) else {
            return false
        }
        return settingsListsExtension(settingsURL: settingsURL, extensionURL: extensionURL)
    }

    /// Whether OMP itself looks installed on this Mac.
    static func isAgentPresent() -> Bool {
        AgentPresence.directoryExists(".omp")
            || AgentPresence.directoryExists(".omp/agent")
            || AgentPresence.commandExists("omp")
    }

    static func installIfNeeded(socketPath: String,
                                extensionURL: URL = OmpHookInstaller.defaultExtensionURL(),
                                settingsURL: URL = OmpHookInstaller.defaultSettingsURL()) {
        do {
            let dir = extensionURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let body = extensionBody
            let needsWrite = (try? String(contentsOf: extensionURL)) != body
            if needsWrite {
                try body.write(to: extensionURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: extensionURL.path
                )
            }
            try mergeSettings(settingsURL: settingsURL, extensionURL: extensionURL)
            // Drop any legacy copy under ~/.omp/agent/extensions/ that an
            // earlier Glint build left behind — those files are invisible to
            // OMP when the agent dir is a whitelist-gitignore repo, and only
            // confuse "is it installed?" eyeballing.
            removeLegacyAgentExtensionsCopy()
            NSLog("[glint] omp extension installed at \(extensionURL.path)")
        } catch {
            NSLog("[glint] omp extension install failed: \(error)")
        }
        _ = socketPath
    }

    static func uninstall(extensionURL: URL = OmpHookInstaller.defaultExtensionURL(),
                          settingsURL: URL = OmpHookInstaller.defaultSettingsURL()) {
        // Always try to un-register, even if the file is already gone.
        try? unmergeSettings(settingsURL: settingsURL, extensionURL: extensionURL)
        if let body = try? String(contentsOf: extensionURL), body.contains(marker) {
            try? FileManager.default.removeItem(at: extensionURL)
            NSLog("[glint] omp extension removed from \(extensionURL.path)")
        }
        removeLegacyAgentExtensionsCopy()
    }

    // MARK: settings.json merge

    private static func settingsListsExtension(settingsURL: URL, extensionURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["extensions"] as? [String] else {
            return false
        }
        let known = knownExtensionRefs(extensionURL: extensionURL)
        return list.contains { known.contains($0) }
    }

    private static func mergeSettings(settingsURL: URL, extensionURL: URL) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                let backup = settingsURL.appendingPathExtension("glint-backup")
                try? FileManager.default.copyItem(at: settingsURL, to: backup)
                setPosixPermissions(posixPermissions(atPath: settingsURL.path), atPath: backup.path)
                NSLog("[glint] \(settingsURL.path) isn't a JSON object; backed up, skipping merge")
                return
            }
            root = dict
        }

        var list = (root["extensions"] as? [String]) ?? []
        let known = knownExtensionRefs(extensionURL: extensionURL)
        // Drop every prior Glint ref (absolute or tilde form), then re-add the
        // portable tilde form so reinstalls don't accumulate duplicates.
        list.removeAll { known.contains($0) }
        list.append(settingsExtensionRef)
        root["extensions"] = list

        guard let out = SafeJSON.data(
            root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            NSLog("[glint] omp settings.json: not serializable, skipping write")
            return
        }
        let mode = posixPermissions(atPath: settingsURL.path)
        try out.write(to: settingsURL, options: [.atomic])
        setPosixPermissions(mode, atPath: settingsURL.path)
        NSLog("[glint] omp settings.json registered \(settingsExtensionRef)")
    }

    private static func unmergeSettings(settingsURL: URL, extensionURL: URL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let data = try Data(contentsOf: settingsURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        guard var list = root["extensions"] as? [String] else { return }
        let known = knownExtensionRefs(extensionURL: extensionURL)
        let before = list.count
        list.removeAll { known.contains($0) }
        guard list.count != before else { return }
        if list.isEmpty {
            root.removeValue(forKey: "extensions")
        } else {
            root["extensions"] = list
        }
        if root.isEmpty {
            try FileManager.default.removeItem(at: settingsURL)
        } else if let out = SafeJSON.data(
            root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            let mode = posixPermissions(atPath: settingsURL.path)
            try out.write(to: settingsURL, options: [.atomic])
            setPosixPermissions(mode, atPath: settingsURL.path)
        }
        NSLog("[glint] omp settings.json unregistered \(settingsExtensionRef)")
    }

    /// Earlier builds wrote into `~/.omp/agent/extensions/`, which a
    /// whitelist-gitignore agent repo renders invisible to OMP discovery.
    /// Clean those up so they don't look "installed" while doing nothing.
    private static func removeLegacyAgentExtensionsCopy() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/extensions/glint-agent-bridge.ts")
        guard let body = try? String(contentsOf: legacy), body.contains(marker) else { return }
        try? FileManager.default.removeItem(at: legacy)
        NSLog("[glint] removed legacy omp extension at \(legacy.path)")
    }

    /// TypeScript extension loaded by OMP's extension runner. Only arms when
    /// the pane env vars are present, so an omp session outside Glint is a
    /// no-op. Session id is pulled from `ctx.sessionManager` when available
    /// and forwarded as `session_b64` for restore-on-launch.
    static let extensionBody: String = """
    // \(marker). Auto-generated by Glint; remove from Settings → Agents.
    // @ts-nocheck
    import { createConnection } from "node:net"
    import { existsSync } from "node:fs"

    const AGENT = "omp"
    const SESSION_ID_RE = /^\(PaneAgentKind.sessionIdCharsetClass){1,\(PaneAgentKind.sessionIdMaxLength)}$/

    function pickSessionId(ctx) {
      try {
        const id = ctx?.sessionManager?.getSessionId?.()
        if (typeof id === "string" && SESSION_ID_RE.test(id)) return id
      } catch {}
      return null
    }

    function send(hook, sessionId) {
      const pane = process.env.GLINT_PANE_ID
      const sock = process.env.GLINT_AGENT_SOCK
      if (!pane || !sock || !existsSync(sock)) return Promise.resolve()

      const payload = { pane, hook, agent: AGENT }
      if (sessionId) {
        payload.session_b64 = Buffer.from(sessionId, "utf8").toString("base64")
      }
      const line = JSON.stringify(payload) + "\\n"

      // Use end(line) so the write is flushed before the socket closes —
      // write()+destroy() races the kernel and can drop the report.
      return new Promise((resolve) => {
        let done = false
        const finish = () => {
          if (done) return
          done = true
          resolve()
        }
        try {
          const client = createConnection(sock, () => client.end(line))
          client.on("error", finish)
          client.on("close", finish)
          const timer = setTimeout(() => {
            try { client.destroy() } catch {}
            finish()
          }, 1000)
          timer.unref?.()
        } catch {
          finish()
        }
      })
    }

    function endedInError(event) {
      const messages = Array.isArray(event?.messages) ? event.messages : []
      for (let i = messages.length - 1; i >= 0; i -= 1) {
        if (messages[i]?.role === "assistant" && messages[i]?.stopReason === "error") {
          return true
        }
      }
      return false
    }

    export default function (pi) {
      const pane = process.env.GLINT_PANE_ID
      const sock = process.env.GLINT_AGENT_SOCK
      if (!pane || !sock) return

      // session_start fires once per root session — subagents run inside
      // the same session, so this reliably identifies the root. OMP 16.5.2
      // sets ctx.hasUI to false even in interactive mode, so we can't use it.
      let rootSession = false
      // Depth counter: nested subagent turns increment/decrement this. We
      // only report NeedsReply/StopFailure when depth returns to 0, so a
      // subagent's agent_end doesn't prematurely clear the root turn's status.
      let activeDepth = 0

      pi.on("session_start", (_event, ctx) => {
        rootSession = true
        void send("SessionStart", pickSessionId(ctx))
      })

      pi.on("session_switch", (_event, ctx) => {
        rootSession = true
        activeDepth = 0
        void send("SessionStart", pickSessionId(ctx))
      })

      pi.on("agent_start", (_event, ctx) => {
        if (!rootSession) return
        activeDepth++
        // Only report UserPromptSubmit on the first (root) agent_start —
        // subagent starts shouldn't re-trigger the "thinking" transition.
        if (activeDepth === 1) {
          void send("UserPromptSubmit", pickSessionId(ctx))
        }
      })

      pi.on("tool_call", (event, ctx) => {
        if (!rootSession) return
        // The ask tool blocks waiting for user input — surface it as
        // NeedsReply so the tab reads "awaiting reply" not "running…".
        if (event?.toolName === "ask") {
          void send("NeedsReply", pickSessionId(ctx))
        } else {
          void send("PreToolUse", pickSessionId(ctx))
        }
      })

      pi.on("tool_result", (_event, ctx) => {
        if (!rootSession) return
        void send("PostToolUse", pickSessionId(ctx))
      })

      pi.on("tool_approval_requested", (_event, ctx) => {
        if (!rootSession) return
        void send("PermissionRequest", pickSessionId(ctx))
      })

      pi.on("tool_approval_resolved", (_event, ctx) => {
        if (!rootSession) return
        // Mirror OpenCode's permission.replied → PreToolUse clear path: once
        // the user answers, the next tool_call will re-assert .tool.
        void send("PreToolUse", pickSessionId(ctx))
      })

      pi.on("session_before_compact", (_event, ctx) => {
        if (!rootSession) return
        void send("PreCompact", pickSessionId(ctx))
      })

      pi.on("auto_compaction_start", (_event, ctx) => {
        if (!rootSession) return
        void send("PreCompact", pickSessionId(ctx))
      })

      pi.on("agent_end", (event, ctx) => {
        if (!rootSession) return
        if (activeDepth > 0) activeDepth--
        // Only report turn end when all nested agents have finished.
        if (activeDepth > 0) return
        void send(endedInError(event) ? "StopFailure" : "Stop", pickSessionId(ctx))
      })
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

    // Block-management math lives in `ShellRcBlock` so InlineSuggestionInstaller
    // and this installer share one set of edge-case handling. The two
    // installers' fenced blocks coexist in the same .zshrc with different
    // sentinels.
    private static func upsertBlock(in text: String, block: String) -> String {
        ShellRcBlock.upsert(in: text, begin: beginMarker, end: endMarker, block: block)
    }

    private static func removeBlock(from text: String) -> String {
        ShellRcBlock.remove(from: text, begin: beginMarker, end: endMarker)
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
        if url == DevinHookInstaller.defaultConfigURL() {
            AgentHookInstaller.removeReporterScriptIfUnused()
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

/// Installs Glint hook entries for Grok Build CLI into
/// `~/.grok/hooks/glint.json`.
///
/// Grok discovers hooks from several sources (including Claude's settings for
/// compat). We write a **dedicated** file under `~/.grok/hooks/` so:
///   1. Grok sessions report `agent=grok` (not Claude's `claude` argv), and
///   2. uninstall only removes Glint's Grok file — never rewrites
///      `~/.claude/settings.json`.
///
/// Schema matches Claude's hooks subtree. The shared `glint-report.sh`
/// remaps Grok's `ask_user_question` / `exit_plan_mode` PreToolUse events to
/// `NeedsReply` so the sidebar surfaces "awaiting reply".
enum GrokHookInstaller {
    /// Events Grok documents and Glint's status machine reacts to.
    /// Grok has no `PermissionRequest` hook (approvals are TUI-native); it
    /// does expose `StopFailure` and `PreCompact`, which we register.
    /// (Internal, not private, so tests can assert the exact set.)
    static let hookEvents: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PreCompact",
        "Stop",
        "StopFailure",
    ]

    /// Marker filename under `~/.grok/hooks/`. Other user/plugin hook files
    /// stay untouched.
    static let hooksFileName = "glint.json"

    static func defaultHooksURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/hooks/\(hooksFileName)")
    }

    static func isInstalled(hooksURL: URL = GrokHookInstaller.defaultHooksURL()) -> Bool {
        guard let data = try? Data(contentsOf: hooksURL),
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

    /// Whether Grok Build itself looks installed on this Mac.
    /// Prefer binary / config signals over a bare `~/.grok` directory: installing
    /// hooks creates `~/.grok/hooks/`, which would otherwise permanently mark
    /// the agent "detected" even when `grok` was never on PATH.
    static func isAgentPresent() -> Bool {
        AgentPresence.commandExists("grok")
            || AgentPresence.fileExists(".grok/config.toml")
            || AgentPresence.fileExists(".grok/version.json")
            || AgentPresence.fileExists(".grok/bin/grok")
    }

    /// Events where Grok rejects a `matcher` field entirely (docs: lifecycle
    /// events reject a matcher; empty/omitted matches everything on tool
    /// events). We omit matcher for *all* Glint entries so SessionStart /
    /// UserPromptSubmit / Stop never get dropped for carrying `"*"`.
    static let lifecycleEventsRejectingMatcher: Set<String> = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
    ]

    static func installIfNeeded(socketPath: String) {
        guard let scriptPath = AgentHookInstaller.ensureReporterScript() else { return }
        mergeGrokHooks(scriptPath: scriptPath)
        _ = socketPath
    }

    /// Remove Glint's `~/.grok/hooks/glint.json`. The shared reporter is only
    /// deleted when no other agent still references it. Injectable `hooksURL`
    /// keeps unit tests off the developer's real Grok config.
    static func uninstall(hooksURL: URL = GrokHookInstaller.defaultHooksURL()) {
        if FileManager.default.fileExists(atPath: hooksURL.path) {
            try? FileManager.default.removeItem(at: hooksURL)
            NSLog("[glint] grok hooks removed from \(hooksURL.path)")
        }
        if hooksURL == GrokHookInstaller.defaultHooksURL() {
            AgentHookInstaller.removeReporterScriptIfUnused()
        }
    }

    static func mergeGrokHooks(scriptPath: String,
                               hooksURL: URL = GrokHookInstaller.defaultHooksURL()) {
        let dir = hooksURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("[glint] couldn't create ~/.grok/hooks: \(error)")
            return
        }

        // Dedicated file owned by Glint — rewrite the full hooks map rather
        // than merging into an unknown multi-purpose document. Other files
        // in ~/.grok/hooks/ are left alone.
        //
        // Do NOT put `"matcher": "*"` on these entries. Grok treats matcher as
        // a regex for tool events only, and lifecycle events (SessionStart,
        // UserPromptSubmit, Stop, …) *reject* a matcher — official plugins
        // omit it entirely. Empty/omitted matcher = match-all for tool events.
        var hooks: [String: Any] = [:]
        for event in hookEvents {
            let entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptPath) \(event) grok",
                ]],
            ]
            hooks[event] = [entry] as [Any]
        }
        let root: [String: Any] = ["hooks": hooks]
        guard let data = SafeJSON.data(
            root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            NSLog("[glint] ~/.grok/hooks/glint.json: hook tree not serializable, skipping write")
            return
        }
        // Skip rewrite when content is identical (idempotent install).
        if let existing = try? Data(contentsOf: hooksURL), existing == data {
            return
        }
        do {
            let mode = FileManager.default.fileExists(atPath: hooksURL.path)
                ? posixPermissions(atPath: hooksURL.path)
                : 0o600
            try data.write(to: hooksURL, options: [.atomic])
            setPosixPermissions(mode, atPath: hooksURL.path)
            NSLog("[glint] grok hooks written to \(hooksURL.path)")
        } catch {
            NSLog("[glint] writing ~/.grok/hooks/glint.json failed: \(error)")
        }
    }
}
