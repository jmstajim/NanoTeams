import XCTest

@testable import NanoTeams

/// Run-boundary and de-reference residency triggers.
///
/// The settings-change triggers (ModelResidencyHooks, openWorkFolder,
/// teamsChanged, onURLCommit) are pinned in `SwitchChatModelTests`. This suite
/// pins the OTHER half: a model whose reference disappeared while a run was
/// live is deferred by the in-use census, and before these triggers the sweep
/// waited for an unrelated settings change — a bounded deferral turned into an
/// unbounded leak. Four triggers close it:
/// - every engine transition to a non-`.running` state (run end, failure,
///   pause, stop, the acceptance/supervisor parks),
/// - `removeTask` (deletion de-references the task's generated-team models),
/// - `switchTeam` (its `clearGeneratedTeam()` flows through `mutateTask`,
///   invisible to the `teamsChanged` trigger),
/// - `evictIfReclaimable` (scheduler eviction de-references the same way).
final class ResidencyTriggerTests: NTMSOrchestratorTestBase {

    private let baseURL = "http://127.0.0.1:1234"

    private func unloadedIDs() -> [String] {
        chatLifecycleClient.calls.compactMap {
            if case .unload(let id, _) = $0 { return id } else { return nil }
        }
    }

    private func resident(_ names: [String]) -> [LoadedModelInstance] {
        names.map { LoadedModelInstance(modelName: $0, instanceID: $0) }
    }

    /// Establishes ownership of `model` on the orchestrator's own ensurer the
    /// way production does — by using it.
    private func manage(_ model: String) async {
        chatLifecycleClient.listLoadedInstancesResults = resident([model])
        _ = try? await sut.chatModelEnsurer.ensureLoaded(
            modelName: model, baseURLString: baseURL, client: chatLifecycleClient)
        chatLifecycleClient.calls.removeAll()
    }

    /// A single-role generated team whose role pins `model` via override —
    /// the reference that only exists while the owning task is loaded.
    private func makeGeneratedTeam(model: String) -> Team {
        var role = TeamRoleDefinition(
            id: "gen_worker", name: "Worker", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: ["Out"])
        )
        role.llmOverride = LLMOverride(modelName: model)
        return Team(
            id: "gen_t", name: "Gen", roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - Engine-transition sweep (the run-end trigger)

    /// The core deferral-then-sweep scenario: a model de-referenced mid-run is
    /// protected by the open-request census; the run ending is what must
    /// release it — not a later, unrelated settings change.
    func testEngineTransition_nonRunning_sweepsAModelDereferencedMidRun() async {
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("orphan")
        await sut.chatModelEnsurer.beginRequest(modelName: "orphan", baseURLString: baseURL)

        await sut.reconcileAndReportResidency(
            client: chatLifecycleClient, ensurer: sut.chatModelEnsurer)
        XCTAssertEqual(unloadedIDs(), [], "An open stream defers the reclaim")

        await sut.chatModelEnsurer.endRequest(modelName: "orphan", baseURLString: baseURL)
        await sut.sweepResidencyAfterEngineTransition(.done)?.value

        XCTAssertEqual(unloadedIDs(), ["orphan"],
                       "The run ending must sweep what the census deferred")
    }

    func testEngineTransition_toRunning_firesNoSweep() async {
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("orphan")

        XCTAssertNil(sut.sweepResidencyAfterEngineTransition(.running),
                     "A run STARTING is not a residency boundary")
        XCTAssertEqual(unloadedIDs(), [])
    }

    /// `stop()` transitions to `.pending` — close/removal/recurrence supersede
    /// all route through it, so the stop path must sweep too.
    func testEngineTransition_stopToPending_sweeps() async {
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("orphan")

        await sut.sweepResidencyAfterEngineTransition(.pending)?.value

        XCTAssertEqual(unloadedIDs(), ["orphan"])
    }

    /// Wiring smoke test: the sweep must actually be reachable from an engine
    /// transition, not just callable directly.
    func testEngineWiring_terminalTransition_firesSweep() async {
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("orphan")

        let engine = sut.engineForTask(42)
        engine.onStateChanged?(.done)

        // The wired sweep is fire-and-forget; poll briefly for its effect.
        for _ in 0..<200 where unloadedIDs().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(unloadedIDs(), ["orphan"],
                       "engineForTask's onStateChanged must fire the sweep")
    }

    // MARK: - Reference guard for the ACTIVE task's generated team

    /// The active task is deliberately absent from `loadedTasks`
    /// (`loadedTask()` special-cases it), so the generated-team reference
    /// loop over `loadedTasks` alone missed it — a reconcile would have swept
    /// the ACTIVE task's generated-roster model mid-run.
    func testReconcile_generatedTeamOnTheActiveTask_keepsItsModel() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("createTask failed")
            return
        }
        await sut.mutateTask(taskID: taskID) { task in
            task.adoptGeneratedTeam(self.makeGeneratedTeam(model: "gen-model"))
        }
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("gen-model")

        await sut.reconcileAndReportResidency(
            client: chatLifecycleClient, ensurer: sut.chatModelEnsurer)

        XCTAssertEqual(unloadedIDs(), [],
                       "The active task's generated roster references the model")
    }

    // MARK: - Model-specific in-use guard (#3: don't thrash a running step's model)

    /// A model a LIVE step captured must not be reclaimed even when it is
    /// unreferenced by any slot and the census is empty (a tool-execution gap
    /// opens no chat request). This is MODEL-SPECIFIC — a step on model B never
    /// pins model A — so it does not reintroduce the model-agnostic
    /// `hasLiveExecutions` guard c70ec54 deleted.
    func testReconcile_modelUsedByALiveStep_isNotReclaimedEvenWhenUnreferenced() async {
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"  // "captured" is unreferenced
        await manage("captured")
        // A live step resolved its effective config to this exact model; no
        // open request right now (mid tool run).
        sut.llmExecutionService._testSetActiveModel(
            stepID: "role", taskID: 1, base: baseURL, model: "captured")

        await sut.reconcileAndReportResidency(
            client: chatLifecycleClient, ensurer: sut.chatModelEnsurer)
        XCTAssertEqual(unloadedIDs(), [],
                       "A live step is still using this exact model across its tool gaps")

        // Step ends → model no longer pinned → reclaimed.
        sut.llmExecutionService.clearRunningTask(stepID: "role", taskID: 1)
        await sut.reconcileAndReportResidency(
            client: chatLifecycleClient, ensurer: sut.chatModelEnsurer)
        XCTAssertEqual(unloadedIDs(), ["captured"],
                       "Once the step ends the unreferenced model is reclaimed")
    }

    // MARK: - Silent background sweeps (#7: no banner spam)

    /// A background sweep (fired on every non-.running engine transition) whose
    /// unload fails must NOT post to `lastInfoMessage` — reclaim keeps ownership
    /// to retry, so a persistently-failing unload would otherwise re-post its
    /// banner on every chat-turn park / pause / completion, clobbering the
    /// single info slot. Residency failures still surface on settings paths.
    func testEngineTransitionSweep_failingUnload_isSilent() async {
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("orphan")
        chatLifecycleClient.unloadError = TestError.boom
        sut.lastInfoMessage = nil

        await sut.sweepResidencyAfterEngineTransition(.done)?.value

        XCTAssertNil(sut.lastInfoMessage,
                     "A background sweep must not surface unload failures as a banner")
        XCTAssertTrue(chatLifecycleClient.calls.contains {
            if case .unload = $0 { return true }; return false
        }, "Sanity: it did attempt the unload")
    }

    // MARK: - evictIfReclaimable contract (#8)

    /// `evictIfReclaimable` for a task not present in `loadedTasks` must be a
    /// true no-op — no eviction, no sweep Task — matching its documented "nil
    /// when nothing was evicted" contract (`evictLoadedTask` is an
    /// unconditional removeValue, so the membership guard is what makes it true).
    func testEvictIfReclaimable_taskNotLoaded_returnsNilNoSweep() async {
        await sut.openWorkFolder(tempDir)
        let sweep = sut.evictIfReclaimable(999_999)
        XCTAssertNil(sweep, "Nothing was loaded to evict — no reconcile should be spawned")
    }

    // MARK: - removeTask

    func testRemoveTask_sweepsModelsOnlyItsGeneratedTeamReferenced() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("createTask failed")
            return
        }
        await sut.mutateTask(taskID: taskID) { task in
            task.adoptGeneratedTeam(self.makeGeneratedTeam(model: "gen-model"))
        }
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("gen-model")

        await sut.reconcileAndReportResidency(
            client: chatLifecycleClient, ensurer: sut.chatModelEnsurer)
        XCTAssertEqual(unloadedIDs(), [],
                       "The loaded task's generated team still references the model")

        await sut.removeTask(taskID)

        XCTAssertEqual(unloadedIDs(), ["gen-model"],
                       "Deleting the task is the de-reference — it must sweep")
    }

    // MARK: - switchTeam (clearGeneratedTeam flows through mutateTask)

    func testSwitchTeam_clearingGeneratedTeam_sweepsItsModels() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("createTask failed")
            return
        }
        await sut.mutateTask(taskID: taskID) { task in
            task.adoptGeneratedTeam(self.makeGeneratedTeam(model: "gen-model"))
        }
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("gen-model")
        guard let realTeamID = sut.snapshot?.projection.teams.first?.id else {
            XCTFail("No folder team to switch to")
            return
        }

        await sut.switchTeam(to: realTeamID)

        XCTAssertEqual(unloadedIDs(), ["gen-model"],
                       "Team switch cleared the generated roster — its model is orphaned")
    }

    // MARK: - evictIfReclaimable

    func testEvictIfReclaimable_evictedBackgroundTask_sweepsItsModels() async {
        await sut.openWorkFolder(tempDir)
        guard let bgID = await sut.createTask(title: "BG", supervisorTask: "G") else {
            XCTFail("createTask failed")
            return
        }
        await sut.mutateTask(taskID: bgID) { task in
            task.adoptGeneratedTeam(self.makeGeneratedTeam(model: "gen-model"))
        }
        // A second task takes over as active; BG stays loaded in the background.
        guard await sut.createTask(title: "FG", supervisorTask: "G") != nil else {
            XCTFail("createTask failed")
            return
        }
        sut.configuration.llmBaseURLString = baseURL
        sut.configuration.llmModelName = "chat-model"
        await manage("gen-model")

        await sut.reconcileAndReportResidency(
            client: chatLifecycleClient, ensurer: sut.chatModelEnsurer)
        XCTAssertEqual(unloadedIDs(), [],
                       "Still loaded in the background — still referenced")

        await sut.evictIfReclaimable(bgID)?.value

        XCTAssertEqual(unloadedIDs(), ["gen-model"],
                       "Scheduler eviction is a de-reference — it must sweep")
    }

    func testEvictIfReclaimable_activeTask_notEvicted_noSweep() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("createTask failed")
            return
        }

        XCTAssertNil(sut.evictIfReclaimable(taskID),
                     "The active task is never evicted, so nothing de-references")
        XCTAssertNotNil(sut.loadedTask(taskID))
    }
}
