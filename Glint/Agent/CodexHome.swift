import Foundation
import Combine

struct CodexHome: Codable, Identifiable, Hashable {
    var id: UUID
    var label: String?
    var path: String
    var isEnabled: Bool

    init(id: UUID = UUID(), label: String? = nil, path: String, isEnabled: Bool = true) {
        self.id = id
        self.label = label
        self.path = path
        self.isEnabled = isEnabled
    }

    static var `default`: CodexHome {
        CodexHome(label: "Default", path: "~/.codex")
    }

    var resolvedURL: URL {
        URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }
}

enum CodexHookStatus: Hashable {
    case installed
    case notInstalled
    case error(String)
}

enum CodexAuthStatus: Hashable {
    case found
    case missing
    case invalid(String)
}

enum CodexQuotaStatus: Hashable {
    case available(AgentQuota)
    case unavailable(String)
    case loading
}

struct CodexHomeStatus: Identifiable, Hashable {
    var id: UUID { home.id }
    var home: CodexHome
    var resolvedURL: URL
    var hookStatus: CodexHookStatus
    var authStatus: CodexAuthStatus
    var quotaStatus: CodexQuotaStatus
}

@MainActor
final class CodexHomeStore: ObservableObject {
    @Published private(set) var homes: [CodexHome]

    nonisolated static let storageKey = "glint.codexHomes"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CodexHome].self, from: data),
           !decoded.isEmpty {
            homes = Self.deduplicated(decoded)
        } else {
            homes = [.default]
        }
    }

    var enabledHomes: [CodexHome] {
        homes.filter(\.isEnabled)
    }

    func add(path: String, label: String? = nil) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let home = CodexHome(label: label?.nilIfBlank, path: trimmed)
        guard !contains(resolvedURL: home.resolvedURL) else { return false }
        homes.append(home)
        save()
        return true
    }

    func update(_ home: CodexHome) -> Bool {
        guard let index = homes.firstIndex(where: { $0.id == home.id }) else { return false }
        guard !homes.enumerated().contains(where: { offset, existing in
            offset != index && existing.resolvedURL == home.resolvedURL
        }) else { return false }
        homes[index] = home
        save()
        return true
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = homes.firstIndex(where: { $0.id == id }),
              homes[index].isEnabled != isEnabled else { return }
        homes[index].isEnabled = isEnabled
        save()
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let home = homes.first(where: { $0.id == id }),
              home.resolvedURL != CodexHome.default.resolvedURL else { return false }
        homes.removeAll { $0.id == id }
        save()
        return true
    }

    func isDefault(_ home: CodexHome) -> Bool {
        home.resolvedURL == CodexHome.default.resolvedURL
    }

    private func contains(resolvedURL: URL) -> Bool {
        homes.contains { $0.resolvedURL == resolvedURL }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(homes) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func deduplicated(_ homes: [CodexHome]) -> [CodexHome] {
        var seen = Set<URL>()
        return homes.filter { seen.insert($0.resolvedURL).inserted }
    }
}

@MainActor
enum CodexHomeRemoval {
    /// Removing Glint's configuration must not depend on an external
    /// `hooks.json` being readable. Return the cleanup error for UI reporting,
    /// but always remove the non-default home from the store.
    static func remove(
        _ home: CodexHome,
        from store: CodexHomeStore,
        cleanup: (URL) throws -> Void
    ) -> String? {
        var cleanupError: String?
        do {
            try cleanup(home.resolvedURL)
        } catch {
            cleanupError = error.localizedDescription
        }
        _ = store.remove(id: home.id)
        return cleanupError
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
