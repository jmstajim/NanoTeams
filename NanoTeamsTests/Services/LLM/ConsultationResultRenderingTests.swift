import XCTest
@testable import NanoTeams

/// Pins the fix for "ask_teammate answers disappear": a consultation answer
/// must (1) reflect onto the tool card instead of staying at the `pending`
/// placeholder, (2) surface as a `.consultation` attribution bubble, (3) render
/// failures honestly (red `{ok:false}` card), (4) recover a reasoning-only
/// answer, and (5) persist card + tool message + bubble in ONE atomic mutation.
/// Also pins that delegation/Autovisor LLM tool messages are single-enveloped,
/// not double-wrapped.
@MainActor
final class ConsultationResultRenderingTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "team_software_engineer"
    private let initiatorRole: Role = .softwareEngineer

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("consult-result-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Success: answer reflects onto the card + attribution bubble

    func testConsultation_success_reflectsAnswerOntoCard_andAppendsBubble() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team)
        let toolCallID = task.runs[0].steps[0].toolCalls[0].id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: consultationResult(),
            toolCallID: toolCallID,
            roleForMessage: initiatorRole,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: ScriptedLLMClient(content: "Use a debounce."),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )

        let card = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(card?.isError, false, "A successful consultation card must stay green.")
        XCTAssertTrue(card?.resultJSON?.contains("Use a debounce.") ?? false,
            "Card must show the answer, not the pending placeholder. got: \(card?.resultJSON ?? "nil")")
        XCTAssertFalse(card?.resultJSON?.contains("\"pending\"") ?? true,
            "The pending placeholder must no longer be the persisted card result.")

        let bubble = mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation
            .last { $0.sourceContext == .consultation }
        XCTAssertEqual(bubble?.content, "Use a debounce.",
            "The answer must also surface as a (consultation) attribution bubble.")
    }

    // MARK: - Failure (unknown teammate): red card + bubble + single atomic commit

    func testConsultation_unknownTeammate_redCard_bubble_singleAtomicCommit() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team)
        let toolCallID = task.runs[0].steps[0].toolCalls[0].id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Unknown teammate → the handler fails at validation BEFORE creating or
        // recording any consultation, so the ONLY task mutation in the whole
        // dispatch is the atomic commit (card + tool message + bubble together).
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: consultationResult(consultedRoleID: "ghost_role"),
            toolCallID: toolCallID,
            roleForMessage: initiatorRole,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: ScriptedLLMClient(content: "unused"),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )

        let card = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(card?.isError, true, "A failed consultation must render red.")
        XCTAssertTrue(card?.resultJSON?.contains("\"ok\":false") ?? false,
            "Card must carry the real error envelope. got: \(card?.resultJSON ?? "nil")")
        XCTAssertTrue(card?.resultJSON?.contains("Unknown teammate") ?? false,
            "Error envelope must surface the reason for diagnostics.")

        let bubble = mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation
            .last { $0.sourceContext == .consultation }
        XCTAssertNotNil(bubble, "Even a failed consultation surfaces its reason as a bubble.")

        let commits = mockDelegate.eventLog.filter { $0 == "mutate-begin:\(task.id)" }.count
        XCTAssertEqual(commits, 1,
            "Card + tool message + bubble must commit in ONE atomic mutateTask (no partial-persist window).")
    }

    // MARK: - Same reflect path for meeting / change-request failures

    // The success → green-card-with-answer branch is shared `reflectAttribution`
    // code, pinned by `testConsultation_success_…`. These two pin that the FAILURE
    // half of that shared branch flips the card red for the OTHER two
    // attribution-bearing tools too (meeting / change request), each of which has
    // its own validation failure mode.

    func testMeeting_failure_redCard_andBubble() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team, toolName: ToolNames.requestTeamMeeting)
        let toolCallID = task.runs[0].steps[0].toolCalls[0].id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Empty participants → handler short-circuits at the no-participants guard.
        let result = ToolExecutionResult(
            providerID: "tc_1", toolName: ToolNames.requestTeamMeeting,
            argumentsJSON: #"{"topic":"x","participants":[]}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false, signal: .teamMeeting(topic: "x", participants: [], context: nil)
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result, toolCallID: toolCallID, roleForMessage: initiatorRole,
            stepID: stepID, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedLLMClient(content: "unused"),
            config: LLMConfig(), networkLogger: nil, conversationMessages: &conversation
        )

        let card = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(card?.isError, true, "A failed meeting must render red, not stay at the pending placeholder.")
        XCTAssertTrue(card?.resultJSON?.contains("\"ok\":false") ?? false,
            "got: \(card?.resultJSON ?? "nil")")
        let bubble = mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation
            .last { $0.sourceContext == .meeting }
        XCTAssertNotNil(bubble, "A failed meeting surfaces its reason as a (meeting) bubble.")
    }

    func testChangeRequest_failure_redCard_andBubble() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team, toolName: ToolNames.requestChanges)
        let toolCallID = task.runs[0].steps[0].toolCalls[0].id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Unknown target role → handler fails at validation.
        let result = ToolExecutionResult(
            providerID: "tc_1", toolName: ToolNames.requestChanges,
            argumentsJSON: #"{"target_role":"ghost_role","changes":"c","reasoning":"r"}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false, signal: .changeRequest(targetRole: "ghost_role", changes: "c", reasoning: "r")
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result, toolCallID: toolCallID, roleForMessage: initiatorRole,
            stepID: stepID, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedLLMClient(content: "unused"),
            config: LLMConfig(), networkLogger: nil, conversationMessages: &conversation
        )

        let card = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(card?.isError, true, "A failed change request must render red, not green ✓.")
        XCTAssertTrue(card?.resultJSON?.contains("\"ok\":false") ?? false,
            "got: \(card?.resultJSON ?? "nil")")
        let bubble = mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation
            .last { $0.sourceContext == .changeRequest }
        XCTAssertNotNil(bubble, "A failed change request surfaces its reason as a (change request) bubble.")
    }

    // MARK: - Empty content → reasoning-channel answer recovered

    func testConsultation_emptyContent_fallsBackToThinking() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let reply = await service.handleTeammateConsultation(
            stepID: stepID, consultedRoleID: "team_pm", question: "ping?", context: nil,
            requestingRole: initiatorRole, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedLLMClient(content: "", thinking: "Reasoned answer."),
            config: LLMConfig()
        )

        XCTAssertTrue(reply.succeeded, "A reasoning-only answer must be recovered, not dropped.")
        XCTAssertEqual(reply.text, "Reasoned answer.")
        let record = mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last
        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(record?.response, "Reasoned answer.")
    }

    // MARK: - Empty content AND thinking → honest failure with sentinel

    func testConsultation_emptyContentAndThinking_failsWithSentinel() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let reply = await service.handleTeammateConsultation(
            stepID: stepID, consultedRoleID: "team_pm", question: "ping?", context: nil,
            requestingRole: initiatorRole, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedLLMClient(content: "", thinking: ""),
            config: LLMConfig()
        )

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("empty response"), "got: \(reply.text)")
        let record = mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last
        XCTAssertEqual(record?.status, .failed)
        XCTAssertEqual(record?.response, reply.text,
            "The empty-answer reason must persist on the record so the structured panel shows it.")
    }

    // MARK: - Delegation LLM tool message is a single envelope (not double-wrapped)

    func testCancelDelegation_failure_llmToolMessage_isSingleEnvelope() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team, toolName: ToolNames.cancelDelegation)
        let toolCallID = task.runs[0].steps[0].toolCalls[0].id
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // No active delegation registered → handler returns an INVALID_ARGS envelope.
        let result = ToolExecutionResult(
            providerID: "tc_1", toolName: ToolNames.cancelDelegation,
            argumentsJSON: #"{"child_task_id":42}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false, signal: .cancelDelegation(childTaskID: 42, reason: nil)
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result, toolCallID: toolCallID, roleForMessage: initiatorRole,
            stepID: stepID, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedLLMClient(content: "unused"),
            config: LLMConfig(), networkLogger: nil, conversationMessages: &conversation
        )

        let toolContent = conversation.last { $0.role == .tool }?.content ?? ""
        XCTAssertFalse(toolContent.isEmpty, "Expected a tool result in the conversation.")
        XCTAssertTrue(toolContent.contains("INVALID_ARGS"),
            "LLM must see the real envelope. got: \(toolContent)")
        XCTAssertFalse(toolContent.contains("\"response\":"),
            "Delegation result must NOT be double-wrapped in {ok:true,response:\"…\"} for the LLM.")
    }

    // MARK: - Not-live dispatch: in-memory tool result still appended, nothing persisted

    /// When the step is no longer live (teardown / task switch), the durable
    /// commit must be skipped (`commitCollaborationOutcome` is gated by
    /// `isExecutionLive`) — but the in-memory `conversationMessages` tool result
    /// is appended UNCONDITIONALLY so the live iteration's assistant tool_call
    /// keeps a matching tool result (chain-protocol invariant). Pins that
    /// asymmetry by driving the dispatcher WITHOUT registering the step.
    func testDispatch_notLive_appendsInMemoryToolResult_butPersistsNothing() async {
        let team = makeTeam()
        let task = makeTaskWithToolCall(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        // Deliberately NO _testRegisterStepTask → isExecutionLive == false.

        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: consultationResult(),
            toolCallID: task.runs[0].steps[0].toolCalls[0].id,
            roleForMessage: initiatorRole,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: ScriptedLLMClient(content: "irrelevant — step not live"),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )

        let toolContent = conversation.last { $0.role == .tool }?.content ?? ""
        XCTAssertFalse(toolContent.isEmpty,
            "Chain protocol: the live iteration must still get a non-empty matching tool result even when not live.")

        XCTAssertFalse(mockDelegate.eventLog.contains { $0.hasPrefix("mutate-begin") },
            "Nothing may be persisted when the step is no longer live (commit is isExecutionLive-gated).")
    }

    // MARK: - Helpers

    private func consultationResult(consultedRoleID: String = "team_pm") -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: "tc_1",
            toolName: ToolNames.askTeammate,
            argumentsJSON: #"{"teammate":"\#(consultedRoleID)","question":"q"}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .teammateConsultation(id: consultedRoleID, question: "q", context: nil)
        )
    }

    private func makeTeam() -> Team {
        let pm = TeamRoleDefinition(
            id: "team_pm", name: "Product Manager", prompt: "p",
            toolIDs: [ToolNames.askTeammate], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "productManager"
        )
        let swe = TeamRoleDefinition(
            id: "team_software_engineer", name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.askTeammate], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "TestTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    private func makeTaskWithToolCall(team: Team, toolName: String = ToolNames.askTeammate) -> NTMSTask {
        let placeholder = StepToolCall(
            id: UUID(), providerID: "tc_1", name: toolName,
            argumentsJSON: "{}", resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false
        )
        let step = StepExecution(
            id: stepID, role: initiatorRole, title: "SWE step", status: .running, toolCalls: [placeholder]
        )
        let run = Run(id: 0, steps: [step])
        var task = NTMSTask(id: 7, title: "T", supervisorTask: "...", runs: [run])
        task.preferredTeamID = team.id
        return task
    }

    private func makeSnapshot(team: Team, task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team]
        )
        return WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
    }
}

// MARK: - Scripted LLM client (emits configurable content + thinking, one event each)

private final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    let content: String
    let thinking: String
    init(content: String, thinking: String = "") {
        self.content = content
        self.thinking = thinking
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        session _: LLMSession?,
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let c = content
        let t = thinking
        return AsyncThrowingStream { cont in
            if !t.isEmpty { cont.yield(StreamEvent(thinkingDelta: t)) }
            if !c.isEmpty { cont.yield(StreamEvent(contentDelta: c)) }
            cont.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    func loadModel(modelName _: String, baseURLString _: String) async throws -> String { "" }
    func unloadModel(instanceID _: String, baseURLString _: String) async throws {}
    func listLoadedInstances(baseURLString _: String) async throws -> [LoadedModelInstance] { [] }
}
