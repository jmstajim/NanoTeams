import XCTest
@testable import NanoTeams

/// Pins `LLMExecutionService.handleStreamLoopBreak` — the top-level thinking-loop
/// recovery dispatch (retry-with-correction → mode-aware terminal). The pure decision
/// is covered by `LoopRecoveryPolicyTests`; this verifies the mapping to `LLMStepStop`
/// plus the regression-critical side effects: that the retry actually PERTURBS the
/// conversation, and the consecutive-break counter.
@MainActor
final class StreamLoopRecoveryDispatchTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() async throws {
        try await super.setUp()
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

    /// Local, not a stored property: Swift 6 refuses to pass actor-isolated state
    /// `inout` to an async call, and `[ChatMessage]` is a value type so a local is safe.
    private func seedConversation() -> [ChatMessage] {
        [
            ChatMessage(role: .user, content: "the task"),
            ChatMessage(role: .assistant, content: "a good prior turn"),
        ]
    }

    override func tearDown() async throws {
        mockDelegate = nil; service = nil; task = nil; stepID = nil
        try await super.tearDown()
    }

    private let signal = LoopSignal.withinMessage(diagnostic: "looped")

    /// Drives one full episode: `maxThinkingLoopBreaks - 1` corrected retries, then the
    /// break that exhausts the budget — and returns THAT stop.
    ///
    /// Derived from the constant rather than hardcoding "the second break": the budget
    /// is a tuning value (raised 2 → 3 after the 2026-07-25 double loop-terminal), and a
    /// literal here would silently turn every terminal-arm pin into an assertion about a
    /// retry the next time it moves.
    private func driveToBudgetExhausted(
        task: NTMSTask,
        supervisorMode: SupervisorMode,
        messages: inout [ChatMessage]
    ) async -> LLMStepStop {
        for _ in 1..<LLMConstants.maxThinkingLoopBreaks {
            _ = await service._testHandleStreamLoopBreak(
                stepID: stepID, signal: signal, task: task,
                supervisorMode: supervisorMode, conversationMessages: &messages)
        }
        return await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: supervisorMode, conversationMessages: &messages)
    }

    /// Nudges appended by one full episode — i.e. every break except the terminal one.
    private var nudgesPerEpisode: Int { LLMConstants.maxThinkingLoopBreaks - 1 }

    /// THE regression this suite exists for. The looping generation is discarded and
    /// `performStreamingCall` takes the conversation by value, so unless the recovery
    /// appends something the next request is byte-identical to the one that just
    /// looped — which is how a production incident burned both attempts 46ms apart and
    /// silently ended an Autovisor pass. Assert the array actually GREW and the tail
    /// differs; the pre-fix `return .continueLoop` fails this.
    func testFirstBreak_perturbsTheConversation_soTheResendIsNotIdentical() async {
        var messages = seedConversation()
        let before = messages

        let stop = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)

        guard case .continueLoop = stop else { return XCTFail("Expected .continueLoop, got \(stop)") }
        XCTAssertEqual(messages.count, before.count + 1, "the retry must append a correction turn")
        XCTAssertNotEqual(messages.map(\.content), before.map(\.content),
                          "the next request must NOT be byte-identical to the one that looped")
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertTrue((messages.last?.content ?? "").contains(LoopRecoveryPolicy.nudgePrefix))
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 1)
    }

    /// The nudge is appended, never spliced in: any earlier entry moving would
    /// change an early byte and invalidate the server's KV prefix from that point.
    func testFirstBreak_appendsAtTail_leavingEarlierEntriesInPlace() async {
        var messages = seedConversation()
        let before = messages
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)

        XCTAssertEqual(Array(messages.prefix(before.count)).map(\.content), before.map(\.content),
                       "existing entries must keep their absolute positions")
    }

    /// The nudge must be persisted with `.loopCorrection`, or the activity feed drops
    /// it: `ActivityFeedBuilder` discards `.user` turns that have neither a
    /// `sourceRole` nor a `sourceContext`, which is exactly the shape a bare
    /// `appendLLMMessage(role: .user, …)` produces. Without the context the only
    /// record of a loop break is a `cancelled` row in `network_log.json`.
    func testFirstBreak_persistsNudgeWithLoopCorrectionContext() async {
        var messages = seedConversation()
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)

        let step = mockDelegate.taskToMutate!.runs[0].steps[0]
        guard let persisted = step.llmConversation.last else {
            return XCTFail("the nudge must be persisted to the display record")
        }
        XCTAssertEqual(persisted.sourceContext, .loopCorrection,
                       "without a sourceContext the feed drops this turn")
        XCTAssertTrue(persisted.content.contains(LoopRecoveryPolicy.nudgePrefix))
    }

    /// Budget exhausted on an autonomous NON-chat task (no resolvable team →
    /// isChatMode false): the step fails honestly (no busy-spin), counter resets.
    func testBudgetExhausted_autonomousNonChat_failsStep_andResetsCounter() async {
        var messages = seedConversation()
        let stop = await driveToBudgetExhausted(
            task: task, supervisorMode: .autonomous, messages: &messages)

        guard case .toolFailure = stop else { return XCTFail("Expected .toolFailure, got \(stop)") }
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0,
                       "Counter resets after a terminal decision")
    }

    /// A terminal decision must NOT append another nudge — across a whole episode the
    /// conversation grows by exactly one turn per RETRY, and none for the terminal.
    func testTerminalBreak_appendsNoFurtherNudge() async {
        var messages = seedConversation()
        let before = messages.count
        _ = await driveToBudgetExhausted(
            task: task, supervisorMode: .autonomous, messages: &messages)

        XCTAssertEqual(messages.count, before + nudgesPerEpisode,
                       "only the retry arm nudges; the terminal arm must not append")
    }

    /// `maxThinkingLoopBreaks` bounds nudges within ONE episode only — the sibling test above
    /// pins that. `consecutiveThinkingLoopBreaks` is reset on every clean stream
    /// (`+ToolIteration`), so `break → nudge → clean stream → break` is reachable and a step
    /// legitimately carries several notes.
    ///
    /// They are all APPENDED, never retired in place: rewriting an earlier index would
    /// invalidate the server's KV prefix from that point (a full re-prefill to save ~115
    /// tokens), and would shift nothing but still break the one thing this arm exists for if
    /// the two episodes render identical text. What keeps that honest is the WORDING — each
    /// note is anchored to its own position, so it stays true when read again later.
    func testSecondEpisode_appendsAnotherNudge_andEachStaysTrueWhereItSits() async {
        var messages = seedConversation()
        let before = messages.count

        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)
        // What a clean stream does between two loop episodes.
        service._testResetThinkingLoopBreakCount(stepID: stepID, taskID: task.id)
        messages.append(ChatMessage(role: .assistant, content: "a productive turn"))
        let snapshot = messages

        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)

        XCTAssertEqual(messages.count, snapshot.count + 1, "the second episode appends its own note")
        XCTAssertNotEqual(
            messages.map(\.content), snapshot.map(\.content),
            "the resend must still differ from the request that just looped, even when both "
                + "episodes carry the SAME diagnostic and therefore render identical text")
        XCTAssertEqual(
            messages.filter { ($0.content ?? "").contains(LoopRecoveryPolicy.nudgePrefix) }.count, 2,
            "notes accumulate rather than being retired — retiring rewrites an early index and "
                + "costs a full re-prefill")

        // The seeded turns are untouched — earlier bytes are exactly where they
        // were, so the server's KV prefix survives the nudge.
        XCTAssertEqual(messages[0].content, "the task")
        XCTAssertEqual(messages[1].content, "a good prior turn")
        XCTAssertEqual(messages[before].content, snapshot[before].content,
                       "the first note stayed exactly where it was written")
    }

    /// The wording is what makes accumulation safe: a note read dozens of turns later must not
    /// claim to describe the reader's immediately preceding turn.
    func testNudgeText_isAnchoredToItsOwnPosition_notToTheReadersPresent() async {
        var messages = seedConversation()
        _ = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)

        let nudge = messages.last?.content ?? ""
        XCTAssertTrue(
            nudge.contains("before this note"),
            "the note must anchor to its own position — it is read again on every later request")
        XCTAssertFalse(
            nudge.lowercased().contains("act on it now"),
            "a directive scoped to 'now' goes stale the moment another turn follows it")
    }

    /// Budget exhausted on an autonomous CHAT-mode task with NO waker (an ordinary
    /// chat team): graceful finish. MUST set `finishRequested` and return
    /// `.continueLoop` so the step-lifecycle guard runs `finishStepGraceful`
    /// (preserving transcript/usage persistence) — NOT a direct finish.
    func testBudgetExhausted_autonomousChat_noWaker_finishesGraceful_setsFinishRequested() async {
        var messages = seedConversation()
        // A chat-mode generated team makes resolveTeam(task:).isChatMode true, and
        // codingAssistant is not the manager → no waker → finish, not park.
        let chatTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "g", runs: task.runs,
            generatedTeam: TeamTemplateFactory.codingAssistant())
        XCTAssertTrue(chatTask.isChatMode, "test premise: the team must be chat-mode")

        let stop = await driveToBudgetExhausted(
            task: chatTask, supervisorMode: .autonomous, messages: &messages)

        guard case .continueLoop = stop else {
            return XCTFail("finishGraceful must return .continueLoop (defer to the lifecycle guard), got \(stop)")
        }
        XCTAssertTrue(service._testFinishRequested(stepID: stepID, taskID: task.id),
                      "finishGraceful must set finishRequested — NOT call finishStepGraceful directly")
        XCTAssertFalse(service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
                       "a role with no waker must not be parked")
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0,
                       "Counter resets after a terminal decision")
    }

    /// The Autovisor shape: autonomous + chat + a waker (its recurrence and the event
    /// wakes). Parks carrying the diagnostic rather than finishing silently, and does
    /// it through the SAME loop-top handoff the idle park uses — so the lifecycle guard
    /// persists the wire transcript BEFORE the park is published. Calling
    /// `setNeedsSupervisorInput` here instead would publish "parked, answer me" against
    /// an empty transcript and the queued-message backstop it fires synchronously could
    /// resume the step against nothing.
    func testBudgetExhausted_autovisor_parksWithDiagnostic_viaLifecycleHandoff() async {
        var messages = seedConversation()
        let managerTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "g", runs: task.runs,
            generatedTeam: TeamTemplateFactory.autovisor())

        let stop = await driveToBudgetExhausted(
            task: managerTask, supervisorMode: .autonomous, messages: &messages)

        guard case .continueLoop = stop else {
            return XCTFail("the park must defer to the lifecycle guard, got \(stop)")
        }
        XCTAssertTrue(service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
                      "the park must go through the flag handoff, not a direct setNeedsSupervisorInput")
        XCTAssertFalse(service._testFinishRequested(stepID: stepID, taskID: task.id),
                       "the manager must park, not silently finish")

        let step = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertFalse(step.needsSupervisorInput,
                       "the park must NOT be published before the lifecycle guard persists the transcript")
    }

    /// The park question must differ from the idle-park text. `taskHasIdleParkStep`
    /// matches `idleParkQuestion` by exact equality and the sidebar gates the manager's
    /// attention badge on `!isIdleParked`, so reusing it would make a loop-terminated
    /// pass pixel-identical to a healthy idle — re-creating the invisibility the fix
    /// exists to remove.
    func testAutovisorPark_questionIsDistinguishableFromIdlePark() async {
        var messages = seedConversation()
        let managerTask = NTMSTask(
            id: 0, title: "T", supervisorTask: "g", runs: task.runs,
            generatedTeam: TeamTemplateFactory.autovisor())
        _ = await driveToBudgetExhausted(
            task: managerTask, supervisorMode: .autonomous, messages: &messages)

        let question = service._testParkQuestionOverride(stepID: stepID, taskID: task.id)
        XCTAssertNotNil(question, "the loop park must carry its own question")
        XCTAssertNotEqual(question, AutovisorConstants.idleParkQuestion,
                          "a loop break must not masquerade as a healthy idle park")
        XCTAssertTrue(question?.contains("reasoning loop") == true,
                      "the park question must say what happened")
    }

    /// Budget exhausted in MANUAL mode: escalate to the Supervisor. Returns
    /// `.needsSupervisorInput` and persists the question + flag on the step.
    func testBudgetExhausted_manual_escalatesSupervisor_persistsQuestion() async {
        var messages = seedConversation()
        let stop = await driveToBudgetExhausted(
            task: task, supervisorMode: .manual, messages: &messages)

        guard case .needsSupervisorInput(let q) = stop else {
            return XCTFail("manual + budget-exhausted must escalate, got \(stop)")
        }
        XCTAssertTrue(q.contains("reasoning loop"), "question describes the loop")
        let step = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertTrue(step.needsSupervisorInput, "escalation must persist the needs-input flag")
        XCTAssertEqual(step.supervisorQuestion, q, "the rendered question must persist on the step")
    }

    /// The budget counts *consecutive* breaks: a clean stream completion (no
    /// `thinkingLoopSignal`) between two breaks must reset the counter, so a healthy
    /// top-level task isn't terminated by two breaks separated by good turns. Pins
    /// the production `resetThinkingLoopBreakCount` that `runOneLLMToolIteration`
    /// calls on every no-loop stream — drop it and `break → recover → break` wrongly
    /// accumulates to the terminal.
    func testCleanCompletion_resetsConsecutiveBreakCounter() {
        _ = seedConversation()
        service._testSetThinkingLoopBreakCount(stepID: stepID, taskID: task.id, count: 1)
        service._testResetThinkingLoopBreakCount(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0,
                       "A clean stream completion must reset the consecutive-break counter")
    }

    /// Defensive: if the escalation fails to persist (mutate misses — step/task gone),
    /// the handler must fail loudly via `.toolFailure`, NOT wedge in a question-less
    /// `.needsSupervisorInput`.
    func testManualEscalate_persistFails_returnsToolFailure() async {
        var messages = seedConversation()
        // Spend every retry, THEN break the persist — so the next break is the terminal
        // one and its `setNeedsSupervisorInput` mutate is the call that misses.
        for _ in 1..<LLMConstants.maxThinkingLoopBreaks {
            _ = await service._testHandleStreamLoopBreak(
                stepID: stepID, signal: signal, task: task,
                supervisorMode: .manual, conversationMessages: &messages)
        }
        mockDelegate.taskToMutate = nil  // next setNeedsSupervisorInput mutate misses → persist fails
        let stop = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .manual, conversationMessages: &messages)  // terminal → escalate (fails to persist)

        guard case .toolFailure = stop else {
            return XCTFail("escalation-persist-failure must fall back to .toolFailure, got \(stop)")
        }
    }

    /// A teardown between the break and the persist (task gone) must not crash and must
    /// still perturb the wire array — the nudge's whole job is making the resend differ,
    /// and the display write is best-effort by contract (`appendLLMMessage` no-ops when
    /// the execution is not live).
    func testFirstBreak_persistMisses_stillPerturbsTheWireConversation() async {
        var messages = seedConversation()
        mockDelegate.taskToMutate = nil
        let before = messages.count

        let stop = await service._testHandleStreamLoopBreak(
            stepID: stepID, signal: signal, task: task,
            supervisorMode: .autonomous, conversationMessages: &messages)

        guard case .continueLoop = stop else { return XCTFail("Expected .continueLoop, got \(stop)") }
        XCTAssertEqual(messages.count, before + 1,
                       "the wire perturbation must not depend on the display-record write")
    }
}
