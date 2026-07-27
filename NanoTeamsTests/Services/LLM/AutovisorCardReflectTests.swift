import XCTest
@testable import NanoTeams

/// Pins Bug B: a Autovisor tool's deferred SUCCESS result must be reflected
/// onto the persisted `StepToolCall` so the activity-feed card shows the real
/// result — not the synchronous `{"data":{"status":"pending"}}` placeholder every
/// manager tool emits.
///
/// Unlike delegation / consultation / meeting (which render their real output in
/// dedicated UI surfaces, so a green placeholder card is fine), Autovisor
/// tools have NO other UI surface — the tool-call card is the only place their
/// result appears. Before the fix, `appendCollaborationResult` only re-wrote the
/// row on FAILURE, so on success the human saw `{"status":"pending"}` forever even
/// though the model received the real data.
@MainActor
final class AutovisorCardReflectTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - The reported symptom: list_tasks card stuck on "pending"

    /// `list_tasks` dispatched through `appendCollaborationResult` must overwrite
    /// the `{"status":"pending"}` placeholder with the handler's real
    /// `{"data":{"tasks":[…]}}` envelope. (`handleListTasks` returns the real
    /// envelope even with a nil snapshot — an empty `tasks` array — which is still
    /// distinct from the placeholder.)
    func testListTasks_reflectsRealResultOntoCard() async {
        let toolCallID = UUID()
        let stepID = "autovisor"
        let task = makeManagerTaskWithPlaceholder(toolCallID: toolCallID, stepID: stepID,
                                                   toolName: ToolNames.listTasks)
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let result = ToolExecutionResult(
            providerID: "tc_1",
            toolName: ToolNames.listTasks,
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .listTasks
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result,
            toolCallID: toolCallID,
            roleForMessage: .codingAgent,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: StubLLMClient(),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )

        let updated = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(updated?.isError, false,
            "list_tasks success must keep the card green.")
        XCTAssertTrue(updated?.resultJSON?.contains("\"tasks\"") ?? false,
            "Card must show the real list_tasks envelope (contains \"tasks\"), not the placeholder.")
        XCTAssertFalse(updated?.resultJSON?.contains("\"pending\"") ?? true,
            "The \"pending\" placeholder must no longer be the persisted card result.")
    }

    // MARK: - Failure branch: manager signal whose handler fails flips the card red

    /// The negative half of `isError: status == .failure` for a manager signal: a
    /// Autovisor tool whose deferred handler FAILS must reflect the real error
    /// envelope with `isError == true`. Together with `testListTasks_…` (manager
    /// success → `isError: false`) this pins that the two manager outcomes diverge —
    /// guarding against a refactor that hardcodes `isError: true` inside the
    /// `isAutovisorSignal` branch (which would render every successful manager
    /// action red). `task_status` on an unknown id is the cheapest manager failure:
    /// `autovisorLoadTask` → nil → error envelope, no extra wiring.
    func testTaskStatus_unknownTask_reflectsFailureOntoCard() async {
        let toolCallID = UUID()
        let stepID = "autovisor"
        let task = makeManagerTaskWithPlaceholder(toolCallID: toolCallID, stepID: stepID,
                                                  toolName: ToolNames.taskStatus)
        mockDelegate.taskToMutate = task            // id 1 — the manager's own task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let result = ToolExecutionResult(
            providerID: "tc_1",
            toolName: ToolNames.taskStatus,
            argumentsJSON: #"{"task_id":777}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .taskStatus(taskID: 777)        // 777 ∉ loadedTask → nil → error envelope
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result,
            toolCallID: toolCallID,
            roleForMessage: .codingAgent,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: StubLLMClient(),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )

        let updated = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(updated?.isError, true,
            "A manager signal whose deferred handler fails must flip the card red.")
        XCTAssertTrue(updated?.resultJSON?.contains("\"ok\":false") ?? false,
            "Card must show the real error envelope, not the 'pending' placeholder.")
        XCTAssertFalse(updated?.resultJSON?.contains("\"pending\"") ?? true,
            "The 'pending' placeholder must no longer be the persisted card result.")
    }

    // MARK: - Classification guard

    /// Pins which signals take the manager reflect path. The 10 manager signals
    /// must classify `true`; the rich-UI collaboration signals must classify
    /// `false`. (`isAutovisorSignal` only gates the manager-only reflect branch;
    /// attribution tools — consultation/meeting/change-request — reflect onto the
    /// card via the separate `reflectAttribution` path, and delegation reflects
    /// only on failure.) Guards against a new manager signal silently shipping
    /// with a stuck-on-"pending" card.
    func testIsAutovisorSignal_classifiesManagerTrue_collaborationFalse() {
        for signal: ToolSignal in [
            .listTasks,
            .taskStatus(taskID: 1),
            .createManagedTask(title: "t", brief: "b", teamID: nil),
            .controlTask(taskID: 1, verb: .stop),
            .manageRole(taskID: 1, roleID: "r", verb: .accept),
            .answerTaskQuestion(taskID: 1, answer: "a"),
            .messageTask(taskID: 1, text: "m", roleID: nil),
            .scheduleTask(taskID: 1, intervalMinutes: 5),
            .setWorkFolderContext(content: "c"),
            .waitForEvents
        ] {
            XCTAssertTrue(LLMExecutionService.isAutovisorSignal(signal),
                "\(signal) is a Autovisor signal and must reflect its result onto the card.")
        }

        for signal: ToolSignal in [
            .delegateToTeam(teamID: "x", taskBrief: "b"),
            .teammateConsultation(id: "r", question: "q", context: nil),
            .teamMeeting(topic: "t", participants: [], context: nil),
            .changeRequest(targetRole: "r", changes: "c", reasoning: "x"),
            .cancelDelegation(childTaskID: 1, reason: nil),
            .resumeDelegation(childTaskID: 1),
            .forwardToTeam(childTaskID: 1, message: "m")
        ] {
            XCTAssertFalse(LLMExecutionService.isAutovisorSignal(signal),
                "\(signal) is not a manager signal — its card reflect (if any) is owned by reflectAttribution / delegation-on-failure, not the manager branch.")
        }

        XCTAssertFalse(LLMExecutionService.isAutovisorSignal(nil))
    }

    // MARK: - Helpers

    private func makeManagerTaskWithPlaceholder(toolCallID: UUID, stepID: String, toolName: String) -> NTMSTask {
        let placeholder = StepToolCall(
            id: toolCallID,
            providerID: "tc_1",
            name: toolName,
            argumentsJSON: "{}",
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false
        )
        let step = StepExecution(
            id: stepID,
            role: .codingAgent,
            title: "Manager",
            status: .running,
            toolCalls: [placeholder]
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: 1, title: "T", supervisorTask: "...", runs: [run])
    }
}

// MARK: - Stub LLM client (Autovisor read tools never stream)

private final class StubLLMClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    func loadModel(modelName _: String, baseURLString _: String) async throws -> String { "" }
    func unloadModel(instanceID _: String, baseURLString _: String) async throws {}
    func listLoadedInstances(baseURLString _: String) async throws -> [LoadedModelInstance] { [] }
}
