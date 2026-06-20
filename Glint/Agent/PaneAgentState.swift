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
