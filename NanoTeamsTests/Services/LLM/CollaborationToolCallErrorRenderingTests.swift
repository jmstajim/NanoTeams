import XCTest
@testable import NanoTeams

/// End-to-end pinning of the deferred-collaboration error-flip path: when a
/// collaboration handler returns an `{"ok": false, ...}` envelope,
/// `appendCollaborationResult` re-updates the persisted `StepToolCall` so the
/// activity-feed card flips from green ✓ (placeholder default) to red error.
///
/// Without this loop, the only `StepToolCall` ever persisted is the placeholder
/// from the handler's `signal` — which always has `isError: false`, so failed
/// delegations / consultations / meetings render as success. Verified through
/// `handleCancelDelegation` because it has the cheapest failure path
/// (no `activeDelegationChildID` registered → instant `INVALID_ARGS`).
@MainActor
final class CollaborationToolCallErrorRenderingTests: XCTestCase {

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

    // MARK: - Happy-path: success envelope stays green AND replaces the placeholder

    /// When the handler returns `{"ok": true, ...}` the card stays green — and now also carries
    /// the real envelope instead of the synchronous `{"status":"pending"}` placeholder.
    ///
    /// This test previously asserted the opposite for the resultJSON, on the stated grounds that
    /// "a non-Autovisor (rich-UI) success must leave the placeholder untouched — its real output
    /// renders in a dedicated UI surface". That surface is `GraphPanelView.resolveDelegationLayers()`,
    /// which gates on `step.activeDelegationChildID != nil`; every delegation arm that resolves —
    /// including this cancellation — calls `clearDelegationFields` BEFORE returning its envelope.
    /// The layers are therefore gone by the time the card is written, and the assertion was
    /// pinning a card that reported a finished delegation as pending, green, permanently.
    func testAppendCollaborationResult_successEnvelope_leavesIsErrorFalse() async {
        let toolCallID = UUID()
        let stepID = "coding_agent"
        let task = makeTaskWithStepAndToolCall(toolCallID: toolCallID, stepID: stepID)
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Wire the active delegation so `handleCancelDelegation` hits the
        // success path. Mock state-key shape mirrors `MockLLMExecutionDelegate`.
        let childID = 999
        mockDelegate.activeDelegationChildStub["\(task.id):\(stepID)"] = childID

        let result = ToolExecutionResult(
            providerID: "tc_1",
            toolName: ToolNames.cancelDelegation,
            argumentsJSON: #"{"child_task_id":999}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .cancelDelegation(childTaskID: childID, reason: nil)
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

        let updatedCall = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(updatedCall?.isError, false,
            "Success envelope must leave the placeholder isError=false untouched.")
        XCTAssertFalse(updatedCall?.resultJSON?.contains("\"status\":\"pending\"") ?? true,
            "The card is the only durable record of a resolved delegation — the graph layers are torn down by the same path — so it must carry the real envelope, not the placeholder. Got: \(updatedCall?.resultJSON ?? "nil")")
        XCTAssertEqual(updatedCall?.resultJSON, conversation.first?.content,
            "the model and the card must see the SAME envelope — no double-wrapping")
    }

    // MARK: - Failure-path: ok:false envelope flips isError + outputJSON

    /// The bug being fixed: `handleCancelDelegation` rejects an unrecognized
    /// `child_task_id` with `INVALID_ARGS` (`{"ok":false,...}`). Before this
    /// PR, the placeholder green ✓ would persist and the user would think the
    /// cancel succeeded. Now the row flips red.
    func testAppendCollaborationResult_failureEnvelope_flipsIsErrorTrue() async {
        let toolCallID = UUID()
        let stepID = "coding_agent"
        let task = makeTaskWithStepAndToolCall(toolCallID: toolCallID, stepID: stepID)
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Intentionally do NOT register an active delegation — handler will
        // bail with INVALID_ARGS.
        let badChildID = 12345

        let result = ToolExecutionResult(
            providerID: "tc_1",
            toolName: ToolNames.cancelDelegation,
            argumentsJSON: #"{"child_task_id":12345}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .cancelDelegation(childTaskID: badChildID, reason: nil)
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

        let updatedCall = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls.first { $0.id == toolCallID }
        XCTAssertEqual(updatedCall?.isError, true,
            "Failure envelope must flip StepToolCall.isError=true so the activity-feed card renders red.")
        XCTAssertTrue(updatedCall?.resultJSON?.contains("\"ok\":false") ?? false,
            "Persisted resultJSON must be the actual error envelope, not the original 'pending' placeholder.")
        XCTAssertTrue(updatedCall?.resultJSON?.contains("INVALID_ARGS") ?? false,
            "Persisted resultJSON must surface the handler's error message for diagnostics.")
    }

    // MARK: - wait_for_events dispatch (GAP2 — the shipped-bug class)

    /// A `.waitForEvents` result dispatched through `appendCollaborationResult` must
    /// reach `handleWaitForEvents`, which arms `parkForEventsRequested`. The shipped
    /// bug was the signal NOT being routed to this deferred path (it fell through to
    /// the regular handler), so the flag was never set and the manager looped on
    /// `wait_for_events`. Paired with `AdvisoryAutoFinishTests.testWaitForEvents_isCollaborationDeferred`
    /// (the routing predicate), this pins the full chain: predicate routes it here →
    /// dispatcher case handles it → flag is armed.
    func testAppendCollaborationResult_waitForEvents_armsParkRequested() async {
        let toolCallID = UUID()
        let stepID = "autovisor"
        let task = makeTaskWithStepAndToolCall(toolCallID: toolCallID, stepID: stepID)
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.parkForEventsRequested, false,
                       "precondition: flag starts unset")

        let result = ToolExecutionResult(
            providerID: "tc_1",
            toolName: ToolNames.waitForEvents,
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .waitForEvents
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

        XCTAssertEqual(service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.parkForEventsRequested, true,
            "wait_for_events dispatched via appendCollaborationResult must arm parkForEventsRequested (parks the review pass)")
        XCTAssertEqual(service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.finishRequested, false,
            "wait_for_events must park, not complete — finishRequested stays unset")
    }

    // MARK: - Helpers

    private func makeTaskWithStepAndToolCall(toolCallID: UUID, stepID: String) -> NTMSTask {
        let placeholder = StepToolCall(
            id: toolCallID,
            providerID: "tc_1",
            name: ToolNames.cancelDelegation,
            argumentsJSON: #"{"child_task_id":999}"#,
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false
        )
        let step = StepExecution(
            id: stepID,
            role: .codingAgent,
            title: "Coding Agent",
            status: .running,
            toolCalls: [placeholder]
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(
            id: 1,
            title: "T",
            supervisorTask: "...",
            runs: [run]
        )
    }
}

// MARK: - Stub LLM client (never called by cancel_delegation path)

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
