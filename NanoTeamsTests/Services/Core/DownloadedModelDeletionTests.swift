import XCTest

@testable import NanoTeams

/// The orchestration around Settings → LLM → Downloaded Models: the residency
/// overlay, the unload-before-delete step, the reference warning, and the
/// deliberate decision NOT to rewrite configuration behind a delete.
@MainActor
final class DownloadedModelDeletionTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var store: RecordingDownloadedModelStore!

    override func setUp() async throws {
        try await super.setUp()
        store = RecordingDownloadedModelStore()
        embeddingClient = RecordingLLMClient()
        chatLifecycleClient = RecordingLLMClient()
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient,
            downloadedModelStore: store
        )
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    private func lmStudioConfig(_ url: String = "http://127.0.0.1:1234") -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: url, modelName: "m")
    }

    private func ollamaConfig() -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
    }

    // MARK: - Residency overlay

    /// The LM Studio store never talks to the server (so the card works with
    /// LM Studio closed) and therefore can't know what's resident. Residency is
    /// the residency subsystem's fact, so it is overlaid here.
    func testDownloadedModels_overlaysResidencyForLMStudio() async throws {
        store.models = [
            DownloadedModel(id: "pub/a-GGUF", displayName: "pub/a-GGUF",
                            referenceHints: ["pub/a-GGUF", "pub/a"]),
            DownloadedModel(id: "pub/b-GGUF", displayName: "pub/b-GGUF",
                            referenceHints: ["pub/b-GGUF", "pub/b"]),
        ]
        chatLifecycleClient.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "pub/a", instanceID: "pub/a")
        ]

        let models = try await sut.downloadedModels(config: lmStudioConfig())

        XCTAssertEqual(models.first { $0.id == "pub/a-GGUF" }?.isLoaded, true)
        XCTAssertEqual(models.first { $0.id == "pub/b-GGUF" }?.isLoaded, false)
    }

    /// Ollama's own store already answers residency from `/api/ps`; re-probing
    /// through the LM-Studio-only lifecycle client would be meaningless.
    func testDownloadedModels_doesNotProbeResidencyForOllama() async throws {
        store.models = [DownloadedModel(id: "llama3.1:8b", displayName: "llama3.1:8b", isLoaded: true)]

        let models = try await sut.downloadedModels(config: ollamaConfig())

        XCTAssertEqual(models.first?.isLoaded, true)
        XCTAssertTrue(
            chatLifecycleClient.calls.isEmpty,
            "Ollama listing must not reach the LM Studio lifecycle client")
    }

    func testDownloadedModels_unreachableServerStillLists() async throws {
        store.models = [DownloadedModel(id: "pub/a", displayName: "pub/a")]
        chatLifecycleClient.listLoadedInstancesError = LLMClientError.missingResponse

        let models = try await sut.downloadedModels(config: lmStudioConfig())

        XCTAssertEqual(models.map(\.id), ["pub/a"])
        XCTAssertEqual(
            models.first?.isLoaded, false,
            "A failed residency probe must degrade to 'no badge', never block the listing")
    }

    // MARK: - Reference warning

    func testReferenceWarning_namesSettingsWhenTheGlobalModelMatches() {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "pub/a"
        let model = DownloadedModel(id: "pub/a-GGUF", displayName: "pub/a-GGUF",
                                    referenceHints: ["pub/a-GGUF", "pub/a"])

        XCTAssertEqual(
            sut.downloadedModelReferenceWarning(
                model, base: "http://127.0.0.1:1234", allFolders: [model],
                serverKeys: ["pub/a"]),
            "Your LLM settings currently use this model.")
    }

    func testReferenceWarning_nilWhenNothingPointsAtIt() {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "something-else"
        let model = DownloadedModel(id: "pub/unused", displayName: "pub/unused")

        // `serverKeys` names what the server actually serves: it does NOT serve
        // "something-else", so that reference cannot be backed by a folder here and the row
        // stays determinate. Without this the honest answer would be "couldn't verify".
        XCTAssertNil(sut.downloadedModelReferenceWarning(
            model, base: "http://127.0.0.1:1234", allFolders: [model],
            serverKeys: ["pub/unused"]))
    }

    /// A model on a DIFFERENT server than the selected one isn't referenced by
    /// that selection, even when the names match.
    func testReferenceWarning_isBaseURLScoped() {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "pub/a"
        let model = DownloadedModel(id: "pub/a", displayName: "pub/a")

        XCTAssertNil(sut.downloadedModelReferenceWarning(
            model, base: "http://10.0.0.9:1234", allFolders: [model], serverKeys: ["pub/a"]))
    }

    /// The MEASURED D-B2 case, and the reason the answer is three-state.
    ///
    /// Settings name `openai/gpt-oss-20b` — the SHIPPED DEFAULT for the shipped default
    /// provider — while the folder on disk is `lmstudio-community/gpt-oss-20b-GGUF`. The
    /// server serves that key, so the reference is real; it just matches no folder here.
    /// The old `Bool` reported "not referenced", which the user reads as safe, and Remove
    /// sent ~11 GB to the Trash.
    ///
    /// RED: collapse `.undetermined` into `.notReferenced` → this returns nil and fails.
    func testReferenceWarning_referenceMatchesNoFolder_saysCouldNotVerify_notNothing() {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "openai/gpt-oss-20b"
        let onDisk = DownloadedModel(
            id: "lmstudio-community/gpt-oss-20b-GGUF",
            displayName: "lmstudio-community/gpt-oss-20b-GGUF",
            referenceHints: ["lmstudio-community/gpt-oss-20b-GGUF", "gpt-oss-20b-GGUF"])

        let warning = sut.downloadedModelReferenceWarning(
            onDisk, base: "http://127.0.0.1:1234", allFolders: [onDisk],
            serverKeys: ["openai/gpt-oss-20b"])

        guard let warning else {
            return XCTFail("an unresolved reference must not read as 'nothing uses this'")
        }
        XCTAssertTrue(warning.contains("Couldn't verify"), warning)
        XCTAssertTrue(warning.contains("openai/gpt-oss-20b"),
                      "the unresolved reference must be NAMED, or the caution is unactionable")
    }

    /// The benchmark target carries its own model name and base URL and belonged to no slot
    /// list at all, so deleting a model the benchmark points at warned about nothing — even
    /// on an exact match, in either namespace.
    ///
    /// RED: drop the `benchmarkTarget` block from `referencedModelSlots` → nil, and fails.
    func testReferenceWarning_benchmarkTarget_isAReferencingSlot() {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "unrelated"
        sut.configuration.benchmarkTarget = BenchmarkTarget(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "pub/bench")
        let model = DownloadedModel(id: "pub/bench", displayName: "pub/bench",
                                    referenceHints: ["pub/bench"])

        XCTAssertEqual(
            sut.downloadedModelReferenceWarning(
                model, base: "http://127.0.0.1:1234", allFolders: [model],
                serverKeys: ["pub/bench", "unrelated"]),
            "Your LLM settings currently use this model.")
    }

    /// A per-role `llmOverride` is a reference too — and one that inherits the global base
    /// while naming its own model is the common shape, so the inheritance arm has to resolve.
    func testReferenceWarning_namesATeamRoleOverride() async {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "unrelated"
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { projection in
            guard let index = projection.teams.indices.first,
                  let roleIndex = projection.teams[index].roles.indices.first else { return }
            projection.teams[index].roles[roleIndex].llmOverride =
                LLMOverride(baseURLString: nil, modelName: "pub/role")
        }
        let model = DownloadedModel(id: "pub/role", displayName: "pub/role",
                                    referenceHints: ["pub/role"])

        XCTAssertEqual(
            sut.downloadedModelReferenceWarning(
                model, base: "http://127.0.0.1:1234", allFolders: [model],
                serverKeys: ["pub/role", "unrelated"]),
            "A team role currently uses this model.")
    }

    /// A generated team lives on the TASK, not in `teams` — and the ACTIVE task is
    /// deliberately absent from `loadedTasks`, so it needs its own walk. Without it, the
    /// roster the user is looking at right now is the one slot that goes unchecked.
    func testReferenceWarning_namesAGeneratedRosterRoleOnTheActiveTask() async {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "unrelated"
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "goal") else {
            return XCTFail("createTask failed")
        }
        var generated = TeamTemplateFactory.startup()
        generated.roles[0].llmOverride = LLMOverride(baseURLString: nil, modelName: "pub/gen")
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(generated) }
        XCTAssertEqual(sut.activeTask?.id, taskID, "premise: the roster under test is ACTIVE")
        let model = DownloadedModel(id: "pub/gen", displayName: "pub/gen",
                                    referenceHints: ["pub/gen"])

        XCTAssertEqual(
            sut.downloadedModelReferenceWarning(
                model, base: "http://127.0.0.1:1234", allFolders: [model],
                serverKeys: ["pub/gen", "unrelated"]),
            "A generated team role currently uses this model.")
    }

    // MARK: - Deletion

    func testDelete_unloadsAResidentLMStudioModelFirst() async {
        chatLifecycleClient.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "pub/a", instanceID: "pub/a:2")
        ]
        let model = DownloadedModel(
            id: "pub/a-GGUF", displayName: "pub/a-GGUF", isLoaded: true,
            referenceHints: ["pub/a-GGUF", "pub/a"])

        let result = await sut.deleteDownloadedModel(model, config: lmStudioConfig())

        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertTrue(
            chatLifecycleClient.calls.contains(
                .unload(instanceID: "pub/a:2", baseURL: "http://127.0.0.1:1234")),
            "A resident model's instance must be unloaded before its files move")
        XCTAssertEqual(store.deleted, ["pub/a-GGUF"])
    }

    func testDelete_skipsUnloadWhenTheModelIsNotResident() async {
        let model = DownloadedModel(id: "pub/a-GGUF", displayName: "pub/a-GGUF", isLoaded: false)

        _ = await sut.deleteDownloadedModel(model, config: lmStudioConfig())

        XCTAssertTrue(chatLifecycleClient.calls.isEmpty)
        XCTAssertEqual(store.deleted, ["pub/a-GGUF"])
    }

    /// Ollama evicts server-side as part of `DELETE /api/delete`.
    func testDelete_neverUnloadsForOllama() async {
        let model = DownloadedModel(id: "llama3.1:8b", displayName: "llama3.1:8b", isLoaded: true)

        _ = await sut.deleteDownloadedModel(model, config: ollamaConfig())

        XCTAssertTrue(chatLifecycleClient.calls.isEmpty)
        XCTAssertEqual(store.deleted, ["llama3.1:8b"])
    }

    func testDelete_surfacesStoreFailure() async {
        store.deleteError = LMStudioModelDeletionError.modelsFolderNotFound
        let model = DownloadedModel(id: "pub/a", displayName: "pub/a")

        let result = await sut.deleteDownloadedModel(model, config: lmStudioConfig())

        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertEqual(
            sut.lastErrorMessage,
            "Couldn't remove pub/a: Couldn't find LM Studio's models folder.")
    }

    // MARK: - Warn before, inform after, mutate nothing

    func testDelete_informsButDoesNotClearTheGlobalSelection() async {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "pub/a"
        let model = DownloadedModel(id: "pub/a-GGUF", displayName: "pub/a-GGUF",
                                    referenceHints: ["pub/a-GGUF", "pub/a"])

        _ = await sut.deleteDownloadedModel(model, config: lmStudioConfig())

        XCTAssertEqual(sut.lastInfoMessage, "Main LLM still points at pub/a — pick a new model.")
        XCTAssertEqual(
            sut.configuration.llmModelName, "pub/a",
            "Deleting a download must not silently rewrite the user's configuration — the reference "
                + "set spans teams.json and per-task generated teams, and the confirm dialog already "
                + "named the exposure")
    }

    func testDelete_noInfoMessageWhenTheGlobalSelectionIsUnrelated() async {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "kept-model"
        let model = DownloadedModel(id: "pub/other", displayName: "pub/other")

        _ = await sut.deleteDownloadedModel(model, config: lmStudioConfig())

        XCTAssertNil(sut.lastInfoMessage)
    }

    func testDelete_noInfoMessageOnFailure() async {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        sut.configuration.llmModelName = "pub/a"
        store.deleteError = LMStudioModelDeletionError.remoteServer

        _ = await sut.deleteDownloadedModel(
            DownloadedModel(id: "pub/a", displayName: "pub/a"), config: lmStudioConfig())

        XCTAssertNil(sut.lastInfoMessage, "A failed delete must not claim the model is gone")
    }
}

// MARK: - Doubles

private final class RecordingDownloadedModelStore: DownloadedModelStore, @unchecked Sendable {
    var models: [DownloadedModel] = []
    var capability: DownloadedModelDeletion = .permanent
    var deleteError: Error?
    private(set) var deleted: [String] = []

    func listDownloaded(config _: LLMConfig) async throws -> [DownloadedModel] { models }

    func deletionCapability(config _: LLMConfig) async -> DownloadedModelDeletion { capability }

    func delete(modelID: String, config _: LLMConfig) async throws {
        if let deleteError { throw deleteError }
        deleted.append(modelID)
    }

    func storageLocationDescription(config _: LLMConfig) async -> String? { nil }
}
