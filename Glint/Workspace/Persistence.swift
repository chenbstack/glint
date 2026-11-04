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

    /// A temporary read failure never authorizes replacing the saved session.
    /// Only a successful explicit load can adopt it and permit later saves.
    private static var unreadablePaths = Set<String>()

    /// Path of a confirmed corrupt state.json whose quarantine failed.
    private static var corruptUnmovablePath: String?

    /// Whether startup must offer recovery rather than silently saving a fresh session.
    static var requiresLoadRetry: Bool {
        guard let url = fileURL else { return false }
        return unreadablePaths.contains(url.path) || corruptUnmovablePath == url.path
    }

    /// Load the application snapshot; no parameters; returns nil if absent or
    /// unavailable. I/O failures keep the original in place and block saves;
    /// only confirmed undecodable data is quarantined after repair attempts.
    static func load() -> PersistedState? {
        guard let url = fileURL else { return nil }
        return load(from: url)
    }

    /// Load a saved snapshot; url is its disk location; returns decoded state or nil on missing/unreadable data.
    static func load(from url: URL) -> PersistedState? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if isMissingOriginal(at: url, readError: error) {
                clearRecoveryBlock(at: url)
            } else {
                unreadablePaths.insert(url.path)
                NSLog("[glint] couldn't read \(fileName): \(error); leaving it in place and blocking saves until it is reloaded")
            }
            return nil
        }
        do {
            let restored = try JSONDecoder().decode(PersistedState.self, from: data)
            clearRecoveryBlock(at: url)
            return restored
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
                clearRecoveryBlock(at: url)
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

            NSLog("[glint] failed to decode \(fileName): \(error); preserving it before starting fresh")
            unreadablePaths.remove(url.path)
            _ = preserveOriginal(at: url)
            return nil
        }
    }

    /// Distinguish a genuinely absent entry from a missing symlink target;
    /// inputs are its URL and read error; returns true only for missing entries.
    private static func isMissingOriginal(at url: URL, readError: Error) -> Bool {
        let failure = readError as NSError
        guard failure.domain == NSCocoaErrorDomain,
              failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError else { return false }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch {
            let lookup = error as NSError
            return lookup.domain == NSCocoaErrorDomain
                && (lookup.code == NSFileReadNoSuchFileError || lookup.code == NSFileNoSuchFileError)
        }
    }

    /// Permit saves after adopting or confirming absence of a saved session;
    /// url identifies the snapshot; returns nothing.
    private static func clearRecoveryBlock(at url: URL) {
        unreadablePaths.remove(url.path)
        if corruptUnmovablePath == url.path { corruptUnmovablePath = nil }
    }

    /// Move an unreadable original to a unique sibling; url is its location; returns whether saving may safely proceed.
    private static func preserveOriginal(at url: URL) -> Bool {
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(fileName).corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            if corruptUnmovablePath == url.path { corruptUnmovablePath = nil }
            NSLog("[glint] preserved \(fileName) at \(backup.lastPathComponent)")
            return true
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError {
                if corruptUnmovablePath == url.path { corruptUnmovablePath = nil }
                return true
            }
            corruptUnmovablePath = url.path
            NSLog("[glint] couldn't preserve \(fileName) (\(error)); refusing to overwrite the original")
            return false
        }
    }

    /// Save the snapshot to the application path; state is the current model; returns no value.
    static func save(_ state: PersistedState) {
        guard let url = fileURL else { return }
        save(state, to: url)
    }

    /// Save a snapshot; state and destination url are inputs; returns no value, preserving unreadable originals.
    static func save(_ state: PersistedState, to url: URL) {
        guard !unreadablePaths.contains(url.path) else { return }
        if corruptUnmovablePath == url.path {
            do {
                let data = try Data(contentsOf: url)
                let paneFixed = stripBadPanes(from: data) ?? data
                let repaired = stripBadWorkspaces(from: paneFixed) ?? paneFixed
                if (try? JSONDecoder().decode(PersistedState.self, from: repaired)) != nil {
                    unreadablePaths.insert(url.path)
                    NSLog("[glint] \(fileName) is now recoverable; leaving it in place until the session is reloaded")
                    return
                }
                guard preserveOriginal(at: url) else { return }
            } catch {
                guard isMissingOriginal(at: url, readError: error) else {
                    unreadablePaths.insert(url.path)
                    return
                }
                clearRecoveryBlock(at: url)
            }
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
    /// only that pane instead of the whole file. Parameter data is saved JSON;
    /// the returned repair also removes stale layout/focus references.
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
            if kept.count != panes.count {
                workspaces[i]["panes"] = kept
                // Workspace's decoder repairs the split trees after pruning;
                // persist those repaired references along with the registry.
                if let blob = SafeJSON.data(workspaces[i]),
                   let workspace = try? pdecoder.decode(Workspace.self, from: blob),
                   let encoded = try? JSONEncoder().encode(workspace),
                   let repaired = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
                    workspaces[i] = repaired
                }
            }
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
    /// original on disk), or if the structure is unrecognizable. Parameter data
    /// is saved JSON; a returned repair selects an existing active survivor.
    static func stripBadWorkspaces(from data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let workspaces = root["workspaces"] as? [Any] else { return nil }
        let wdecoder = JSONDecoder()
        var kept: [Any] = []
        var decoded: [Workspace] = []
        var dropped = 0
        for ws in workspaces {
            // SafeJSON, not bare data(withJSONObject:): a stray non-JSON leaf
            // or non-finite number throws an NSException (uncatchable by try?).
            let blob = SafeJSON.data(ws) ?? Data()
            if let workspace = try? wdecoder.decode(Workspace.self, from: blob) {
                kept.append(ws)
                decoded.append(workspace)
            } else {
                dropped += 1
            }
        }
        guard dropped > 0, !kept.isEmpty else { return nil }
        root["workspaces"] = kept
        if let selected = root["selectedWorkspaceID"] as? String,
           let id = UUID(uuidString: selected),
           !decoded.contains(where: { $0.id == id }) {
            root["selectedWorkspaceID"] = (decoded.first(where: { !$0.archived }) ?? decoded[0]).id.uuidString
        }
        NSLog("[glint] \(fileName): dropping \(dropped) undecodable workspace(s), keeping \(kept.count)")
        return SafeJSON.data(root)
    }
}
