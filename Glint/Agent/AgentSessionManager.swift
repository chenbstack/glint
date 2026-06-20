import Foundation

struct AgentCapabilities {
    var supportsHooks: Bool
    var supportsTemporarySettings: Bool
    var supportsOneRunConfigOverrides: Bool
    var supportsConfigDir: Bool
    var supportsResume: Bool
}

protocol AgentAdapter {
    var id: AgentKind { get }
    var displayName: String { get }
    var capabilities: AgentCapabilities { get }
    func writeRuntime(session: AgentSession, directory: URL, runtimePath: String) throws
}

private struct ClaudeAdapter: AgentAdapter {
    let id = AgentKind.claude
    let displayName = "Claude Code"
    let capabilities = AgentCapabilities(supportsHooks: true, supportsTemporarySettings: true,
                                         supportsOneRunConfigOverrides: false,
                                         supportsConfigDir: true, supportsResume: true)

    func writeRuntime(session: AgentSession, directory: URL, runtimePath: String) throws {
        let fm = FileManager.default
        // Keep the command definition identical across sessions so Codex-like
        // trust hashes and Claude overlays do not depend on a random ID.
        let reporter = "\"$GLINT_SESSION_DIR/hooks/glint-report.sh\""
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PermissionRequest", "PreCompact", "Stop", "StopFailure"]
        var glintHooks: [String: Any] = [:]
        if session.profile.hookMode == .glintOverlay {
            for event in events {
                glintHooks[event] = [["matcher": "", "hooks": [[
                    "type": "command", "command": "\(reporter) \(event) claude", "timeout": 1,
                ]]]]
            }
        }
        let overlay: [String: Any] = ["hooks": glintHooks]
        try jsonData(overlay).write(to: directory.appendingPathComponent("claude-settings.json"), options: .atomic)

        var merged: [String: Any] = [:]
        if case .local = session.host,
           let path = session.profile.settingsFile.map(expandHome),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged = object
        }
        var hooks = (merged["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in glintHooks {
            let existing = (hooks[event] as? [Any]) ?? []
            hooks[event] = existing + ((value as? [Any]) ?? [])
        }
        if !hooks.isEmpty { merged["hooks"] = hooks }
        try jsonData(merged).write(to: directory.appendingPathComponent("merged-claude-settings.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600],
                             ofItemAtPath: directory.appendingPathComponent("merged-claude-settings.json").path)

        let real = session.profile.command.isEmpty ? "claude" : session.profile.command
        let configExport = session.profile.configDir.map {
            "export CLAUDE_CONFIG_DIR=\(profilePathExpression($0, host: session.host))\n"
        } ?? ""
        let args = session.profile.args.map(shellQuote).joined(separator: " ")
        let wrapper = """
        #!/bin/sh
        \(configExport)REAL=\(shellQuote(real))
        case "$REAL" in */*) ;; *)
          PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v d="$GLINT_SESSION_DIR/bin" '$0 != d')
          REAL=$(command -v "$REAL" 2>/dev/null)
        esac
        [ -n "$REAL" ] || { echo 'Glint: Claude Code is not installed.' >&2; exit 127; }
        exec "$REAL" --settings "$GLINT_SESSION_DIR/merged-claude-settings.json" \(args) "$@"
        """
        try write(wrapper, to: directory.appendingPathComponent("bin/claude"), mode: 0o700)
    }
}

private struct CodexAdapter: AgentAdapter {
    let id = AgentKind.codex
    let displayName = "Codex CLI"
    let capabilities = AgentCapabilities(supportsHooks: true, supportsTemporarySettings: false,
                                         supportsOneRunConfigOverrides: true,
                                         supportsConfigDir: true, supportsResume: true)

    func writeRuntime(session: AgentSession, directory: URL, runtimePath: String) throws {
        let real = session.profile.command.isEmpty ? "codex" : session.profile.command
        let configExport = session.profile.configDir.map {
            "export CODEX_HOME=\(profilePathExpression($0, host: session.host))\n"
        } ?? ""
        let args = session.profile.args.map(shellQuote).joined(separator: " ")
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PermissionRequest", "PreCompact", "Stop", "StopFailure"]
        let overrides = events.map { event in
            let value = "hooks.\(event)=[{hooks=[{type=\"command\",command=\"\\\"$GLINT_SESSION_DIR/hooks/glint-report.sh\\\" \(event) codex\",timeout=1}]}]"
            return "  -c \(shellQuote(value)) \\\n"
        }.joined()
        let probe = "hooks.Stop=[{hooks=[{type=\"command\",command=\"/bin/true\",timeout=1}]}]"
        let hookLaunch: String
        if session.profile.hookMode == .glintOverlay {
            hookLaunch = """
            if "$REAL" --strict-config -c \(shellQuote(probe)) --version >/dev/null 2>&1; then
              exec "$REAL" \\
            \(overrides)    \(args) "$@"
            fi
            """
        } else {
            hookLaunch = ""
        }
        let wrapper = """
        #!/bin/sh
        \(configExport)REAL=\(shellQuote(real))
        case "$REAL" in */*) ;; *)
          PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v d="$GLINT_SESSION_DIR/bin" '$0 != d')
          REAL=$(command -v "$REAL" 2>/dev/null)
        esac
        [ -n "$REAL" ] || { echo 'Glint: Codex is not installed.' >&2; exit 127; }
        \(hookLaunch)
        exec "$REAL" \(args) "$@"
        """
        try write(wrapper, to: directory.appendingPathComponent("bin/codex"), mode: 0o700)
    }
}

private struct PassthroughAdapter: AgentAdapter {
    let id: AgentKind
    var displayName: String { id.displayName }
    var capabilities: AgentCapabilities {
        AgentCapabilities(supportsHooks: false, supportsTemporarySettings: false,
                          supportsOneRunConfigOverrides: false,
                          supportsConfigDir: false, supportsResume: false)
    }
    func writeRuntime(session: AgentSession, directory: URL, runtimePath: String) throws {
        guard id != .terminal else { return }
        let real = session.profile.command.isEmpty ? id.defaultCommand : session.profile.command
        let args = session.profile.args.map(shellQuote).joined(separator: " ")
        let wrapper = """
        #!/bin/sh
        REAL=\(shellQuote(real))
        case "$REAL" in */*) ;; *)
          PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v d="$GLINT_SESSION_DIR/bin" '$0 != d')
          REAL=$(command -v "$REAL" 2>/dev/null)
        esac
        [ -n "$REAL" ] || { echo 'Glint: \(id.displayName) is not installed.' >&2; exit 127; }
        exec "$REAL" \(args) "$@"
        """
        try write(wrapper, to: directory.appendingPathComponent("bin/\(id.rawValue)"), mode: 0o700)
    }
}

enum AgentSessionManagerError: Error {
    case tmuxNotFound
    case commandFailed(executable: String, status: Int32)
}

/// Compiles an AgentSession into a disposable tmux/SSH runtime. It never edits
/// the selected agent profile or global configuration.
final class AgentSessionManager {
    static let shared = AgentSessionManager()
    private let fm = FileManager.default
    private init() {}

    func prepare(_ session: AgentSession, paneKey: String, bridgeSocket: String) throws -> ManagedSessionLaunch {
        switch session.host {
        case .local: return try prepareLocal(session, paneKey: paneKey, bridgeSocket: bridgeSocket)
        case .ssh(let alias):
            return try prepareRemote(session, sshTarget: alias, paneKey: paneKey, bridgeSocket: bridgeSocket)
        }
    }

    func kill(_ session: AgentSession) throws {
        switch session.host {
        case .local:
            let tmux = try resolveLocalTmux()
            _ = try runAndWait(tmux, ["kill-session", "-t", session.tmuxSessionName])
            try? fm.removeItem(at: sessionDirectory(session.id))
        case .ssh(let alias):
            let dir = "~/.cache/glint/sessions/\(session.id)"
            let remote = """
            TMUX_BIN=$(command -v tmux 2>/dev/null || true)
            if [ -z "$TMUX_BIN" ]; then
              for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
                [ -x "$candidate" ] && TMUX_BIN="$candidate" && break
              done
            fi
            [ -n "$TMUX_BIN" ] || exit 127
            "$TMUX_BIN" kill-session -t \(shellQuote(session.tmuxSessionName)) >/dev/null 2>&1 || true
            rm -rf -- "$HOME/\(dir.dropFirst(2))"
            """
            let status = try runAndWait("/usr/bin/ssh", [alias, remote])
            guard status == 0 else {
                throw AgentSessionManagerError.commandFailed(executable: "ssh", status: status)
            }
            try? fm.removeItem(at: sessionDirectory(session.id))
        }
    }

    private func prepareLocal(_ session: AgentSession, paneKey: String,
                              bridgeSocket: String) throws -> ManagedSessionLaunch {
        let dir = sessionDirectory(session.id)
        try writeRuntimeFiles(session: session, at: dir, runtimePath: dir.path,
                              paneKey: paneKey, socketPath: dir.appendingPathComponent("agent.sock").path)
        let socket = dir.appendingPathComponent("agent.sock")
        try? fm.removeItem(at: socket)
        try fm.createSymbolicLink(at: socket, withDestinationURL: URL(fileURLWithPath: bridgeSocket))
        let env = runtimeEnvironment(session: session, directory: dir.path,
                                     socket: socket.path, paneKey: paneKey)
        return ManagedSessionLaunch(environment: env,
                                    initialInput: "exec \(shellQuote(dir.appendingPathComponent("bootstrap-and-attach.sh").path))\n")
    }

    private func prepareRemote(_ session: AgentSession, sshTarget: String, paneKey: String,
                               bridgeSocket: String) throws -> ManagedSessionLaunch {
        let staging = sessionDirectory(session.id)
        let remoteDir = "~/.cache/glint/sessions/\(session.id)"
        try writeRuntimeFiles(session: session, at: staging, runtimePath: remoteDir,
                              paneKey: paneKey, socketPath: "\(remoteDir)/agent.sock")

        let files: [(relative: String, mode: Int)] = [
            ("env", 0o600),
            ("hooks/glint-report.sh", 0o700),
            ("bin/claude", 0o700),
            ("bin/codex", 0o700),
            ("bin/opencode", 0o700),
            ("claude-settings.json", 0o600),
            ("merged-claude-settings.json", 0o600),
            ("merge-claude-settings.py", 0o700),
            ("bootstrap-and-attach.sh", 0o700),
        ]
        var setup = "set -e; D=\"$HOME/.cache/glint/sessions/\(session.id)\"; mkdir -p \"$D/hooks\" \"$D/bin\"; chmod 700 \"$D\" \"$D/hooks\" \"$D/bin\"; "
        for file in files {
            let relative = file.relative
            let url = staging.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url) else { continue }
            setup += "printf %s \(shellQuote(data.base64EncodedString())) | base64 -d > \"$D/\(relative)\"; chmod \(String(file.mode, radix: 8)) \"$D/\(relative)\"; "
        }
        setup += "exec \"$D/bootstrap-and-attach.sh\""

        let prepareForwardSocket = "mkdir -p \"$HOME/.cache/glint/sessions/\(session.id)\"; rm -f -- \"$HOME/.cache/glint/sessions/\(session.id)/agent.sock\""
        let target = shellQuote(sshTarget)
        let homeProbe = shellQuote("printf '\\n%s\\n' \"$HOME\"")
        let remoteForward = "\"$GLINT_REMOTE_HOME/.cache/glint/sessions/\(session.id)/agent.sock:\(shellDoubleQuoteContent(bridgeSocket))\""
        let ssh = """
        #!/bin/sh
        set -e
        remote_home_output=`ssh \(target) \(homeProbe)` || exit $?
        GLINT_REMOTE_HOME=$(printf '%s\\n' "$remote_home_output" | awk 'NF { last=$0 } END { print last }')
        [ -n "$GLINT_REMOTE_HOME" ] || { printf 'Glint: unable to resolve remote home.\\n' >&2; exit 1; }
        ssh \(target) \(shellQuote(prepareForwardSocket))
        exec ssh -tt -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -R \(remoteForward) \(target) sh -lc \(shellQuote(setup))
        """
        let launcher = staging.appendingPathComponent("launch-remote.sh")
        try write(ssh, to: launcher, mode: 0o700)
        return ManagedSessionLaunch(environment: [:],
                                    initialInput: "exec \(shellQuote(launcher.path))\n")
    }

    private func writeRuntimeFiles(session: AgentSession, at dir: URL, runtimePath: String,
                                   paneKey: String, socketPath: String) throws {
        try fm.createDirectory(at: dir.appendingPathComponent("hooks"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let reporter = """
        #!/bin/sh
        set +e
        HOOK_NAME="$1"; AGENT_NAME="$2"
        cat >/dev/null 2>/dev/null || true
        [ -n "$GLINT_SESSION_ID" ] && [ -n "$GLINT_AGENT_SOCK" ] && [ -S "$GLINT_AGENT_SOCK" ] || exit 0
        [ -x /usr/bin/nc ] || exit 0
        printf '{"session":"%s","pane":"%s","hook":"%s","agent":"%s"}\\n' "$GLINT_SESSION_ID" "$GLINT_PANE_ID" "$HOOK_NAME" "$AGENT_NAME" \\
          | /usr/bin/nc -U -w 1 "$GLINT_AGENT_SOCK" >/dev/null 2>&1 || true
        exit 0
        """
        try write(reporter, to: dir.appendingPathComponent("hooks/glint-report.sh"), mode: 0o700)
        try adapter(for: session.agent).writeRuntime(session: session, directory: dir, runtimePath: runtimePath)

        // Ensure all expected remote upload paths exist even when an adapter
        // does not use them.
        for name in ["claude", "codex", "opencode"] {
            let url = dir.appendingPathComponent("bin/\(name)")
            if !fm.fileExists(atPath: url.path) {
                try write("#!/bin/sh\nexit 127\n", to: url, mode: 0o700)
            }
        }
        for name in ["claude-settings.json", "merged-claude-settings.json"] {
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { try write("{}\n", to: url, mode: 0o600) }
        }

        let env = runtimeEnvironment(session: session, directory: runtimePath,
                                     socket: socketPath, paneKey: paneKey)
        let envBody = env.map { "export \($0.key)=\(shellQuote($0.value))" }.sorted().joined(separator: "\n")
        try write(envBody + "\n", to: dir.appendingPathComponent("env"), mode: 0o600)
        let hooksEnabled = !env["GLINT_AGENT_SOCK", default: ""].isEmpty
        let bootstrapAgentSock = hooksEnabled ? "\"$GLINT_SESSION_DIR/agent.sock\"" : "''"

        let mergeScript = Self.mergeClaudeSettingsScript
        try write(mergeScript, to: dir.appendingPathComponent("merge-claude-settings.py"), mode: 0o700)
        let sourceSettings = session.profile.settingsFile ?? ""
        let envSource = session.profile.envFile.map {
            let p = shellPathExpression($0)
            return "[ -f \(p) ] && . \(p)\n"
        } ?? ""
        let launch: String = session.agent == .terminal
            ? "exec \"${SHELL:-/bin/sh}\" -l"
            : "exec \"$GLINT_SESSION_DIR/bin/\(session.agent.rawValue)\""
        let isRemote: Bool = { if case .ssh = session.host { return true }; return false }()
        let mergeRemote = isRemote && session.agent == .claude && !sourceSettings.isEmpty
            ? "python3 \"$GLINT_SESSION_DIR/merge-claude-settings.py\" \(shellPathExpression(sourceSettings)) \"$GLINT_SESSION_DIR/claude-settings.json\" \"$GLINT_SESSION_DIR/merged-claude-settings.json\" >/dev/null 2>&1 || true\n"
            : ""
        let bootstrap = """
        #!/bin/sh
        set -e
        GLINT_SESSION_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        export GLINT_SESSION_DIR
        export GLINT_SESSION_ID=\(shellQuote(session.id))
        export GLINT_AGENT_SOCK=\(bootstrapAgentSock)
        export GLINT_PANE_ID=\(shellQuote(paneKey))
        export PATH="$GLINT_SESSION_DIR/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        TMUX_BIN=$(command -v tmux 2>/dev/null || true)
        if [ -z "$TMUX_BIN" ]; then
          for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
            [ -x "$candidate" ] && TMUX_BIN="$candidate" && break
          done
        fi
        if [ -z "$TMUX_BIN" ]; then
          printf 'Glint: tmux is required on this device but was not found.\\n' >&2
          printf 'Install it on the selected device, for example: brew install tmux\\n' >&2
          exit 127
        fi
        \(envSource)\(mergeRemote)exec "$TMUX_BIN" new-session -A \
          -e GLINT_SESSION_ID="$GLINT_SESSION_ID" \
          -e GLINT_SESSION_DIR="$GLINT_SESSION_DIR" \
          -e GLINT_AGENT_SOCK="$GLINT_AGENT_SOCK" \
          -e GLINT_PANE_ID="$GLINT_PANE_ID" \
          -e PATH="$PATH" \
          -s \(shellQuote(session.tmuxSessionName)) -c \(shellPathExpression(session.workingDirectory)) \(shellQuote(launch))
        """
        try write(bootstrap, to: dir.appendingPathComponent("bootstrap-and-attach.sh"), mode: 0o700)
    }

    private func runtimeEnvironment(session: AgentSession, directory: String,
                                    socket: String, paneKey: String) -> [String: String] {
        let basePath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let hooksEnabled = (session.agent == .claude || session.agent == .codex)
            && session.profile.hookMode == .glintOverlay
        return ["GLINT_SESSION_ID": session.id, "GLINT_SESSION_DIR": directory,
                "GLINT_AGENT_SOCK": hooksEnabled ? socket : "", "GLINT_PANE_ID": paneKey,
                "PATH": "\(directory)/bin:\(basePath)"]
    }

    private func adapter(for kind: AgentKind) -> any AgentAdapter {
        switch kind {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .opencode: return PassthroughAdapter(id: .opencode)
        case .terminal: return PassthroughAdapter(id: .terminal)
        }
    }

    private func sessionDirectory(_ id: String) -> URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/glint/sessions/\(id)", isDirectory: true)
    }
    private func resolveLocalTmux() throws -> String {
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if let tmux = findExecutable("tmux", in: searchPath) { return tmux }
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw AgentSessionManagerError.tmuxNotFound
    }

    private func findExecutable(_ name: String, in path: String) -> String? {
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func runAndWait(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static let mergeClaudeSettingsScript = """
    #!/usr/bin/env python3
    import json, os, sys
    source, overlay, output = sys.argv[1:4]
    source = os.path.expanduser(source)
    try:
        with open(source) as f: base = json.load(f)
    except Exception: base = {}
    try:
        with open(overlay) as f: extra = json.load(f)
    except Exception: extra = {}
    hooks = base.setdefault("hooks", {})
    for event, groups in extra.get("hooks", {}).items(): hooks[event] = hooks.get(event, []) + groups
    with open(output, "w") as f: json.dump(base, f, indent=2)
    """
}

struct ManagedSessionLaunch { let environment: [String: String]; let initialInput: String }

private func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
}
private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}
private func write(_ text: String, to url: URL, mode: Int) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}
private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
private func shellDoubleQuoteContent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}
private func shellPathExpression(_ value: String) -> String {
    if value == "~" { return "\"$HOME\"" }
    if value.hasPrefix("~/") {
        return "\"$HOME/\(shellDoubleQuoteContent(String(value.dropFirst(2))))\""
    }
    return shellQuote(value)
}
private func profilePathExpression(_ value: String, host: HostTarget) -> String {
    switch host {
    case .local: return shellQuote(expandHome(value))
    case .ssh: return shellPathExpression(value)
    }
}
