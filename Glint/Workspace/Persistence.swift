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

    /// Whether a saved state file already exists on disk — i.e. the app has run
    /// and persisted at least once before this launch. Lets us tell an existing
    /// user (who upgraded into a new feature) apart from a fresh install, even
    /// before this launch writes its own first save.
    static var hasSavedState: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
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
            // Progressive recovery before quarantining. Two stages, each
            // feeding the next so a file with mixed damage still recovers the
            // good workspaces:
            //   1. stripBadPanes — drops a single undecodable pane entry.
            //      PaneID isn't a String/Int key, so [PaneID: Pane] serializes
            //      as a flat alternating [key, value, ...] array; we drop just
            //      the bad pair, keeping the workspace.
            //   2. stripBadWorkspaces — drops a whole undecodable workspace
            //      (corruption in a workspace-level field like tabs/source/
            //      accentHex, not a pane), keeping the rest.
            let paneFixed = Self.stripBadPanes(from: data) ?? data
            let repaired = Self.stripBadWorkspaces(from: paneFixed) ?? paneFixed
            if repaired != data,
               let state = try? JSONDecoder().decode(PersistedState.self, from: repaired) {
                NSLog("[glint] decoded \(fileName) after stripping undecodable pane(s)/workspace(s); persisting the repaired copy")
                do {
                    try repaired.write(to: url, options: [.atomic])
                } catch {
                    // Couldn't persist the repair (disk full/permissions) — but
                    // the repaired state decoded fine and is now the in-memory
                    // truth, so DON'T block further saves. A later autosave
                    // carries this good state plus any new work, and an atomic
                    // write that fails leaves the original intact (no worse
                    // corruption). Setting corruptUnmovablePath here would
                    // permanently drop EVERY subsequent edit until relaunch —
                    // a worse outcome than overwriting a corrupt original we
                    // already recovered from. The "preserve the only copy"
                    // guard belongs only to the unreadable-file path below,
                    // where no repair could be decoded at all.
                    NSLog("[glint] couldn't persist repaired \(fileName) (\(error)); will retry on next save — original kept at \(url.path)")
                }
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
    static func stripBadPanes(from data: Data) -> Data? {
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
                // SafeJSON, not a bare data(withJSONObject:): the latter throws
                // an Objective-C NSException (uncatchable by try?) on a stray
                // non-JSON leaf or non-finite number. Project-wide convention.
                let blob = SafeJSON.data(value) ?? Data()
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
        return SafeJSON.data(root)
    }

    /// Drop any top-level workspace that won't decode, keeping the rest.
    /// Runs after stripBadPanes, so by the time this fires the damage is in a
    /// workspace-level field (tabs, source, accentHex, …) rather than a pane —
    /// letting one bad workspace cost only that workspace instead of the whole
    /// file. Returns nil if nothing was dropped, if every workspace is bad
    /// (abstaining lets the caller fall back to a fresh state and preserve the
    /// original on disk), or if the structure is unrecognizable.
    static func stripBadWorkspaces(from data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let workspaces = root["workspaces"] as? [Any] else { return nil }
        let wdecoder = JSONDecoder()
        var kept: [Any] = []
        var dropped = 0
        for ws in workspaces {
            // SafeJSON, not bare data(withJSONObject:): a stray non-JSON leaf
            // or non-finite number throws an NSException (uncatchable by try?).
            let blob = SafeJSON.data(ws) ?? Data()
            if (try? wdecoder.decode(Workspace.self, from: blob)) != nil {
                kept.append(ws)
            } else {
                dropped += 1
            }
        }
        guard dropped > 0, !kept.isEmpty else { return nil }
        root["workspaces"] = kept
        NSLog("[glint] \(fileName): dropping \(dropped) undecodable workspace(s), keeping \(kept.count)")
        return SafeJSON.data(root)
    }
}
