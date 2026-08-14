import XCTest

@testable import NanoTeams

/// `llmEndpointGeneration` is the COMMIT-boundary key that endpoint-keyed views
/// (`ModelQuickPicker`, `LLMModelDetailsCard`, `DownloadedModelsCard`) use instead
/// of the live `llmBaseURLString`.
///
/// It exists because the Settings URL field binds `TextField(text:)` straight to
/// the config with no buffer, so `llmBaseURLString` changes on every keystroke. A
/// view keyed on it re-fires `.task(id:)` per typed character, each time with a
/// brand-new uncached key — one real request per keystroke against half-typed
/// hosts, and one poisoned `ModelCatalog.errorByKey` entry per typed prefix.
@MainActor
final class StoreConfigurationEndpointGenerationTests: XCTestCase {

    private final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

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

    func testInitialGeneration_isZero() {
        XCTAssertEqual(config.llmEndpointGeneration, 0)
    }

    /// THE point of the seam. Mutation: bump it from `llmBaseURLString`'s `didSet`
    /// → every keystroke advances the generation and the storm is back, just keyed
    /// differently.
    func testTypingIntoTheURL_doesNotAdvanceTheGeneration() {
        for partial in ["h", "ht", "htt", "http", "http:", "http://1", "http://127.0.0.1:1234"] {
            config.llmBaseURLString = partial
        }

        XCTAssertEqual(
            config.llmEndpointGeneration, 0,
            "Raw writes are keystrokes, not commits — endpoint-keyed views must not re-fetch")
    }

    func testNoteLLMEndpointCommitted_advancesByExactlyOne() {
        config.noteLLMEndpointCommitted()
        XCTAssertEqual(config.llmEndpointGeneration, 1)

        config.noteLLMEndpointCommitted()
        XCTAssertEqual(config.llmEndpointGeneration, 2)
    }

    /// A flip rewrites URL + model programmatically, so there is no field commit for
    /// views to observe. Mutation: remove the bump from `llmProvider.didSet` → the
    /// picker keeps serving the previous provider's model list until something else
    /// commits.
    func testProviderFlip_advancesTheGenerationExactlyOnce() {
        let before = config.llmEndpointGeneration

        config.llmProvider = config.llmProvider == .lmStudio ? .ollama : .lmStudio

        XCTAssertEqual(config.llmEndpointGeneration, before + 1)
    }

    /// The `didSet` guards on `oldValue != llmProvider`, so a no-op assignment is
    /// not an endpoint change and must not invalidate anyone's cache.
    func testAssigningTheSameProvider_doesNotAdvanceTheGeneration() {
        let before = config.llmEndpointGeneration

        config.llmProvider = config.llmProvider

        XCTAssertEqual(config.llmEndpointGeneration, before)
    }

    /// `resetToDefaults` rewrites the URL and model programmatically. The provider
    /// `didSet` only bumps when the provider actually changed, so a reset that
    /// leaves it alone would otherwise strand endpoint-keyed views.
    func testResetToDefaults_advancesTheGeneration() {
        let before = config.llmEndpointGeneration

        config.resetToDefaults()

        XCTAssertGreaterThan(config.llmEndpointGeneration, before)
    }

    /// Session-scoped: it identifies which endpoint generation THIS process is on,
    /// which has no meaning across launches.
    func testGeneration_isNotPersisted() async {
        config.noteLLMEndpointCommitted()
        config.noteLLMEndpointCommitted()
        XCTAssertEqual(config.llmEndpointGeneration, 2)

        let reloaded = StoreConfiguration(storage: storage)

        XCTAssertEqual(reloaded.llmEndpointGeneration, 0)
    }
}
