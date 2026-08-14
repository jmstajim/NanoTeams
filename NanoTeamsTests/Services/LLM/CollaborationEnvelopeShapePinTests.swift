import XCTest

@testable import NanoTeams

/// Structural pin for the invariant `isAutovisorSignal`'s doc comment states but
/// nothing enforced:
///
///   > Invariant every listed handler MUST uphold: return a well-formed
///   > `makeSuccessEnvelope` / `makeErrorEnvelope` (always carries an `ok` field).
///   > A raw / non-envelope string parses as `EnvelopeStatus.indeterminate`, and
///   > `reflectEnvelope`'s `cardIsError = (envelopeStatus(env) == .failure)` would
///   > then render a broken result falsely green.
///
/// The hazard is real and asymmetric, because `.indeterminate` is NOT `.failure`:
///
///   * **Autovisor signals** reflect ALWAYS. A handler returning a bare string
///     (an early `return "Autovisor unavailable."`, a `String(describing:)` slip)
///     lands on the card with `isError == false` — a green card carrying an error
///     the human reads as a success, on the one surface a manager tool has.
///   * **Delegation signals** reflect only on FAILURE. The same slip reflects
///     NOTHING, so the card keeps the synchronous `{"status":"pending"}`
///     placeholder forever — a delegation that failed shows as still running.
///
/// Both failure modes are silent: the model still receives the string, so nothing
/// errors, retries, or logs. Only the human sees the lie. This suite drives every
/// deferred collaboration signal through the real dispatch and asserts the
/// envelope the card and the wire both receive carries a top-level `ok`.
@MainActor
final class CollaborationEnvelopeShapePinTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let stepID = "manager"
    private let taskID = 88

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

    /// Every Autovisor management signal, both outcomes of the shared
    /// `performAutovisorAction` seam. A `nil` `ok` here is the falsely-green card.
    func testEveryAutovisorSignal_yieldsAWellFormedEnvelope() async {
        for actionResult: AutovisorActionResult in [.success("done"), .failure("nope")] {
            mockDelegate.autovisorActionResult = actionResult
            for signal in Self.autovisorSignals {
                let envelope = await dispatch(signal: signal, toolName: "manager_tool")
                assertWellFormed(envelope, signal: signal)
            }
        }
    }

    /// The delegation family. Their handlers reject early here (no child engine),
    /// but the shape requirement is identical — and for delegation a malformed
    /// envelope is worse, because a non-`.failure` parse reflects nothing at all.
    func testEveryDelegationSignal_yieldsAWellFormedEnvelope() async {
        for signal in Self.delegationSignals {
            let envelope = await dispatch(signal: signal, toolName: "delegation_tool")
            assertWellFormed(envelope, signal: signal)
        }
    }

    /// The card and the wire must carry the SAME bytes. A card built from a
    /// re-render rather than the dispatched envelope can drift from what the model
    /// was told — the two surfaces are then evidence for different stories.
    func testAutovisorSignal_cardAndWireCarryIdenticalBytes() async {
        mockDelegate.autovisorActionResult = .failure("the write failed")
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.controlTask)

        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: makeResult(toolName: ToolNames.controlTask,
                               signal: .controlTask(taskID: 5, verb: .stop)),
            toolCallID: toolCallID, roleForMessage: .autovisor, stepID: stepID,
            task: mockDelegate.taskToMutate!, runIndex: 0, stepIndex: 0,
            client: NoStreamClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &conversation)

        let card = mockDelegate.taskToMutate?.runs[0].steps[0].toolCalls
            .first { $0.id == toolCallID }
        XCTAssertEqual(card?.resultJSON, conversation.first?.content,
                       "the manager's card and the model's tool result must be one envelope")
        XCTAssertEqual(card?.isError, true,
                       "a failed manager action must flip the card red — a non-envelope string "
                        + "would parse as indeterminate and leave it green")
    }

    // MARK: - Assertion

    private func assertWellFormed(_ envelope: String, signal: ToolSignal, line: UInt = #line) {
        let label = String(describing: signal).prefix(50)
        guard let data = envelope.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return XCTFail("\(label): handler returned a non-JSON envelope: \(envelope)")
        }
        guard let ok = dict["ok"] as? Bool else {
            return XCTFail(
                "\(label): envelope has no top-level `ok` — it parses as indeterminate, which "
                    + "reflectEnvelope treats as NOT-a-failure. Got: \(envelope)")
        }
        if !ok {
            XCTAssertNotNil(dict["error"],
                            "\(label): a failing envelope must carry `error` so buildToolErrorGuidance "
                                + "can pick a recovery direction; got: \(envelope)")
        }
    }

    // MARK: - Signal rosters
    //
    // Listed literally rather than derived: a new signal must be added here by
    // hand, which is the moment its envelope shape gets considered.

    private static let autovisorSignals: [ToolSignal] = [
        .listTasks,
        .taskStatus(taskID: 404),
        .createManagedTask(title: "t", brief: "b", teamID: nil),
        .controlTask(taskID: 1, verb: .stop),
        .manageRole(taskID: 1, roleID: "r", verb: .accept),
        .answerTaskQuestion(taskID: 1, answer: "a"),
        .messageTask(taskID: 1, text: "m", roleID: nil),
        .scheduleTask(taskID: 1, intervalMinutes: 5),
        .setWorkFolderContext(content: "c"),
        .waitForEvents,
    ]

    private static let delegationSignals: [ToolSignal] = [
        .delegateToTeam(teamID: "t", taskBrief: "b"),
        .cancelDelegation(childTaskID: 1, reason: "r"),
        .resumeDelegation(childTaskID: 1),
        .forwardToTeam(childTaskID: 1, message: "m"),
    ]

    /// Guards the rosters against a signal being added to the deferred path and
    /// silently escaping this suite.
    func testRosters_coverEveryDeferredCollaborationSignal() {
        for signal in Self.autovisorSignals {
            XCTAssertTrue(LLMExecutionService.isCollaborationDeferredSignal(signal),
                          "\(signal) must take the deferred path")
            XCTAssertTrue(LLMExecutionService.isAutovisorSignal(signal))
        }
        for signal in Self.delegationSignals {
            XCTAssertTrue(LLMExecutionService.isCollaborationDeferredSignal(signal),
                          "\(signal) must take the deferred path")
            XCTAssertFalse(LLMExecutionService.isAutovisorSignal(signal),
                           "\(signal) reflects only on failure, so its shape matters differently")
        }
        XCTAssertEqual(Self.autovisorSignals.count, 10,
                       "all ten manager tools must be exercised — a new one needs a roster entry")
    }

    // MARK: - Helpers

    private func dispatch(signal: ToolSignal, toolName: String) async -> String {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: toolName)
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: makeResult(toolName: toolName, signal: signal),
            toolCallID: toolCallID, roleForMessage: .autovisor, stepID: stepID,
            task: mockDelegate.taskToMutate!, runIndex: 0, stepIndex: 0,
            client: NoStreamClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &conversation)
        return conversation.first?.content ?? ""
    }

    private func makeResult(toolName: String, signal: ToolSignal) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: "tc_1", toolName: toolName, argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false, signal: signal)
    }

    private func seedStep(toolCallID: UUID, toolName: String) {
        let placeholder = StepToolCall(
            id: toolCallID, providerID: "tc_1", name: toolName, argumentsJSON: "{}",
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false)
        let step = StepExecution(
            id: stepID, role: .autovisor, title: "Manager",
            status: .running, toolCalls: [placeholder])
        let task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }
}

private final class NoStreamClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
