import XCTest
@testable import Glint

/// Recovery logic in `Persistence.load()` is the only thing standing between a
/// half-written state.json and losing every workspace. `load()`/`save()` read a
/// fixed Application Support path, so these tests exercise the pure
/// `Data -> Data?` recovery helpers directly — pinning them so a future
/// refactor can't quietly regress the "one bad entry costs only that entry"
/// guarantee.
final class PersistenceRecoveryTests: XCTestCase {

    private func stateData(workspaces: [Workspace]) throws -> Data {
        let state = PersistedState(workspaces: workspaces,
                                   selectedWorkspaceID: nil,
                                   sidebarCollapsed: false)
        return try JSONEncoder().encode(state)
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
