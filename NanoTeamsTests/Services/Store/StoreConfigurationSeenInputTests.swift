import XCTest
@testable import NanoTeams

/// Persistence tests for the sidebar "read" indicator state.
///
/// Bug context: chats that were marked read kept reappearing as unread after
/// an app relaunch because the seen set was in-memory only. This pins the
/// new `StoreConfiguration` API that backs the set with UserDefaults and
/// namespaces entries by `(workFolderID, taskID)` so different work folders
/// can't cross-contaminate each other's sequential task IDs.
@MainActor
final class StoreConfigurationSeenInputTests: XCTestCase {

    final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        private var store: [String: Any] = [:]
        func string(forKey key: String) -> String? { store[key] as? String }
        func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
        func data(forKey key: String) -> Data? { store[key] as? Data }
        func object(forKey key: String) -> Any? { store[key] }
        func set(_ value: Any?, forKey key: String) {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    }

    var storage: InMemoryStorage!
    var config: StoreConfiguration!
    let folderA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let folderB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Round-trip mutators

    func testMarkTaskSeen_addsEntry() {
        config.markTaskSeen(workFolderID: folderA, taskID: 7)
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 7))
    }

    func testUnmarkTaskSeen_removesEntry() {
        config.markTaskSeen(workFolderID: folderA, taskID: 7)
        config.unmarkTaskSeen(workFolderID: folderA, taskID: 7)
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 7))
    }

    func testUnmarkTaskSeen_nonexistent_noOp() {
        config.unmarkTaskSeen(workFolderID: folderA, taskID: 99)
        XCTAssertFalse(config.isTaskSeen(workFolderID: folderA, taskID: 99))
    }

    func testMarkTaskSeen_isIdempotent() {
        config.markTaskSeen(workFolderID: folderA, taskID: 5)
        config.markTaskSeen(workFolderID: folderA, taskID: 5)
        XCTAssertEqual(config.seenTaskIDs(forWorkFolder: folderA), Set([5]))
    }

    // MARK: - Workfolder namespacing

    func testWorkfolderIsolation_sameTaskIDInDifferentFolders() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        XCTAssertTrue(config.isTaskSeen(workFolderID: folderA, taskID: 1))
        XCTAssertFalse(
            config.isTaskSeen(workFolderID: folderB, taskID: 1),
            "Same task ID in a different folder must be unseen — folders share UserDefaults but never seen-set entries"
        )
    }

    func testSeenTaskIDs_filtersByWorkFolder() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        config.markTaskSeen(workFolderID: folderA, taskID: 2)
        config.markTaskSeen(workFolderID: folderB, taskID: 1)
        config.markTaskSeen(workFolderID: folderB, taskID: 99)
        XCTAssertEqual(config.seenTaskIDs(forWorkFolder: folderA), Set([1, 2]))
        XCTAssertEqual(config.seenTaskIDs(forWorkFolder: folderB), Set([1, 99]))
    }

    // MARK: - Persistence across "relaunch"

    func testRelaunch_preservesSeenSet() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        config.markTaskSeen(workFolderID: folderA, taskID: 2)
        config.markTaskSeen(workFolderID: folderB, taskID: 42)

        // Simulate process restart by rebuilding StoreConfiguration on the same storage.
        let reloaded = StoreConfiguration(storage: storage)

        XCTAssertEqual(reloaded.seenTaskIDs(forWorkFolder: folderA), Set([1, 2]))
        XCTAssertEqual(reloaded.seenTaskIDs(forWorkFolder: folderB), Set([42]))
    }

    func testUnmark_persistsRemoval() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        config.markTaskSeen(workFolderID: folderA, taskID: 2)
        config.unmarkTaskSeen(workFolderID: folderA, taskID: 1)

        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.seenTaskIDs(forWorkFolder: folderA), Set([2]))
    }

    // MARK: - resetToDefaults

    func testResetToDefaults_clearsSeenInputKeys() {
        config.markTaskSeen(workFolderID: folderA, taskID: 1)
        config.markTaskSeen(workFolderID: folderB, taskID: 2)
        XCTAssertFalse(config.seenSupervisorInputKeys.isEmpty)

        config.resetToDefaults()

        XCTAssertTrue(config.seenSupervisorInputKeys.isEmpty)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertTrue(reloaded.seenSupervisorInputKeys.isEmpty)
    }

    // MARK: - Defensive: malformed entries on load

    func testInit_skipsMalformedEntries() {
        // Simulate a stray entry that doesn't match the "<uuid>:<int>" shape —
        // e.g. an older build wrote a different schema. Must not crash, must
        // not contribute to any folder's seen set.
        storage.set(
            ["not-a-uuid:5", "\(folderA.uuidString):3", "\(folderA.uuidString):notAnInt"],
            forKey: UserDefaultsKeys.seenSupervisorInputKeys
        )
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.seenTaskIDs(forWorkFolder: folderA), Set([3]))
    }
}
