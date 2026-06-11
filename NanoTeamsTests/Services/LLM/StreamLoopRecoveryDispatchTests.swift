import XCTest
@testable import NanoTeams

/// Pins `LLMExecutionService.handleStreamLoopBreak` — the top-level thinking-loop
/// recovery dispatch (clean-retry → mode-aware terminal). The pure decision is
/// covered by `LoopRecoveryPolicyTests`; this verifies the mapping to `LLMStepStop`
/// plus the two regression-critical side effects: the stateless-replay session clear
/// and the consecutive-break counter.
@MainActor
final class StreamLoopRecoveryDispatchTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Step", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "goal", runs: [run])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        mockDelegate = nil; service = nil; task = nil; stepID = nil
        super.tearDown()
    }

    private let signal = LoopSignal.withinMessage(diagnostic: "looped")

    /// First break (within budget): stateless replay. The session MUST be cleared
    /// (the caller only updates `session` on non-nil, so the handler must nil it
    /// explicitly or the stale chain would be reused). Counter increments to 1.
    func testFirstBreak_retryStateless_clearsSession_andIncrementsCounter() async {
        let (stop, sessionOut) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, sessionIn: LLMSession(responseID: "resp-123"))

        guard case .continueLoop = stop else { return XCTFail("Expected .continueLoop, got \(stop)") }
        XCTAssertNil(sessionOut, "retryStateless must clear the session for a clean stateless replay")
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 1)
    }

    /// Budget exhausted on an autonomous NON-chat task (no resolvable team →
    /// isChatMode false): the step fails honestly (no busy-spin), counter resets.
    func testSecondBreak_autonomousNonChat_failsStep_andResetsCounter() async {
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, sessionIn: nil)  // break 1 → retryStateless
        let (stop, _) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, sessionIn: nil)  // break 2 (== maxRetries) → terminal

        guard case .toolFailure = stop else { return XCTFail("Expected .toolFailure, got \(stop)") }
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0,
                       "Counter resets after a terminal decision")
    }

    /// Budget exhausted on an autonomous CHAT-mode task (the Autovisor shape):
    /// graceful finish. MUST set `finishRequested` and return `.continueLoop` so the
    /// step-lifecycle guard runs `finishStepGraceful` (preserving session/usage
    /// persistence) — NOT a direct finish. Guards against the tempting simplification
    /// the production comment flags as wrong.
    func testSecondBreak_autonomousChat_finishesGraceful_setsFinishRequested() async {
        // A chat-mode generated team makes resolveTeam(task:).isChatMode true.
        let chatTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "g", runs: task.runs,
            generatedTeam: TeamTemplateFactory.codingAssistant())
        XCTAssertTrue(chatTask.isChatMode, "test premise: the team must be chat-mode")

        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: chatTask,
            supervisorMode: .autonomous, sessionIn: nil)  // break 1 → retryStateless
        let (stop, _) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: chatTask,
            supervisorMode: .autonomous, sessionIn: nil)  // break 2 → terminal(finishGraceful)

        guard case .continueLoop = stop else {
            return XCTFail("finishGraceful must return .continueLoop (defer to the lifecycle guard), got \(stop)")
        }
        XCTAssertTrue(service._testFinishRequested(stepID: stepID, taskID: task.id),
                      "finishGraceful must set finishRequested — NOT call finishStepGraceful directly")
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0,
                       "Counter resets after a terminal decision")
    }

    /// Budget exhausted in MANUAL mode: escalate to the Supervisor. Returns
    /// `.needsSupervisorInput` and persists the question + flag on the step.
    func testSecondBreak_manual_escalatesSupervisor_persistsQuestion() async {
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, sessionIn: nil)  // break 1 → retryStateless
        let (stop, _) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, sessionIn: nil)  // break 2 → escalate

        guard case .needsSupervisorInput(let q) = stop else {
            return XCTFail("manual + budget-exhausted must escalate, got \(stop)")
        }
        XCTAssertTrue(q.contains("reasoning loop"), "question describes the loop")
        let step = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertTrue(step.needsSupervisorInput, "escalation must persist the needs-input flag")
        XCTAssertEqual(step.supervisorQuestion, q, "the rendered question must persist on the step")
    }

    /// A terminal decision MUST clear the `inout` session (mirroring `.retryStateless`).
    /// `performStreamingCall` returned `session: nil` on the break, but the caller only
    /// assigns `session` on a non-nil value, so on iteration 2+ of a stateful step the
    /// stale chain ID is still live when the handler runs. If escalation doesn't clear
    /// it, the lifecycle's `.needsSupervisorInput` arm re-persists `session?.responseID`
    /// onto the step — silently resuming the stateful chain whose last attempt was the
    /// discarded looping turn, defeating the stateless-replay contract.
    func testTerminalEscalate_clearsSession() async {
        let stale = LLMSession(responseID: "stale-looping-chain")
        var sessionOut: LLMSession? = stale
        // break 1 → retryStateless (already clears; re-seed before the terminal call)
        (_, sessionOut) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, sessionIn: stale)
        (_, sessionOut) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, sessionIn: stale)  // break 2 == budget → escalate
        XCTAssertNil(sessionOut,
                     "Terminal escalation must clear the session so the lifecycle persists nil (stateless resume)")
    }

    /// Same contract for the autonomous-chat graceful-finish terminal: clear the
    /// session so the lifecycle's `finishRequested` arm doesn't re-persist a stale
    /// chain onto the (about-to-finish) step.
    func testTerminalFinishGraceful_clearsSession() async {
        let chatTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "g", runs: task.runs,
            generatedTeam: TeamTemplateFactory.codingAssistant())
        let stale = LLMSession(responseID: "stale-looping-chain")
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: chatTask,
            supervisorMode: .autonomous, sessionIn: stale)  // break 1 → retryStateless
        let (_, sessionOut) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: chatTask,
            supervisorMode: .autonomous, sessionIn: stale)  // break 2 → finishGraceful
        XCTAssertNil(sessionOut, "Graceful-finish terminal must clear the session")
    }

    /// The budget counts *consecutive* breaks: a clean stream completion (no
    /// `thinkingLoopSignal`) between two breaks must reset the counter, so a healthy
    /// top-level task isn't terminated by two breaks separated by good turns. Pins
    /// the production `resetThinkingLoopBreakCount` that `runOneLLMToolIteration`
    /// calls on every no-loop stream — drop it and `break → recover → break` wrongly
    /// accumulates to the terminal.
    func testCleanCompletion_resetsConsecutiveBreakCounter() {
        service._testSetThinkingLoopBreakCount(stepID: stepID, taskID: task.id, count: 1)
        service._testResetThinkingLoopBreakCount(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0,
                       "A clean stream completion must reset the consecutive-break counter")
    }

    /// Defensive: if the escalation fails to persist (mutate misses — step/task gone),
    /// the handler must fail loudly via `.toolFailure`, NOT wedge in a question-less
    /// `.needsSupervisorInput`.
    func testManualEscalate_persistFails_returnsToolFailure() async {
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, sessionIn: nil)  // break 1 → retryStateless
        mockDelegate.taskToMutate = nil  // next setNeedsSupervisorInput mutate misses → persist fails
        let (stop, _) = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, sessionIn: nil)  // break 2 → escalate (fails to persist)

        guard case .toolFailure = stop else {
            return XCTFail("escalation-persist-failure must fall back to .toolFailure, got \(stop)")
        }
    }
}
