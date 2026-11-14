import XCTest

@testable import NanoTeams

/// The gate in front of a step's deferred tool calls — the Autovisor's actions, the delegation
/// family, consultations and meetings — and the write barrier behind them.
///
/// `processToolResults` awaits the deferred handlers of one batch in turn, and any of them can
/// suspend for seconds: a removal that reconciles model residency, a start's prompt warm-up, a
/// delegation's whole child run. The step can be stopped meanwhile — Pause cancels its task, and
/// a folder transition cancels every step's task at its first line. Two things must then hold:
///
/// - no handler of the batch runs after its step is gone. The gate is the step's OWN task
///   (`Task.isCancelled`), an identity: `isExecutionLive` reads `executionStates[TaskStepKey]`,
///   and a `TaskStepKey` collides across folders (task ids are per folder, template role ids are
///   deterministic), so after a transition it can answer for the next folder's step. The model's
///   turn gets a "not run" result for each skipped call, so the call chain stays well-formed.
/// - a handler that was already running when the transition began commits nothing: its write
///   barrier is the folder lifecycle it was dispatched in, not the key.
@MainActor
final class DeferredHandlerGateTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tracker: ToolCallTracker!
    private var memoryStore: MemoryTagStore!
    private var tempDir: URL!
    private var outcome: LLMExecutionService.ToolResultsOutcome?
    private var conversation: [ChatMessage] = []

    private let stepID = "manager"
    private let taskID = 7

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tracker = ToolCallTracker()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deferred-gate-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        memoryStore = MemoryTagStore(workFolderRoot: tempDir)
        mockDelegate.workFolderURL = tempDir
        outcome = nil
        conversation = []
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        service?.cancelAllExecutions()
        tempDir = nil
        memoryStore = nil
        tracker = nil
        mockDelegate = nil
        service = nil
        outcome = nil
        conversation = []
        try await super.tearDown()
    }

    // MARK: - The gate

    /// Two Autovisor actions in one batch, the first of which stops the step — what a folder
    /// transition (`cancelAllExecutions`) or a Pause does while the batch is dispatched: the
    /// second is not performed, its call is answered "not run" to the model, and it counts as a
    /// failed call.
    ///
    /// RED until the dispatcher gated each deferred handler on its step's own task: it awaited
    /// every handler in turn with no check, so the second action ran after its step was gone —
    /// after a folder transition, on the next folder's task of the same id.
    func testADeferredCallAfterItsStepWasStoppedIsNotRun() async throws {
        let calls = [controlCall("tc_1", taskID: 3, verb: "stop"), controlCall("tc_2", taskID: 4, verb: "delete")]
        seedStep(calls: calls)
        mockDelegate.onAutovisorAction = { [unowned self] _ in self.service.cancelAllExecutions() }

        await runBatch(calls: calls, signals: [
            .controlTask(taskID: 3, verb: .stop), .controlTask(taskID: 4, verb: .delete),
        ])

        XCTAssertEqual(mockDelegate.autovisorActions, [.controlTask(taskID: 3, verb: .stop)],
                       "a deferred call ran after its step was stopped")
        let toolTurns = conversation.filter { $0.role == .tool }
        XCTAssertEqual(toolTurns.map(\.toolCallID), ["tc_1", "tc_2"], "every call keeps exactly one tool result, in order")
        let skipped = try XCTUnwrap(toolTurns.last?.content)
        XCTAssertTrue(skipped.contains(#""ok":false"#), "the skipped call was answered as done: \(skipped)")
        XCTAssertTrue(skipped.contains(DeferredCallReplies.notRun), "the skipped call does not say it was not run: \(skipped)")
        XCTAssertEqual(outcome?.effectiveResults.last?.isError, true, "a call that never ran counted as productive")
    }

    /// The gate is only for what comes AFTER the stop: a batch whose step is live runs every
    /// deferred call.
    func testEveryDeferredCallOfALiveStepRuns() async {
        let calls = [controlCall("tc_1", taskID: 3, verb: "stop"), controlCall("tc_2", taskID: 4, verb: "close")]
        seedStep(calls: calls)

        await runBatch(calls: calls, signals: [
            .controlTask(taskID: 3, verb: .stop), .controlTask(taskID: 4, verb: .close),
        ])

        XCTAssertEqual(mockDelegate.autovisorActions.count, 2, "a live step's deferred call was skipped")
        XCTAssertEqual(conversation.filter { $0.role == .tool }.count, 2)
    }

    // MARK: - The write barrier

    /// An action already running when a folder transition begins: the transition cancels every
    /// step and the NEXT folder's step with the same task and role id is then registered — the
    /// collision `TaskStepKey` permits. The action's outcome is committed nowhere: the card the
    /// key now names keeps its placeholder, and no tool message is persisted to its step.
    ///
    /// RED until the commit asked the folder lifecycle the handler was dispatched in: it asked
    /// `isExecutionLive`, which the next folder's step answered, and the manager's result was
    /// written onto the next folder's task.
    func testAnOutcomeIsNotCommittedOnceTheFolderLifecycleItRanInHasEnded() async throws {
        let calls = [controlCall("tc_1", taskID: 3, verb: "stop")]
        seedStep(calls: calls)
        let placeholder = card(calls[0].id)?.resultJSON
        let messagesBefore = step()?.llmConversation.count
        mockDelegate.onAutovisorAction = { [unowned self] _ in
            self.service.cancelAllExecutions()
            self.mockDelegate.folderTransitions += 1
            self.service._testRegisterStepTask(stepID: self.stepID, taskID: self.taskID)
        }

        await runBatch(calls: calls, signals: [.controlTask(taskID: 3, verb: .stop)])

        XCTAssertEqual(mockDelegate.autovisorActions.count, 1, "premise: the action ran")
        XCTAssertEqual(card(calls[0].id)?.resultJSON, placeholder,
                       "the outcome was written onto the card the key now names")
        XCTAssertEqual(step()?.llmConversation.count, messagesBefore,
                       "the outcome was persisted to the step the key now names")
    }

    /// The barrier still lets an ordinary outcome through: same lifecycle, live step.
    func testAnOutcomeIsCommittedWhileItsLifecycleAndStepLive() async {
        let calls = [controlCall("tc_1", taskID: 3, verb: "stop")]
        seedStep(calls: calls)
        let placeholder = card(calls[0].id)?.resultJSON

        await runBatch(calls: calls, signals: [.controlTask(taskID: 3, verb: .stop)])

        XCTAssertNotEqual(card(calls[0].id)?.resultJSON, placeholder, "a live outcome was not committed")
    }

    // MARK: - Helpers

    private func controlCall(_ providerID: String, taskID: Int, verb: String) -> StepToolCall {
        StepToolCall(
            id: UUID(), providerID: providerID, name: ToolNames.controlTask,
            argumentsJSON: #"{"task_id":\#(taskID),"action":"\#(verb)"}"#,
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false)
    }

    /// Runs the batch inside a task registered as the step's own running task — the shape a real
    /// step has — so the step's cancellation reaches it.
    private func runBatch(calls: [StepToolCall], signals: [ToolSignal]) async {
        let task = mockDelegate.taskToMutate!
        let results = zip(calls, signals).map { call, signal in
            ToolExecutionResult(
                providerID: call.providerID, toolName: call.name, argumentsJSON: call.argumentsJSON,
                outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false, signal: signal)
        }
        let running = Task { [unowned self] in
            var messages: [ChatMessage] = []
            self.outcome = await self.service.processToolResults(
                resolvedToolCalls: calls, results: results,
                stepID: self.stepID, roleForMessage: .softwareEngineer, task: task,
                runIndex: 0, stepIndex: 0, assistantContent: "",
                client: UnreachableChatClient(), config: LLMConfig(), tracker: self.tracker,
                memoryStore: self.memoryStore, wireIsMidPlanning: false, allowedToolNames: [],
                conversationMessages: &messages, networkLogger: nil)
            self.conversation = messages
        }
        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: running)
        await running.value
    }

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func card(_ id: UUID) -> StepToolCall? {
        step()?.toolCalls.first { $0.id == id }
    }

    private func seedStep(calls: [StepToolCall]) {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "Manager",
            status: .running, toolCalls: calls)
        mockDelegate.taskToMutate = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }
}
