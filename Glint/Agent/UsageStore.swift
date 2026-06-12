import SwiftUI
import Combine

/// One agent's rate-limit snapshot. Percentages are 0–100 (fraction of the
/// window already consumed); `nil` fields mean "not reported by this source".
struct AgentQuota: Equatable, Codable {
    /// Rolling session window (Codex `primary`, ~5h). 0–100.
    var sessionPercent: Double
    /// Longer rolling window (Codex `secondary`, ~7d). nil when unknown.
    var weeklyPercent: Double?
    /// When the session window rolls over. nil when unknown.
    var sessionResetsAt: Date?
    /// When the weekly window rolls over. nil when unknown.
    var weeklyResetsAt: Date?
    /// Plan label, e.g. "plus" / "pro". Shown verbatim if present.
    var planType: String?

    /// >= this fraction used → render the session readout in the warn (amber)
    /// color. Chosen so the common "busy but fine" range stays calm and only
    /// genuinely tight budgets draw the eye.
    static let warnThreshold: Double = 80
    var sessionIsWarn: Bool { sessionPercent >= Self.warnThreshold }
}

/// Polls per-agent usage/rate-limit data and republishes it for the sidebar.
///
/// Data sources are asymmetric on purpose:
///   • Codex (ChatGPT login) is read live from the same `/backend-api/wham/usage`
///     endpoint the Codex TUI polls, authorizing with the OAuth token in
///     `~/.codex/auth.json` — so the numbers refresh even with no session
///     running (`CodexLiveReader`). When that's unavailable (API-key login,
///     expired token, network/shape failure) it falls back to the `rate_limits`
///     block Codex persists into every session rollout JSONL under
///     `~/.codex/sessions/…`, which needs no auth but only updates while Codex
///     is active (`CodexUsageReader`).
///   • Claude Code does NOT persist account-level 5h/weekly limits to disk —
///     it only sees them in live API response headers. The only way to read
///     them out-of-process is the OAuth usage endpoint using the token in the
///     login keychain. That path is best-effort (see `ClaudeUsageReader`); any
///     failure leaves `claude == nil` so the row simply doesn't render.
///
/// Each agent has its own switch. With both off, polling stops entirely and
/// nothing is read from disk or network. With one off, only that agent's
/// snapshot is cleared and skipped — the other keeps refreshing. A snapshot is
/// also `nil` when its source yields no data (e.g. the user only uses one of
/// the two CLIs), so the sidebar shows a row only when there's real data AND
/// the toggle is on.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claude: AgentQuota?
    @Published private(set) var codex: AgentQuota?

    /// Per-agent switches, persisted, default off — opt-in, since Claude's
    /// poll needs login-keychain access (a system prompt on first read).
    @Published var claudeEnabled: Bool {
        didSet {
            guard claudeEnabled != oldValue else { return }
            UserDefaults.standard.set(claudeEnabled, forKey: Self.claudeKey)
            if !claudeEnabled { claude = nil; Self.saveQuota(nil, agent: .claude) }
            syncTimer()
            if claudeEnabled { refreshNow() }
        }
    }
    @Published var codexEnabled: Bool {
        didSet {
            guard codexEnabled != oldValue else { return }
            UserDefaults.standard.set(codexEnabled, forKey: Self.codexKey)
            if !codexEnabled { codex = nil; Self.saveQuota(nil, agent: .codex) }
            syncTimer()
            if codexEnabled { refreshNow() }
        }
    }

    private static let claudeKey = "glint.showClaudeUsage"
    private static let codexKey = "glint.showCodexUsage"
    private var timer: Timer?
    /// Refresh cadence. Rate-limit windows move on the order of minutes, so a
    /// minute of staleness is invisible and keeps disk/network churn trivial.
    private let interval: TimeInterval = 60

    private var anyEnabled: Bool { claudeEnabled || codexEnabled }

    init() {
        self.claudeEnabled = (UserDefaults.standard.object(forKey: Self.claudeKey) as? Bool) ?? false
        self.codexEnabled = (UserDefaults.standard.object(forKey: Self.codexKey) as? Bool) ?? false
        // Show the last-known numbers immediately so the bars don't pop in blank
        // on launch; the first poll refreshes them a moment later.
        if claudeEnabled { self.claude = Self.loadQuota(.claude) }
        if codexEnabled { self.codex = Self.loadQuota(.codex) }
        syncTimer()
    }

    deinit { timer?.invalidate() }

    /// Start or stop the repeating poll to match whether anything is enabled.
    private func syncTimer() {
        if anyEnabled {
            guard timer == nil else { return }
            refreshNow()
            let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshNow() }
            }
            // Let the poll fire while the user is dragging a scroller etc.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Refresh whichever agents are currently enabled and publish results.
    func refreshNow() {
        if codexEnabled {
            Task { [weak self] in
                let codex = await CodexUsageReader.readPreferLive()
                await MainActor.run { self?.apply(codex, to: .codex) }
            }
        }
        if claudeEnabled {
            Task { [weak self] in
                let claude = await ClaudeUsageReader.read()
                await MainActor.run {
                    self?.apply(claude, to: .claude)
                }
            }
        }
    }

    /// Publish and persist a fresh snapshot. A `nil` result (transient network
    /// error, unsupported endpoint, no sessions yet) is ignored rather than
    /// allowed to wipe a good last-known value — the bar keeps showing the
    /// previous numbers until real data replaces them. Disabling an agent is
    /// the only thing that clears it, and that's handled in the toggle's didSet.
    private func apply(_ quota: AgentQuota?, to agent: Agent) {
        switch agent {
        case .claude: guard claudeEnabled, let quota else { return }; claude = quota
        case .codex:  guard codexEnabled,  let quota else { return }; codex = quota
        }
        Self.saveQuota(quota, agent: agent)
    }

    // MARK: Snapshot persistence (non-sensitive — UserDefaults is fine)

    private enum Agent: String { case claude, codex }

    private static func snapshotKey(_ agent: Agent) -> String {
        "glint.usage.snapshot.\(agent.rawValue)"
    }

    private static func loadQuota(_ agent: Agent) -> AgentQuota? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey(agent)) else { return nil }
        return try? JSONDecoder().decode(AgentQuota.self, from: data)
    }

    private static func saveQuota(_ quota: AgentQuota?, agent: Agent) {
        let key = snapshotKey(agent)
        if let quota, let data = try? JSONEncoder().encode(quota) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Codex (disk)

/// Reads the most recent `rate_limits` block out of Codex's session rollout
/// files. No auth: Codex writes these as it runs.
enum CodexUsageReader {
    private struct Window: Decodable {
        let used_percent: Double?
        let resets_at: Double?      // unix seconds
    }
    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }

    /// Prefer the live ChatGPT usage endpoint (current numbers even with no
    /// active session, ChatGPT login only); fall back to the on-disk session
    /// snapshot on any failure or in API-key mode. The disk read is bounced off
    /// the main actor since it touches the filesystem.
    static func readPreferLive() async -> AgentQuota? {
        if let live = await CodexLiveReader.read() { return live }
        return await Task.detached(priority: .utility) { read() }.value
    }

    static func read() -> AgentQuota? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = recentRolloutFiles(under: sessions, limit: 6)
        // Walk newest-first; the first file that yields a rate_limits line wins
        // (an idle older session would only carry staler numbers).
        for file in files {
            if let q = lastRateLimits(in: file) { return q }
        }
        return nil
    }

    /// The N most-recently-modified `rollout-*.jsonl` files, newest first.
    private static func recentRolloutFiles(under dir: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var dated: [(URL, Date)] = []
        for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-")
            && url.pathExtension == "jsonl" {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            dated.append((url, vals?.contentModificationDate ?? .distantPast))
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Rollout files grow with the session (tens of MB for a long one) and
    /// rate_limits lines are appended per turn, so the newest one always lives
    /// near the end — read only this much of the tail instead of the whole file.
    private static let tailBytes: UInt64 = 256 * 1024

    /// Scan a rollout file from the end for the last line carrying rate limits.
    private static func lastRateLimits(in file: URL) -> AgentQuota? {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let offset = size > tailBytes ? size - tailBytes : 0
        try? fh.seek(toOffset: offset)
        guard var data = try? fh.readToEnd() else { return nil }
        if offset > 0 {
            // Drop the (likely mid-line, possibly mid-UTF-8-sequence) partial
            // first line so the String decode below can't fail on it.
            guard let nl = data.firstIndex(of: 0x0A) else { return nil }
            data = data[data.index(after: nl)...]
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rlAny = payload["rate_limits"],
                  let rlData = try? JSONSerialization.data(withJSONObject: rlAny),
                  let rl = try? JSONDecoder().decode(RateLimits.self, from: rlData)
            else { continue }

            let primary = rl.primary
            let secondary = rl.secondary
            guard let sessionPercent = primary?.used_percent else { continue }
            return AgentQuota(
                sessionPercent: sessionPercent,
                weeklyPercent: secondary?.used_percent,
                sessionResetsAt: primary?.resets_at.map { Date(timeIntervalSince1970: $0) },
                weeklyResetsAt: secondary?.resets_at.map { Date(timeIntervalSince1970: $0) },
                planType: rl.plan_type
            )
        }
        return nil
    }
}

// MARK: - Codex (live ChatGPT usage endpoint, best-effort)

/// Reads Codex's rate limits from the same ChatGPT backend endpoint the Codex
/// TUI polls — `GET https://chatgpt.com/backend-api/wham/usage` — authorizing
/// with the OAuth token in `~/.codex/auth.json`. Unlike the on-disk snapshot
/// (which only moves while Codex is running), this reflects the current window
/// usage at any time, the same way `ClaudeUsageReader` does for Claude.
///
/// Best-effort and fails closed: API-key login (no OAuth token), an expired
/// token, a network error, or an unexpected response shape all return `nil`,
/// and the caller falls back to the disk snapshot. The endpoint, headers, and
/// payload mirror Codex's own `backend-client` as of mid-2026 (ChatGPT-plan
/// mode only); if they drift, only this type needs updating.
enum CodexLiveReader {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// `~/.codex/auth.json`. ChatGPT logins carry `tokens.access_token` +
    /// `tokens.account_id`; API-key logins leave the token empty/absent.
    private struct Auth: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    /// Mirrors Codex's `RateLimitStatusPayload` — note this is the RAW endpoint
    /// shape (`rate_limit.{primary,secondary}_window`), NOT the already-mapped
    /// `rate_limits` block Codex persists to its session files.
    private struct Payload: Decodable {
        struct Window: Decodable {
            let used_percent: Double?   // 0–100 (integer over the wire)
            let reset_at: Double?       // unix seconds
        }
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        let plan_type: String?
        let rate_limit: RateLimit?
    }

    static func read() async -> AgentQuota? {
        guard let (token, accountId) = loadAuth() else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId { req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return decode(data)
    }

    /// (access token, account id) when in ChatGPT-OAuth mode. The access token
    /// is owned and rotated by Codex; we only read it. An empty/absent token
    /// (API-key login) yields `nil` so the caller uses the disk fallback.
    private static func loadAuth() -> (String, String?)? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let auth = try? JSONDecoder().decode(Auth.self, from: data),
              let token = auth.tokens?.access_token, !token.isEmpty else { return nil }
        let account = auth.tokens?.account_id.flatMap { $0.isEmpty ? nil : $0 }
        return (token, account)
    }

    private static func decode(_ data: Data) -> AgentQuota? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              let primary = p.rate_limit?.primary_window,
              let sessionPercent = primary.used_percent else { return nil }
        let secondary = p.rate_limit?.secondary_window
        return AgentQuota(
            sessionPercent: sessionPercent,
            weeklyPercent: secondary?.used_percent,
            sessionResetsAt: primary.reset_at.map { Date(timeIntervalSince1970: $0) },
            weeklyResetsAt: secondary?.reset_at.map { Date(timeIntervalSince1970: $0) },
            planType: p.plan_type
        )
    }
}

// MARK: - Claude (keychain + OAuth usage endpoint, best-effort)

/// Reads Claude's 5h/weekly limits via the OAuth usage endpoint, authorizing
/// with the token Claude Code stores in the login keychain.
///
/// This is best-effort and intentionally fails closed: any missing token,
/// network error, or unexpected response shape returns `nil`, which keeps the
/// Claude row out of the sidebar rather than showing wrong numbers. The
/// endpoint/response shape can shift with Claude Code releases — when it does,
/// only `decode`/`endpoint` here need updating; the sidebar handles absence.
enum ClaudeUsageReader {
    /// Keychain generic-password service used by Claude Code's CLI login — the
    /// token's source of truth, owned by Claude Code. Reading it can pop a macOS
    /// authorization prompt (its ACL is bound to Claude Code's signature, not
    /// ours), so we touch it as little as possible: once on first launch to seed
    /// our own copy, then again ONLY when the seeded copy is rejected (token
    /// rotated). See `glintService`.
    private static let keychainService = "Claude Code-credentials"
    /// Glint-owned generic-password item we copy the token into, so steady-state
    /// launches read OUR item — whose ACL we own — instead of Claude Code's.
    /// In a signed release this is a one-time "Always Allow" then silent; in dev
    /// the ad-hoc signature churns per rebuild so it still re-prompts, but the
    /// design is correct and the release path is the one that matters.
    private static let glintService = "app.glint.claude-usage"
    private static let glintAccount = "oauth-token"
    /// OAuth usage endpoint. Unverified against a live token in this build —
    /// see the type doc. Wrong path simply yields `nil`.
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// In-memory cache of the OAuth token. Every keychain access happens INSIDE
    /// this actor, so callers are fully serialized: concurrent reads (two
    /// pollers, or a duplicated `@StateObject` init firing `refreshNow` twice)
    /// coalesce onto a single access instead of each popping their own prompt.
    ///
    /// `token()` loads once per launch (our item first, falling back to Claude's
    /// and seeding ours). `refreshFromSource(rejected:)` re-reads Claude's item
    /// on a genuine auth failure — THROTTLED to once per 15 minutes rather than
    /// once per launch: Claude Code rotates its access token every few hours,
    /// so a long-running app sees several rotations in one launch. A once-ever
    /// guard permanently froze the quota bar after the second rotation (every
    /// poll 401'd, the stale last-known numbers stayed up until relaunch). The
    /// throttle still prevents prompt storms when the endpoint fails for other
    /// reasons.
    private actor TokenCache {
        private var cached: String?
        private var loaded = false
        private var lastSourceRead: Date?
        private static let sourceReadInterval: TimeInterval = 15 * 60
        func token() -> String? {
            if !loaded {
                cached = ClaudeUsageReader.loadToken()
                loaded = true
            }
            return cached
        }
        /// Re-read Claude's source item after `rejected` came back 401/403,
        /// at most once per throttle window. Persists the fresh token into our
        /// own item. Returns it only if it actually changed (no point retrying
        /// the same token). A failed read keeps the old cached token so a later
        /// window can try the source again once Claude Code has rotated it.
        func refreshFromSource(rejected: String) -> String? {
            if let last = lastSourceRead,
               Date().timeIntervalSince(last) < Self.sourceReadInterval {
                return nil
            }
            lastSourceRead = Date()
            let fresh = ClaudeUsageReader.readClaudeToken()
            if let fresh {
                ClaudeUsageReader.saveGlintToken(fresh)
                cached = fresh
            }
            return (fresh != nil && fresh != rejected) ? fresh : nil
        }
    }
    private static let cache = TokenCache()

    private struct Stored: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }

    /// Outcome of one usage request, so the caller can tell a rotated token
    /// (worth one source re-read) apart from any other failure (fail closed).
    private enum FetchResult {
        case ok(AgentQuota?)
        case authFailed
        case otherFailure
    }

    static func read() async -> AgentQuota? {
        guard let token = await cache.token() else { return nil }
        switch await fetch(token: token) {
        case .ok(let quota):
            return quota
        case .otherFailure:
            return nil
        case .authFailed:
            // The seeded token was rejected — Claude Code likely rotated it.
            // Go back to the source ONCE; retry only if it actually changed.
            guard let fresh = await cache.refreshFromSource(rejected: token) else { return nil }
            if case .ok(let quota) = await fetch(token: fresh) { return quota }
            return nil
        }
    }

    /// One usage request with a given token. 200 → parsed quota; 401/403 →
    /// `.authFailed` (token rotated); anything else → `.otherFailure`.
    private static func fetch(token: String) async -> FetchResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .otherFailure }
        switch http.statusCode {
        case 200: return .ok(decode(data))
        case 401, 403: return .authFailed
        default: return .otherFailure
        }
    }

    /// Load the token for this launch: prefer our own item (ACL we own, so no
    /// prompt in a signed release); fall back to Claude Code's source item and
    /// seed ours from it for next time.
    private static func loadToken() -> String? {
        if let own = readGlintToken() { return own }
        let claude = readClaudeToken()
        if let claude { saveGlintToken(claude) }
        return claude
    }

    /// Pull the OAuth access token out of Claude Code's login keychain item.
    /// Reads only the item Claude Code itself created; nothing is written here.
    private static func readClaudeToken() -> String? {
        guard let data = readKeychainData(service: keychainService, account: nil) else { return nil }
        // The stored blob is the credentials JSON; tolerate a bare token too.
        if let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let tok = stored.claudeAiOauth?.accessToken {
            return tok
        }
        return String(data: data, encoding: .utf8)
    }

    /// Read our own copied token. Stored as the bare token string.
    private static func readGlintToken() -> String? {
        guard let data = readKeychainData(service: glintService, account: glintAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Persist the token into Glint's own keychain item (update-or-add). Uses
    /// `AfterFirstUnlock` so a background poll right after login can still read
    /// it. Best-effort: a failure just means we re-read Claude's item next time.
    private static func saveGlintToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: glintService,
            kSecAttrAccount as String: glintAccount,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Shared generic-password read. `account == nil` matches by service only.
    private static func readKeychainData(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse an ISO8601 timestamp. `ISO8601DateFormatter` only reliably handles
    /// 3 fractional digits, but the endpoint sends 6 (microseconds), so on
    /// failure we strip the `.ffffff` and retry — minute-level precision is all
    /// the reset countdown needs anyway.
    private static func parseISODate(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? s.endIndex
        return isoPlain.date(from: String(s[..<dot]) + s[tz...])
    }

    /// Decode the usage payload into our model. Lenient about field names so a
    /// minor server rename doesn't break the whole row.
    private static func decode(_ data: Data) -> AgentQuota? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Accept either a flat shape or one nested under "five_hour"/"seven_day".
        func window(_ keys: [String]) -> [String: Any]? {
            for k in keys { if let w = obj[k] as? [String: Any] { return w } }
            return nil
        }
        let session = window(["five_hour", "fiveHour", "primary", "session"])
        let weekly = window(["seven_day", "sevenDay", "weekly", "secondary"])

        func pct(_ w: [String: Any]?) -> Double? {
            for k in ["used_percent", "utilization", "usedPercent", "percent"] {
                if let v = w?[k] as? Double { return v <= 1 ? v * 100 : v }
            }
            return nil
        }
        func reset(_ w: [String: Any]?) -> Date? {
            for k in ["resets_at", "resetsAt", "reset_at"] {
                // Unix seconds (Codex-style) or an ISO8601 string (Claude's
                // OAuth endpoint sends e.g. "2026-06-11T08:20:00.446069+00:00").
                if let v = w?[k] as? Double { return Date(timeIntervalSince1970: v) }
                if let s = w?[k] as? String, let d = ClaudeUsageReader.parseISODate(s) { return d }
            }
            return nil
        }
        guard let sp = pct(session) else { return nil }
        return AgentQuota(
            sessionPercent: sp,
            weeklyPercent: pct(weekly),
            sessionResetsAt: reset(session),
            weeklyResetsAt: reset(weekly),
            planType: obj["plan_type"] as? String ?? obj["planType"] as? String
        )
    }
}
