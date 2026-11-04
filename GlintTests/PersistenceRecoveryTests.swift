import XCTest
@testable import Glint

/// Recovery logic in `Persistence.load()` is the only thing standing between a
/// half-written state.json and losing every workspace. `load()`/`save()` read a
/// fixed Application Support path by default, so these tests use explicit
/// temporary URLs or pure `Data -> Data?` helpers — pinning them so a future
/// refactor can't quietly regress the "one bad entry costs only that entry"
/// guarantee.
final class PersistenceRecoveryTests: XCTestCase {

    /// Run disk tests in a private temporary directory; body receives state URL; returns no value or throws.
    private func withTemporaryState(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir.appendingPathComponent("state.json"))
    }

    /// Read preserved temporary files; url identifies the state directory; returns their bytes or throws.
    private func preservedStateBytes(at url: URL) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "state.json" }
            .map {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: $0.path)
                return try Data(contentsOf: $0)
            }
    }

    /// Keep a read-failing original in place; no inputs; returns no value and asserts temporary saves cannot overwrite it.
    func testUnreadableStateStaysInPlaceAndBlocksSave() throws {
        try withTemporaryState { url in
            let original = try stateData(workspaces: [Workspace.fresh(name: "Original", accentHex: "5E5CE6", symbol: "O")])
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            XCTAssertNil(Persistence.load(from: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "A temporary read error must not move state.json")
            Persistence.save(.fresh, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(try preservedStateBytes(at: url).isEmpty, "I/O failures must not create corrupt backups")
        }
    }

    /// Resume saving only after explicitly adopting a recovered snapshot; no inputs; returns no value and asserts restored permissions alone cannot authorize replacement.
    func testUnreadableStateRequiresSuccessfulReloadBeforeSave() throws {
        try withTemporaryState { url in
            let original = try stateData(workspaces: [Workspace.fresh(name: "Original", accentHex: "5E5CE6", symbol: "O")])
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            XCTAssertNil(Persistence.load(from: url))
            Persistence.save(.fresh, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            Persistence.save(.fresh, to: url)
            XCTAssertEqual(try Data(contentsOf: url), original, "A now-readable original still belongs to the saved session")
            let restored = try XCTUnwrap(Persistence.load(from: url))
            XCTAssertEqual(restored.workspaces.first?.name, "Original")
            let updated = PersistedState.fresh
            Persistence.save(updated, to: url)
            XCTAssertEqual(Persistence.load(from: url)?.workspaces.first?.id, updated.workspaces.first?.id)
            XCTAssertTrue(try preservedStateBytes(at: url).isEmpty)
        }
    }

    /// Keep an original protected across repeated transient reads; no inputs; returns no value and asserts recovery is an explicit read.
    func testRepeatedReadFailuresDoNotQuarantineState() throws {
        try withTemporaryState { url in
            let original = try stateData(workspaces: [Workspace.fresh(name: "Original", accentHex: "5E5CE6", symbol: "O")])
            try original.write(to: url)
            for _ in 0..<3 {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
                XCTAssertNil(Persistence.load(from: url))
                Persistence.save(.fresh, to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
            XCTAssertEqual(Persistence.load(from: url)?.workspaces.first?.name, "Original")
            XCTAssertTrue(try preservedStateBytes(at: url).isEmpty)
        }
    }

    /// Retry failed corrupt-file quarantine after permissions recover; no inputs; returns no value and asserts saving resumes safely.
    func testCorruptBackupFailureCanRecoverOnLaterSave() throws {
        try withTemporaryState { url in
            let original = Data("not-json".utf8)
            try original.write(to: url)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
            XCTAssertNil(Persistence.load(from: url))
            Persistence.save(.fresh, to: url)
            XCTAssertEqual(try Data(contentsOf: url), original)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            Persistence.save(.fresh, to: url)
            XCTAssertTrue(try preservedStateBytes(at: url).contains(original))
            XCTAssertNotNil(Persistence.load(from: url))
        }
    }

    /// Do not quarantine a valid file repaired after a failed backup; no inputs; returns no value and asserts save waits for adoption.
    func testRepairedCorruptOriginalMustReloadBeforeSave() throws {
        try withTemporaryState { url in
            try Data("not-json".utf8).write(to: url)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
            XCTAssertNil(Persistence.load(from: url))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let repaired = try stateData(workspaces: [Workspace.fresh(name: "Repaired", accentHex: "5E5CE6", symbol: "R")])
            try repaired.write(to: url)
            Persistence.save(.fresh, to: url)
            XCTAssertEqual(try Data(contentsOf: url), repaired, "A valid repaired original must not be moved or replaced")
            XCTAssertTrue(try preservedStateBytes(at: url).isEmpty)
            XCTAssertEqual(Persistence.load(from: url)?.workspaces.first?.name, "Repaired")
        }
    }

    /// Allow fresh installations to save; no inputs; returns no value and asserts missing files create no quarantine.
    func testMissingStateAllowsSaveWithoutBackup() throws {
        try withTemporaryState { url in
            XCTAssertNil(Persistence.load(from: url))
            Persistence.save(.fresh, to: url)
            XCTAssertNotNil(Persistence.load(from: url))
            XCTAssertTrue(try preservedStateBytes(at: url).isEmpty)
        }
    }

    /// Leave a temporarily unavailable symlink target untouched; no inputs; returns no value and asserts later reads restore its session.
    func testDanglingStateSymlinkRemainsInPlace() throws {
        try withTemporaryState { url in
            let target = url.deletingLastPathComponent().appendingPathComponent("temporarily-unavailable.json")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertNil(Persistence.load(from: url))
            Persistence.save(.fresh, to: url)
            let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            XCTAssertEqual(link, target.path, "Missing targets must not cause the original symlink to be replaced")
            let original = try stateData(workspaces: [Workspace.fresh(name: "Returned", accentHex: "5E5CE6", symbol: "R")])
            try original.write(to: target)
            XCTAssertEqual(Persistence.load(from: url)?.workspaces.first?.name, "Returned")
            let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state.json.corrupt-") }
            XCTAssertTrue(backups.isEmpty)
        }
    }

    /// Encode a fixture without disk access; workspaces and selection are inputs; returns JSON data.
    private func stateData(workspaces: [Workspace], selectedWorkspaceID: UUID? = nil) throws -> Data {
        let state = PersistedState(workspaces: workspaces,
                                   selectedWorkspaceID: selectedWorkspaceID,
                                   sidebarCollapsed: false)
        return try JSONEncoder().encode(state)
    }

    /// Corrupt pane values in a fixture; workspace, pane IDs and legacy flag are inputs; returns broken JSON.
    private func corruptPanes(in workspace: Workspace, ids: Set<PaneID>, legacy: Bool = false) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData(workspaces: [workspace])) as? [String: Any])
        var encoded = try XCTUnwrap((root["workspaces"] as? [[String: Any]])?.first)
        var panes = try XCTUnwrap(encoded["panes"] as? [Any])
        for index in stride(from: 0, to: panes.count, by: 2) {
            let keyData = try JSONSerialization.data(withJSONObject: panes[index])
            if ids.contains(try JSONDecoder().decode(PaneID.self, from: keyData)) {
                panes[index + 1] = ["__corrupted": true]
            }
        }
        encoded["panes"] = panes
        if legacy {
            let tab = try XCTUnwrap((encoded["tabs"] as? [[String: Any]])?.first)
            encoded["root"] = tab["root"]
            encoded["focusedPane"] = tab["focusedPane"]
            encoded.removeValue(forKey: "tabs")
        }
        root["workspaces"] = [encoded]
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Build a split fixture; no parameters; returns a workspace with two registered panes.
    private func splitWorkspace() -> Workspace {
        var workspace = Workspace.fresh(name: "Split", accentHex: "5E5CE6", symbol: "S")
        let other = PaneID(value: 1)
        workspace.panes[other] = Pane(id: other, title: "bash", workingDirectory: "/tmp")
        workspace.tabs[0].root = .split(direction: .horizontal, ratio: 0.4,
                                         a: .leaf(PaneID(value: 0)), b: .leaf(other))
        workspace.nextPaneSeq = 2
        return workspace
    }

    /// Recover a broken focused leaf; no parameters; returns no value and asserts the surviving pane is shown.
    func testStripBadPanesPrunesSplitAndRepairsFocus() throws {
        let workspace = splitWorkspace()
        let broken = try corruptPanes(in: workspace, ids: [PaneID(value: 0)])
        let repaired = try XCTUnwrap(Persistence.stripBadPanes(from: broken))
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: repaired).workspaces.first)
        XCTAssertEqual(recovered.tabs[0].root.leaves, [PaneID(value: 1)])
        XCTAssertEqual(recovered.tabs[0].focusedPane, PaneID(value: 1))
        XCTAssertEqual(recovered.panes[PaneID(value: 1)]?.workingDirectory, "/tmp")
        let serialized = try XCTUnwrap(JSONSerialization.jsonObject(with: repaired) as? [String: Any])
        let saved = try XCTUnwrap((serialized["workspaces"] as? [[String: Any]])?.first)
        let savedTab = try XCTUnwrap((saved["tabs"] as? [[String: Any]])?.first)
        let savedTree = try XCTUnwrap(savedTab["root"] as? [String: Any])
        XCTAssertEqual(savedTree["kind"] as? String, "leaf", "the saved repair must remove stale split references")
    }

    /// Recover a pre-tabs split; no parameters; returns no value and asserts migration has no stale leaves.
    func testStripBadPanesRepairsLegacySplit() throws {
        let workspace = splitWorkspace()
        let broken = try corruptPanes(in: workspace, ids: [PaneID(value: 0)], legacy: true)
        let repaired = try XCTUnwrap(Persistence.stripBadPanes(from: broken))
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: repaired).workspaces.first)
        XCTAssertEqual(recovered.tabs[0].root.leaves, [PaneID(value: 1)])
        XCTAssertEqual(recovered.tabs[0].focusedPane, PaneID(value: 1))
    }

    /// Recover an entirely broken tab; no parameters; returns no value and asserts a usable fresh terminal remains.
    func testStripBadPanesReplacesEntirelyBrokenTab() throws {
        let workspace = splitWorkspace()
        let broken = try corruptPanes(in: workspace, ids: Set(workspace.panes.keys))
        let repaired = try XCTUnwrap(Persistence.stripBadPanes(from: broken))
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: repaired).workspaces.first)
        XCTAssertEqual(recovered.id, workspace.id)
        XCTAssertEqual(recovered.tabs[0].id, workspace.tabs[0].id)
        XCTAssertEqual(recovered.panes.count, 1)
        let leaf = try XCTUnwrap(recovered.tabs[0].root.leaves.first)
        XCTAssertNotNil(recovered.panes[leaf])
        XCTAssertEqual(recovered.tabs[0].focusedPane, leaf)
        XCTAssertGreaterThan(recovered.nextPaneSeq, leaf.value)
    }

    /// Recover a workspace's only broken terminal; no parameters; returns no value and asserts its replacement is visible.
    @MainActor
    func testStripBadPanesReplacesOnlyPaneWithVisibleTerminal() throws {
        let workspace = Workspace.fresh(name: "Only", accentHex: "5E5CE6", symbol: "O")
        let broken = try corruptPanes(in: workspace, ids: Set(workspace.panes.keys))
        let repaired = try XCTUnwrap(Persistence.stripBadPanes(from: broken))
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: repaired).workspaces.first)
        let pane = recovered.tabs[0].focusedPane
        XCTAssertEqual(recovered.panes.count, 1)
        XCTAssertNotNil(recovered.panes[pane])
        XCTAssertTrue(WorkspaceStore.paneIsVisible(.init(workspace: recovered.id, pane: pane),
                                                   selectedWorkspaceID: recovered.id, in: recovered))
    }

    /// Repair a focus pointing into another tab; no parameters; returns no value and asserts focus stays inside its tree.
    func testDecodeRepairsFocusThatPointsToAnotherTab() throws {
        var workspace = splitWorkspace()
        workspace.tabs[0].root = .leaf(PaneID(value: 0))
        workspace.tabs[0].focusedPane = PaneID(value: 1)
        workspace.tabs.append(WorkspaceTab(id: TabID(value: 1), name: nil,
                                          root: .leaf(PaneID(value: 1)), focusedPane: PaneID(value: 1)))
        workspace.nextTabSeq = 2
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [workspace])).workspaces.first)
        XCTAssertEqual(recovered.tabs[0].focusedPane, PaneID(value: 0))
        XCTAssertEqual(recovered.tabs[1].focusedPane, PaneID(value: 1))
    }

    /// Reject exhausted IDs during empty-tab recovery; no parameters; returns no value and asserts a decoding error instead of a crash.
    func testDecodeRejectsExhaustedNextPaneSequence() throws {
        var workspace = Workspace.fresh(name: "Exhausted", accentHex: "5E5CE6", symbol: "E")
        workspace.panes = [:]
        workspace.nextPaneSeq = UInt32.max
        var decodeError: Error?
        do {
            _ = try JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [workspace]))
        } catch {
            decodeError = error
        }
        XCTAssertTrue(decodeError is DecodingError)
    }

    /// Reject a registry whose maximum ID cannot advance; no parameters; returns no value and asserts recovery delegates to quarantine.
    func testDecodeRejectsExhaustedRegisteredPaneID() throws {
        for value in [UInt32.max, UInt32.max - 1] {
            var workspace = Workspace.fresh(name: "Exhausted", accentHex: "5E5CE6", symbol: "E")
            let id = PaneID(value: value)
            workspace.panes = [id: Pane(id: id, title: "zsh")]
            var decodeError: Error?
            do {
                _ = try JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [workspace]))
            } catch {
                decodeError = error
            }
            XCTAssertTrue(decodeError is DecodingError)
        }
    }

    /// Recover one broken tab among several; no parameters; returns no value and asserts healthy tabs remain intact.
    func testStripBadPanesKeepsHealthyTabAndSelection() throws {
        var workspace = splitWorkspace()
        workspace.tabs[0].root = .leaf(PaneID(value: 0))
        let second = WorkspaceTab(id: TabID(value: 1), name: "Healthy", root: .leaf(PaneID(value: 1)), focusedPane: PaneID(value: 1))
        workspace.tabs.append(second)
        workspace.selectedTabID = second.id
        workspace.nextTabSeq = 2
        let broken = try corruptPanes(in: workspace, ids: [PaneID(value: 0)])
        let repaired = try XCTUnwrap(Persistence.stripBadPanes(from: broken))
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: repaired).workspaces.first)
        XCTAssertEqual(recovered.tabs.count, 2)
        XCTAssertEqual(recovered.selectedTabID, second.id)
        XCTAssertEqual(recovered.tabs[1].name, "Healthy")
        XCTAssertEqual(recovered.tabs[1].root.leaves, [PaneID(value: 1)])
        XCTAssertEqual(recovered.tabs[1].focusedPane, PaneID(value: 1))
        XCTAssertNotNil(recovered.panes[recovered.tabs[0].focusedPane])
    }

    /// Leave healthy state untouched; no parameters; returns no value and asserts no repair rewrite is requested.
    func testStripBadPanesHealthyDataReturnsNil() throws {
        let workspace = splitWorkspace()
        let clean = try stateData(workspaces: [workspace])
        XCTAssertNil(Persistence.stripBadPanes(from: clean))
        let recovered = try XCTUnwrap(JSONDecoder().decode(PersistedState.self, from: clean).workspaces.first)
        XCTAssertEqual(recovered.tabs[0].root.leaves, workspace.tabs[0].root.leaves)
        XCTAssertEqual(recovered.tabs[0].focusedPane, workspace.tabs[0].focusedPane)
        XCTAssertEqual(recovered.nextPaneSeq, workspace.nextPaneSeq)
    }

    /// Repair the selection of a removed workspace; no parameters; returns no value and asserts an active survivor is selected.
    func testStripBadWorkspacesRepairsRemovedSelection() throws {
        let doomed = Workspace.fresh(name: "Doomed", accentHex: "5E5CE6", symbol: "D")
        var archived = Workspace.fresh(name: "Archived", accentHex: "5E5CE6", symbol: "A")
        archived.archived = true
        let healthy = Workspace.fresh(name: "Healthy", accentHex: "5E5CE6", symbol: "H")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData(workspaces: [doomed, archived, healthy], selectedWorkspaceID: doomed.id)) as? [String: Any])
        var workspaces = try XCTUnwrap(root["workspaces"] as? [Any])
        workspaces[0] = ["__corrupted": true]
        root["workspaces"] = workspaces
        let repaired = try XCTUnwrap(Persistence.stripBadWorkspaces(from: JSONSerialization.data(withJSONObject: root)))
        let recovered = try JSONDecoder().decode(PersistedState.self, from: repaired)
        XCTAssertEqual(recovered.selectedWorkspaceID, healthy.id)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: repaired) as? [String: Any])
        XCTAssertEqual(saved["selectedWorkspaceID"] as? String, healthy.id.uuidString)
    }

    /// Decode a stale UUID without workspace corruption; no parameters; returns no value and asserts selection falls back.
    func testDecodeRepairsDanglingWorkspaceSelection() throws {
        let healthy = Workspace.fresh(name: "Healthy", accentHex: "5E5CE6", symbol: "H")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [healthy], selectedWorkspaceID: UUID()))
        XCTAssertEqual(decoded.selectedWorkspaceID, healthy.id)
    }

    /// Preserve a valid non-first selection; no parameters; returns no value and asserts the user's choice survives decoding.
    func testDecodePreservesHealthyWorkspaceSelection() throws {
        let first = Workspace.fresh(name: "First", accentHex: "5E5CE6", symbol: "F")
        let selected = Workspace.fresh(name: "Selected", accentHex: "5E5CE6", symbol: "S")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [first, selected], selectedWorkspaceID: selected.id))
        XCTAssertEqual(decoded.selectedWorkspaceID, selected.id)
    }

    /// Preserve absent selection for launch policy; no parameters; returns no value and asserts nil remains nil.
    func testDecodePreservesAbsentWorkspaceSelection() throws {
        let workspace = Workspace.fresh(name: "First", accentHex: "5E5CE6", symbol: "F")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [workspace]))
        XCTAssertNil(decoded.selectedWorkspaceID)
    }

    /// Recover selection with only archived survivors; no parameters; returns no value and asserts the first survivor is used.
    func testDecodeDanglingSelectionFallsBackWhenAllArchived() throws {
        var workspace = Workspace.fresh(name: "Archived", accentHex: "5E5CE6", symbol: "A")
        workspace.archived = true
        let decoded = try JSONDecoder().decode(PersistedState.self, from: stateData(workspaces: [workspace], selectedWorkspaceID: UUID()))
        XCTAssertEqual(decoded.selectedWorkspaceID, workspace.id)
    }

    /// Two good workspaces, then one is replaced with a dict missing every
    /// required Workspace field. stripBadWorkspaces must drop only the bad one
    /// and leave the survivor decodable.
    func testStripBadWorkspaces_dropsCorruptKeepsGood() throws {
        let survivor = Workspace.fresh(name: "Survivor", accentHex: "5E5CE6", symbol: "S")
        let clean = try stateData(workspaces: [
            survivor,
            Workspace.fresh(name: "Doomed", accentHex: "FF6482", symbol: "D")
        ])
        XCTAssertNotNil(try? JSONDecoder().decode(PersistedState.self, from: clean))

        // Corrupt the second workspace with a garbage dict (missing id/name/…).
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        var workspaces = try XCTUnwrap(root["workspaces"] as? [Any])
        workspaces[1] = ["__corrupted": true]
        root["workspaces"] = workspaces
        let corrupted = try JSONSerialization.data(withJSONObject: root)

        // Sanity: the corrupted blob no longer decodes as a whole.
        XCTAssertNil(try? JSONDecoder().decode(PersistedState.self, from: corrupted))

        let repaired = Persistence.stripBadWorkspaces(from: corrupted)
        XCTAssertNotNil(repaired, "expected the bad workspace to be stripped")
        let recovered = try JSONDecoder().decode(
            PersistedState.self, from: try XCTUnwrap(repaired))
        XCTAssertEqual(recovered.workspaces.count, 1)
        XCTAssertEqual(recovered.workspaces.first?.name, "Survivor")
    }

    /// Undamaged data must return nil ("nothing to fix") so the caller doesn't
    /// rewrite a healthy file.
    func testStripBadWorkspaces_cleanDataReturnsNil() throws {
        let clean = try stateData(workspaces: [
            Workspace.fresh(name: "A", accentHex: "5E5CE6", symbol: "A")
        ])
        XCTAssertNil(Persistence.stripBadWorkspaces(from: clean))
    }

    /// If every workspace is bad we abstain (nil) rather than emitting an empty
    /// state — the caller then preserves the original on disk and falls back to
    /// a fresh start.
    func testStripBadWorkspaces_allBadReturnsNil() throws {
        let clean = try stateData(workspaces: [
            Workspace.fresh(name: "A", accentHex: "5E5CE6", symbol: "A")
        ])
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        root["workspaces"] = [["__bad": 1], ["__bad": 2]]
        let allBad = try JSONSerialization.data(withJSONObject: root)
        XCTAssertNil(Persistence.stripBadWorkspaces(from: allBad))
    }

    /// A blob that isn't even PersistedState-shaped must not crash — returns nil.
    func testStripBadWorkspaces_unrecognizableReturnsNil() throws {
        let blob = try JSONSerialization.data(withJSONObject: ["not": "state"])
        XCTAssertNil(Persistence.stripBadWorkspaces(from: blob))
    }

    /// A `selectedTabID` that names no existing tab used to survive decoding
    /// intact, and every derived value then degraded quietly: `selectedTab`
    /// nil, `currentRoot` a synthetic leaf, and `paneIsVisible` false for
    /// every pane — which `SurfaceAttachGate` reads as "this tree is on its
    /// way out", so the pane the tree still renders never gets a surface and
    /// stays blank with no self-healing pass. Decode must snap the dangling
    /// selection back to the first tab.
    @MainActor
    func testDanglingSelectedTabIDSnapsBackToFirstTab() throws {
        let workspace = Workspace.fresh(name: "A", accentHex: "5E5CE6", symbol: "A")
        let data = try stateData(workspaces: [workspace])

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var workspaces = try XCTUnwrap(root["workspaces"] as? [Any])
        var encoded = try XCTUnwrap(workspaces[0] as? [String: Any])
        encoded["selectedTabID"] = ["value": 999]
        workspaces[0] = encoded
        root["workspaces"] = workspaces
        let tampered = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(PersistedState.self, from: tampered)
        let recovered = try XCTUnwrap(decoded.workspaces.first)
        let tab = try XCTUnwrap(recovered.selectedTab,
                                "a dangling selection must not leave the workspace tab-less")
        XCTAssertEqual(recovered.selectedTabID, try XCTUnwrap(recovered.tabs.first).id)

        // The consequence the fix exists for: the rendered pane is visible, so
        // the attach gate lets its surface mount.
        let pane = try XCTUnwrap(tab.root.leaves.first)
        XCTAssertTrue(WorkspaceStore.paneIsVisible(
            .init(workspace: recovered.id, pane: pane),
            selectedWorkspaceID: recovered.id,
            in: recovered
        ))
    }
}
