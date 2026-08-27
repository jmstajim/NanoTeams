import Foundation
import XCTest

@testable import NanoTeams

/// THE construction site for `NTMSOrchestrator` in the test target.
///
/// Several seams on `NTMSOrchestrator.init` are optional, and each one's `nil`
/// resolves to something that reaches the outside world: a real
/// `LMStudioEmbeddingClient`, a real `LLMClientRouter` (three times now — chat
/// lifecycle, team generation, and the STEP-EXECUTION client inside a defaulted
/// `LLMExecutionService`), and the process-global `ChatModelEnsurer.shared`. A
/// forgotten argument therefore compiles cleanly and silently sends the test at
/// the developer's LM Studio — `openWorkFolder` alone issues two
/// `GET /api/v0/models` with a 5 s timeout, and an adopted instance can later be
/// UNLOADED out from under a model the developer hand-loaded.
///
/// The count is deliberately not written down here any more. It was "four", then
/// "five", and each correction arrived only after a seam had already been missed —
/// so `OrchestratorTestConstructionPinTests.testTheFactoryStubsEverySeam` now
/// DERIVES the list from the init signature instead of restating it. Adding a
/// parameter of an outward-reaching type turns that pin red until this factory
/// passes it.
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

    /// The automation poll delay a factory orchestrator gets: one year — no test
    /// worker process lives to see a tick. NOT `.infinity` (a Duration built from
    /// an infinite Double is undefined), and NOT zero-suppression of the loop
    /// itself (the scheduler pins assert `automationPollTask` arms and stops).
    ///
    /// Why the loop must never tick in a test: `openWorkFolder` arms it with the
    /// production cadence — phase-aligned wall-clock MINUTE boundaries — so any
    /// test staging a condition the tick body acts on (a due recurrence, an
    /// over-budget run, an Autovisor-wakeable task) raced the wall clock, in
    /// every run mode, with p ≈ window/60 s per test. That race is exactly the
    /// D-4 form-B flake (DEBTS.md §5). A scheduler test that WANTS ticks passes
    /// its own sub-second `automationTickInterval` instead.
    static let automationTickNever: TimeInterval = 31_536_000

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
        teamGenerationClient: (any LLMClient)? = nil,
        chatModelEnsurer: ChatModelEnsurer? = nil,
        downloadedModelStore: (any DownloadedModelStore)? = nil,
        skillsCatalogueStore: AgentSkillsCatalogueStore? = nil,
        stepExecutionClient: (any LLMClient)? = nil,
        automationTickInterval: TimeInterval? = nil
    ) -> NTMSOrchestrator {
        let resolvedRepository = repository ?? NTMSRepository()
        return NTMSOrchestrator(
            repository: resolvedRepository,
            // The FIFTH seam, and the one the doc above missed: `nil` here builds
            // `LLMExecutionService(repository:)`, whose `clientFactory` default is
            // `{ LLMClientRouter() }` — so every suite that reaches `startRun` →
            // `runStep` → `performStreamingCall` issued a genuine chat request at
            // whatever is listening on the developer's machine. Stubbed as an
            // UNREACHABLE server, which is exactly what those suites already
            // experience whenever LM Studio is down; the point is that it no longer
            // depends on whether it is.
            llmExecutionService: llmExecutionService ?? LLMExecutionService(
                repository: resolvedRepository,
                clientFactory: { stepExecutionClient ?? UnreachableChatClient() }
            ),
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
            // `runTeamGeneration` issues a real `create_team` chat request. Unstubbed,
            // every suite that reaches `startRun` on a Generated Team task posts it at
            // the developer's LM Studio. Same "server isn't listening" stub as
            // `stepExecutionClient`, and for the same reason: a suite not asserting on
            // team generation must not have its behaviour changed by one.
            teamGenerationClient: teamGenerationClient ?? UnreachableChatClient(),
            // A FRESH ledger, never `.shared`: ownership must not survive
            // between suites, or one test's adoption becomes another's unload.
            chatModelEnsurer: chatModelEnsurer ?? ChatModelEnsurer(),
            // Unstubbed, the LM Studio half of the real router walks — and can
            // Trash — directories under the developer's `~/.lmstudio/models`.
            downloadedModelStore: downloadedModelStore ?? StubDownloadedModelStore(),
            // A per-orchestrator temp directory, never `.shared`. Unstubbed, the
            // catalogue store's default resolves to the developer's real
            // `~/Library/Application Support/NanoTeams/skills/` — so a suite would
            // both READ the machine's installed skills (making assertions depend on
            // whose laptop ran them) and WRITE its own fixtures over that cache.
            skillsCatalogueStore: skillsCatalogueStore ?? AgentSkillsCatalogueStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("nt-skills-catalogue-\(UUID().uuidString)",
                                            isDirectory: true)),
            // `nil` on the ORCHESTRATOR's init means "production cadence" (wall-clock
            // minute boundaries) — the nondeterminism source, so the factory never
            // forwards it. See `automationTickNever`.
            automationTickInterval: automationTickInterval ?? Self.automationTickNever
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

/// The step-execution client for orchestrator tests: behaves like a server that
/// isn't listening.
///
/// Deliberately NOT a client that returns an empty stream. A suite reaching
/// `runStep` without injecting its own client is not asserting on the LLM, and an
/// empty-but-successful response would silently push those steps down the
/// no-tool-call recovery arms — changing behaviour rather than pinning it. An
/// unreachable server is what they already got whenever LM Studio was down, which
/// on CI is always; this only removes the dependency on whether it happens to be up.
final class UnreachableChatClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: URLError(.cannotConnectToHost)) }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] {
        throw URLError(.cannotConnectToHost)
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
///
/// Locked, because `@unchecked Sendable` is a PROMISE and an unsynchronized dictionary cannot
/// keep it. The promise became load-bearing on 2026-08-25, when `ConfigurationStorage` became
/// `nonisolated` so `Theme.current` could read it from AppKit's appearance-resolution thread:
/// before that the conformance inherited `@MainActor` from the protocol and the main actor was
/// doing the serializing. The production conformer (`UserDefaults`) is thread-safe on its own,
/// so this double had been riding a guarantee it never actually had.
nonisolated final class InMemoryConfigurationStorage: ConfigurationStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func string(forKey key: String) -> String? { withLock { store[key] as? String } }
    func bool(forKey key: String) -> Bool { withLock { (store[key] as? Bool) ?? false } }
    func data(forKey key: String) -> Data? { withLock { store[key] as? Data } }
    func object(forKey key: String) -> Any? { withLock { store[key] } }
    func set(_ value: Any?, forKey key: String) {
        withLock {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
    }
    func removeObject(forKey key: String) { withLock { store.removeValue(forKey: key) } }
}
