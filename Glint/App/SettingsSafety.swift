import Foundation

/// Crash-loop guard for preferences.
///
/// A sticky setting that crashes the launch/first-render path — e.g. a
/// persisted value the sidebar turns into `Int(NaN)` (issue #15) — bricks the
/// app: every relaunch replays the same crash before the user can reach
/// Settings to undo it. Because a Swift trap kills the process and can't be
/// caught in-process, recovery has to happen out-of-process, on the *next*
/// launch. This is that dead man's switch.
///
/// Two files live under the per-flavor Application Support folder (so Debug and
/// Release never share state):
///
///  - A **journal** (`settings-journal.json`) records, for every `glint.*`
///    scalar setting changed since the last healthy launch, the value it held
///    *before* the change. No write-site cooperation is needed — we diff
///    `UserDefaults` on `didChangeNotification`, so every present *and future*
///    setting is covered automatically, with zero per-setting maintenance.
///  - A **launch marker** (`launch.marker`) is written at the very start of
///    launch and deleted once the app has been alive and on-screen for a few
///    seconds (`markHealthy`). If it's still there next launch, the previous
///    launch crashed before proving itself healthy.
///
/// On a detected crash we pop the single most-recent journal entry and restore
/// that value, then let launch continue. A `healthyMark` high-water line —
/// advanced only by `markHealthy`, never by a clean quit — bounds rollback to
/// changes made *after* the last launch that actually ran stably, so a crash
/// unrelated to settings (or one whose cause predates the last healthy launch)
/// never silently rewrites the user's preferences. Each further crash peels
/// back one more recent change; once nothing past the mark remains, the crash
/// isn't ours to fix and we stop.
///
/// Not annotated `@MainActor`: `beginLaunch()` runs synchronously from
/// `GlintApp.init` (before any setting is read) and the notification handler
/// can fire on whatever thread performed the write, so all mutable state is
/// guarded by `lock` instead.
final class SettingsSafety {
    static let shared = SettingsSafety()

    /// `glint.*` keys we never journal or roll back: the window frame churns on
    /// every move/resize (it would evict real settings from the ring buffer),
    /// and the dev-seed flag is internal bookkeeping whose rollback would
    /// re-copy the production domain. Everything else is covered automatically.
    private static let ignoredKeys: Set<String> = [
        "glint.mainWindowFrame",
        "glint.devDefaultsSeeded",
    ]
    private static let keyPrefix = "glint."
    /// Cap the journal so a chatty setting can't grow the file without bound;
    /// recovery only ever needs the most-recent changes.
    private static let maxEntries = 64

    /// One recorded change: the value `key` held *before* it changed. A nil
    /// value means the key didn't exist yet, so rolling back removes it.
    private struct Entry: Codable {
        let key: String
        let value: ScalarValue?
    }

    /// On-disk journal: a high-water mark proven safe by the last healthy
    /// launch, plus every change recorded since.
    private struct JournalFile: Codable {
        var healthyMark: Int
        var entries: [Entry]
    }

    /// A plist scalar we know how to compare and restore. Non-scalars (Data
    /// snapshots, arrays, dicts) are skipped — they can't be a settings toggle
    /// and JSON couldn't round-trip a non-finite Double into them anyway.
    private enum ScalarValue: Codable, Equatable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)

        init?(_ any: Any) {
            switch any {
            case let number as NSNumber:
                // __NSCFBoolean is an NSNumber subclass; distinguish it by type
                // id so a Bool isn't misfiled as Int (and vice-versa).
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                } else if CFNumberIsFloatType(number as CFNumber) {
                    self = .double(number.doubleValue)
                } else {
                    self = .int(number.intValue)
                }
            case let string as String:
                self = .string(string)
            default:
                return nil
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    /// Last-seen scalar snapshot; diffed against the live values to learn which
    /// key changed (the notification itself carries no key list).
    private var snapshot: [String: ScalarValue] = [:]
    private var file = JournalFile(healthyMark: 0, entries: [])
    private var started = false

    private init() {}

    // MARK: Launch lifecycle

    /// Call at the very start of launch, before any setting is read. Detects a
    /// crashed previous launch and rolls back the most recent post-healthy
    /// change if so, writes a fresh marker, then begins journaling. Idempotent.
    func beginLaunch() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        file = loadFile()
        if markerExists() {
            recoverFromCrashLocked()
        }
        writeMarker()

        // Baseline the diff AFTER any rollback, and register the observer only
        // now — so the rollback's own writes (above) are never re-journaled.
        snapshot = currentScalars()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    /// Call once the app is alive and on-screen (a few seconds in). Clears the
    /// marker — this launch is proven good — and advances the high-water mark
    /// so only changes made *after* now are candidates for a future rollback.
    func markHealthy() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        removeMarker()
        file.healthyMark = file.entries.count
        saveFileLocked()
    }

    /// Call on a clean quit. Clears the marker so the next launch isn't mistaken
    /// for a crash — but deliberately does NOT advance the high-water mark: a
    /// setting changed this session can still crash the *next* launch (that's
    /// exactly issue #15), so those changes must stay rollback-eligible.
    func markCleanExit() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        removeMarker()
    }

    // MARK: Recovery

    private func recoverFromCrashLocked() {
        guard file.entries.count > file.healthyMark else {
            NSLog("[glint] launch marker present but no setting changed since the last healthy launch — crash isn't ours to fix; preferences left untouched")
            return
        }
        let entry = file.entries.removeLast()
        restore(entry)
        saveFileLocked()
        NSLog("[glint] previous launch crashed; rolled back '\(entry.key)' to its prior value to recover")
    }

    // MARK: Journaling

    @objc private func defaultsChanged() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }

        let current = currentScalars()
        var changed = false
        // Existing keys whose value moved (or that were removed).
        for (key, old) in snapshot where current[key] != old {
            file.entries.append(Entry(key: key, value: old))
            changed = true
        }
        // Brand-new keys: record their prior absence so a rollback removes them.
        for key in current.keys where snapshot[key] == nil {
            file.entries.append(Entry(key: key, value: nil))
            changed = true
        }
        guard changed else { return }

        snapshot = current
        if file.entries.count > Self.maxEntries {
            let drop = file.entries.count - Self.maxEntries
            file.entries.removeFirst(drop)
            file.healthyMark = max(0, file.healthyMark - drop)
        }
        saveFileLocked()
    }

    private func currentScalars() -> [String: ScalarValue] {
        var out: [String: ScalarValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.keyPrefix) {
            guard !Self.ignoredKeys.contains(key), let scalar = ScalarValue(value) else { continue }
            out[key] = scalar
        }
        return out
    }

    private func restore(_ entry: Entry) {
        guard let value = entry.value else {
            defaults.removeObject(forKey: entry.key)
            return
        }
        switch value {
        case .bool(let b): defaults.set(b, forKey: entry.key)
        case .int(let i): defaults.set(i, forKey: entry.key)
        case .double(let d): defaults.set(d, forKey: entry.key)
        case .string(let s): defaults.set(s, forKey: entry.key)
        }
    }

    // MARK: Files

    private var markerURL: URL? {
        SupportDir.url?.appendingPathComponent("launch.marker", isDirectory: false)
    }
    private var fileURL: URL? {
        SupportDir.url?.appendingPathComponent("settings-journal.json", isDirectory: false)
    }

    private func markerExists() -> Bool {
        guard let url = markerURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    private func writeMarker() {
        guard let url = markerURL else { return }
        try? Data().write(to: url, options: .atomic)
    }
    private func removeMarker() {
        guard let url = markerURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func loadFile() -> JournalFile {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(JournalFile.self, from: data)
        else { return JournalFile(healthyMark: 0, entries: []) }
        return decoded
    }
    private func saveFileLocked() {
        guard let url = fileURL, let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
