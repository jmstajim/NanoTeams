import XCTest
@testable import NanoTeams

/// Storage round-trip for exploratory-search settings: the on/off toggle, the
/// optional embedding-model override, and the two cosine thresholds.
@MainActor
final class ExploratorySearchConfigurationTests: XCTestCase {

    private var storage: InMemoryStorage!
    private var config: StoreConfiguration!

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

    // MARK: - Defaults

    func testDefaults_disabled_noOverride() {
        XCTAssertFalse(config.exploratorySearchEnabled)
        XCTAssertNil(config.exploratorySearchEmbeddingConfig)
    }

    func testDefaults_thresholds_matchPlannedValues() {
        XCTAssertEqual(config.exploratorySearchPerTokenThreshold, 0.75, accuracy: 0.001)
        XCTAssertEqual(config.exploratorySearchPhraseThreshold, 0.70, accuracy: 0.001)
    }

    func testEffectiveEmbeddingConfig_withoutOverride_usesDefaultNomic() {
        XCTAssertEqual(config.effectiveEmbeddingConfig, EmbeddingConfig.defaultNomicLMStudio)
    }

    // MARK: - Toggle round-trip

    // `async` is load-bearing for tests that construct a `@MainActor` class
    // (here `StoreConfiguration`) in the body — see CLAUDE.md "Common API
    // pitfalls when writing tests" for the Xcode 26.3 abort pattern.
    func testEnabled_persistsAcrossReload() async {
        config.exploratorySearchEnabled = true
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertTrue(fresh.exploratorySearchEnabled)
    }

    func testDisabled_persistsAcrossReload() async {
        config.exploratorySearchEnabled = true
        config.exploratorySearchEnabled = false
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertFalse(fresh.exploratorySearchEnabled)
    }

    // MARK: - Embedding config round-trip

    func testEmbeddingConfig_setAndLoad() async {
        let override = EmbeddingConfig(
            baseURLString: "http://remote-box:4321",
            modelName: "custom-embed",
            batchSize: 32,
            requestTimeout: 15
        )
        config.exploratorySearchEmbeddingConfig = override

        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.exploratorySearchEmbeddingConfig))

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.exploratorySearchEmbeddingConfig, override)
    }

    func testEmbeddingConfig_nil_removesKey() {
        config.exploratorySearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://x", modelName: "y"
        )
        config.exploratorySearchEmbeddingConfig = nil
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.exploratorySearchEmbeddingConfig))
    }

    // MARK: - Thresholds

    func testThresholds_persistAcrossReload() async {
        config.exploratorySearchPerTokenThreshold = 0.82
        config.exploratorySearchPhraseThreshold = 0.65
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.exploratorySearchPerTokenThreshold, 0.82, accuracy: 0.001)
        XCTAssertEqual(fresh.exploratorySearchPhraseThreshold, 0.65, accuracy: 0.001)
    }

    // MARK: - Effective config picks override when present

    func testEffectiveEmbeddingConfig_withOverride_usesOverride() {
        let override = EmbeddingConfig(
            baseURLString: "http://x", modelName: "y", batchSize: 8, requestTimeout: 5
        )
        config.exploratorySearchEmbeddingConfig = override
        XCTAssertEqual(config.effectiveEmbeddingConfig, override)
    }

    // MARK: - Legacy key migration

    /// `StoreConfiguration.init` runs a one-shot migration that copies the
    /// legacy `expandedSearch*` UserDefaults keys onto the new
    /// `exploratorySearch*` keys (and removes the originals). Verifies that
    /// users coming from an older build keep their toggle / thresholds /
    /// embedding-model override after the rename.
    func testInit_migratesLegacyExpandedSearchKeysToExploratoryKeys() async throws {
        let legacy = InMemoryStorage()
        legacy.set(true, forKey: "NanoTeams.search.expandedSearchEnabled.v1")
        legacy.set(0.82, forKey: "NanoTeams.search.expandedSearchPerTokenThreshold.v1")
        legacy.set(0.55, forKey: "NanoTeams.search.expandedSearchPhraseThreshold.v1")
        let override = EmbeddingConfig(
            baseURLString: "http://legacy:1234",
            modelName: "legacy-embed",
            batchSize: 16,
            requestTimeout: 9
        )
        let overrideData = try JSONCoderFactory.makePersistenceEncoder().encode(override)
        legacy.set(overrideData, forKey: "NanoTeams.search.expandedSearchEmbeddingConfig.v1")

        let migrated = StoreConfiguration(storage: legacy)

        XCTAssertTrue(migrated.exploratorySearchEnabled)
        XCTAssertEqual(migrated.exploratorySearchPerTokenThreshold, 0.82, accuracy: 0.001)
        XCTAssertEqual(migrated.exploratorySearchPhraseThreshold, 0.55, accuracy: 0.001)
        XCTAssertEqual(migrated.exploratorySearchEmbeddingConfig, override)

        XCTAssertNil(legacy.object(forKey: "NanoTeams.search.expandedSearchEnabled.v1"))
        XCTAssertNil(legacy.object(forKey: "NanoTeams.search.expandedSearchEmbeddingConfig.v1"))
        XCTAssertNil(legacy.object(forKey: "NanoTeams.search.expandedSearchPerTokenThreshold.v1"))
        XCTAssertNil(legacy.object(forKey: "NanoTeams.search.expandedSearchPhraseThreshold.v1"))
    }

    /// When new keys already exist, migration must NOT overwrite them with
    /// stale legacy values — protects users who upgraded, ran the new build
    /// (which wrote new keys), then somehow had legacy keys reappear.
    func testInit_doesNotOverwriteExistingNewKeys_whenLegacyKeysAlsoPresent() async {
        let storage = InMemoryStorage()
        storage.set(false, forKey: UserDefaultsKeys.exploratorySearchEnabled)
        storage.set(true, forKey: "NanoTeams.search.expandedSearchEnabled.v1")

        let migrated = StoreConfiguration(storage: storage)

        XCTAssertFalse(migrated.exploratorySearchEnabled,
                       "Existing new key wins; legacy must not clobber it.")
        XCTAssertNil(storage.object(forKey: "NanoTeams.search.expandedSearchEnabled.v1"),
                     "Legacy key is removed even when the new key already had a value.")
    }

    // MARK: - Reset

    func testResetToDefaults_clearsExploratorySearch() {
        config.exploratorySearchEnabled = true
        config.exploratorySearchEmbeddingConfig = EmbeddingConfig(
            baseURLString: "http://x", modelName: "y"
        )
        config.exploratorySearchPerTokenThreshold = 0.9
        config.exploratorySearchPhraseThreshold = 0.5

        config.resetToDefaults()

        XCTAssertFalse(config.exploratorySearchEnabled)
        XCTAssertNil(config.exploratorySearchEmbeddingConfig)
        XCTAssertEqual(config.exploratorySearchPerTokenThreshold, 0.75, accuracy: 0.001)
        XCTAssertEqual(config.exploratorySearchPhraseThreshold, 0.70, accuracy: 0.001)
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.exploratorySearchEmbeddingConfig))
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
