import XCTest
@testable import NanoTeams

/// Storage round-trip for expanded-search settings: the on/off toggle, the
/// optional embedding-model override, and the two cosine thresholds.
@MainActor
final class ExpandedSearchConfigurationTests: XCTestCase {

    private var storage: InMemoryStorage!
    private var config: StoreConfiguration!

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

    // MARK: - Defaults

    func testDefaults_disabled_noOverride() {
        XCTAssertFalse(config.expandedSearchEnabled)
        XCTAssertNil(config.expandedSearchEmbeddingConfig)
    }

    func testDefaults_thresholds_matchPlannedValues() {
        XCTAssertEqual(config.expandedSearchPerTokenThreshold, 0.75, accuracy: 0.001)
        XCTAssertEqual(config.expandedSearchPhraseThreshold, 0.70, accuracy: 0.001)
    }

    func testEffectiveEmbeddingConfig_withoutOverride_usesDefaultNomic() {
        XCTAssertEqual(config.effectiveEmbeddingConfig, EmbeddingConfig.defaultNomicLMStudio)
    }

    // MARK: - Toggle round-trip

    // `async` is load-bearing for tests that construct a `@MainActor` class
    // (here `StoreConfiguration`) in the body — see CLAUDE.md "Common API
    // pitfalls when writing tests" for the Xcode 26.3 abort pattern.
    func testEnabled_persistsAcrossReload() async {
        config.expandedSearchEnabled = true
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertTrue(fresh.expandedSearchEnabled)
    }

    func testDisabled_persistsAcrossReload() async {
        config.expandedSearchEnabled = true
        config.expandedSearchEnabled = false
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertFalse(fresh.expandedSearchEnabled)
    }

    // MARK: - Embedding config round-trip

    func testEmbeddingConfig_setAndLoad() async {
        let override = EmbeddingConfig(
            baseURLString: "http://remote-box:4321",
            modelName: "custom-embed",
            batchSize: 32,
            requestTimeout: 15
        )
        config.expandedSearchEmbeddingConfig = override

        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.expandedSearchEmbeddingConfig))

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.expandedSearchEmbeddingConfig, override)
    }

    func testEmbeddingConfig_nil_removesKey() {
        config.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://x", modelName: "y"
        )
        config.expandedSearchEmbeddingConfig = nil
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.expandedSearchEmbeddingConfig))
    }

    // MARK: - Thresholds

    func testThresholds_persistAcrossReload() async {
        config.expandedSearchPerTokenThreshold = 0.82
        config.expandedSearchPhraseThreshold = 0.65
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.expandedSearchPerTokenThreshold, 0.82, accuracy: 0.001)
        XCTAssertEqual(fresh.expandedSearchPhraseThreshold, 0.65, accuracy: 0.001)
    }

    // MARK: - Effective config picks override when present

    func testEffectiveEmbeddingConfig_withOverride_usesOverride() {
        let override = EmbeddingConfig(
            baseURLString: "http://x", modelName: "y", batchSize: 8, requestTimeout: 5
        )
        config.expandedSearchEmbeddingConfig = override
        XCTAssertEqual(config.effectiveEmbeddingConfig, override)
    }

    // MARK: - Reset

    func testResetToDefaults_clearsExpandedSearch() {
        config.expandedSearchEnabled = true
        config.expandedSearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://x", modelName: "y"
        )
        config.expandedSearchPerTokenThreshold = 0.9
        config.expandedSearchPhraseThreshold = 0.5

        config.resetToDefaults()

        XCTAssertFalse(config.expandedSearchEnabled)
        XCTAssertNil(config.expandedSearchEmbeddingConfig)
        XCTAssertEqual(config.expandedSearchPerTokenThreshold, 0.75, accuracy: 0.001)
        XCTAssertEqual(config.expandedSearchPhraseThreshold, 0.70, accuracy: 0.001)
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.expandedSearchEmbeddingConfig))
    }
}

// File-private InMemoryStorage — Swift's `private` keyword is file-scoped;
// the same helper shape is duplicated across store tests.
private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
