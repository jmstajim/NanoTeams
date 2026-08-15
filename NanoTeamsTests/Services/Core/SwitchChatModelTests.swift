import XCTest

@testable import NanoTeams

/// Chat-model residency: NanoTeams keeps a ledger of the LM Studio instances it
/// manages and reconciles them against what the settings reference.
///
/// The three rules this exists to satisfy:
/// 1. Vision turned off ⇒ its override model is reclaimed.
/// 2. A judge turned off ⇒ its override model is reclaimed.
///    (The embedding half of rule 2 — Exploratory Search off ⇒ unload — has
///    always been `EmbeddingModelLifecycleService`'s job and is tested there.)
/// 3. Main model switched A → B ⇒ A unloaded, B loaded.
///
/// Why a reconciler and not "unload the old model": a delta handler only ever
/// names the single model of the current transition, so anything an earlier
/// transition failed to free stayed resident forever. That is how two chat
/// models (a 35B at 262144 context and a second vlm) plus the embedding model
/// ended up co-resident until a 26B refused to load for want of memory.
final class SwitchChatModelTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let baseURL = "http://127.0.0.1:1234"

    private func loadedModels(_ client: RecordingLLMClient) -> [String] {
        client.calls.compactMap { if case .load(let m, _) = $0 { return m } else { return nil } }
    }

    private func unloadedIDs(_ client: RecordingLLMClient) -> [String] {
        client.calls.compactMap {
            if case .unload(let id, _) = $0 { return id } else { return nil }
        }
    }

    /// Puts a model into the ownership ledger the way production does — by
    /// using it. Only MANAGED instances are ever unloaded, so a switch test has
    /// to establish ownership first, exactly as a real run would by issuing one
    /// request through `streamChat` → `ensureLoaded`.
    @discardableResult
    private func managed(
        _ models: [String],
        base: String? = nil,
        client: RecordingLLMClient
    ) async -> ChatModelEnsurer {
        let ensurer = ChatModelEnsurer()
        for model in models {
            _ = try? await ensurer.ensureLoaded(
                modelName: model, baseURLString: base ?? baseURL, client: client)
        }
        client.calls.removeAll()
        return ensurer
    }

    private func resident(_ names: [String]) -> [LoadedModelInstance] {
        names.map { LoadedModelInstance(modelName: $0, instanceID: $0) }
    }

    // MARK: - Rule 3: switching the main model

    func testSwitch_unloadsOldAndLoadsNew() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["old-model"])
        sut.configuration.llmBaseURLString = baseURL
        let ensurer = await managed(["old-model"], client: client)
        sut.configuration.llmModelName = "new-model"

        await sut.switchChatModel(
            oldModel: "old-model", newModel: "new-model", baseURLString: baseURL,
            client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["old-model"])
        XCTAssertEqual(loadedModels(client), ["new-model"])
    }

    /// Ollama manages its own residency (`keep_alive`, no load/unload REST
    /// surface) — a switch under provider `.ollama` must NOT attempt an
    /// explicit load (the 404 would surface as a spurious "couldn't load
    /// model" banner on every switch), while reconcile still reclaims the
    /// LM Studio instance orphaned by the provider flip itself.
    func testSwitch_ollamaProvider_reconcilesButNeverLoads() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["old-lm-model"])
        let ensurer = await managed(["old-lm-model"], client: client)
        // Global slot now points at Ollama — the LM Studio model is orphaned.
        sut.configuration.llmBaseURLString = "http://127.0.0.1:11434"
        sut.configuration.llmModelName = "gpt-oss:20b"

        await sut.switchChatModel(
            oldModel: "old-lm-model", newModel: "gpt-oss:20b",
            baseURLString: "http://127.0.0.1:11434", provider: .ollama,
            client: client, ensurer: ensurer)

        XCTAssertEqual(loadedModels(client), [], "no explicit load against an Ollama server")
        XCTAssertEqual(unloadedIDs(client), ["old-lm-model"],
                       "reconcile still reclaims the orphaned LM Studio instance")
        XCTAssertNil(sut.lastErrorMessage)
    }

    /// The accumulation bug, reproduced: TWO models were orphaned by earlier
    /// switches. A delta handler frees only the one it was told about; the
    /// reconciler frees both.
    func testSwitch_reclaimsEveryOrphan_notJustTheOneNamed() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan-a", "orphan-b"])
        sut.configuration.llmBaseURLString = baseURL
        let ensurer = await managed(["orphan-a", "orphan-b"], client: client)
        sut.configuration.llmModelName = "new-model"

        await sut.switchChatModel(
            oldModel: "orphan-b", newModel: "new-model", baseURLString: baseURL,
            client: client, ensurer: ensurer)

        XCTAssertEqual(
            Set(unloadedIDs(client)), ["orphan-a", "orphan-b"],
            "A model orphaned by an EARLIER switch must be reclaimed too — that is "
                + "the accumulation that exhausted memory")
    }

    // MARK: - Rule 1: Vision turned off reclaims its override

    func testReconcile_visionDisabled_reclaimsItsOverrideModel() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["vision-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        sut.configuration.visionEnabled = true
        sut.configuration.visionModelName = "vision-model"
        let ensurer = await managed(["vision-model"], client: client)

        // Still referenced while Vision is on.
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)
        XCTAssertEqual(unloadedIDs(client), [], "An enabled Vision slot still needs its model")

        sut.configuration.visionEnabled = false
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["vision-model"],
                       "Turning Vision off must reclaim the model only Vision referenced")
    }

    /// Vision inheriting the global model must NOT drag the global model down
    /// with it when Vision is switched off.
    func testReconcile_visionDisabled_doesNotReclaimTheInheritedGlobalModel() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["chat-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        sut.configuration.visionEnabled = true
        sut.configuration.visionModelName = ""  // "use global"
        let ensurer = await managed(["chat-model"], client: client)

        sut.configuration.visionEnabled = false
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [], "The global chat slot still references it")
    }

    // MARK: - Rule 2: a disabled judge reclaims its override

    func testReconcile_bashJudgeDisabled_reclaimsItsOverrideModel() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["judge-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        sut.configuration.bashMode = .auto
        sut.configuration.bashRestrictionLevel = .standard
        sut.configuration.bashJudgeLLMOverride = LLMOverride(modelName: "judge-model")
        let ensurer = await managed(["judge-model"], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)
        XCTAssertEqual(unloadedIDs(client), [], "An active judge still needs its model")

        // Safety=Off short-circuits to allow before the judge is ever called.
        sut.configuration.bashRestrictionLevel = .off
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["judge-model"])
    }

    func testReconcile_computerUseJudgeDisabled_reclaimsItsOverrideModel() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["cu-judge"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        sut.configuration.computerUseMode = .auto
        sut.configuration.computerUseRestrictionLevel = .standard
        sut.configuration.computerUseJudgeLLMOverride = LLMOverride(modelName: "cu-judge")
        let ensurer = await managed(["cu-judge"], client: client)

        sut.configuration.computerUseMode = .off
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["cu-judge"])
    }

    // MARK: - Ownership: only what the app manages

    /// The core of "NanoTeams tracks what IT loaded". A model resident because
    /// the user loaded it by hand in the LM Studio UI, which no request of ours
    /// ever used, is not ours to unload.
    func testReconcile_neverUnloadsAModelTheAppNeverUsed() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["hand-loaded-by-user"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"

        await sut.reconcileAndReportResidency(client: client, ensurer: ChatModelEnsurer())

        XCTAssertEqual(unloadedIDs(client), [],
                       "An instance the app never touched is not app-managed")
    }

    /// A fresh ensurer whose listing FAILS records no ownership — there is no
    /// instance id to unload with, so a later reconcile must not invent one.
    func testReconcile_listingFailureDuringEnsure_recordsNoOwnership() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesError = TestError.boom
        let ensurer = ChatModelEnsurer()
        _ = try? await ensurer.ensureLoaded(
            modelName: "some-model", baseURLString: baseURL, client: client)
        client.calls.removeAll()
        client.listLoadedInstancesError = nil
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [])
    }

    /// Ownership is dropped only on a SUCCESSFUL unload — otherwise the id is
    /// lost and the instance is orphaned with no way to reclaim it.
    func testReconcile_unloadFailure_keepsOwnershipSoTheNextPassRetries() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)

        client.unloadError = TestError.boom
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)
        XCTAssertNotNil(sut.lastInfoMessage, "A failed reclaim must reach the user")

        client.unloadError = nil
        client.calls.removeAll()
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["orphan"], "The retry must still know the id")
    }

    func testReconcile_afterSuccessfulUnload_doesNotUnloadTwice() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)
        client.calls.removeAll()
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [], "Ownership is released on success")
    }

    // MARK: - In-use deferral

    /// The only legitimate deferral: pulling an instance out from under an
    /// OPEN request kills it. Deferral, not leak — the next reconcile sweeps it.
    func testReconcile_modelWithAnOpenRequest_isDeferredThenReclaimed() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)
        await ensurer.beginRequest(modelName: "orphan", baseURLString: baseURL)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)
        XCTAssertEqual(unloadedIDs(client), [], "Must not kill an open stream")

        await ensurer.endRequest(modelName: "orphan", baseURLString: baseURL)
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["orphan"], "The deferral must not become a leak")
    }

    /// BEHAVIOUR CHANGE, pinned deliberately. A busy engine used to block the
    /// unload — but "is the app busy" is not "is THIS model needed": a step
    /// running on model B pinned model A forever, which is what let orphans
    /// accumulate. A step captures its config once, and `streamChat` re-ensures
    /// before every request, so a wrong unload costs one reload, never a
    /// failure. Do not restore the busy guard.
    func testReconcile_whileAnEngineIsRunningOnAnotherModel_stillReclaimsTheOrphan() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)
        sut.engineState[1] = .running
        sut._testRegisterStepTask(stepID: "some-role", taskID: 1)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["orphan"])
    }

    // MARK: - Reference guards

    func testReconcile_modelReferencedByAnotherSlot_survives() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["shared-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "shared-model"
        sut.configuration.visionEnabled = true
        sut.configuration.visionModelName = "vision-model"
        let ensurer = await managed(["shared-model"], client: client)

        await sut.switchChatModel(
            oldModel: "shared-model", newModel: "vision-model", baseURLString: baseURL,
            client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [],
                       "The global slot still resolves to it")
    }

    func testReconcile_modelReferencedByTeamGenOverride_survives() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["teamgen-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        sut.configuration.teamGenLLMOverride = LLMOverride(modelName: "teamgen-model")
        let ensurer = await managed(["teamgen-model"], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [])
    }

    func testReconcile_modelReferencedByPerRoleOverride_survives() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { projection in
            guard var team = projection.teams.first,
                  let role = team.roles.first(where: { $0.id != Role.supervisor.baseID })
            else { return }
            var updated = role
            updated.llmOverride = LLMOverride(modelName: "role-pinned-model")
            team.updateRole(updated)
            projection.teams[0] = team
        }

        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["role-pinned-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["role-pinned-model"], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [])
    }

    /// The embedding model has a different lifecycle owner. It is protected
    /// twice over: it is never in the chat ledger, and its slot is referenced.
    func testReconcile_neverTouchesTheEmbeddingInstance() async {
        let client = RecordingLLMClient()
        let embedModel = sut.configuration.effectiveEmbeddingConfig.modelName
        client.listLoadedInstancesResults = resident([embedModel, "orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertFalse(unloadedIDs(client).contains(embedModel),
                       "Owned by EmbeddingModelLifecycleService")
    }

    // MARK: - Duplicate instances (the one-slot ledger can't represent them)

    /// The live-observed case: LM Studio holds `qwen` AND `qwen:2`; adoption
    /// collapses both onto one ledger key (last wins), the other instance
    /// becomes unowned and — before this fix — nothing ever unloaded it, even
    /// though the model is the ACTIVE one. The reconciler must reap the
    /// unowned sibling while keeping the owned instance.
    func testReconcile_reapsUnownedDuplicateOfTheActiveModel() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen"),
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2"),
        ]
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "qwen"
        let ensurer = ChatModelEnsurer()
        await sut.adoptResidentReferencedModels(client: client, ensurer: ensurer)
        client.calls.removeAll()

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["qwen"],
                       "The unowned sibling goes; the owned instance of the active model stays")
        let owned = await ensurer.ownedModels()
        XCTAssertEqual(owned.map(\.instanceID), ["qwen:2"],
                       "The kept instance's ledger entry must survive the sibling reap")
        XCTAssertEqual(client.listLoadedInstancesResults.map(\.instanceID), ["qwen:2"],
                       "Exactly one instance remains resident")
    }

    /// The census is (base, model)-keyed — an open stream might be served by
    /// either instance, so a busy model defers sibling reaping too.
    func testReconcile_duplicateOfAStreamingModel_isDeferredThenReaped() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen"),
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2"),
        ]
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "qwen"
        let ensurer = ChatModelEnsurer()
        await sut.adoptResidentReferencedModels(client: client, ensurer: ensurer)
        client.calls.removeAll()
        await ensurer.beginRequest(modelName: "qwen", baseURLString: baseURL)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)
        XCTAssertEqual(unloadedIDs(client), [],
                       "A stream might be served by the sibling — don't pull it mid-request")

        await ensurer.endRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["qwen"], "The deferral must not become a leak")
    }

    /// A duplicate that refuses to unload must SAY so. The ordinary orphan reclaim
    /// already reports its failures; the sibling reap — added later — was the one
    /// unload in the pass whose failure went nowhere.
    ///
    /// It matters more than the orphan case, not less: a duplicate of the model the
    /// user is actively chatting with is, by construction, a second full copy of the
    /// largest thing in memory, and the pile-up that motivated the reap was observed
    /// on the ACTIVE model (three co-resident instances until a 26B refused to load).
    /// A silent failure there reads to the user as "NanoTeams is leaking memory".
    ///
    /// The model stays referenced (`llmModelName == "qwen"`), so the orphan reclaim
    /// below is skipped and the duplicate's unload is the only one in the pass —
    /// which is what makes the blanket `unloadError` a precise instrument here.
    ///
    /// RED: drop the `if case .failed(let error) = outcome { notices.append(…) }` arm
    /// → `lastInfoMessage` is nil and both assertions fail, while the reap itself
    /// still ran (the attempt assertion keeps this from passing vacuously).
    func testReconcile_duplicateReapFails_saysSoInsteadOfSilentlyLeakingIt() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen"),
        ]
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "qwen"
        let ensurer = await managed(["qwen"], client: client)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen"),
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2"),
        ]
        client.unloadError = TestError.boom

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["qwen:2"],
                       "precondition: the reap was attempted on the duplicate only")
        let notice = sut.lastInfoMessage ?? ""
        XCTAssertTrue(notice.contains("qwen:2"),
                      "the notice must name the instance that is still resident; got: \(notice)")
        XCTAssertTrue(notice.contains("duplicate"),
                      "and say it was a duplicate, so the user can tell it from an orphan; got: \(notice)")
    }

    /// An unreferenced model with a duplicate pile goes entirely — the sibling
    /// through the reap, the owned instance through the ordinary orphan path.
    func testReconcile_unreferencedModelWithDuplicates_reapsAllInstances() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2"),
        ]
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["qwen"], client: client)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen"),
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2"),
        ]

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(Set(unloadedIDs(client)), ["qwen", "qwen:2"],
                       "Nothing references the model — the whole pile goes in one pass")
    }

    /// Listing failure skips the reap for that server (a missed reap creates
    /// nothing; the next reconcile retries) but must not stop the ordinary
    /// owned-orphan reclaim, which needs no listing.
    func testReconcile_listingFailure_skipsReapButStillReclaimsOrphans() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)
        client.listLoadedInstancesError = TestError.boom

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["orphan"],
                       "The orphan reclaim keys off the ledger, not the listing")
    }

    /// A duplicated model the app never touched is not ours, duplicate or not.
    func testReconcile_duplicateOfAForeignModel_isLeftAlone() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = await managed(["orphan"], client: client)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "orphan", instanceID: "orphan"),
            LoadedModelInstance(modelName: "foreign", instanceID: "foreign"),
            LoadedModelInstance(modelName: "foreign", instanceID: "foreign:2"),
        ]

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["orphan"],
                       "Foreign duplicates are the user's business, not ours")
    }

    /// Mid-session server restart: the owned instance is gone, and an
    /// identically-named resident instance is the user's fresh hand-load, NOT
    /// a duplicate. Reaping keys on the owned instance being itself listed.
    func testReconcile_ownedInstanceGoneFromServer_doesNotReapLookalikes() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2"),
        ]
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "qwen"
        let ensurer = await managed(["qwen"], client: client)
        // Server restarted (qwen:2 died with it); the user hand-loaded afresh.
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen"),
        ]

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [],
                       "A stale ledger entry must not license unloading a lookalike")
    }

    /// Pins the ledger's one-instance-per-(model, base) invariant explicitly:
    /// two instances of one model is never a DESIRED state, so the ledger
    /// represents one and the reconciler repairs the excess.
    func testAdoption_twoInstancesOfOneModel_collapseToOneOwnedEntry() async {
        let ensurer = ChatModelEnsurer()
        await ensurer.adoptExistingInstance(
            modelName: "qwen", baseURLString: baseURL, instanceID: "qwen")
        await ensurer.adoptExistingInstance(
            modelName: "qwen", baseURLString: baseURL, instanceID: "qwen:2")

        let owned = await ensurer.ownedModels()
        XCTAssertEqual(owned.count, 1, "One ledger slot per (model, base) — last adoption wins")
        XCTAssertEqual(owned.first?.instanceID, "qwen:2")
    }

    // MARK: - Duplicate-reap hardening (atomic unowned reclaim)

    /// A "duplicate" that is actually owned under ANOTHER ledger key — the
    /// alias-base case (global localhost:1234 + per-role 127.0.0.1:1234,
    /// deliberately non-collapsed) — must NOT be reaped: it is the per-role
    /// override's keeper, and killing it strands that authority.
    func testReclaimUnownedDuplicate_instanceOwnedUnderAnotherKey_isSkipped() async {
        let client = RecordingLLMClient()
        let ensurer = ChatModelEnsurer()
        await ensurer.adoptExistingInstance(
            modelName: "M", baseURLString: "http://127.0.0.1:1234", instanceID: "M:2")

        let outcome = await ensurer.reclaimUnownedDuplicate(
            instanceID: "M:2", modelName: "M",
            baseURLString: "http://localhost:1234", client: client)

        guard case .skippedOwned = outcome else {
            XCTFail("Expected skippedOwned, got \(outcome)")
            return
        }
        XCTAssertEqual(unloadedIDs(client), [],
                       "An instance owned under any key is someone's keeper")
    }

    /// An open request for the (base, model) defers the sibling reap — the
    /// stream might be served by this very instance (the census is
    /// (base, model)-keyed and can't attribute it).
    func testReclaimUnownedDuplicate_openRequest_isSkippedBusy() async {
        let client = RecordingLLMClient()
        let ensurer = ChatModelEnsurer()
        await ensurer.beginRequest(modelName: "M", baseURLString: baseURL)

        let outcome = await ensurer.reclaimUnownedDuplicate(
            instanceID: "M:2", modelName: "M", baseURLString: baseURL, client: client)

        guard case .skippedBusy = outcome else {
            XCTFail("Expected skippedBusy, got \(outcome)")
            return
        }
        XCTAssertEqual(unloadedIDs(client), [])
    }

    /// An idle, unowned duplicate is unloaded — WITHOUT touching the ledger.
    /// Routing it through `reclaim` (as the first cut did) would drop a fresh
    /// ownership record if a concurrent ensure adopted this exact id; the
    /// dedicated path never mutates `owned`.
    func testReclaimUnownedDuplicate_idleUnowned_unloadsWithoutTouchingLedger() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "M", instanceID: "M:2"),
        ]
        let ensurer = ChatModelEnsurer()
        await ensurer.adoptExistingInstance(
            modelName: "M", baseURLString: baseURL, instanceID: "M")
        let ledgerBefore = await ensurer.ownedModels()

        let outcome = await ensurer.reclaimUnownedDuplicate(
            instanceID: "M:2", modelName: "M", baseURLString: baseURL, client: client)

        guard case .unloaded = outcome else {
            XCTFail("Expected unloaded, got \(outcome)")
            return
        }
        XCTAssertTrue(unloadedIDs(client).contains("M:2"))
        let ledgerAfter = await ensurer.ownedModels()
        XCTAssertEqual(ledgerBefore, ledgerAfter,
                       "Reaping an unowned duplicate must leave the ledger untouched")
    }

    /// The embedding model's duplicates belong to EmbeddingModelLifecycleService.
    /// The chat reconciler must not reap them (the two authorities have
    /// different keep-rules and would each unload the other's keeper).
    func testReconcile_doesNotReapEmbeddingModelDuplicates() async {
        let client = RecordingLLMClient()
        let embedModel = sut.configuration.effectiveEmbeddingConfig.modelName
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: embedModel, instanceID: embedModel),
            LoadedModelInstance(modelName: embedModel, instanceID: "\(embedModel):2"),
        ]
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        // Adopt the embedding instance into the chat ledger the way open-time
        // adoption does (it is referenced via the embedding slot).
        let ensurer = await managed([embedModel], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [],
                       "The embedding model's siblings are its own service's job, not the chat reconciler's")
    }

    // MARK: - Coalescing latch (a colliding pass is re-run, not dropped)

    /// A reconcile that collides with an in-flight pass must be COALESCED into a
    /// second pass, not dropped — otherwise a dedicated de-reference sweep can
    /// no-op while the competing sweep's snapshot predates the de-reference,
    /// leaking the model. Proven by listing count: each pass lists its base
    /// once (+ once per orphan settle), so a coalesced rerun produces strictly
    /// more listings than a dropped one.
    func testReconcile_collidingPass_isCoalescedNotDropped() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["orphan", "kept"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "kept"  // kept referenced; orphan not
        let ensurer = await managed(["orphan", "kept"], client: client)

        // Freeze the first pass inside the orphan's unload.
        let gate = TestGate()
        client.unloadHold = { await gate.wait() }

        async let firstPass: Void = sut.reconcileAndReportResidency(
            client: client, ensurer: ensurer)

        // Wait until the orphan's unload has started (pass 1 is now suspended).
        for _ in 0..<300 where !client.calls.contains(where: {
            if case .unload = $0 { return true }; return false
        }) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Collide a second reconcile — it hits the guard and must record a
        // rerun (returns immediately without its own pass).
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        let listingsAfterCollision = client.calls.filter {
            if case .listLoadedInstances = $0 { return true }; return false
        }.count

        gate.open()
        await firstPass

        let totalListings = client.calls.filter {
            if case .listLoadedInstances = $0 { return true }; return false
        }.count
        XCTAssertGreaterThan(
            totalListings, listingsAfterCollision,
            "The coalesced rerun must run a second pass after the collision, not be dropped")
    }

    // MARK: - Adoption across a relaunch

    /// The ledger is in-memory, so after a relaunch the models this app loaded
    /// last session look foreign. Adoption re-claims the ones a slot still
    /// references, so a later switch can reclaim them.
    func testAdoptResidentReferencedModels_claimsReferencedOnly() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["chat-model", "foreign-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"

        let ensurer = ChatModelEnsurer()
        await sut.adoptResidentReferencedModels(client: client, ensurer: ensurer)
        // Now switch away: the adopted model becomes an orphan and is reclaimed,
        // while the never-referenced foreign one is left alone.
        sut.configuration.llmModelName = "next-model"
        client.calls.removeAll()
        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["chat-model"],
                       "Only the instance a slot referenced is adopted, so only it is reclaimed")
    }

    // MARK: - Review regressions (each of these shipped broken once)

    /// BLOCKER, found in review. The server-URL field is bound to a LIVE
    /// `TextField`, so every keystroke writes `llmBaseURLString`. When that was
    /// in the residency fingerprint, one Backspace in the port reconciled
    /// against a half-typed URL, decided the resident model was unreferenced,
    /// and unloaded it — the unload even SUCCEEDED, because it targets the
    /// instance's own stored (still valid) base.
    func testFingerprint_doesNotChangeWhileTheUserTypesAServerURL() {
        sut.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        let before = sut.residencyRelevantSettings

        sut.configuration.llmBaseURLString = "http://127.0.0.1:123"   // mid-Backspace
        sut.configuration.visionBaseURLString = "http://127.0.0.1:99" // and the Vision one

        XCTAssertEqual(
            sut.residencyRelevantSettings, before,
            "URL fields must reconcile from the editor's commit boundary, never "
                + "from the live binding")
    }

    /// Same fingerprint, other direction: a real enablement change MUST still
    /// be seen, or rules 1 and 2 stop firing.
    func testFingerprint_changesWhenAFeatureIsToggled() {
        sut.configuration.visionEnabled = true
        let before = sut.residencyRelevantSettings
        sut.configuration.visionEnabled = false
        XCTAssertNotEqual(sut.residencyRelevantSettings, before)
    }

    /// BLOCKER, found in review. The judge-override model is ALSO used by the
    /// "Ask AI" advisory on the MANUAL approval card, so gating the slot on
    /// `mode == .auto` unloaded a model Manual mode actively uses — and
    /// `BashJudgeService` is fail-closed, so the next tap could render a benign
    /// command as denied.
    func testReconcile_bashJudgeInManualApproval_keepsItsOverrideModel() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["judge-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        sut.configuration.bashMode = .manual
        sut.configuration.bashRestrictionLevel = .standard
        sut.configuration.bashJudgeLLMOverride = LLMOverride(modelName: "judge-model")
        let ensurer = await managed(["judge-model"], client: client)

        await sut.reconcileAndReportResidency(client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), [],
                       "Manual approval's 'Ask AI' still runs this model")
    }

    /// Found in review. An in-flight LOAD is in neither residency signal — not
    /// yet in the ledger, no open request — so a reconcile racing it would skip
    /// it, and nothing later would sweep it.
    func testReconcile_modelWithALoadInFlight_isTreatedAsBusy() async {
        let client = RecordingLLMClient()
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        let ensurer = ChatModelEnsurer()
        client.loadDelay = .milliseconds(200)

        async let loading: Void = {
            _ = try? await ensurer.ensureLoaded(
                modelName: "slow-model", baseURLString: baseURL, client: client)
        }()

        // Give the ensure time to register before reconciling against it.
        try? await Task.sleep(for: .milliseconds(40))
        let inFlight = await ensurer.hasInFlightEnsure(
            modelName: "slow-model", baseURLString: baseURL)
        XCTAssertTrue(inFlight, "Precondition: the load must still be running")

        await loading
    }

    /// Found in review. Ownership is dropped only when the ledger still holds
    /// the exact instance that was unloaded, so a re-adoption that landed
    /// during the unload's round trip is not erased.
    func testReclaim_doesNotEraseANewerOwnershipRecord() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["m"])
        let ensurer = await managed(["m"], client: client)

        // A second instance of the same model replaces the ledger entry the
        // way a re-adopt during the round trip would.
        await ensurer.adoptExistingInstance(
            modelName: "m", baseURLString: baseURL, instanceID: "m:2")
        let stale = OwnedChatModel(
            modelName: "m", baseURLString: baseURL, instanceID: "m")
        try? await ensurer.reclaim(stale, client: client)

        let remaining = await ensurer.ownedModels()
        XCTAssertEqual(remaining.map(\.instanceID), ["m:2"],
                       "Unloading the OLD instance must not forget the new one")
    }

    // MARK: - Post-unload settle, persistence, message shape

    /// LM Studio acks the unload BEFORE the memory is released (measured: ack
    /// 213 ms, instance gone and ~4 GB returned at 400 ms). Loading the
    /// replacement inside that window fails for want of memory — the reported
    /// "unload doesn't keep up, so nothing ends up loaded".
    func testReclaim_waitsForTheInstanceToActuallyDisappear() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["old-model"])
        let ensurer = await managed(["old-model"], client: client)

        // The listing keeps reporting the instance: reclaim must not return
        // until it is gone (or the settle budget expires).
        let instance = OwnedChatModel(
            modelName: "old-model", baseURLString: baseURL, instanceID: "old-model")
        let started = Date()
        client.listLoadedInstancesResults = []  // server now reports it gone
        try? await ensurer.reclaim(instance, client: client)

        XCTAssertLessThan(
            Date().timeIntervalSince(started), ModelResidencyConstants.unloadSettleTimeout,
            "A settled instance must not burn the whole budget")
        let owned = await ensurer.ownedModels()
        XCTAssertEqual(owned, [], "Ownership is released once the instance is gone")
    }

    /// The ledger is the ONLY thing that permits an unload, so if it does not
    /// survive a relaunch, a model the app loaded last session is orphaned
    /// forever — the exact state that filled memory with two chat models.
    func testLedger_persistsAcrossAnAppRelaunch() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["chat-model"])
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"

        let firstRun = ChatModelEnsurer()
        await sut.adoptResidentReferencedModels(client: client, ensurer: firstRun)
        _ = try? await firstRun.ensureLoaded(
            modelName: "chat-model", baseURLString: baseURL, client: client)

        XCTAssertFalse(sut.configuration.chatModelLedger.isEmpty,
                       "Ownership must be written through to settings")

        // Relaunch: fresh ensurer, same persisted settings. The user has since
        // switched away, so adoption alone would NOT re-claim it.
        sut.configuration.llmModelName = "next-model"
        let secondRun = ChatModelEnsurer()
        await sut.adoptResidentReferencedModels(client: client, ensurer: secondRun)
        client.calls.removeAll()
        client.listLoadedInstancesResults = []
        await sut.reconcileAndReportResidency(client: client, ensurer: secondRun)

        XCTAssertEqual(unloadedIDs(client), ["chat-model"],
                       "A model orphaned in a PREVIOUS session must still be reclaimable")
    }

    /// A persisted entry whose instance is no longer resident must be dropped:
    /// instance ids are deterministic, so a stale record would otherwise claim
    /// an identically-named instance the user hand-loaded after restarting
    /// LM Studio.
    func testLedger_dropsPersistedEntriesWhoseInstanceIsGone() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = []
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.chatModelLedger = [
            OwnedChatModel(modelName: "ghost", baseURLString: baseURL, instanceID: "ghost")
        ]

        let ensurer = ChatModelEnsurer()
        await sut.adoptResidentReferencedModels(client: client, ensurer: ensurer)

        let owned = await ensurer.ownedModels()
        XCTAssertEqual(owned, [], "LM Studio restarted — the record is stale")
    }

    /// `errorDescription` already names the model for the out-of-memory case,
    /// so the caller must not prefix it again ("Couldn't load model 'X':
    /// Couldn't load 'X' — …" reached the user once).
    func testSwitch_outOfMemory_reportsTheMessageOnce() async {
        let client = RecordingLLMClient()
        client.loadError = LLMClientError.badHTTPStatus(
            500, #"{"error":{"type":"model_load_failed","message":"Failed to load LLM 'gemma': insufficient system resources"}}"#)

        await sut.switchChatModel(
            oldModel: "", newModel: "gemma", baseURLString: baseURL,
            client: client, ensurer: ChatModelEnsurer())

        let message = sut.lastErrorMessage ?? ""
        XCTAssertEqual(
            message.components(separatedBy: "Couldn't load").count - 1, 1,
            "The message must not be double-prefixed: \(message)")
    }

    // MARK: - No-ops

    func testSwitch_sameModel_isNoOp() async {
        let client = RecordingLLMClient()

        await sut.switchChatModel(
            oldModel: "same", newModel: "same", baseURLString: baseURL,
            client: client, ensurer: ChatModelEnsurer())

        XCTAssertEqual(client.calls, [])
    }

    func testSwitch_sameModelDifferentCase_isNoOp() async {
        let client = RecordingLLMClient()

        await sut.switchChatModel(
            oldModel: "Qwen/Model", newModel: "qwen/model", baseURLString: baseURL,
            client: client, ensurer: ChatModelEnsurer())

        XCTAssertEqual(client.calls, [])
    }

    func testSwitch_emptyBaseURL_isNoOp() async {
        let client = RecordingLLMClient()

        await sut.switchChatModel(
            oldModel: "a", newModel: "b", baseURLString: "   ",
            client: client, ensurer: ChatModelEnsurer())

        XCTAssertEqual(client.calls, [])
    }

    func testSwitch_newModelAlreadyLoaded_isAdoptedNotReloaded() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["old-model", "new-model"])
        sut.configuration.llmBaseURLString = baseURL
        let ensurer = await managed(["old-model"], client: client)
        sut.configuration.llmModelName = "new-model"

        await sut.switchChatModel(
            oldModel: "old-model", newModel: "new-model", baseURLString: baseURL,
            client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["old-model"])
        XCTAssertEqual(loadedModels(client), [], "An already-loaded target is adopted")
    }

    /// Clearing the model reclaims the old one but has nothing to load.
    func testSwitch_emptyNewModel_reclaimsWithoutLoading() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["old-model"])
        sut.configuration.llmBaseURLString = baseURL
        let ensurer = await managed(["old-model"], client: client)
        sut.configuration.llmModelName = ""

        await sut.switchChatModel(
            oldModel: "old-model", newModel: "", baseURLString: baseURL,
            client: client, ensurer: ensurer)

        XCTAssertEqual(unloadedIDs(client), ["old-model"])
        XCTAssertEqual(loadedModels(client), [])
    }

    // MARK: - Notices

    /// `lastInfoMessage` is a single coalescing slot: a reclaim failure and the
    /// "model ready" note must not clobber each other.
    func testSwitch_reclaimFailure_noticeSurvivesTheModelReadyMessage() async {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = resident(["old-model"])
        sut.configuration.llmBaseURLString = baseURL
        let ensurer = await managed(["old-model"], client: client)
        sut.configuration.llmModelName = "new-model"
        client.unloadError = TestError.boom

        await sut.switchChatModel(
            oldModel: "old-model", newModel: "new-model", baseURLString: baseURL,
            client: client, ensurer: ensurer)

        let info = sut.lastInfoMessage ?? ""
        XCTAssertTrue(info.contains("Couldn't unload"), info)
        XCTAssertTrue(info.contains("new-model"), info)
    }

    func testSwitch_loadFailure_surfacesError() async {
        let client = RecordingLLMClient()
        client.loadError = TestError.boom

        await sut.switchChatModel(
            oldModel: "", newModel: "new-model", baseURLString: baseURL,
            client: client, ensurer: ChatModelEnsurer())

        XCTAssertNotNil(sut.lastErrorMessage)
    }
}

/// One-shot async gate: `wait()` suspends until `open()` is called (and returns
/// immediately once opened). Lets a test freeze a reclaim mid-unload to collide
/// a second reconcile with it deterministically.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
