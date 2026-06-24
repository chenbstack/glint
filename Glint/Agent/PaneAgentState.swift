import Foundation

/// Which CLI agent the pane is running.
enum PaneAgentKind: String, Codable {
    case claude
    case codex
    case opencode
    case devin

    /// Human-facing label for the per-pane summary popover.
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .opencode: return "OpenCode"
        case .devin:    return "Devin"
        }
    }

    /// Shell command (with trailing newline) that boots the agent at session
    /// restore time. With a captured `sessionId`, jumps straight back to THAT
    /// pane's session (#45 fix — without it, multiple panes collapse onto the
    /// most-recent session). nil id ⇒ "resume the most-recent" fallback for
    /// pre-fix data or panes where no hook fired before shutdown.
    func restoreCommand(sessionId: String?) -> String {
        switch self {
        case .claude:
            return sessionId.map { "claude --resume \($0)\n" } ?? "claude --continue\n"
        case .codex:
            return sessionId.map { "codex resume \($0)\n" } ?? "codex resume --last\n"
        case .opencode:
            return sessionId.map { "opencode --session \($0)\n" } ?? "opencode --continue\n"
        case .devin:
            return sessionId.map { "devin --resume \($0)\n" } ?? "devin --continue\n"
        }
    }
}

enum PaneAgentStatus: String, Codable {
    case idle              // session live, no active turn
    case thinking          // user prompted, agent working
    case tool              // a tool just fired
    case needsPermission   // agent is asking for user approval
    case compacting        // auto-compacting context window
    case justCompleted     // turn just finished — transient, fades to idle
    case failed            // turn ended in an API/transport error (StopFailure)
}

struct PaneAgentState: Codable, Equatable {
    var kind: PaneAgentKind
    var status: PaneAgentStatus
    var detail: String?       // tool name, notification text, …
    var updatedAt: Date       // last status change — bumped on every hook event
    /// When the CURRENT turn began (user sent the request). Unlike `updatedAt`,
    /// this is NOT reset on intermediate tool/thinking transitions, so the
    /// sidebar can show total turn elapsed time rather than per-step time.
    var turnStartedAt: Date

    init(kind: PaneAgentKind, status: PaneAgentStatus, detail: String? = nil,
         updatedAt: Date, turnStartedAt: Date? = nil) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.updatedAt = updatedAt
        self.turnStartedAt = turnStartedAt ?? updatedAt
    }
}
