import XCTest
@testable import NanoTeams

/// Lightweight regression guards for `NTMSOrchestrator+TeamGeneration` that don't
/// require a running LLM. The full streaming flow is exercised in
/// `TeamGenerationServiceStreamTests`; these tests pin the contracts that bridge
/// the service output to the in-memory task state.
@MainActor
final class TeamGenerationOrchestratorTests: NTMSOrchestratorTestBase {

    // MARK: - Placeholder-string consistency (catches drift between files)

    /// `runTeamGeneration` writes a placeholder result of the form `{ok:true,status:"generating"}`
    /// and `StepToolCall.isGeneratingTeam` checks for `"status":"generating"`. These live in
    /// separate files; if either drifts, the graph spinner would never appear. Pin both.
    func testGeneratingEnvelope_matchesIsGeneratingTeamMarker() {
        let envelope = NTMSOrchestrator._testGeneratingEnvelope()

        // Build a tool call whose result is the orchestrator's actual placeholder.
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: "{}",
            resultJSON: envelope,
            isError: false
        )

        XCTAssertTrue(call.isGeneratingTeam,
                      "StepToolCall.isGeneratingTeam must recognize the orchestrator's placeholder envelope: \(envelope)")
    }

    /// Final success envelope must NOT match `isGeneratingTeam` (otherwise the spinner
    /// would persist forever after generation completed).
    func testSuccessEnvelope_doesNotMatchGeneratingMarker() {
        let team = Team(
            id: "t1", name: "T", roles: [], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let envelope = NTMSOrchestrator._testSuccessEnvelope(team: team)

        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: "{}",
            resultJSON: envelope,
            isError: false
        )

        XCTAssertFalse(call.isGeneratingTeam)
    }

    /// Error envelope must surface the underlying message so the GraphPanelView retry
    /// overlay can render something useful (`generationErrorMessage` parses this).
    func testErrorEnvelope_carriesMessage() {
        let envelope = NTMSOrchestrator._testErrorEnvelope(message: "Connection refused")
        XCTAssertTrue(envelope.contains("Connection refused"))
        XCTAssertTrue(envelope.contains("\"ok\":false"))
    }

    // MARK: - applyGeneratedTeamSuccess: re-pin run.teamID (Part 1 of the gen-team pin fix)

    /// On generation success the run must be RE-PINNED from the transient
    /// "Generated Team" placeholder id to the real generated team's id. Without
    /// this, `findOrCreateStep`'s roster-swap guard rejects every generated role
    /// (run 0 pinned to the placeholder → "not a member"; the placeholder has no
    /// roster). Also adopts the team, finalizes the step, and propagates the id
    /// into `TaskSummary.pinnedTeamID` (the deletion-guard input).
    func testApplyGeneratedTeamSuccess_repinsRunTeamID_finalizesStep_andAdopts() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build something") else {
            XCTFail("createTask returned nil"); return
        }

        // Mirror runTeamGeneration step 1: a run pinned to the placeholder id with
        // a synthetic create_team step in the "generating" state.
        let placeholderID = NTMSID.from(name: "Generated Team")
        let stepID = "team_generation_TEST"
        let toolCallID = UUID()
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: placeholderID)
            run.steps = [StepExecution(
                id: stepID, role: .supervisor, title: "Generate Team", status: .running,
                toolCalls: [StepToolCall(
                    id: toolCallID, name: ToolNames.createTeam, argumentsJSON: "{}",
                    resultJSON: NTMSOrchestrator._testGeneratingEnvelope(), isError: false)])]
            task.runs = [run]
        }

        // The real generated team (NOT in workFolder.teams), one ready worker role.
        let genID = NTMSID.from(name: "gen_\(UUID().uuidString)")
        let genTeam = Team(
            id: genID, name: "Gen Team", description: "",
            roles: [TeamRoleDefinition(id: "gen_worker", name: "Worker", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())

        await sut.applyGeneratedTeamSuccess(
            taskID: taskID, team: genTeam, stepID: stepID, toolCallID: toolCallID, warnings: [])

        let run = sut.loadedTask(taskID)?.runs.last
        XCTAssertEqual(run?.teamID, genID,
                       "run.teamID must be re-pinned from the placeholder to the generated team's id")
        XCTAssertEqual(sut.loadedTask(taskID)?.generatedTeam?.id, genID, "generated team must be adopted")
        XCTAssertEqual(sut.loadedTask(taskID)?.toSummary().pinnedTeamID, genID,
                       "summary.pinnedTeamID must carry the generated id (deletion-guard input)")
        let step = run?.steps.first(where: { $0.id == stepID })
        XCTAssertEqual(step?.status, .done, "generation step must be finalized to .done")
        XCTAssertFalse(step?.toolCalls.first?.isError ?? true, "create_team tool call must be marked success")
        XCTAssertEqual(run?.roleStatuses["gen_worker"], .ready,
                       "a no-dependency worker must be seeded .ready by the shared seeding helper")
    }

    /// Retry / regeneration: the run is pinned to a PRIOR generation's `_gen_` id
    /// while a NEW team (different id) is produced. The re-pin must OVERWRITE the
    /// stale pin with the new team's id. Seeding a stale pin distinct from the new
    /// id is what makes this catch a deleted re-pin (an `== genID` pre-state could
    /// not — pinned by review #12).
    func testApplyGeneratedTeamSuccess_overwritesStalePriorGenPin() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build") else {
            XCTFail("createTask returned nil"); return
        }

        let newGenID = NTMSID.from(name: "gen_new_\(UUID().uuidString)")
        let stalePriorGenID = NTMSID.from(name: "gen_old_\(UUID().uuidString)")
        XCTAssertNotEqual(newGenID, stalePriorGenID, "Test setup: stale and new ids must differ")
        let genTeam = Team(
            id: newGenID, name: "Gen Team", description: "",
            roles: [TeamRoleDefinition(id: "gen_worker", name: "Worker", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())

        let stepID = "team_generation_RETRY"
        let toolCallID = UUID()
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: stalePriorGenID)   // pinned to a PRIOR generation
            run.steps = [StepExecution(
                id: stepID, role: .supervisor, title: "Generate Team", status: .running,
                toolCalls: [StepToolCall(
                    id: toolCallID, name: ToolNames.createTeam, argumentsJSON: "{}",
                    resultJSON: NTMSOrchestrator._testGeneratingEnvelope(), isError: false)])]
            task.runs = [run]
        }

        let applied = await sut.applyGeneratedTeamSuccess(
            taskID: taskID, team: genTeam, stepID: stepID, toolCallID: toolCallID, warnings: [])

        XCTAssertTrue(applied, "the mutation landed (run + step present)")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.teamID, newGenID,
                       "re-pin must OVERWRITE the stale prior-generation pin with the new team's id — deleting the re-pin would leave the old id and fail this")
        XCTAssertEqual(sut.loadedTask(taskID)?.generatedTeam?.id, newGenID)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .done)
    }

    /// Teardown / task-switch race: the generation step is gone before the success
    /// mutation lands. `applyGeneratedTeamSuccess` must return `false` and NOT adopt
    /// the team (CLAUDE.md §7: mutateTask==true means "persisted", not "did
    /// something"); the caller then keeps the engine from starting on a non-adopted
    /// placeholder-pinned team.
    func testApplyGeneratedTeamSuccess_missingStep_returnsFalse_doesNotAdopt() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build") else {
            XCTFail("createTask returned nil"); return
        }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, teamID: NTMSID.from(name: "placeholder"))]  // no generation step
        }
        let genTeam = Team(
            id: NTMSID.from(name: "gen_\(UUID().uuidString)"), name: "Gen", description: "",
            roles: [TeamRoleDefinition(id: "gen_w", name: "W", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())

        let applied = await sut.applyGeneratedTeamSuccess(
            taskID: taskID, team: genTeam, stepID: "team_generation_MISSING",
            toolCallID: UUID(), warnings: [])

        XCTAssertFalse(applied, "a missing generation step must report failure, not silent success")
        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam,
                     "the team must NOT be adopted when the success mutation can't land")
    }

    // MARK: - switchTeam abandons a stale generated team (review #1/#2/#3 root cause)

    /// Switching a generated-team task to a real team must CLEAR `task.generatedTeam`.
    /// Otherwise `TeamResolution` (generatedTeam-first) keeps resolving the old
    /// generated roster for `makeStep` / `buildChatMessages` while the run is
    /// re-pinned to the new team — a dead run + wrong prompt. Also aligns the task's
    /// chat mode to the switched-to team.
    func testSwitchTeam_clearsStaleGeneratedTeam_andAdoptsTargetChatMode() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "...") else {
            XCTFail("createTask returned nil"); return
        }

        let genID = NTMSID.from(name: "gen_\(UUID().uuidString)")
        let genTeam = Team(
            id: genID, name: "Gen", description: "",
            roles: [TeamRoleDefinition(id: "gen_w", name: "Assistant", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        // A real folder team whose chat mode DIFFERS from the generated team — makes
        // the chat-mode assertion catch a missing setStoredChatMode.
        guard let target = sut.workFolder?.teams.first(where: {
            $0.templateID != "generated" && !$0.isManagedSingleton && $0.isChatMode != genTeam.isChatMode
        }) else { XCTFail("need a real team with the opposite chat mode"); return }

        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, teamID: genID)]
            task.adoptGeneratedTeam(genTeam)
        }
        await sut.switchTask(to: taskID)   // switchTeam operates on the active task
        XCTAssertNotNil(sut.loadedTask(taskID)?.generatedTeam, "precondition: generated team set")

        await sut.switchTeam(to: target.id)

        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam,
                     "switchTeam must clear the stale generated team so resolution stops preferring it")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.teamID, target.id,
                       "the run is re-pinned to the switched-to team")
        XCTAssertEqual(sut.loadedTask(taskID)?.isChatMode, target.isChatMode,
                       "task chat mode must align with the switched-to team after the generated team is cleared")
    }

    /// END-TO-END regression for the review's CONFIRMED dead-run (#1): after
    /// switching a generated-team task to a real team, `findOrCreateStep` must mint
    /// the real team's role. Pre-fix, `switchTeam` left `task.generatedTeam` set, so
    /// the guard validated the role against the (pinned) real team but `makeStep`
    /// resolved the STALE generated team (TeamResolution generatedTeam-first) and
    /// returned nil → the role failed and the whole run was dead.
    func testSwitchTeamFromGenerated_thenFindOrCreateStep_mintsTargetRole() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "...") else {
            XCTFail("createTask returned nil"); return
        }

        let genID = NTMSID.from(name: "gen_\(UUID().uuidString)")
        let genTeam = Team(
            id: genID, name: "Gen", description: "",
            roles: [TeamRoleDefinition(id: "gen_only", name: "GenRole", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        guard let target = sut.workFolder?.teams.first(where: { t in
            t.templateID != "generated" && !t.isManagedSingleton && t.roles.contains { !$0.isSupervisor }
        }), let targetRoleID = target.roles.first(where: { !$0.isSupervisor })?.id else {
            XCTFail("need a real team with a non-supervisor role"); return
        }
        XCTAssertNil(genTeam.findRole(byIdentifier: targetRoleID),
                     "Test setup: target role absent from the generated team (so a stale generatedTeam would fail makeStep)")

        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, teamID: genID)]
            task.adoptGeneratedTeam(genTeam)
        }
        await sut.switchTask(to: taskID)
        await sut.switchTeam(to: target.id)

        let stepID = await sut.findOrCreateStep(taskID: taskID, roleID: targetRoleID)
        XCTAssertNotNil(stepID,
                        "After switching off a generated team, the target team's role must mint a step — the dead run is fixed")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.count, 1)
    }

    /// `clearGeneratedTeam()` on switch must be a safe no-op for a NON-generated
    /// task: the switch still re-pins + aligns chat mode, generatedTeam stays nil.
    func testSwitchTeam_nonGeneratedTask_generatedTeamStaysNil() async {
        await sut.openWorkFolder(tempDir)
        guard let reals = sut.workFolder?.teams.filter({ $0.templateID != "generated" && !$0.isManagedSingleton }),
              reals.count >= 2 else { XCTFail("need 2 real teams"); return }
        let t1 = reals[0], t2 = reals[1]
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "...", preferredTeamID: t1.id) else {
            XCTFail("createTask returned nil"); return
        }
        await sut.mutateTask(taskID: taskID) { task in task.runs = [Run(id: 0, teamID: t1.id)] }
        await sut.switchTask(to: taskID)
        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam, "precondition: no generated team")

        await sut.switchTeam(to: t2.id)

        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam, "clearGeneratedTeam is a safe no-op for a non-generated task")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.teamID, t2.id, "run re-pinned to the switched-to team")
        XCTAssertEqual(sut.loadedTask(taskID)?.isChatMode, t2.isChatMode, "chat mode aligns to the switched-to team")
    }

    /// `applyGeneratedTeamSuccess` adopt/re-pin are the contract; the tool-call
    /// envelope update is best-effort. An unmatched `toolCallID` (step present)
    /// must still adopt, re-pin, finalize the step, and return true.
    func testApplyGeneratedTeamSuccess_wrongToolCallID_stillAdoptsAndRepins() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build") else {
            XCTFail("createTask returned nil"); return
        }
        let genID = NTMSID.from(name: "gen_\(UUID().uuidString)")
        let genTeam = Team(
            id: genID, name: "Gen", description: "",
            roles: [TeamRoleDefinition(id: "gen_w", name: "W", prompt: "", toolIDs: [],
                                       usePlanningPhase: false, dependencies: RoleDependencies())],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        let stepID = "team_generation_WTC"
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: NTMSID.from(name: "placeholder"))
            run.steps = [StepExecution(
                id: stepID, role: .supervisor, title: "Generate Team", status: .running,
                toolCalls: [StepToolCall(
                    id: UUID(), name: ToolNames.createTeam, argumentsJSON: "{}",
                    resultJSON: NTMSOrchestrator._testGeneratingEnvelope(), isError: false)])]
            task.runs = [run]
        }

        let applied = await sut.applyGeneratedTeamSuccess(
            taskID: taskID, team: genTeam, stepID: stepID, toolCallID: UUID(), warnings: [])

        XCTAssertTrue(applied, "the step exists → the mutation lands even if the toolCall id doesn't match")
        XCTAssertEqual(sut.loadedTask(taskID)?.generatedTeam?.id, genID, "team adopted regardless of toolCall match")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.teamID, genID, "run re-pinned regardless of toolCall match")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .done, "step finalized")
        XCTAssertTrue(sut.loadedTask(taskID)?.runs.last?.steps.first?.toolCalls.first?.isGeneratingTeam ?? false,
                      "an unmatched toolCall keeps its generating placeholder — envelope update is best-effort")
    }

    // MARK: - retryTeamGeneration removes prior generation steps

    /// `retryTeamGeneration` must clear any prior `create_team` step from the latest
    /// run before re-running generation, otherwise multiple stacked steps appear.
    func testRetryTeamGeneration_removesPriorGenerationStep() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build something") else {
            XCTFail("createTask returned nil")
            return
        }
        // Inject a synthetic prior generation step (simulating a failed attempt).
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [
                StepExecution(
                    id: "team_generation_PRIOR",
                    role: .supervisor,
                    title: "Generate Team",
                    status: .failed,
                    toolCalls: [
                        StepToolCall(
                            name: ToolNames.createTeam,
                            argumentsJSON: "{}",
                            resultJSON: #"{"ok":false,"error":{"message":"prior"}}"#,
                            isError: true
                        )
                    ]
                )
            ], roleStatuses: [:])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        // Sanity: prior step exists.
        XCTAssertEqual(sut.activeTask?.runs.last?.steps.count, 1)

        // Retry. We don't have a generated team configured (preferredTeamID is nil),
        // so retryTeamGeneration's `needsTeamGeneration` guard short-circuits before
        // touching the LLM — but the cleanup step still removes the prior step.
        await sut.retryTeamGeneration(taskID: taskID)

        let stepsAfter = sut.activeTask?.runs.last?.steps ?? []
        XCTAssertFalse(
            stepsAfter.contains { step in step.toolCalls.contains { $0.name == ToolNames.createTeam } },
            "Prior create_team step should be cleared before retry"
        )
    }

    // MARK: - needsTeamGeneration gate

    func testNeedsTeamGeneration_falseForNormalTask() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        // No preferred team set — defaults to nil — should not need generation.
        XCTAssertFalse(sut.needsTeamGeneration(taskID: taskID))
    }

    func testNeedsTeamGeneration_falseWhenTaskAlreadyHasGeneratedTeam() async {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let generatedTemplate = sut.workFolder?.teams.first(where: { $0.templateID == "generated" }) else {
            XCTFail("Expected a generated template after seeding"); return
        }
        guard let taskID = await sut.createTask(
            title: "T", supervisorTask: "do",
            preferredTeamID: generatedTemplate.id
        ) else {
            XCTFail("createTask returned nil"); return
        }
        // Initially needs generation.
        XCTAssertTrue(sut.needsTeamGeneration(taskID: taskID))

        // After adopting a team, no longer needs generation.
        let adoptedTeam = Team(
            id: "adopted", name: "Adopted", roles: [
                TeamRoleDefinition(id: "sup", name: "Supervisor", prompt: "",
                                   toolIDs: [], usePlanningPhase: false,
                                   dependencies: RoleDependencies())
            ], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(adoptedTeam) }
        XCTAssertFalse(sut.needsTeamGeneration(taskID: taskID))
    }

    func testNeedsTeamGeneration_trueOnlyForGeneratedTemplate() async {
        await sut.openWorkFolder(tempDir)
        // Pick a NON-generated team — needs generation should be false even with preferred.
        guard let normalTemplate = sut.workFolder?.teams.first(where: { $0.templateID != "generated" }) else {
            XCTFail("Expected a non-generated template"); return
        }
        guard let taskID = await sut.createTask(
            title: "T", supervisorTask: "do",
            preferredTeamID: normalTemplate.id
        ) else {
            XCTFail("createTask returned nil"); return
        }
        XCTAssertFalse(sut.needsTeamGeneration(taskID: taskID),
                       "Non-generated templates should never need generation")
    }

    // MARK: - saveGeneratedTeam lifecycle

    func testSaveGeneratedTeam_movesTeamToWorkfolderAndClearsTransient() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        let team = Team(
            id: "gen_xyz", name: "MyGenTeam", roles: [
                TeamRoleDefinition(id: "sup", name: "Supervisor", prompt: "",
                                   toolIDs: [], usePlanningPhase: false,
                                   dependencies: RoleDependencies())
            ], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(team) }

        let priorTeamCount = sut.workFolder?.teams.count ?? 0
        await sut.saveGeneratedTeam(taskID: taskID)

        // Team is now persisted, transient cleared, preferredTeamID rewired.
        XCTAssertEqual(sut.workFolder?.teams.count, priorTeamCount + 1, "Team should be appended to workfolder")
        XCTAssertTrue(sut.workFolder?.teams.contains { $0.id == "gen_xyz" } ?? false)
        XCTAssertNil(sut.activeTask?.generatedTeam, "Transient generatedTeam should be cleared")
        XCTAssertEqual(sut.activeTask?.preferredTeamID, "gen_xyz", "preferredTeamID should be rewired to saved team")
        XCTAssertNotNil(sut.lastInfoMessage, "Save should surface a confirmation message")
    }

    /// After saving a generated team with a Supervisor deliverable, the task's
    /// `isChatMode` must reflect the saved team (not the Generated Team template
    /// default that was frozen at task creation).
    func testSaveGeneratedTeam_syncsTaskChatMode_fromSavedTeam() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        let supervisorWithDeliverable = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final"],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        let team = Team(
            id: "gen_non_chat", name: "NonChat", roles: [supervisorWithDeliverable],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        XCTAssertFalse(team.isChatMode, "Sanity: supervisor with deliverables is not chat mode")

        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(team) }
        await sut.saveGeneratedTeam(taskID: taskID)

        guard let saved = sut.activeTask else {
            XCTFail("activeTask should survive saveGeneratedTeam"); return
        }
        XCTAssertNil(saved.generatedTeam)
        XCTAssertFalse(saved.isChatMode,
                       "Task must not snap back to chat mode after the generated team is cleared")
    }

    func testSaveGeneratedTeam_noOpWhenNoGeneratedTeam() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        let priorTeamCount = sut.workFolder?.teams.count ?? 0
        await sut.saveGeneratedTeam(taskID: taskID)
        XCTAssertEqual(sut.workFolder?.teams.count, priorTeamCount, "No team should be appended")
    }

    // MARK: - Concurrency guards (beginTeamGeneration / cancelTeamGeneration)

    /// `beginTeamGeneration` is the atomic reserve primitive. First call wins,
    /// repeat calls return `false` until `endTeamGeneration` releases the slot.
    func testBeginTeamGeneration_firstCallReservesSlot_secondReturnsFalse() {
        XCTAssertFalse(sut.isGeneratingTeam(taskID: 42))
        XCTAssertTrue(sut.beginTeamGeneration(taskID: 42), "first call should reserve the slot")
        XCTAssertTrue(sut.isGeneratingTeam(taskID: 42))

        XCTAssertFalse(sut.beginTeamGeneration(taskID: 42), "second call should no-op while reserved")

        // Different taskID is independent.
        XCTAssertTrue(sut.beginTeamGeneration(taskID: 99))

        sut.endTeamGeneration(taskID: 42)
        XCTAssertFalse(sut.isGeneratingTeam(taskID: 42))
        XCTAssertTrue(sut.beginTeamGeneration(taskID: 42), "after release, slot should be available again")
        sut.endTeamGeneration(taskID: 42)
        sut.endTeamGeneration(taskID: 99)
    }

    /// While team generation is in flight for a task, `startRun` must short-circuit
    /// before creating a new run — otherwise the placeholder Supervisor step gets
    /// wiped and a second concurrent `runTeamGeneration` spawns.
    func testStartRun_whileTeamGenerationInFlight_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let generatedTemplate = sut.workFolder?.teams.first(where: { $0.templateID == "generated" }) else {
            XCTFail("Expected a generated template after seeding"); return
        }
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: "build something",
            preferredTeamID: generatedTemplate.id
        ) else { XCTFail("createTask returned nil"); return }

        let runCountBefore = sut.activeTask?.runs.count ?? 0

        // Simulate in-flight generation without actually spawning the LLM stream.
        XCTAssertTrue(sut.beginTeamGeneration(taskID: taskID))
        defer { sut.endTeamGeneration(taskID: taskID) }

        await sut.startRun(taskID: taskID)

        let runCountAfter = sut.activeTask?.runs.count ?? 0
        XCTAssertEqual(runCountAfter, runCountBefore,
                       "startRun must not create a new run while generation is in flight")
        XCTAssertNil(sut.taskEngines[taskID],
                     "startRun must not spawn an engine while generation is in flight")
    }

    /// Double-clicking Retry must surface an info banner instead of silently dropping.
    func testRetryTeamGeneration_whileGenerationInFlight_setsInfoMessage() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }

        // Simulate an already-running generation.
        XCTAssertTrue(sut.beginTeamGeneration(taskID: taskID))
        defer { sut.endTeamGeneration(taskID: taskID) }

        sut.lastInfoMessage = nil
        await sut.retryTeamGeneration(taskID: taskID)

        XCTAssertNotNil(sut.lastInfoMessage)
        XCTAssertTrue(sut.lastInfoMessage?.contains("already in progress") == true,
                      "expected 'already in progress' in info message, got: \(sut.lastInfoMessage ?? "nil")")
    }

    /// The `loadedTask(taskID) == nil` early-return must surface an error message
    /// so the caller can't mistake silence for success.
    func testRunTeamGeneration_taskNotLoaded_setsLastErrorMessage() async {
        await sut.openWorkFolder(tempDir)

        sut.lastErrorMessage = nil
        let ok = await sut.runTeamGeneration(taskID: 9999)

        XCTAssertFalse(ok)
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.lastErrorMessage?.contains("not loaded") == true,
                      "expected 'not loaded' in error message, got: \(sut.lastErrorMessage ?? "nil")")
    }

    /// `pauseRun` must cancel an in-flight generation Task so the detached Task's
    /// `guard !Task.isCancelled` skips `engine.start()` and its `defer` releases
    /// the reserve flag.
    func testPauseRun_cancelsInFlightTeamGeneration() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }

        // Stand in for the real detached team-generation Task: sleep long enough
        // that cooperative cancellation is the only way the Task exits quickly.
        let cancellationObserved = XCTestExpectation(description: "Task observed cancellation")
        let syntheticTask = Task { @MainActor [weak sut] in
            defer { sut?.endTeamGeneration(taskID: taskID) }
            do {
                try await Task.sleep(for: .seconds(5)) // 5s — test fails before this if not cancelled.
            } catch {
                cancellationObserved.fulfill()
            }
        }

        XCTAssertTrue(sut.beginTeamGeneration(taskID: taskID))
        sut.registerTeamGenerationTask(taskID: taskID, task: syntheticTask)
        XCTAssertTrue(sut.isGeneratingTeam(taskID: taskID))

        await sut.pauseRun(taskID: taskID)

        await fulfillment(of: [cancellationObserved], timeout: 2.0)

        // Let the task's `defer` run on the MainActor.
        await syntheticTask.value
        XCTAssertFalse(sut.isGeneratingTeam(taskID: taskID),
                       "reserve flag should be released after the cancelled Task's defer runs")
    }

    /// Defensive: registering a handle without a prior `beginTeamGeneration` must
    /// NOT mark the slot as in-flight, but cancellation should still work.
    func testRegisterTeamGenerationTask_withoutBegin_doesNotLeakFlag() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }

        let cancelled = XCTestExpectation(description: "task cancelled")
        let syntheticTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelled.fulfill()
            }
        }
        sut.registerTeamGenerationTask(taskID: taskID, task: syntheticTask)

        XCTAssertFalse(sut.isGeneratingTeam(taskID: taskID),
                       "registering a handle without begin must not flip the in-flight flag")

        sut.cancelTeamGeneration(taskID: taskID)
        await fulfillment(of: [cancelled], timeout: 2.0)
        await syntheticTask.value
    }

    func testSaveGeneratedTeam_idempotentOnRepeatedCalls() async {
        // Calling save twice should not duplicate the team in the workfolder.
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        let team = Team(
            id: "gen_dup", name: "Dup", roles: [
                TeamRoleDefinition(id: "sup", name: "Supervisor", prompt: "",
                                   toolIDs: [], usePlanningPhase: false,
                                   dependencies: RoleDependencies())
            ], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(team) }

        await sut.saveGeneratedTeam(taskID: taskID)
        let countAfterFirst = sut.workFolder?.teams.filter { $0.id == "gen_dup" }.count ?? 0

        // Second call: no generatedTeam to save (already cleared), should no-op.
        await sut.saveGeneratedTeam(taskID: taskID)
        let countAfterSecond = sut.workFolder?.teams.filter { $0.id == "gen_dup" }.count ?? 0

        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(countAfterSecond, 1, "Repeated save must not duplicate")
    }

    // MARK: - Chat mode is never seeded from the placeholder

    /// The Generated Team placeholder is VACUOUSLY chat-mode (no roles ⇒ its Supervisor
    /// requires no artifacts), and `createTask` used to copy that straight onto the task.
    /// Nothing on the generation-failure path ever rewrites `storedIsChatMode`, so a task
    /// whose generation failed reported `chat_mode: true` forever — to the Autovisor,
    /// whose prompt answers that with `control_task close`.
    ///
    /// Both surfaces are asserted because they have DIFFERENT readers: `task_status`
    /// loads the task, while `list_tasks` reads the index summary and never loads
    /// anything.
    func testCreateTask_onGeneratedPlaceholder_isNotChatMode_onTaskAndIndex() async {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let placeholder = sut.workFolder?.teams.first(where: { $0.isGeneratedPlaceholder })
        else { XCTFail("seedGeneratedTemplate did not install the placeholder"); return }
        XCTAssertTrue(
            placeholder.isChatMode,
            "precondition: the placeholder IS vacuously chat-mode — that is the trap")

        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: "build a calculator", preferredTeamID: placeholder.id)
        else { XCTFail("createTask returned nil"); return }

        XCTAssertEqual(
            sut.loadedTask(taskID)?.isChatMode, false,
            "task.json must not inherit the placeholder's vacuous chat mode")
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode, false,
            "tasks_index.json is what list_tasks reads — it must agree")
    }

    /// The seeding change must not touch genuinely chat-mode teams.
    func testCreateTask_onARealChatTeam_staysChatMode() async {
        await sut.openWorkFolder(tempDir)
        guard let chatTeam = sut.workFolder?.teams.first(where: { $0.isChatMode }) else {
            XCTFail("expected a bundled chat-mode team"); return
        }
        guard let taskID = await sut.createTask(
            title: "Chat", supervisorTask: "hello", preferredTeamID: chatTeam.id)
        else { XCTFail("createTask returned nil"); return }

        XCTAssertEqual(sut.loadedTask(taskID)?.isChatMode, true)
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode, true)
    }

    /// Adoption still governs: a generated team that comes out chat-shaped flips the task
    /// to chat mode, which is what `adoptGeneratedTeam` is for.
    func testAdoptGeneratedTeam_chatShapedRoster_flipsTheTaskToChatMode() async {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let placeholder = sut.workFolder?.teams.first(where: { $0.isGeneratedPlaceholder }),
              let taskID = await sut.createTask(
                title: "Gen", supervisorTask: "chat with me", preferredTeamID: placeholder.id)
        else { XCTFail("setup failed"); return }
        XCTAssertEqual(sut.loadedTask(taskID)?.isChatMode, false, "precondition")

        let chatRoster = Team(
            id: "gen_chat", name: "Gen Chat",
            roles: [
                TeamRoleDefinition(
                    id: "sup", name: "Supervisor", prompt: "", toolIDs: [],
                    usePlanningPhase: false, dependencies: RoleDependencies(),
                    isSystemRole: true, systemRoleID: "supervisor")
            ],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        XCTAssertTrue(chatRoster.isChatMode, "fixture sanity")
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(chatRoster) }

        XCTAssertEqual(sut.loadedTask(taskID)?.isChatMode, true)
    }

    // MARK: - Helpers

    /// Appends the Generated Team placeholder to the workfolder. Mirrors the
    /// on-the-fly creation path used by `QuickCaptureFormView.selectGeneratedTeamTemplate`.
    /// Required because the placeholder is no longer bootstrapped by default.
    private func seedGeneratedTemplate() async {
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.templateID == "generated" }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
    }
}
