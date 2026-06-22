import Foundation

/// Which agent (if any) to auto-launch in a freshly created terminal pane.
///
/// Shared by every "new terminal" surface — the New Workspace sheet's source
/// panes, the tab bar's "+" menu, and the command palette — so picking an
/// agent works the same way everywhere, not just on the worktree path.
/// `.shell` is the no-agent escape hatch (a bare shell, the default).
enum AgentChoice: String, CaseIterable, Identifiable {
    case claude = "Claude Code", codex = "Codex", opencode = "OpenCode", devin = "Devin", shell = "Shell only"

    /// Chip / menu label. Product names stay verbatim; only "Shell only" is UI
    /// copy, so it (and only it) is routed through the string catalog.
    /// `rawValue` is a String, so `Text(choice.rawValue)` would hit the verbatim
    /// overload and never localize — read this instead.
    var displayName: String { self == .shell ? String(localized: "Shell only") : rawValue }

    var id: String { rawValue }

    /// The command typed into the new pane's shell, or nil for a bare shell.
    var command: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .devin: return "devin"
        case .shell: return nil
        }
    }

    /// Asset-catalog brand mark, or nil for `.shell` (which uses an SF Symbol).
    var brandAsset: String? {
        switch self {
        case .claude: return "Claude"
        case .codex: return "CodexMark"
        case .opencode: return "OpenCodeMark"
        case .devin: return "DevinMark"
        case .shell: return nil
        }
    }
}

/// Which "new terminal" action the agent chooser is gating, so the overlay can
/// label itself and run the right thing once an agent is picked.
enum NewTerminalIntent {
    case tab, splitRight, splitDown, workspace
}

/// One selectable row in the agent launch chooser. Every agent maps to a
/// single item, EXCEPT Codex: when more than one Codex Home is enabled it
/// fans out into one item per home, each launching `codex` seeded with that
/// home's `CODEX_HOME`, so the pick chooses which home the session runs under.
struct AgentLaunchItem: Identifiable, Hashable {
    let id: String
    let choice: AgentChoice
    /// Verbatim row title — a product name, or a Codex Home's label. Never
    /// localized (it is data); `.shell` carries its already-localized name.
    let title: String
    /// Secondary line: a Codex Home directory path, else nil. Data, verbatim.
    let subtitle: String?
    /// Dim suffix after the title — a non-default Codex Home's label, so the
    /// row reads as "Codex test". nil for the default home and other agents.
    let tag: String?
    /// Resolved shell command typed into the new pane, nil = bare shell. For a
    /// non-default Codex Home this carries a `CODEX_HOME=…` prefix.
    let command: String?

    var brandAsset: String? { choice.brandAsset }
}

extension AgentLaunchItem {
    /// Build the chooser rows. Codex expands across enabled homes (see type doc);
    /// every other agent is a single row.
    static func all(codexHomes: [CodexHome]) -> [AgentLaunchItem] {
        AgentChoice.allCases.flatMap { choice in
            choice == .codex ? codexItems(codexHomes) : [single(choice)]
        }
    }

    private static func single(_ choice: AgentChoice) -> AgentLaunchItem {
        AgentLaunchItem(id: choice.id, choice: choice,
                        title: choice.displayName, subtitle: nil, tag: nil, command: choice.command)
    }

    private static func codexItems(_ homes: [CodexHome]) -> [AgentLaunchItem] {
        let enabled = homes.filter(\.isEnabled)
        // No enabled home, or the default alone → one plain "Codex" row, exactly
        // as before. A single NON-default home still needs its CODEX_HOME, so it
        // goes through `item(for:)` too (just nothing else to disambiguate it).
        guard enabled.count > 1 else {
            guard let only = enabled.first,
                  only.resolvedURL != CodexHome.default.resolvedURL else { return [single(.codex)] }
            return [item(for: only)]
        }
        return enabled.map(item(for:))
    }

    /// A per-home Codex row. Title stays "Codex" so it still reads as the
    /// product; the path goes on the subtitle, and a non-default home appends
    /// its label as a dim tag after the title to tell the rows apart.
    private static func item(for home: CodexHome) -> AgentLaunchItem {
        let isDefault = home.resolvedURL == CodexHome.default.resolvedURL
        return AgentLaunchItem(
            id: "codex:\(home.id.uuidString)",
            choice: .codex,
            title: AgentChoice.codex.displayName,
            subtitle: home.path,
            tag: isDefault ? nil : (home.label ?? home.resolvedURL.lastPathComponent),
            command: codexCommand(for: home)
        )
    }

    /// `codex` seeded with the home's `CODEX_HOME`. The default `~/.codex` is
    /// codex's own default, so it launches bare with no override.
    private static func codexCommand(for home: CodexHome) -> String {
        guard home.resolvedURL != CodexHome.default.resolvedURL else { return "codex" }
        return "CODEX_HOME=\(shellQuoted(home.resolvedURL.path)) codex"
    }

    private static func shellQuoted(_ path: String) -> String {
        if !path.contains("'") { return "'\(path)'" }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
