import XCTest

@testable import NanoTeams

/// Provider-flip endpoint memory: switching the global provider must be a
/// REVERSIBLE toggle, not a destructive reset. The old provider's (URL, model)
/// is remembered and restored on flip-back — and because the bearer token is
/// Keychain-keyed by URL, restoring the URL also reconnects the saved token.
@MainActor
final class StoreConfigurationProviderFlipTests: XCTestCase {

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

    func testFlipAndBack_restoresCustomizedEndpoint() {
        config.llmBaseURLString = "http://192.168.1.50:1234"
        config.llmModelName = "qwen3.5-35b"

        config.llmProvider = .ollama
        XCTAssertEqual(config.llmBaseURLString, LLMProvider.ollama.defaultBaseURL,
                       "first visit to a provider starts at its defaults")
        XCTAssertEqual(config.llmModelName, LLMProvider.ollama.defaultModel)

        config.llmProvider = .lmStudio
        XCTAssertEqual(config.llmBaseURLString, "http://192.168.1.50:1234",
                       "a look at the other provider must not destroy a customized setup")
        XCTAssertEqual(config.llmModelName, "qwen3.5-35b")
    }

    func testFlip_remembersEachProviderIndependently() {
        config.llmBaseURLString = "http://lm-box:1234"
        config.llmModelName = "lm-model"

        config.llmProvider = .ollama
        config.llmBaseURLString = "http://ollama-box:11434"
        config.llmModelName = "llama3.1:8b"

        config.llmProvider = .lmStudio
        XCTAssertEqual(config.llmBaseURLString, "http://lm-box:1234")

        config.llmProvider = .ollama
        XCTAssertEqual(config.llmBaseURLString, "http://ollama-box:11434")
        XCTAssertEqual(config.llmModelName, "llama3.1:8b")
    }

    func testEndpointMemory_persistsAcrossRelaunch() {
        config.llmBaseURLString = "http://lm-box:1234"
        config.llmModelName = "lm-model"
        config.llmProvider = .ollama

        // Relaunch: fresh StoreConfiguration over the same storage.
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.llmProvider, .ollama)
        reloaded.llmProvider = .lmStudio
        XCTAssertEqual(reloaded.llmBaseURLString, "http://lm-box:1234",
                       "the memory rides UserDefaults, not just the in-memory dict")
        XCTAssertEqual(reloaded.llmModelName, "lm-model")
    }

    func testFlipBack_emptyRememberedEndpoint_restoresDefaultsNotEmptiness() {
        // User clears the URL field mid-edit, then flips provider: the
        // remembered pair is empty strings. Flip-back must restore the
        // provider DEFAULTS — resurrecting an empty URL would leave every
        // request throwing invalidBaseURL with no visible cause.
        config.llmBaseURLString = ""
        config.llmModelName = "   "

        config.llmProvider = .ollama
        config.llmProvider = .lmStudio

        XCTAssertEqual(config.llmBaseURLString, LLMProvider.lmStudio.defaultBaseURL)
        XCTAssertEqual(config.llmModelName, LLMProvider.lmStudio.defaultModel)
    }

    func testSameProviderReassignment_doesNotTouchEndpoint() {
        config.llmBaseURLString = "http://custom:1234"
        config.llmProvider = .lmStudio
        XCTAssertEqual(config.llmBaseURLString, "http://custom:1234",
                       "no-op provider write must not reset the endpoint")
    }

    // MARK: - knownLLMEndpoints(for:)

    /// The ACTIVE provider's endpoint is the live field. `providerEndpointMemory` never holds it —
    /// it is written from `oldValue` on a flip — so a lookup that consulted only the memory would
    /// be blind to the provider the user is actually using.
    ///
    /// RED: read `rememberedEndpoint` for every provider → the active provider answers with
    /// nothing at all, and the benchmark stops clearing the one server it definitely knows about.
    func testKnownEndpoints_forTheActiveProvider_includeTheLiveURL() {
        config.llmProvider = .ollama
        config.llmBaseURLString = "http://ollama-box:11434"

        XCTAssertEqual(config.knownLLMEndpoints(for: .ollama), ["http://ollama-box:11434"])
    }

    /// RED: return `llmBaseURLString` regardless of the argument → the sweep asks LM Studio's
    /// address about Ollama, and a run clears a server the user never named.
    func testKnownEndpoints_forTheOtherProvider_areItsRememberedOnes() {
        config.llmBaseURLString = "http://lm-box:1234"
        config.llmProvider = .ollama
        config.llmBaseURLString = "http://ollama-box:11434"

        XCTAssertEqual(config.knownLLMEndpoints(for: .lmStudio), ["http://lm-box:1234"])
        XCTAssertEqual(config.knownLLMEndpoints(for: .ollama), ["http://ollama-box:11434"])
    }

    /// A provider nobody has ever pointed the app at is not "at its default address" — it is
    /// unknown, and saying so is the whole point.
    ///
    /// RED: fall back to `provider.defaultBaseURL` → every caller receives a guess shaped exactly
    /// like a fact, and the one that clears servers starts acting on addresses the user never
    /// confirmed. `DEBTS.md` D-B1 §2 refused precisely that.
    func testKnownEndpoints_forANeverVisitedProvider_areEmpty() {
        XCTAssertEqual(config.llmProvider, .lmStudio, "precondition: Ollama never visited")

        XCTAssertTrue(config.knownLLMEndpoints(for: .ollama).isEmpty)
    }

    /// The benchmark screen owns a target that can point somewhere the global settings never did —
    /// a second LM Studio box, say. That address is known too, and a run measuring on one of them
    /// has to clear the other.
    ///
    /// RED: drop the `benchmarkTarget` source → the sweep never clears the box the user actually
    /// benchmarks against unless it happens to match the global endpoint.
    func testKnownEndpoints_includeTheBenchmarkTargetsOwnEndpoint() {
        config.benchmarkTarget = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://bench-box:11434", modelName: "qwen3.8")

        XCTAssertEqual(config.knownLLMEndpoints(for: .ollama), ["http://bench-box:11434"])
    }

    /// RED: drop the de-duplication → the same server is listed, unloaded and reported twice, and
    /// the provenance line claims a machine that does not exist.
    func testKnownEndpoints_deduplicateOnTheNormalizedAddress() {
        config.llmProvider = .ollama
        config.llmBaseURLString = "http://ollama-box:11434"
        config.benchmarkTarget = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://ollama-box:11434/", modelName: "qwen3.8")

        XCTAssertEqual(config.knownLLMEndpoints(for: .ollama), ["http://ollama-box:11434"],
                       "a trailing slash is not a second machine")
    }

    /// RED: drop the `nonBlank` filter → a URL cleared mid-edit is handed on as "", and the
    /// listing throws `invalidBaseURL` while the row records "not verified" about a machine
    /// nobody named.
    func testKnownEndpoints_dropBlankValues() {
        config.llmBaseURLString = "   "

        XCTAssertTrue(config.knownLLMEndpoints(for: .lmStudio).isEmpty)
    }

    func testKnownEndpoints_surviveRelaunch() {
        config.llmBaseURLString = "http://lm-box:1234"
        config.llmProvider = .ollama

        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.knownLLMEndpoints(for: .lmStudio), ["http://lm-box:1234"],
                       "the memory rides UserDefaults, not just the in-memory dict")
    }

    // MARK: - visionProvider

    func testVisionProvider_persistsAndRestores() {
        config.visionProvider = .ollama
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.visionProvider, .ollama)

        reloaded.visionProvider = nil
        XCTAssertNil(storage.string(forKey: UserDefaultsKeys.visionProvider),
                     "nil must REMOVE the key, not store a stale raw value")
        let again = StoreConfiguration(storage: storage)
        XCTAssertNil(again.visionProvider)
    }

    func testResolvedVisionProvider_fallsBackToGlobal() {
        config.llmProvider = .ollama
        XCTAssertEqual(config.resolvedVisionProvider, .ollama)
        config.visionProvider = .lmStudio
        XCTAssertEqual(config.resolvedVisionProvider, .lmStudio,
                       "an explicit vision provider wins over the global")
    }

    func testResetToDefaults_clearsVisionProvider() {
        config.visionProvider = .ollama
        config.resetToDefaults()
        XCTAssertNil(config.visionProvider)
        XCTAssertNil(storage.string(forKey: UserDefaultsKeys.visionProvider))
    }

    // MARK: - writeOverride provider semantics

    func testWriteOverride_providerOnly_createsSlot_andClearingCollapsesToNil() {
        config.writeOverride(\.teamGenLLMOverride, \.provider, LLMProvider.ollama)
        XCTAssertEqual(config.teamGenLLMOverride?.provider, .ollama)
        XCTAssertTrue(config.teamGenLLMOverride?.isEmpty == false)

        config.writeOverride(\.teamGenLLMOverride, \.provider, LLMProvider?.none)
        XCTAssertNil(config.teamGenLLMOverride,
                     "provider back to Global with no other fields set → the whole slot collapses to nil")
    }

    func testWriteOverride_clearingURLKeepsProviderPinnedSlot() {
        config.writeOverride(\.teamGenLLMOverride, \.provider, LLMProvider.ollama)
        config.writeOverride(\.teamGenLLMOverride, \.baseURLString, "http://x:11434")
        config.writeOverride(\.teamGenLLMOverride, \.baseURLString, String?.none)
        XCTAssertEqual(config.teamGenLLMOverride?.provider, .ollama,
                       "clearing the URL must not drop a still-meaningful provider pin")
    }

    func testResetToDefaults_wipesEndpointMemory() {
        config.llmBaseURLString = "http://lm-box:1234"
        config.llmProvider = .ollama
        config.resetToDefaults()

        XCTAssertEqual(config.llmProvider, .lmStudio)
        XCTAssertEqual(config.llmBaseURLString, LLMProvider.lmStudio.defaultBaseURL)
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.llmProviderEndpoints),
                     "reset must not leave endpoint memory behind")

        config.llmProvider = .ollama
        XCTAssertEqual(config.llmBaseURLString, LLMProvider.ollama.defaultBaseURL,
                       "post-reset flip starts from defaults, not a resurrected memory")
    }
}
