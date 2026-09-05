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

    // MARK: - A no-op is not a write (CLAUDE.md #106)

    /// `Set.remove` of a non-member changes nothing and still fires `didSet` — a whole-set
    /// re-serialisation to UserDefaults for the COMMON case (every answer retires a key
    /// that is almost never there). Counted, never timed.
    ///
    /// RED: delete `guard dismissedNotificationKeys.contains(entry) else { return }` in
    /// `undismissNotification` → the absent-key call writes, `_testWrites() == 1`.
    /// GREEN control (CLAUDE.md #56): write `Array(dismissedNotificationKeys).sorted()`
    /// instead of `Array(...)` in the `didSet` — a legitimate retune, still one write.
    func testUndismiss_absentKey_isNotAPersistenceWrite() {
        DismissalStoreProbe._testReset()
        config.undismissNotification(workFolderID: folderA, key: key1)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 0, "absent key ⇒ nothing to persist")

        config.dismissNotification(workFolderID: folderA, key: key1)
        DismissalStoreProbe._testReset()
        config.undismissNotification(workFolderID: folderA, key: key1)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 1, "anti-vacuum: a real retirement is exactly one write")
        XCTAssertFalse(config.isDismissed(workFolderID: folderA, key: key1))
    }

    /// The batch form (the GC sweep and `retireRoleBannerDismissals`): a disjoint set is
    /// subtracted without a write; one hit costs one write and drops only the hits.
    ///
    /// RED: delete `guard !hits.isEmpty else { return }` in `undismissNotifications` →
    /// `subtract` of a disjoint set fires `didSet`, `_testWrites() == 1` on the no-hit call.
    func testUndismissBatch_noHits_isNotAPersistenceWrite() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        DismissalStoreProbe._testReset()
        config.undismissNotifications(workFolderID: folderA, keys: [key2])
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 0, "no hit ⇒ no write")
        XCTAssertTrue(config.isDismissed(workFolderID: folderA, key: key1))

        config.undismissNotifications(workFolderID: folderA, keys: [key1, key2])
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 1, "one hit among two keys ⇒ exactly one write")
        XCTAssertTrue(config.dismissedKeys(forWorkFolder: folderA).isEmpty)
    }

    /// `MainLayoutView.dismissNotifications` re-dismisses every visible banner on each
    /// chat open, so an already-dismissed key is the hot no-op on the insert side.
    ///
    /// RED: delete `guard !dismissedNotificationKeys.contains(entry) else { return }` in
    /// `dismissNotification` → `insert` of a member fires `didSet`, `_testWrites() == 1`.
    func testDismiss_alreadyDismissed_isNotAPersistenceWrite() {
        DismissalStoreProbe._testReset()
        config.dismissNotification(workFolderID: folderA, key: key1)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 1, "anti-vacuum: a first dismissal is exactly one write")

        DismissalStoreProbe._testReset()
        config.dismissNotification(workFolderID: folderA, key: key1)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 0, "already dismissed ⇒ nothing to persist")
        XCTAssertEqual(config.dismissedKeys(forWorkFolder: folderA), [key1])
    }

    /// `forgetDismissals` (`closeTask` / `TaskManagementState.forgetTask`) is the fourth
    /// writer, and a task that never had a banner dismissed is the common closed task —
    /// a filter that drops nothing must not re-serialise the set either.
    ///
    /// RED: delete `guard kept.count != dismissedNotificationKeys.count else { return }`
    /// in `forgetDismissals` → the reassignment fires `didSet`, `_testWrites() == 1` on
    /// the no-key call.
    func testForget_taskWithNoDismissals_isNotAPersistenceWrite() {
        config.dismissNotification(workFolderID: folderA, key: key1)
        DismissalStoreProbe._testReset()
        config.forgetDismissals(workFolderID: folderA, taskID: 99)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 0, "no key of that task ⇒ no write")
        XCTAssertTrue(config.isDismissed(workFolderID: folderA, key: key1), "and nothing else was touched")

        config.forgetDismissals(workFolderID: folderA, taskID: key1.taskID)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 1, "anti-vacuum: forgetting a task that has a key is exactly one write")
        XCTAssertFalse(config.isDismissed(workFolderID: folderA, key: key1))
    }
}
