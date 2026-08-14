import XCTest

@testable import NanoTeams

/// Pins that a deferred tool result reports what it RESOLVED to — to its caller and to the card —
/// rather than the `{"status":"pending"}` placeholder its synchronous handler emitted.
///
/// Every collaboration / delegation / Autovisor / vision / computer-use handler returns a green
/// placeholder immediately and finishes its real work seconds-to-minutes later in
/// `appendCollaborationResult` (or a sibling finalizer). Those finalizers computed the true outcome
/// and discarded it: nothing wrote it back into the `results` array, so `toolResults[i].isError`
/// stayed `false` — the flag on the placeholder — for 20 of the 23 `ToolSignal` cases.
///
/// Two consumers read that flag, and both were wrong:
///
///   • `ToolTurnProductivity.classify` is `toolResults.contains { !$0.isError }`, and it is the sole
///     writer that resets `consecutiveNonProductiveTurns`. A turn whose every tool call actually
///     FAILED therefore classified `.productive` and re-armed the ceiling. That ceiling is the only
///     shape-independent unbounded-loop guard the Autovisor has: `maxToolIterations` is 0
///     (unlimited), the manager is excluded from its own stuck detector, and `ToolCallLoopDetector`
///     needs three calls sharing `(toolName, argumentsSummary)` — which a manager guessing a
///     different task id each turn never produces.
///
///   • The persisted card. Delegation reflected only on FAILURE, on the stated grounds that
///     "success renders in the stacked graph delegation layers". That is false at exactly the
///     moment it matters: both terminal arms call `clearDelegationFields` BEFORE returning their
///     envelope, and `GraphPanelView.resolveDelegationLayers()` gates on
///     `activeDelegationChildID != nil` — so the layers vanish the instant the delegation resolves,
///     and the card that was supposed to stand in for them still reads "pending".
@MainActor
final class DeferredToolOutcomeCoverageTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let stepID = "agent_step"
    private let taskID = 91
    private let childTaskID = 92

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

    // MARK: - The resolved outcome reaches the caller

    /// A delegation that never launched resolves to a failure envelope. The finalizer must SAY so
    /// to its caller, not merely paint the card red.
    ///
    /// RED: return `Void` from `appendCollaborationResult` (the pre-fix signature) → there is no
    /// value to assert, `processToolResults` has nothing to write back, and the turn that produced
    /// only this failure still re-arms the no-tool ceiling.
    func testFailedDelegation_reportsIsErrorToItsCaller() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.delegateToTeam)

        var conversation: [ChatMessage] = []
        let resolvedIsError = await dispatch(
            signal: .delegateToTeam(teamID: "some-team", taskBrief: "do the thing"),
            toolName: ToolNames.delegateToTeam, toolCallID: toolCallID,
            conversation: &conversation)

        XCTAssertTrue(resolvedIsError,
                      "the finalizer resolved a failure envelope and must report it upward")
    }

    /// The complement, so the pin distinguishes "reports the outcome" from "always says true": a
    /// cancellation that matches the in-flight child succeeds, and reports `false`.
    ///
    /// RED: hard-code `true` as the return → this reds while the failure test above still passes.
    func testSucceedingCancellation_reportsIsErrorFalse() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.cancelDelegation)
        mockDelegate.activeDelegationChildStub["\(taskID):\(stepID)"] = childTaskID

        var conversation: [ChatMessage] = []
        let resolvedIsError = await dispatch(
            signal: .cancelDelegation(childTaskID: childTaskID, reason: "changed plan"),
            toolName: ToolNames.cancelDelegation, toolCallID: toolCallID,
            conversation: &conversation)

        XCTAssertFalse(resolvedIsError, "a cancellation that did what it was asked is not an error")
    }

    // MARK: - The card stops saying "pending"

    /// The graph layers that were supposed to be the success surface are torn down by the same
    /// path that produces the success, so the card is the only durable record — and it was still
    /// showing the synchronous placeholder, green, forever.
    ///
    /// RED: restore `else if isFailure` in `reflectEnvelope` → the card keeps
    /// `{"ok":true,"data":{"status":"pending"}}` after a delegation that has demonstrably finished.
    func testSucceedingDelegationControl_reflectsOntoTheCard() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.cancelDelegation)
        mockDelegate.activeDelegationChildStub["\(taskID):\(stepID)"] = childTaskID

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .cancelDelegation(childTaskID: childTaskID, reason: nil),
            toolName: ToolNames.cancelDelegation, toolCallID: toolCallID,
            conversation: &conversation)

        let card = reflectedCard(toolCallID)
        XCTAssertEqual(card?.isError, false, "a successful control action is not an error")
        XCTAssertFalse(card?.resultJSON?.contains("\"status\":\"pending\"") ?? true,
                       "the placeholder must be replaced: \(card?.resultJSON ?? "nil")")
        XCTAssertEqual(conversation.first?.content, card?.resultJSON,
                       "the model and the card must see the SAME envelope")
    }

    /// The failure half must keep working — narrowing is not the fix, reflecting BOTH outcomes is.
    ///
    /// RED: reflect only on success → this reds while the success test above still passes.
    func testFailingDelegationControl_stillReflectsRedOntoTheCard() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.cancelDelegation)
        // No stub ⇒ no in-flight delegation ⇒ INVALID_ARGS.

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .cancelDelegation(childTaskID: childTaskID, reason: nil),
            toolName: ToolNames.cancelDelegation, toolCallID: toolCallID,
            conversation: &conversation)

        let card = reflectedCard(toolCallID)
        XCTAssertEqual(card?.isError, true)
        XCTAssertTrue(card?.resultJSON?.contains(#""ok":false"#) ?? false,
                      "got: \(card?.resultJSON ?? "nil")")
    }

    // MARK: - The productivity rule, given correct inputs

    /// `ToolTurnProductivity` itself was never wrong — its INPUT was. This pins the composition at
    /// the boundary the write-back feeds, and shows what the ceiling used to see.
    ///
    /// RED: make `ToolTurnProductivity.classify` ignore `isError` (return `.productive` whenever
    /// the batch is non-empty) → the first assertion reds, and the no-tool ceiling loses the only
    /// input that can distinguish acting from failing.
    func testClassify_allDeferredResultsFailed_isNonProductive() {
        let failed = [
            ToolExecutionResult(toolName: ToolNames.manageRole, argumentsJSON: "{}",
                                outputJSON: #"{"ok":false}"#, isError: true),
            ToolExecutionResult(toolName: ToolNames.controlTask, argumentsJSON: "{}",
                                outputJSON: #"{"ok":false}"#, isError: true),
        ]
        XCTAssertEqual(
            ToolTurnProductivity.classify(isAskSupervisorOnly: false, toolResults: failed),
            .nonProductive)

        let placeholders = failed.map { r -> ToolExecutionResult in
            var copy = r
            copy.isError = false
            copy.outputJSON = #"{"ok":true,"data":{"status":"pending"}}"#
            return copy
        }
        XCTAssertEqual(
            ToolTurnProductivity.classify(isAskSupervisorOnly: false, toolResults: placeholders),
            .productive,
            "this is what the ceiling used to see — the reason the write-back exists")
    }

    // MARK: - Helpers

    @discardableResult
    private func dispatch(
        signal: ToolSignal,
        toolName: String,
        toolCallID: UUID,
        roleForMessage: Role = .codingAgent,
        conversation: inout [ChatMessage]
    ) async -> Bool {
        let result = ToolExecutionResult(
            providerID: "tc_1", toolName: toolName, argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false, signal: signal)
        return await service.appendCollaborationResult(
            result: result, toolCallID: toolCallID, roleForMessage: roleForMessage,
            stepID: stepID, task: mockDelegate.taskToMutate!, runIndex: 0, stepIndex: 0,
            client: InertLLMClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &conversation)
    }

    private func seedStep(toolCallID: UUID, toolName: String) {
        let placeholder = StepToolCall(
            id: toolCallID, providerID: "tc_1", name: toolName, argumentsJSON: "{}",
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false)
        let step = StepExecution(
            id: stepID, role: .codingAgent, title: "Agent",
            status: .running, toolCalls: [placeholder])
        let task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = nil
        // `commitCollaborationOutcome` is gated by a single `isExecutionLive` check, so without a
        // registered execution state NOTHING is committed and every card assertion below reads the
        // untouched placeholder — passing or failing for a reason that has nothing to do with the
        // reflect rule under test.
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    private func reflectedCard(_ id: UUID) -> StepToolCall? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }?
            .toolCalls.first { $0.id == id }
    }
}

// MARK: - Inert client

/// Never streams. Every arm exercised here resolves without an LLM call, so a client that DID
/// reach the network would itself be the finding.
private final class InertLLMClient: LLMClient, @unchecked Sendable {
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
}
