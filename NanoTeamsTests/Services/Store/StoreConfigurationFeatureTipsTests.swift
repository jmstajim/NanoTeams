import XCTest
@testable import NanoTeams

@MainActor
final class StoreConfigurationFeatureTipsTests: XCTestCase {

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

    // MARK: - Stringly-typed mutators (used by view code)

    func testDismissFeatureTip_addsToSet() {
        config.dismissFeatureTip(id: "llm")
        XCTAssertTrue(config.dismissedFeatureTipIDs.contains("llm"))
    }

    func testUndismissFeatureTip_removesFromSet() {
        config.dismissFeatureTip(id: "llm")
        config.undismissFeatureTip(id: "llm")
        XCTAssertFalse(config.dismissedFeatureTipIDs.contains("llm"))
    }

    func testUndismiss_nonexistentID_noOp() {
        config.undismissFeatureTip(id: "nonexistent")
        XCTAssertTrue(config.dismissedFeatureTipIDs.isEmpty)
    }

    // MARK: - Typed enum API

    func testTypedDismiss_writesRawValue() {
        config.dismiss(.vision)
        XCTAssertTrue(config.dismissedFeatureTipIDs.contains("vision"))
        XCTAssertTrue(config.isDismissed(.vision))
        XCTAssertFalse(config.isDismissed(.llm))
    }

    func testIsDismissed_unaffectedByUnknownIDs() {
        // Future tip IDs from newer builds shouldn't break the typed API for
        // current ones — they coexist as opaque strings in the set.
        config.dismissFeatureTip(id: "future_tip")
        XCTAssertFalse(config.isDismissed(.llm))
        XCTAssertFalse(config.isDismissed(.vision))
        XCTAssertTrue(config.dismissedFeatureTipIDs.contains("future_tip"))
    }

    // MARK: - UserDefaults round-trip

    func testDismiss_persistsToStorage() {
        config.dismiss(.dictation)
        let raw = storage.object(forKey: UserDefaultsKeys.dismissedFeatureTipIDs) as? [String]
        XCTAssertEqual(raw.map(Set.init), Set(["dictation"]))
    }

    func testInit_loadsPersistedDismissals() {
        // Pre-seed storage as if a prior run had dismissed two tips.
        storage.set(["llm", "vision"], forKey: UserDefaultsKeys.dismissedFeatureTipIDs)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dismissedFeatureTipIDs, Set(["llm", "vision"]))
        XCTAssertTrue(reloaded.isDismissed(.llm))
        XCTAssertTrue(reloaded.isDismissed(.vision))
    }

    // MARK: - resetToDefaults

    func testResetToDefaults_clearsDismissedFeatureTips() {
        config.dismiss(.llm)
        config.dismiss(.vision)
        config.dismissFeatureTip(id: "future_tip")
        XCTAssertEqual(config.dismissedFeatureTipIDs.count, 3)

        config.resetToDefaults()

        // In-memory state is empty.
        XCTAssertTrue(config.dismissedFeatureTipIDs.isEmpty)
        // Storage is either absent or holds an empty array (the in-memory clear
        // in resetToDefaults reassigns to []; didSet writes that back).
        let stored = (storage.object(forKey: UserDefaultsKeys.dismissedFeatureTipIDs) as? [String]) ?? []
        XCTAssertTrue(stored.isEmpty)
    }
}
