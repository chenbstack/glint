import XCTest
@testable import Glint

/// Locks the JSON migration path for the per-pane #45 session id store:
/// the legacy 4 `lastXSessionId` fields → the unified `sessionIds` dict.
/// Without these tests a future refactor of `Pane.init(from:)` could silently
/// drop the legacy entries and reintroduce the multi-pane session-collapse
/// bug for any user upgrading from beta cycle 1.
final class PaneSessionIdMigrationTests: XCTestCase {

    private func decode(_ json: String) throws -> Pane {
        try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    }

    private func encode(_ pane: Pane) throws -> [String: Any] {
        let data = try JSONEncoder().encode(pane)
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: legacy decode

    func testLegacyFourFieldsAreLiftedIntoSessionIds() throws {
        let json = """
        {
          "id": {"value": 42},
          "title": "pane",
          "lastClaudeSessionId": "c-id",
          "lastCodexSessionId": "x-id",
          "lastOpenCodeSessionId": "o-id",
          "lastDevinSessionId": "d-id"
        }
        """
        let pane = try decode(json)
        XCTAssertEqual(pane.sessionIds["claude"], "c-id")
        XCTAssertEqual(pane.sessionIds["codex"], "x-id")
        XCTAssertEqual(pane.sessionIds["opencode"], "o-id")
        XCTAssertEqual(pane.sessionIds["devin"], "d-id")
    }

    func testLegacyPartialFieldsOnlyMigrateWhatExists() throws {
        let json = """
        {
          "id": {"value": 7},
          "title": "pane",
          "lastClaudeSessionId": "only-claude"
        }
        """
        let pane = try decode(json)
        XCTAssertEqual(pane.sessionIds, ["claude": "only-claude"])
    }

    func testFreshPanePreSessionIdProducesEmptyDict() throws {
        let json = """
        { "id": {"value": 1}, "title": "fresh" }
        """
        let pane = try decode(json)
        XCTAssertTrue(pane.sessionIds.isEmpty)
    }

    // MARK: typeMismatch surfaces (no silent swallow)

    func testTypeMismatchOnLegacyFieldThrows() {
        // A corrupt legacy field (number stored where a String was expected)
        // must NOT silently produce an empty dict — that would mask the
        // corruption AND lose the user's #45 resume hint with no diagnostic.
        let json = """
        {
          "id": {"value": 99},
          "title": "pane",
          "lastClaudeSessionId": 42
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: encode shape

    func testEncodingOmitsEmptySessionIds() throws {
        let pane = Pane(id: PaneID(value: 1), title: "t")
        let dict = try encode(pane)
        XCTAssertNil(dict["sessionIds"],
                     "empty sessionIds must NOT be written — keeps autosaves quiet")
    }

    func testEncodingDropsLegacyKeys() throws {
        // After a round-trip, the legacy per-agent keys must be gone — the
        // encoder is the migration's commit step.
        let legacyJson = """
        {
          "id": {"value": 5},
          "title": "pane",
          "lastClaudeSessionId": "c-id",
          "lastDevinSessionId": "d-id"
        }
        """
        let pane = try decode(legacyJson)
        let reencoded = try encode(pane)
        XCTAssertNil(reencoded["lastClaudeSessionId"])
        XCTAssertNil(reencoded["lastCodexSessionId"])
        XCTAssertNil(reencoded["lastOpenCodeSessionId"])
        XCTAssertNil(reencoded["lastDevinSessionId"])
        let mapped = reencoded["sessionIds"] as? [String: String]
        XCTAssertEqual(mapped, ["claude": "c-id", "devin": "d-id"])
    }

    // MARK: round-trip

    func testRoundTripPreservesSessionIds() throws {
        var pane = Pane(id: PaneID(value: 3), title: "round-trip")
        pane.sessionIds = ["claude": "abc-123", "codex": "def-456"]
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        XCTAssertEqual(decoded.sessionIds, pane.sessionIds)
    }
}
