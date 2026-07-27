import Foundation
import XCTest

@testable import NanoTeams

/// THE construction site for `NTMSOrchestrator` in the test target.
///
/// `NTMSOrchestrator.init` leaves four seams optional, and each one's `nil`
/// resolves to something that reaches the outside world: a real
/// `LMStudioEmbeddingClient`, a real `LLMClientRouter` (twice), and the
/// process-global `ChatModelEnsurer.shared`. A forgotten argument therefore
/// compiles cleanly and silently sends the test at the developer's LM Studio —
/// `openWorkFolder` alone issues two `GET /api/v0/models` with a 5 s timeout,
/// and an adopted instance can later be UNLOADED out from under a model the
/// developer hand-loaded.
///
/// Routing every test through here makes that unrepresentable rather than
/// remembered. Enforced by `OrchestratorTestConstructionPinTests`, which fails
/// any bare `NTMSOrchestrator(` elsewhere under `NanoTeamsTests/`.
///
/// The production-side half of the guarantee is `resolvedChatLifecycleClient`
/// in `NTMSOrchestrator+ChatModelLifecycle`: it makes `nil` mean "this
/// orchestrator's client", so even a residency entry point invoked with no
/// arguments — as production's own `ModelResidencyHooks` does — stays on the
/// injected stub.
///
/// **Every parameter defaults to `nil`, never to an expression that constructs
/// a class.** A Swift default argument is evaluated at the CALL SITE, so
/// `repository: NTMSRepository()` as a default would build a `@MainActor` class
/// inside each of the ~90 callers — reviving the sync-test `abort()` documented
/// in CLAUDE.md §Testing Conventions. All construction happens in the body.
@MainActor
enum TestOrchestrator {

    /// Builds an orchestrator with every network seam stubbed and a
    /// per-instance model ledger. Pass a parameter only when the test asserts
    /// on that collaborator.
    static func make(
        repository: (any NTMSRepositoryProtocol)? = nil,
        llmExecutionService: LLMExecutionService? = nil,
        settingsService: SettingsService? = nil,
        taskService: TaskService? = nil,
        workFolderManagementService: WorkFolderManagementService? = nil,
        engineFactory: (@MainActor () -> TeamEngine)? = nil,
        engineState: OrchestratorEngineState? = nil,
        streamingPreviewManager: StreamingPreviewManager? = nil,
        configuration: StoreConfiguration? = nil,
        fileManager: FileManager? = nil,
        embeddingLifecycle: EmbeddingModelLifecycleService? = nil,
        embeddingClient: RecordingLLMClient? = nil,
        searchEmbeddingClient: (any EmbeddingClient)? = nil,
        chatLifecycleClient: RecordingLLMClient? = nil,
        chatModelEnsurer: ChatModelEnsurer? = nil,
        downloadedModelStore: (any DownloadedModelStore)? = nil
    ) -> NTMSOrchestrator {
        NTMSOrchestrator(
            repository: repository ?? NTMSRepository(),
            llmExecutionService: llmExecutionService,
            settingsService: settingsService,
            taskService: taskService,
            workFolderManagementService: workFolderManagementService,
            engineFactory: engineFactory ?? { TeamEngine() },
            engineState: engineState,
            streamingPreviewManager: streamingPreviewManager,
            configuration: configuration ?? makeConfiguration(),
            fileManager: fileManager,
            embeddingLifecycle: embeddingLifecycle
                ?? EmbeddingModelLifecycleService(client: embeddingClient ?? RecordingLLMClient()),
            // Stubs the vector-index embedding path. Unstubbed, every
            // `SearchIndexCoordinator.start()` / `rebuild()` posts a real
            // /v1/embeddings — ~2.5 s of round-trip per index build.
            searchEmbeddingClient: searchEmbeddingClient ?? StubSearchEmbeddingClient(),
            chatLifecycleClient: chatLifecycleClient ?? RecordingLLMClient(),
            // A FRESH ledger, never `.shared`: ownership must not survive
            // between suites, or one test's adoption becomes another's unload.
            chatModelEnsurer: chatModelEnsurer ?? ChatModelEnsurer(),
            // Unstubbed, the LM Studio half of the real router walks — and can
            // Trash — directories under the developer's `~/.lmstudio/models`.
            downloadedModelStore: downloadedModelStore ?? StubDownloadedModelStore()
        )
    }

    /// Isolated from `UserDefaults.standard` in both directions: settings can't
    /// leak between tests (making execution order matter), and a test can't
    /// write into the developer's real app preferences.
    ///
    /// The watcher debounce is pinned to the user-facing clamp floor because
    /// the production value is 10 s — every `SearchIndexCoordinator` a test
    /// spins up would otherwise serialize around a 10 s FSEvents coalescing
    /// window, which dominated wall-clock in the exploratory-search suites.
    static func makeConfiguration() -> StoreConfiguration {
        let configuration = StoreConfiguration(storage: InMemoryConfigurationStorage())
        configuration.searchIndexWatcherDebounceSeconds =
            AppDefaults.searchIndexWatcherDebounceSecondsMin
        return configuration
    }
}

/// In-memory `EmbeddingClient` for orchestrator tests — deterministic 3-dim
/// vectors, never touches the network. Distinct from the `RecordingEmbedClient`
/// declared file-private in `SearchIndexCoordinatorTests` (different ownership,
/// same shape).
final class StubSearchEmbeddingClient: EmbeddingClient, @unchecked Sendable {
    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        texts.enumerated().map { (i, _) in [Float(i), 0, 0] }
    }
}

/// Inert `DownloadedModelStore` for orchestrator tests: reports nothing on disk
/// and no deletion capability, so no suite can walk (or Trash) the developer's
/// real `~/.lmstudio/models`. Suites that assert on deletion inject their own
/// recording double instead.
final class StubDownloadedModelStore: DownloadedModelStore, @unchecked Sendable {
    func listDownloaded(config _: LLMConfig) async throws -> [DownloadedModel] { [] }
    func deletionCapability(config _: LLMConfig) async -> DownloadedModelDeletion {
        .unavailable(reason: "Stubbed in tests.")
    }
    func delete(modelID _: String, config _: LLMConfig) async throws {}
    func storageLocationDescription(config _: LLMConfig) async -> String? { nil }
}

/// In-memory `ConfigurationStorage` isolating tests from `UserDefaults.standard`.
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
