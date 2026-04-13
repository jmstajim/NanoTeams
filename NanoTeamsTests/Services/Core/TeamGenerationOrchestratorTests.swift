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
        guard let generatedTemplate = sut.workFolder?.teams.first(where: { $0.templateID == "generated" }) else {
            XCTFail("Expected a generated template in default teams"); return
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

    func testSaveGeneratedTeam_noOpWhenNoGeneratedTeam() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        let priorTeamCount = sut.workFolder?.teams.count ?? 0
        await sut.saveGeneratedTeam(taskID: taskID)
        XCTAssertEqual(sut.workFolder?.teams.count, priorTeamCount, "No team should be appended")
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
}
