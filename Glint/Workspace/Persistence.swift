import Foundation

/// Per-build-flavor Application Support folder. Debug builds live in
/// "Glint-Dev" (and, via the .dev bundle id, their own defaults domain) so a
/// dev run can never corrupt the installed production app's state. The first
/// dev launch seeds itself with a one-time copy of the production folder;
/// after that the two diverge independently.
enum SupportDir {
    #if DEBUG
    static let name = "Glint-Dev"
    #else
    static let name = "Glint"
    #endif

    static var url: URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        #if DEBUG
        _ = seedOnce
        #endif
        let dir = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if DEBUG
    private static let seedOnce: Void = {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return }
        let dev = appSupport.appendingPathComponent(name, isDirectory: true)
        let prod = appSupport.appendingPathComponent("Glint", isDirectory: true)
        if !fm.fileExists(atPath: dev.path), fm.fileExists(atPath: prod.path) {
            try? fm.copyItem(at: prod, to: dev)
        }
    }()
    #endif
}

enum Persistence {
    private static let fileName = "state.json"

    private static var fileURL: URL? {
        SupportDir.url?.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Path of a corrupt state.json that we could NOT move aside (disk full,
    /// permissions). save() refuses to write over it so the only copy of the
    /// user's data is never clobbered. Session-scoped: cleared on next launch.
    private static var corruptUnmovablePath: String?

    /// Returns nil both for "no saved state" (fresh install) and "state was
    /// unreadable" — but the two paths differ in side effects: an unreadable
    /// file is moved aside (never deleted or overwritten) so a decode bug or
    /// half-written file can't silently destroy the user's workspaces. Before
    /// quarantining we try to surgically strip a single bad pane entry so it
    /// costs only that pane, not every workspace.
    static func load() -> PersistedState? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            // A single undecodable pane entry would otherwise quarantine the
            // whole file and lose every workspace. PaneID isn't a String/Int
            // key, so [PaneID: Pane] serializes as a flat alternating
            // [key, value, ...] array; stripBadPanes drops just the bad pair.
            if let repaired = Self.stripBadPanes(from: data),
               let state = try? JSONDecoder().decode(PersistedState.self, from: repaired) {
                NSLog("[glint] decoded \(fileName) after stripping undecodable pane(s); persisting the repaired copy")
                try? repaired.write(to: url, options: [.atomic])
                return state
            }

            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(fileName).corrupt-\(stamp)")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                NSLog("[glint] failed to decode \(fileName): \(error); moved it aside to \(backup.lastPathComponent) and starting fresh")
            } catch {
                // Couldn't move it aside either — remember the path so save()
                // won't overwrite the only copy. The original stays put for
                // the user to recover manually; we start fresh in memory.
                corruptUnmovablePath = url.path
                NSLog("[glint] \(fileName) couldn't be moved aside to \(backup.lastPathComponent); refusing to overwrite — original kept at \(url.path), starting fresh")
            }
            return nil
        }
    }

    static func save(_ state: PersistedState) {
        guard let url = fileURL else { return }
        if corruptUnmovablePath == url.path {
            NSLog("[glint] skipping save: \(fileName) is the corrupt file we couldn't move aside; not overwriting the user's data")
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Persistence failing silently is the worst kind of failure —
            // at least leave a trail in the console.
            NSLog("[glint] failed to save \(fileName): \(error)")
        }
    }

    /// Walk each workspace's `panes` — `[PaneID: Pane]` serializes as a flat
    /// alternating [key, value, key, value, ...] array because PaneID isn't a
    /// String/Int key — and drop any pair whose value half won't decode as a
    /// `Pane`. Returns re-serialized JSON if a bad pane was removed, nil if
    /// nothing changed or the structure is unrecognizable (so the caller only
    /// retries when there's something to retry with). Lets one bad pane cost
    /// only that pane instead of the whole file.
    private static func stripBadPanes(from data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        let pdecoder = JSONDecoder()
        var changed = false
        for i in workspaces.indices {
            guard let panes = workspaces[i]["panes"] as? [Any] else { continue }
            var kept: [Any] = []
            var j = 0
            while j + 1 < panes.count {
                let value = panes[j + 1]
                let blob = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
                if (try? pdecoder.decode(Pane.self, from: blob)) != nil {
                    kept.append(panes[j]); kept.append(value)
                } else {
                    changed = true
                }
                j += 2
            }
            if kept.count != panes.count { workspaces[i]["panes"] = kept }
        }
        guard changed else { return nil }
        root["workspaces"] = workspaces
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
