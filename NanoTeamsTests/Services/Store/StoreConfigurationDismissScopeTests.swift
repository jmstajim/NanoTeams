import XCTest
@testable import NanoTeams

/// Persistence tests for Watchtower inbox dismissals.
///
/// Two properties the old `Set<String>` of bare `dismissID`s could not hold: entries
/// are namespaced by work folder (task IDs are per-folder sequential `Int`s, so a
/// global set let one folder's dismissals suppress another's banners), and they carry
/// the task, so a garbage collector can tell whose key it is looking at.
@MainActor
final class StoreConfigurationDismissScopeTests: XCTestCase {

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
    let key1 = WatchtowerDismissKey(taskID: 1, typeID: "engineer::Q")
    let key2 = WatchtowerDismissKey(taskID: 2, typeID: "engineer::Q")

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

    func testDismissAndRead() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        XCTAssertTrue(config.isDismissed(workFolderID: folderA, key: key1))
        XCTAssertEqual(config.dismissedKeys(forWorkFolder: folderA), [key1])
    }

    func testUndismiss() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        config.undismissNotification(workFolderID: folderA, key: key1)
        XCTAssertFalse(config.isDismissed(workFolderID: folderA, key: key1))
    }

    /// The whole reason for namespacing: folder A's task 1 and folder B's task 1 are
    /// different tasks that happen to share an id.
    func testFoldersDoNotCrossContaminate() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        XCTAssertFalse(config.isDismissed(workFolderID: folderB, key: key1))
        XCTAssertTrue(config.dismissedKeys(forWorkFolder: folderB).isEmpty)
    }

    func testBatchUndismiss() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        config.dismissNotification(workFolderID: folderA, key: key2)
        config.undismissNotifications(workFolderID: folderA, keys: [key1, key2])
        XCTAssertTrue(config.dismissedKeys(forWorkFolder: folderA).isEmpty)
    }

    func testBatchUndismiss_emptySetIsNoOp() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        config.undismissNotifications(workFolderID: folderA, keys: [])
        XCTAssertEqual(config.dismissedKeys(forWorkFolder: folderA), [key1])
    }

    func testForgetDismissals_dropsOnlyThatTask() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        config.dismissNotification(workFolderID: folderA, key: key2)
        config.dismissNotification(workFolderID: folderB, key: key1)
        config.forgetDismissals(workFolderID: folderA, taskID: 1)
        XCTAssertEqual(config.dismissedKeys(forWorkFolder: folderA), [key2])
        XCTAssertEqual(config.dismissedKeys(forWorkFolder: folderB), [key1])
    }

    func testSurvivesReload() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dismissedKeys(forWorkFolder: folderA), [key1])
    }

    /// `.v1` held bare, task-less `dismissID` strings. They can never be attributed to
    /// a task, so the GC could never expire them — deleting the key once is the only
    /// way they stop accumulating.
    func testLegacyV1KeyIsPurgedOnLoad() {
        storage.set(["engineer::What next?"], forKey: UserDefaultsKeys.legacyDismissedNotificationIDsV1)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.legacyDismissedNotificationIDsV1))
        XCTAssertTrue(reloaded.dismissedKeys(forWorkFolder: folderA).isEmpty)
    }

    func testUnparseableEntryIsSkippedNotGuessedAt() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        var raw = config.dismissedNotificationKeys
        raw.insert("\(folderA.uuidString):engineer")   // legacy shape, no task scope
        storage.set(Array(raw), forKey: UserDefaultsKeys.dismissedNotificationIDs)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dismissedKeys(forWorkFolder: folderA), [key1])
    }

    func testResetToDefaultsClearsThem() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        config.resetToDefaults()
        XCTAssertTrue(config.dismissedKeys(forWorkFolder: folderA).isEmpty)
    }
}
