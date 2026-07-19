import XCTest

@testable import NanoTeams

/// Retiring a setting deletes its `Keys` constant — which also deletes the
/// `removeObject` line in `resetToDefaults`. Without an explicit purge the
/// stored value then survives forever on upgraded installs: unreadable by the
/// app, and untouched even by a full "reset all settings".
///
/// Pins the one-shot purge that mirrors `migrateExpandedSearchKeys` and the
/// legacy `bashJudgeModel` migration.
@MainActor
final class StoreConfigurationRetiredKeysTests: XCTestCase {

    /// Spelled out because the constants no longer exist — the whole point is
    /// that nothing in production references these strings any more.
    private let retiredKeys = [
        "llmMaxTokens",
        "llmTemperature",
        "NanoTeams.vision.maxTokens.v1",
    ]

    private var storage: InMemoryStorage!

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    func testInit_removesRetiredSamplingKeys() {
        for key in retiredKeys { storage.set(4096, forKey: key) }

        _ = StoreConfiguration(storage: storage)

        for key in retiredKeys {
            XCTAssertNil(
                storage.object(forKey: key),
                "\(key) was retired in 2026-07 — it must not survive an app launch")
        }
    }

    /// Idempotent: a second launch has nothing to purge and must not fail or
    /// touch anything else.
    func testInit_repeatedLaunches_isIdempotent() {
        storage.set(4096, forKey: retiredKeys[0])
        _ = StoreConfiguration(storage: storage)
        _ = StoreConfiguration(storage: storage)

        XCTAssertNil(storage.object(forKey: retiredKeys[0]))
    }

    /// The purge is a targeted list, not a prefix sweep — a live setting that
    /// merely looks related must survive.
    func testInit_leavesLiveKeysAlone() {
        let config = StoreConfiguration(storage: storage)
        config.llmModelName = "qwen"
        config.llmRequestTimeoutSeconds = 900

        _ = StoreConfiguration(storage: storage)

        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.llmModelName, "qwen")
        XCTAssertEqual(reloaded.llmRequestTimeoutSeconds, 900)
    }
}

private final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
    var store: [String: Any] = [:]
    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { store[key] = value } else { store.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
