import XCTest
@testable import NanoTeams

/// Verifies the synthetic `create_team` placeholder lifecycle inside
/// `handleDelegateToTeam` when the role calls `delegate_to_team(team_id: "generated", …)`.
///
/// The handler appends a placeholder `create_team` tool call to the
/// delegating role's step BEFORE invoking `TeamGenerationService.generate`,
/// then flips its `resultJSON` to a success or error envelope. This is the
/// activity-feed affordance that mirrors `runTeamGeneration`'s spinner —
/// without it, users see only an opaque in-flight `delegate_to_team` row
/// during the (multi-second) team-generation phase.
///
/// `StepToolCall.isGeneratingTeam` matches against the `"status":"generating"`
/// substring; the `TeamGenerationOrchestratorTests.testGeneratingEnvelope_*`
/// suite pins that contract end-to-end. These tests pin the delegate-side
/// of the same contract: that the handler actually emits the placeholder
/// and updates it on success/failure.
@MainActor
final class DelegateToTeamGenerationPlaceholderTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    private static let parentTaskID = 1
    private static let stepID = "delegator_role"
    private static let parentTeamID: NTMSID = "parent_team"

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Success path

    func testHandleDelegateToTeam_generatedFlow_appendsCreateTeamPlaceholder_onSuccess() async {
        seedParentTaskAndTeam()
        service._testRegisterStepTask(stepID: Self.stepID, taskID: Self.parentTaskID)
        // No createDelegatedTask stub — the handler will return commandFailed
        // AFTER the placeholder is updated to its success envelope, which is
        // the only thing this test asserts on. Skipping createDelegatedTask
        // keeps the test scoped to the placeholder lifecycle.

        let envelope = await service.handleDelegateToTeam(
            stepID: Self.stepID,
            teamIDRaw: DelegationConstants.generatedTeamSentinel,
            taskBrief: "Build a calculator",
            initiatingRole: .codingAgent,
            task: delegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: SuccessLLMClient(),
            config: makeConfig()
        )

        // The placeholder must exist in the parent step's toolCalls.
        let toolCalls = delegate.taskToMutate?.runs.last?.steps
            .first(where: { $0.id == Self.stepID })?.toolCalls ?? []
        let createTeamCalls = toolCalls.filter { $0.name == ToolNames.createTeam }
        XCTAssertEqual(createTeamCalls.count, 1,
                       "Exactly one synthetic create_team placeholder must be appended in the generated branch")

        // After generation succeeds, the placeholder's resultJSON must carry
        // the success envelope (so the activity-feed spinner flips to ✓) and
        // its isError flag must be false.
        let placeholder = createTeamCalls[0]
        XCTAssertFalse(placeholder.isGeneratingTeam,
                       "After successful generation the placeholder must no longer match the generating-spinner marker — otherwise the spinner would persist forever")
        XCTAssertEqual(placeholder.isError, false,
                       "Successful generation must clear the isError flag")
        let resultJSON = try? XCTUnwrap(placeholder.resultJSON)
        XCTAssertTrue(resultJSON?.contains("\"status\":\"created\"") == true,
                      "Success envelope must carry status:\"created\" (consumed by ToolCallSummarizer + GraphPanelView readers); got \(placeholder.resultJSON ?? "nil")")

        // The handler returns commandFailed when createDelegatedTask isn't
        // stubbed — that's expected; we asserted the placeholder updated
        // BEFORE the failure path was reached.
        XCTAssertTrue(envelope.contains("Could not create delegated child task")
            || envelope.contains("COMMAND_FAILED"),
            "Without a createDelegatedTask stub the broader handler returns commandFailed; this is unrelated to the placeholder lifecycle. Got: \(envelope)")
    }

    // MARK: - Failure path

    func testHandleDelegateToTeam_generatedFlow_marksPlaceholderAsError_onFailure() async {
        seedParentTaskAndTeam()
        service._testRegisterStepTask(stepID: Self.stepID, taskID: Self.parentTaskID)

        let envelope = await service.handleDelegateToTeam(
            stepID: Self.stepID,
            teamIDRaw: DelegationConstants.generatedTeamSentinel,
            taskBrief: "Build a calculator",
            initiatingRole: .codingAgent,
            task: delegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: ThrowingLLMClient(),
            config: makeConfig()
        )

        let toolCalls = delegate.taskToMutate?.runs.last?.steps
            .first(where: { $0.id == Self.stepID })?.toolCalls ?? []
        let createTeamCalls = toolCalls.filter { $0.name == ToolNames.createTeam }
        XCTAssertEqual(createTeamCalls.count, 1,
                       "Placeholder must be appended on the generated path even when generation later throws — otherwise a spinner-less feed gives no signal that generation was attempted")

        let placeholder = createTeamCalls[0]
        XCTAssertEqual(placeholder.isError, true,
                       "Failed generation must flip the placeholder to isError:true so the activity-feed icon renders the red ✗ instead of stranding a spinner")
        XCTAssertFalse(placeholder.isGeneratingTeam,
                       "Error envelope must NOT match isGeneratingTeam — the substring matchers are independent and a stuck spinner on a failed generation is the worst-case UX")
        let resultJSON = placeholder.resultJSON ?? ""
        XCTAssertTrue(resultJSON.contains("GENERATION_FAILED"),
                      "Error envelope must carry the GENERATION_FAILED code so GraphPanelView (and any future debug surfacing) can render the message; got: \(resultJSON)")

        // The handler must also surface the human banner and return its own
        // commandFailed envelope to the LLM tool loop.
        XCTAssertFalse(delegate.lastErrorMessages.isEmpty,
                       "Generation failure must set lastErrorMessage so the human Supervisor sees why their delegation aborted, not just the collapsed tool-call card")
        XCTAssertTrue(envelope.contains("COMMAND_FAILED")
            || envelope.contains("Failed to generate a delegated team"),
            "Tool envelope back to LLM must indicate failure; got: \(envelope)")
    }

    // MARK: - Negative paths (placeholder must NOT appear)

    /// Pins ordering invariant: the placeholder append lives INSIDE the
    /// `teamIDRaw == generatedTeamSentinel` branch. If a future refactor
    /// hoists it above the if/else (or swaps to a different sentinel
    /// detection), every existing-team delegation would silently emit a
    /// phantom "generating…" card with no actual generation happening.
    func testHandleDelegateToTeam_existingTeamFlow_doesNotAppendPlaceholder() async {
        let existingTeamID: NTMSID = "existing_target_team"
        seedParentTaskAndTeam(allowedDelegationTeamIDs: [existingTeamID])
        // Add the target team to the snapshot so the existing-team branch
        // resolves it instead of returning .invalidArgs.
        injectTeamIntoSnapshot(id: existingTeamID, name: "Target")
        service._testRegisterStepTask(stepID: Self.stepID, taskID: Self.parentTaskID)

        _ = await service.handleDelegateToTeam(
            stepID: Self.stepID,
            teamIDRaw: existingTeamID,
            taskBrief: "Use the existing team",
            initiatingRole: .codingAgent,
            task: delegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: ThrowingLLMClient(),  // generate must NOT be invoked on this branch
            config: makeConfig()
        )

        let toolCalls = delegate.taskToMutate?.runs.last?.steps
            .first(where: { $0.id == Self.stepID })?.toolCalls ?? []
        let createTeamCalls = toolCalls.filter { $0.name == ToolNames.createTeam }
        XCTAssertTrue(createTeamCalls.isEmpty,
                      "No create_team placeholder may appear when delegating to an existing (whitelisted) team — the spinner pattern is exclusive to the generated branch")
    }

    /// Pins ordering invariant for the eligibility guard. The role's
    /// `allowDelegationToGeneratedTeams = false` early-returns BEFORE the
    /// placeholder append. If someone moves the eligibility check below
    /// the append, denied delegations would leave a phantom spinner card
    /// + an audit-trail entry for generation that never happened.
    func testHandleDelegateToTeam_generatedFlow_roleNotAllowed_doesNotAppendPlaceholder() async {
        seedParentTaskAndTeam(allowDelegationToGeneratedTeams: false)
        service._testRegisterStepTask(stepID: Self.stepID, taskID: Self.parentTaskID)

        let envelope = await service.handleDelegateToTeam(
            stepID: Self.stepID,
            teamIDRaw: DelegationConstants.generatedTeamSentinel,
            taskBrief: "Build something",
            initiatingRole: .codingAgent,
            task: delegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: ThrowingLLMClient(),  // generate must NOT be invoked
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("DELEGATION_DENIED"),
                      "Eligibility guard must surface delegationDenied; got: \(envelope)")
        let toolCalls = delegate.taskToMutate?.runs.last?.steps
            .first(where: { $0.id == Self.stepID })?.toolCalls ?? []
        let createTeamCalls = toolCalls.filter { $0.name == ToolNames.createTeam }
        XCTAssertTrue(createTeamCalls.isEmpty,
                      "No create_team placeholder may appear when the eligibility guard early-returns — otherwise denied delegations leave a phantom audit-trail entry for generation that never happened")
    }

    // MARK: - Helpers

    private func seedParentTaskAndTeam(
        allowDelegationToGeneratedTeams: Bool = true,
        allowedDelegationTeamIDs: [NTMSID] = []
    ) {
        // Parent role: peer-with-Supervisor (no reportsTo entry), allowed to
        // generate teams. systemRoleID matches `Role.codingAgent.baseID` so
        // `findRole(byIdentifier:)` resolves it via the systemRoleID branch.
        var parentRole = TeamRoleDefinition(
            id: Self.stepID,
            name: "Coding Agent",
            prompt: "test",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: Role.codingAgent.baseID
        )
        parentRole.allowDelegationToGeneratedTeams = allowDelegationToGeneratedTeams
        parentRole.allowedDelegationTeamIDs = allowedDelegationTeamIDs

        let supervisorRole = TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "test",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "supervisor"
        )

        let parentTeam = Team(
            id: Self.parentTeamID,
            name: "Test Parent Team",
            roles: [supervisorRole, parentRole],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )

        // Parent task with a single run + step matching the role.id so the
        // appendToolCalls path's `locateStepInLatestRun(stepID:)` succeeds.
        var parentTask = NTMSTask(id: Self.parentTaskID, title: "Parent", supervisorTask: "x")
        parentTask.preferredTeamID = Self.parentTeamID
        parentTask.runs = [Run(id: 0, steps: [
            StepExecution(id: Self.stepID, role: .codingAgent, title: "Coding Agent", status: .running)
        ])]
        delegate.taskToMutate = parentTask

        // Snapshot must contain the parent team so `resolveTeam(task:)` finds it.
        var state = WorkFolderState(name: "Test")
        state.activeTeamID = Self.parentTeamID
        delegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: state,
                settings: .defaults,
                teams: [parentTeam]
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: Self.parentTaskID,
            activeTask: parentTask
        )
    }

    /// Append a target team to the existing snapshot so the existing-team
    /// branch's `delegate.snapshot?.workFolder.team(withID:)` lookup
    /// succeeds. Used by the existing-team negative test.
    private func injectTeamIntoSnapshot(id: NTMSID, name: String) {
        let supervisor = TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "test",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "supervisor"
        )
        let target = Team(
            id: id, name: name, roles: [supervisor], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        guard var snap = delegate.snapshot else { return }
        snap.projection.teams.append(target)
        delegate.snapshot = snap
    }

    private func makeConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost",
            modelName: "stub",
            temperature: nil
        )
    }

    // MARK: - LLMClient stubs

    /// Emits a single content delta carrying a valid `GeneratedTeamConfig`
    /// JSON body. `TeamGenerationService.generate` falls through to its
    /// `extractJSONObject` (json_extract) parsing path — no tool-call
    /// streaming machinery required for this test.
    private final class SuccessLLMClient: LLMClient, @unchecked Sendable {
        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let json = #"""
                {
                    "name": "Generated Test Team",
                    "description": "Synthetic team for the placeholder test",
                    "roles": [
                        {
                            "name": "Worker",
                            "prompt": "Do the work.",
                            "produces_artifacts": ["Result"],
                            "requires_artifacts": [],
                            "tools": []
                        }
                    ],
                    "artifacts": [
                        {"name": "Result", "description": "Final output"}
                    ],
                    "supervisor_requires": ["Result"]
                }
                """#
                continuation.yield(StreamEvent(contentDelta: json))
                continuation.finish()
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    /// Throws on stream open — drives the handler's `catch` branch so we
    /// can assert the placeholder flips to the error envelope.
    private final class ThrowingLLMClient: LLMClient, @unchecked Sendable {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "stub failure" }
        }
        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: StubError())
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
