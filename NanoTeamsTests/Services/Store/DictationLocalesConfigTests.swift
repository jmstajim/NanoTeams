import XCTest
@testable import NanoTeams

/// Pins the persistence + reset behavior of `StoreConfiguration.dictationLocaleIdentifiers`.
/// Uses an in-memory storage backend so tests don't touch `UserDefaults.standard`.
@MainActor
final class DictationLocalesConfigTests: XCTestCase {

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

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() {
        config = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - Default

    func testDefault_emptyArray() {
        XCTAssertEqual(config.dictationLocaleIdentifiers, [])
    }

    // MARK: - Persistence

    func testSet_persistsToStorage() {
        config.dictationLocaleIdentifiers = ["en_US", "ru_RU"]
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.dictationLocales) as? [String],
            ["en_US", "ru_RU"]
        )
    }

    func testSet_orderPreserved() {
        // Selection order is meaningful — leader selection in
        // DictationService uses it as a stable tie-breaker.
        config.dictationLocaleIdentifiers = ["ru_RU", "en_US", "de_DE"]
        XCTAssertEqual(config.dictationLocaleIdentifiers, ["ru_RU", "en_US", "de_DE"])
    }

    // `async` to avoid the Xcode 26.3 CI `abort()` that fires when a sync
    // `@MainActor` test method constructs a `@MainActor` type as a local.
    // See CLAUDE.md Testing Conventions #7.
    func testReloadFromStorage_restoresValue() async {
        storage.set(["ru_RU", "en_US"], forKey: UserDefaultsKeys.dictationLocales)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, ["ru_RU", "en_US"])
    }

    func testSet_emptyArray_persists() async {
        config.dictationLocaleIdentifiers = ["en_US"]
        config.dictationLocaleIdentifiers = []
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [])
    }

    // MARK: - Reset

    func testResetToDefaults_clearsDictationLocales() async {
        config.dictationLocaleIdentifiers = ["ru_RU", "en_US"]
        config.resetToDefaults()
        XCTAssertEqual(config.dictationLocaleIdentifiers, [])
        // Per CLAUDE.md "Adding a New StoreConfiguration Setting", reset must
        // both `removeObject` AND reassign the property. The reassignment's
        // `didSet` leaves the key present with `[]` — pin that so a future
        // refactor that drops the reassignment would fail here.
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.dictationLocales) as? [String],
            []
        )
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [])
    }
}
