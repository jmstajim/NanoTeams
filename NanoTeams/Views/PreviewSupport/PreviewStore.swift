import SwiftUI

// MARK: - Preview Store

/// The one legal place a SwiftUI preview builds an `NTMSOrchestrator`.
///
/// ## Why this exists
///
/// `NTMSOrchestrator.init` leaves seven seams optional and every one of them resolves
/// **outward** — `llmExecutionService ?? LLMExecutionService(repository:, computerUse: .system)`
/// (the one line in the tree that hands the finalizer the real screenshot / AX / CGEvent
/// adapters), `searchEmbeddingClient ?? LMStudioEmbeddingClient()`, `embeddingLifecycle ??
/// EmbeddingModelLifecycleService()` (whose own default is a live `LLMClientRouter()`), and
/// `chatModelEnsurer: ChatModelEnsurer = .shared`, the process global. A forgotten argument
/// compiles cleanly. That is CLAUDE.md #49, and `OrchestratorTestConstructionPinTests` has
/// policed it for the TEST target since — but its scan roots are `NanoTeamsTests` and
/// `Ratchet` only, so 58 preview-support constructions under `Views/` were outside it.
///
/// **What is and is not measured.** Construction itself is inert: `NTMSRepository` stores two
/// values (its root arrives later at `openOrCreateWorkFolder`, which no preview calls), and the
/// orchestrator's init starts no timer and no `Task`. So this factory is not fixing observed
/// network traffic at canvas-open — it is closing the wiring, which a canvas *interaction*
/// reaches: `ExploratorySearchSettingsView`'s buttons call
/// `store.searchIndexCoordinator?.rebuild()`, which is a real embedding pass against whatever
/// server the developer has configured.
///
/// ## Keeping it complete
///
/// The argument list below is the closure of that `??` chain, and it has to stay that way as
/// the init grows. Two guards, because one would be a coincidence (CLAUDE.md #52):
/// `OrchestratorTestConstructionPinTests` derives the seam list from the init itself and now
/// checks this factory alongside the test one, and `coverage/tools/swiftui_declarations.py`
/// axis v1 records this file's constructions as the deliberate exception — so a change to
/// *this file's* site count is a review event, not a silent edit. That count is not restated
/// here: it moved from three to five on 2026-08-24 when the two catalog factories landed, and
/// this sentence still said "three" until the audit that found it. Ask the tool instead —
/// `python3 coverage/tools/swiftui_declarations.py --axis v1` (CLAUDE.md #100).
///
/// **A label is not a seam.** Both guards were satisfied while `LLMExecutionService`'s own
/// `clientFactory` stayed at `{ LLMClientRouter() }`: axis v1 ranks the construction and its
/// baseline `why` argued only about `computerUse`, while the Swift pin asserted the *label*
/// `llmExecutionService:` was present. A seam handed a collaborator is only closed if that
/// collaborator's own outward defaults are closed too — which is what
/// `testFactoriesCloseTheNestedSeamsTheyConstruct` now derives rather than trusts.
///
/// Deliberately not `#if DEBUG`: `#Preview` bodies compile in every configuration, and the
/// established precedent (`SidebarView.makePreviewStore`, `QuickCapturePanelPreview.makeStore`)
/// is a plain file-scope helper. It lives under `Views/`, which keeps it out of the tracked
/// coverage denominator for the reason `PreviewLocationPinTests` documents.
enum PreviewStore {

    /// An orchestrator with every outward-resolving seam closed — its own, and those of the
    /// collaborators it hands over.
    ///
    /// Callers that need seeded state (`snapshot`, `workFolderURL`, an active task) assign it
    /// afterwards, exactly as the hand-rolled helpers did before this factory existed.
    static func make() -> NTMSOrchestrator {
        let repository = NTMSRepository()
        return NTMSOrchestrator(
            repository: repository,
            // TWO seams on one line, and naming only the first is how the second stayed open
            // until 2026-08-24. `.inert` is `computerUse`'s own default; naming it here is what
            // keeps the real screenshot / AX / CGEvent adapters out of a preview. `clientFactory`
            // is the one whose default is `{ LLMClientRouter() }` — reached from a canvas through
            // `startRun` → `runStep` → `performStreamingCall`, exactly as the test-side twin
            // records (`TestOrchestratorFactory`, "the FIFTH seam, and the one the doc above
            // missed"). One seam of two is a coincidence, not a defence (CLAUDE.md #52).
            llmExecutionService: LLMExecutionService(
                repository: repository,
                clientFactory: { InertLLMClient() },
                computerUse: .inert),
            embeddingLifecycle: EmbeddingModelLifecycleService(client: InertLLMClient()),
            searchEmbeddingClient: InertEmbeddingClient(),
            chatLifecycleClient: InertLLMClient(),
            teamGenerationClient: InertLLMClient(),
            // NOT `.shared`: a preview must not mutate the process-global ensurer that the
            // running app and any hand-loaded model share.
            chatModelEnsurer: ChatModelEnsurer(),
            downloadedModelStore: InertDownloadedModelStore()
        )
    }

    /// A `ModelCatalog` that reaches nothing.
    ///
    /// The orchestrator is not the only type whose default resolves outward: this one's
    /// `clientFactory` defaults to `{ LLMClientRouter() }`, and it is injected into every
    /// preview that renders a model picker. Most of those hosts reach an UNCONDITIONAL
    /// first-appear `loadIfNeeded` from `.task` — directly or through an embedded
    /// `LLMOverrideEditor` / `ModelQuickPicker` / `LLMVisionCard` — so those canvases were
    /// issuing a real `GET` for the model list on open, and axis v1 could not see it because
    /// the seam is the DEFAULT ARGUMENT of a type whose own name is not a client. The axis
    /// now ranks the catalogs too, so this factory is what keeps the previews out of it.
    ///
    /// Neither count is restated here, and that is the correction rather than an omission:
    /// this comment said "eight previews … three of their hosts" and the second number was
    /// already wrong when it was written — it counts a TRANSITIVE reach, so it moves whenever
    /// any of those hosts gains or loses an embedded picker, while reading as settled
    /// (CLAUDE.md #100 — a count that understates the blast radius never trips the alarm that
    /// would expose it). Re-derive instead:
    ///
    ///     grep -rn 'PreviewStore.catalog()' NanoTeams --include='*.swift'      # the hosts
    ///     grep -rn -B6 'loadIfNeeded' NanoTeams/Views --include='*.swift' \
    ///       | grep -E '\.task'                                                # the fetchers
    // periphery:ignore - used in #Preview macros
    static func catalog() -> ModelCatalog {
        ModelCatalog(clientFactory: { InertLLMClient() })
    }

    /// An `EmbeddingModelCatalog` that reaches nothing. Same story, one card:
    /// `ExploratorySearchEmbeddingsCard` fetches from `.task` on first appear.
    // periphery:ignore - used in #Preview macros
    static func embeddingCatalog() -> EmbeddingModelCatalog {
        EmbeddingModelCatalog(clientFactory: { _ in InertLLMClient() })
    }
}

// MARK: - Inert Seams

/// An `EmbeddingClient` that reaches nothing.
///
/// Returns a correctly-shaped answer rather than throwing: a preview that renders an empty
/// results list is a useful preview, and one that renders an error banner is a misleading one.
nonisolated struct InertEmbeddingClient: EmbeddingClient {
    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        texts.map { _ in [] }
    }
}

/// An `LLMClient` that reaches nothing.
///
/// Every member answers "nothing here" in its own vocabulary — an immediately-finished stream,
/// empty catalogues, `nil` capabilities — so a preview renders its empty state instead of
/// hanging on a socket. The model-lifecycle members throw, because silently reporting success
/// for a load that never happened is the failure mode `LLMClientRouter` was split up to end.
nonisolated struct InertLLMClient: LLMClient {

    private struct Unavailable: LocalizedError {
        var errorDescription: String? { "No LLM server in a preview." }
    }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }

    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] { [] }

    func loadModel(
        provider: LLMProvider,
        modelName: String,
        baseURLString: String
    ) async throws -> String {
        throw Unavailable()
    }

    func unloadModel(
        provider: LLMProvider,
        instanceID: String,
        baseURLString: String
    ) async throws {
        throw Unavailable()
    }

    func listLoadedInstances(
        provider: LLMProvider,
        baseURLString: String
    ) async throws -> LoadedInstanceListing {
        throw Unavailable()
    }

    func modelSupportsVision(config: LLMConfig) async -> Bool? { nil }

    func modelContextLength(config: LLMConfig) async -> Int? { nil }

    func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? { nil }
}

/// A `DownloadedModelStore` that reaches nothing.
///
/// The seam this factory forgot on its first draft — caught by
/// `OrchestratorTestConstructionPinTests.testThePreviewFactoryStubsEverySeam` the first time it
/// ran, which is the entire argument for deriving the seam list from the init instead of
/// restating it. Its outward default is `DownloadedModelStoreRouter()`, which lists and DELETES
/// files on the model host.
nonisolated struct InertDownloadedModelStore: DownloadedModelStore {

    func listDownloaded(config: LLMConfig) async throws -> [DownloadedModel] { [] }

    func deletionCapability(config: LLMConfig) async -> DownloadedModelDeletion {
        .unavailable(reason: "No model host in a preview.")
    }

    /// Deliberately a no-op rather than a throw: the capability above already tells the UI
    /// deletion is impossible here, so nothing should reach this — and if something does, a
    /// preview must not be the thing that reports a failed delete.
    func delete(modelID: String, config: LLMConfig) async throws {}

    func storageLocationDescription(config: LLMConfig) async -> String? { nil }
}
