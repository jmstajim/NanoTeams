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
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5s — test fails before this if not cancelled.
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
                try await Task.sleep(nanoseconds: 5_000_000_000)
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
