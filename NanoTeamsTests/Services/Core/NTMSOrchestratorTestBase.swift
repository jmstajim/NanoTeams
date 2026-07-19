import XCTest

@testable import NanoTeams

/// Base class for tests that need a fresh NTMSOrchestrator + temp directory.
/// Subclass and add test methods. setUp/tearDown are handled automatically.
///
/// Uses an in-memory `ConfigurationStorage` so each test starts with clean
/// defaults — otherwise settings (e.g. `exploratorySearchEnabled`) leak between
/// tests via `UserDefaults.standard` and the order of execution starts to
/// matter.
@MainActor
class NTMSOrchestratorTestBase: XCTestCase, @unchecked Sendable {

    var sut: NTMSOrchestrator!
    var tempDir: URL!

    /// Recording client behind the orchestrator's `embeddingLifecycle`. Tests
    /// can inspect `embeddingClient.loadUnloadCalls` for load/unload sequencing
    /// (filtered view), or `.calls` for the full sequence including the
    /// adoption-path `listLoadedInstances` calls. Pre-installed here so every
    /// existing scenario test runs without touching the real LM Studio endpoint.
    var embeddingClient: RecordingLLMClient!

    /// Stubs the chat-residency reconcile that `openWorkFolder` now runs.
    /// Tests that assert on residency inject their own client per call; this
    /// exists so the other ~700 `openWorkFolder` sites do no network I/O.
    var chatLifecycleClient: RecordingLLMClient!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        embeddingClient = RecordingLLMClient()
        chatLifecycleClient = RecordingLLMClient()
        // Production debounce is 10 s — without overriding it here, every
        // SearchIndexCoordinator that tests spin up serializes around a 10 s
        // FSEvents coalescing window, dominating wall-clock time in
        // `ExploratorySearchUserScenarioTests` (~20 s avg per test). The
        // user-facing clamp floor (`searchIndexWatcherDebounceSecondsMin`,
        // 0.5 s) is the lowest legal value for the configured setting.
        let configuration = StoreConfiguration(storage: InMemoryConfigurationStorage())
        configuration.searchIndexWatcherDebounceSeconds =
            AppDefaults.searchIndexWatcherDebounceSecondsMin
        sut = NTMSOrchestrator(
            repository: NTMSRepository(),
            configuration: configuration,
            embeddingLifecycle: EmbeddingModelLifecycleService(client: embeddingClient),
            // Stub the vector-index embedding path. Without this every
            // `SearchIndexCoordinator.start()` / `rebuild()` issued a real
            // POST /v1/embeddings to the default LMStudioEmbeddingClient,
            // adding ~2.5s of network round-trip per build to every
            // exploratory-search scenario test.
            searchEmbeddingClient: StubSearchEmbeddingClient(),
            // Same reason as `searchEmbeddingClient` (CLAUDE.md #49): with the
            // production defaults, `openWorkFolder`'s chat-residency reconcile
            // issues a live GET to the default LM Studio URL from every one of
            // the ~700 test call sites — and `ChatModelEnsurer.shared` is
            // process-global, so a suite that adopted a real model could then
            // unload it from the developer's running LM Studio.
            chatLifecycleClient: chatLifecycleClient,
            chatModelEnsurer: ChatModelEnsurer()
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        sut = nil
        embeddingClient = nil
        chatLifecycleClient = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }
}

/// In-memory `EmbeddingClient` for orchestrator tests — returns deterministic
/// 3-dim vectors and never touches the network. Distinct from the
/// `RecordingEmbedClient` defined file-private in `SearchIndexCoordinatorTests`
/// (different ownership, but same shape).
final class StubSearchEmbeddingClient: EmbeddingClient, @unchecked Sendable {
    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        texts.enumerated().map { (i, _) in [Float(i), 0, 0] }
    }
}

/// In-memory `ConfigurationStorage` used by `NTMSOrchestratorTestBase` to
/// isolate tests from `UserDefaults.standard`.
final class InMemoryConfigurationStorage: ConfigurationStorage, @unchecked Sendable {
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
