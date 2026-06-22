import XCTest
@testable import Glint

@MainActor
final class CodexHomeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CodexHomeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshStoreExposesDefaultWithoutPersistingIt() {
        let store = CodexHomeStore(defaults: defaults)

        XCTAssertEqual(store.homes.count, 1)
        XCTAssertEqual(store.homes[0].path, "~/.codex")
        XCTAssertTrue(store.homes[0].isEnabled)
        XCTAssertNil(defaults.data(forKey: CodexHomeStore.storageKey))
    }

    func testDefaultHomeHasStableIdentity() {
        XCTAssertEqual(CodexHome.default.id, CodexHome.default.id)
        XCTAssertEqual(CodexHome.default.id, CodexHome.defaultID)
    }

    func testEquivalentPathsCannotBeAddedTwice() {
        let store = CodexHomeStore(defaults: defaults)
        let absoluteDefault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").path

        XCTAssertEqual(store.add(path: absoluteDefault, label: "Duplicate"), .duplicate)
        XCTAssertEqual(store.homes.count, 1)
    }

    func testChangesPersistAndDisabledHomesAreExcluded() {
        var store = CodexHomeStore(defaults: defaults)
        XCTAssertEqual(store.add(path: "~/work/.codex", label: "Work"), .added)
        let work = try! XCTUnwrap(store.homes.last)
        store.setEnabled(false, for: work.id)

        store = CodexHomeStore(defaults: defaults)
        XCTAssertEqual(store.homes.count, 2)
        XCTAssertEqual(store.homes.last?.label, "Work")
        XCTAssertEqual(store.enabledHomes.map(\.path), ["~/.codex"])
    }

    func testDefaultCannotBeRemoved() {
        let store = CodexHomeStore(defaults: defaults)

        XCTAssertFalse(store.remove(id: store.homes[0].id))
        XCTAssertEqual(store.homes.count, 1)
    }

    func testCustomHomeIsRemovedEvenWhenHookCleanupFails() throws {
        struct CleanupError: LocalizedError {
            var errorDescription: String? { "Invalid hooks.json" }
        }
        let store = CodexHomeStore(defaults: defaults)
        XCTAssertEqual(store.add(path: "~/broken/.codex", label: "Broken"), .added)
        let broken = try XCTUnwrap(store.homes.last)

        let warning = CodexHomeRemoval.remove(broken, from: store) { _ in
            throw CleanupError()
        }

        XCTAssertEqual(warning, "Invalid hooks.json")
        XCTAssertFalse(store.homes.contains(where: { $0.id == broken.id }))
    }

    func testAddRejectsRelativePaths() {
        let store = CodexHomeStore(defaults: defaults)

        XCTAssertEqual(store.add(path: "work/.codex"), .relativePath)
        XCTAssertEqual(store.add(path: "  "), .emptyPath)
        XCTAssertEqual(store.homes.count, 1)
        XCTAssertNil(defaults.data(forKey: CodexHomeStore.storageKey))
    }
}
