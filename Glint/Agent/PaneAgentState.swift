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

    /// Single source of truth for what a CLI-agent session id may look like.
    /// Used by Swift's `isValid(sessionId:)` validator AND interpolated into
    /// the OpenCode JS plugin's regex, so the same alphabet+length applies on
    /// both ingress sides. Bare character-class body (no anchors) — JS adds
    /// `^…$`; Swift's validator walks unicode scalars.
    static let sessionIdCharsetClass = "[A-Za-z0-9_-]"
    static let sessionIdMaxLength = 128

    /// Cheap whitelist for a CLI-agent session id before we paste it into a
    /// resume command (`claude --resume <id>`, `codex resume <id>`). The
    /// string ends up on the pane's stdin, so a stray quote/newline/space
    /// would break the command (or worse, smuggle extra input). Both Claude
    /// and Codex session ids are UUIDs in practice; we keep the alphabet a
    /// touch wider (alnum + `-`/`_`) to absorb minor format changes, then
    /// bound the length so a corrupt payload can't wedge an unbounded string.
    static func isValid(sessionId s: String) -> Bool {
        guard !s.isEmpty, s.count <= sessionIdMaxLength else { return false }
        return s.unicodeScalars.allSatisfy { sc in
            (sc.value >= 0x30 && sc.value <= 0x39) ||  // 0-9
            (sc.value >= 0x41 && sc.value <= 0x5A) ||  // A-Z
            (sc.value >= 0x61 && sc.value <= 0x7A) ||  // a-z
            sc == "-" || sc == "_"
        }
    }

    /// Shell command (with trailing newline) that boots the agent at session
    /// restore time. With a captured `sessionId`, jumps straight back to THAT
    /// pane's session (#45 fix — without it, multiple panes collapse onto the
    /// most-recent session). nil id ⇒ "resume the most-recent" fallback for
    /// pre-fix data or panes where no hook fired before shutdown.
    ///
    /// Defends in depth: any non-nil id that fails the charset whitelist is
    /// downgraded to the fallback form rather than being interpolated into
    /// the TTY string. This keeps the function safe even if a future caller
    /// forgets the outer validation step (the value lands on a real shell).
    func restoreCommand(sessionId: String?) -> String {
        let validated: String? = sessionId.flatMap {
            PaneAgentKind.isValid(sessionId: $0) ? $0 : nil
        }
        switch self {
        case .claude:
            return validated.map { "claude --resume \($0)\n" } ?? "claude --continue\n"
        case .codex:
            return validated.map { "codex resume \($0)\n" } ?? "codex resume --last\n"
        case .opencode:
            return validated.map { "opencode --session \($0)\n" } ?? "opencode --continue\n"
        case .devin:
            return validated.map { "devin --resume \($0)\n" } ?? "devin --continue\n"
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
