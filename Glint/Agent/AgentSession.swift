import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude, codex, opencode, terminal
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .opencode: return "OpenCode"
        case .terminal: return "Terminal only"
        }
    }

    var defaultCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .terminal: return ""
        }
    }
}

enum HostTarget: Codable, Hashable, Identifiable {
    case local
    case ssh(alias: String)

    var id: String {
        switch self { case .local: return "local"; case .ssh(let alias): return "ssh:\(alias)" }
    }
    var label: String {
        switch self { case .local: return "This Mac"; case .ssh(let alias): return alias }
    }

    private enum CodingKeys: String, CodingKey { case kind, alias, profileID }
    private enum Kind: String, Codable { case local, ssh }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .local: self = .local
        case .ssh:
            // `profileID` reads the first implementation's persisted shape.
            let value = try c.decodeIfPresent(String.self, forKey: .alias)
                ?? c.decode(String.self, forKey: .profileID)
            self = .ssh(alias: value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local: try c.encode(Kind.local, forKey: .kind)
        case .ssh(let alias):
            try c.encode(Kind.ssh, forKey: .kind)
            try c.encode(alias, forKey: .alias)
        }
    }
}

enum AgentHookMode: String, Codable, CaseIterable, Hashable {
    case glintOverlay
    case disabled
}

struct AgentProfile: Identifiable, Codable, Hashable {
    var id: String
    var label: String
    var agent: AgentKind
    var hostScope: String?
    var command: String
    var configDir: String?
    var settingsFile: String?
    var envFile: String?
    var args: [String]
    var hookMode: AgentHookMode

    static func defaultProfile(for agent: AgentKind) -> AgentProfile {
        AgentProfile(
            id: "default-\(agent.rawValue)",
            label: agent.displayName,
            agent: agent,
            hostScope: nil,
            command: agent.defaultCommand,
            configDir: agent == .codex ? "~/.codex" : nil,
            settingsFile: agent == .claude ? "~/.claude/settings.json" : nil,
            envFile: nil,
            args: [],
            hookMode: agent == .terminal || agent == .opencode ? .disabled : .glintOverlay
        )
    }
}

extension AgentProfile {
    var displayLabel: String {
        guard let hostScope else { return label }
        return "\(label) @ \(hostScope)"
    }

    var deviceLabel: String {
        hostScope ?? String(localized: "This Mac")
    }

    var summaryLine: String {
        var parts = [agent.displayName, deviceLabel]
        if !command.isEmpty { parts.append(command) }
        if let configDir, !configDir.isEmpty { parts.append(configDir) }
        return parts.joined(separator: " · ")
    }
}

enum AgentTransportState: String, Codable {
    case local, connected, detached, reconnecting, unreachable
}

struct AgentSession: Identifiable, Codable, Hashable {
    let id: String
    var agent: AgentKind
    var host: HostTarget
    var profile: AgentProfile
    var workingDirectory: String
    var tmuxSessionName: String
    var lastAttachedPane: String?
    var needsHookTrust: Bool

    var profileID: String { profile.id }

    static func create(agent: AgentKind, host: HostTarget, profile: AgentProfile,
                       workingDirectory: String, pane: String? = nil) -> AgentSession {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let id = "glint-\(token)"
        let hostPart = slug(host.label)
        let profilePart = slug(profile.id)
        return AgentSession(
            id: id,
            agent: agent,
            host: host,
            profile: profile,
            workingDirectory: workingDirectory,
            tmuxSessionName: "glint-\(hostPart)-\(profilePart)-\(token)",
            lastAttachedPane: pane,
            needsHookTrust: agent == .codex && profile.hookMode == .glintOverlay
        )
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let joined = String(mapped).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return joined.isEmpty ? "session" : joined
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, host, profile, workingDirectory, tmuxSessionName, lastAttachedPane, needsHookTrust
    }

    init(id: String, agent: AgentKind, host: HostTarget, profile: AgentProfile,
         workingDirectory: String, tmuxSessionName: String, lastAttachedPane: String?,
         needsHookTrust: Bool) {
        self.id = id; self.agent = agent; self.host = host; self.profile = profile
        self.workingDirectory = workingDirectory; self.tmuxSessionName = tmuxSessionName
        self.lastAttachedPane = lastAttachedPane; self.needsHookTrust = needsHookTrust
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .terminal
        host = try c.decode(HostTarget.self, forKey: .host)
        profile = try c.decodeIfPresent(AgentProfile.self, forKey: .profile)
            ?? .defaultProfile(for: agent)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        tmuxSessionName = try c.decode(String.self, forKey: .tmuxSessionName)
        lastAttachedPane = try c.decodeIfPresent(String.self, forKey: .lastAttachedPane)
        needsHookTrust = try c.decodeIfPresent(Bool.self, forKey: .needsHookTrust)
            ?? (agent == .codex && profile.hookMode == .glintOverlay)
    }
}

enum AgentProfileStore {
    private static let key = "glint.agentProfiles.v1"

    static var profiles: [AgentProfile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let custom = try? JSONDecoder().decode([AgentProfile].self, from: data) else {
                return AgentKind.allCases.map(AgentProfile.defaultProfile)
            }
            return normalizedProfiles(custom)
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func scopedDefaultID(for agent: AgentKind, hostScope: String) -> String {
        "default-\(agent.rawValue)-\(slug(hostScope))"
    }

    static func save(_ profile: AgentProfile) {
        let profile = normalizedProfile(profile)
        var all = profiles
        if let i = all.firstIndex(where: { $0.id == profile.id }) { all[i] = profile }
        else { all.append(profile) }
        profiles = all
    }

    static func delete(_ profile: AgentProfile) {
        guard !isBuiltInDefault(profile) else { return }
        profiles = profiles.filter { $0.id != profile.id }
    }

    static func isBuiltInDefault(_ profile: AgentProfile) -> Bool {
        profile.hostScope == nil && profile.id == "default-\(profile.agent.rawValue)"
    }

    static func newProfileID(for agent: AgentKind) -> String {
        "\(agent.rawValue)-\(UUID().uuidString.lowercased())"
    }

    private static func normalizedProfiles(_ profiles: [AgentProfile]) -> [AgentProfile] {
        var result: [AgentProfile] = []
        var seen = Set<String>()
        for raw in profiles {
            var profile = normalizedProfile(raw)
            let baseID = profile.id
            var candidate = baseID
            var suffix = 2
            while seen.contains(candidate) {
                candidate = "\(baseID)-\(suffix)"
                suffix += 1
            }
            profile.id = candidate
            seen.insert(candidate)
            result.append(profile)
        }

        for kind in AgentKind.allCases {
            let defaultProfile = AgentProfile.defaultProfile(for: kind)
            if !result.contains(where: { $0.id == defaultProfile.id && $0.hostScope == nil }) {
                result.append(defaultProfile)
            }
        }
        return result
    }

    private static func normalizedProfile(_ profile: AgentProfile) -> AgentProfile {
        var profile = profile
        if let hostScope = profile.hostScope,
           profile.id == "default-\(profile.agent.rawValue)" {
            profile.id = scopedDefaultID(for: profile.agent, hostScope: hostScope)
        }
        return profile
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = value.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let joined = String(mapped).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return joined.isEmpty ? "host" : joined
    }
}

enum SSHConfigHosts {
    static func aliases() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("host ") else { continue }
            for alias in line.dropFirst(5).split(whereSeparator: \.isWhitespace) {
                let value = String(alias)
                if !value.contains("*") && !value.contains("?") { result.insert(value) }
            }
        }
        return result.sorted()
    }
}
