import XCTest
@testable import NanoTeams

/// Pins the durable "someone is owed a Supervisor answer" predicate after its move
/// out of `ActivityFeedBuilder` into Domain.
///
/// The move is what makes `TaskSummary.hasPendingSupervisorInput` possible at all
/// (`toSummary()` is Domain and cannot reach into `Views/`), and the point of the
/// predicate is that it keys on the PERSISTED flag + ask/answer counting rather than
/// on `status` — `StatusRecoveryService` rewrites `status` at launch and leaves the
/// question standing.
final class StepExecutionSupervisorInputTests: XCTestCase {

    // MARK: - StepExecution.hasActiveSupervisorInput

    func testNoAskCalls_flagSet_isWaiting() {
        XCTAssertTrue(makeStep(needsSupervisorInput: true).hasActiveSupervisorInput)
    }

    func testNoAskCalls_flagClear_isNotWaiting() {
        XCTAssertFalse(makeStep(needsSupervisorInput: false).hasActiveSupervisorInput)
    }

    func testTrailingAsk_noAnswerMessage_isWaiting() {
        let step = makeStep(needsSupervisorInput: false, toolCalls: [askCall("Q1")])
        XCTAssertTrue(step.hasActiveSupervisorInput)
    }

    func testTrailingAsk_answered_isNotWaiting() {
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [askCall("Q1")],
            answerMessages: 1
        )
        XCTAssertFalse(step.hasActiveSupervisorInput)
    }

    /// The multi-round race the answer-after-ask law exists for: round N is
    /// answered, round N+1's call is already appended, and `supervisorAnswer`
    /// still holds round N. Construction order mirrors the wire: Q1, A1, Q2.
    func testMultiRoundRace_secondQuestionInFlight_isWaiting() {
        let first = askCall("Q1")
        let a1 = answerMessage("A1")
        let second = askCall("Q2")
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [first, second],
            conversation: [a1],
            supervisorAnswer: "A1"
        )
        XCTAssertTrue(step.hasActiveSupervisorInput)
    }

    /// A model that batches several `ask_supervisor` calls in one response gets
    /// ONE answer for the whole batch. Under the retired ask/answer COUNT law,
    /// asks outran answers forever and every later round read as waiting.
    func testBatchedAsks_oneAnswerResolvesTheBatch() {
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [askCall("Q1a"), askCall("Q1b"), askCall("Q1c")],
            answerMessages: 1
        )
        XCTAssertFalse(step.hasActiveSupervisorInput)
    }

    /// An answer to a flag-only escalation has no matching ask call. Under the
    /// count law it silently pre-paid for the NEXT ask; under the order law the
    /// next ask has no answer after it and correctly reads as waiting.
    func testEscalationAnswer_doesNotPrepayTheNextAsk() {
        let escalationAnswer = answerMessage("resolved the stall")
        let nextAsk = askCall("Q-next")
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [nextAsk],
            conversation: [escalationAnswer]
        )
        XCTAssertTrue(step.hasActiveSupervisorInput)
    }

    func testTrailingCallIsNotAsk_answered_isNotWaiting() {
        let other = StepToolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"a"}"#)
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [askCall("Q1"), other],
            answerMessages: 1
        )
        XCTAssertFalse(step.hasActiveSupervisorInput)
    }

    /// The backstop's other reachable case: the ask was asked AND answered, then an
    /// engine cap (drift / refusal-loop) escalated via `setNeedsSupervisorInput`
    /// without appending a call. The ask/answer count reads "resolved"; the flag
    /// must still win. Without this fixture the `|| needsSupervisorInput` tail has
    /// no test that traverses it while `askCalls` is non-empty (CLAUDE.md #59).
    func testEscalationAfterAnsweredAsk_flagStillWins() {
        let step = makeStep(
            needsSupervisorInput: true,
            toolCalls: [askCall("Q1")],
            answerMessages: 1
        )
        XCTAssertTrue(step.hasActiveSupervisorInput)
    }

    /// The whole point of the move: a step parked by `StatusRecoveryService` still
    /// reads as waiting, because only `status` was rewritten.
    func testParkedByRecovery_stillWaiting() {
        let step = makeStep(
            needsSupervisorInput: true,
            status: .paused,
            toolCalls: [askCall("Q1")]
        )
        XCTAssertTrue(step.hasActiveSupervisorInput)
        XCTAssertNotEqual(step.status, .needsSupervisorInput)
    }

    // MARK: - Question identity

    func testActiveQuestionID_isTrailingAskCallID() {
        let first = askCall("Q1")
        let second = askCall("Q2")
        let step = makeStep(needsSupervisorInput: true, toolCalls: [first, second])
        XCTAssertEqual(step.activeSupervisorQuestionID, second.id)
    }

    func testActiveQuestionID_nilWhenNotWaiting() {
        let step = makeStep(needsSupervisorInput: false, toolCalls: [askCall("Q1")], answerMessages: 1)
        XCTAssertNil(step.activeSupervisorQuestionID)
    }

    /// Escalation path: the engine flips the flag with no call to name.
    func testActiveQuestionID_nilOnEscalationPath() {
        let step = makeStep(needsSupervisorInput: true)
        XCTAssertTrue(step.hasActiveSupervisorInput)
        XCTAssertNil(step.activeSupervisorQuestionID)
    }

    /// Escalation on a step that asked (and was answered) BEFORE: the flag-only
    /// question must NOT inherit the answered call's UUID — that identity was
    /// already read (and possibly dismissed), so the escalation banner would be
    /// born-dismissed. Nil forces the question-text fallback identity.
    func testActiveQuestionID_nilOnEscalationAfterAnsweredAsk() {
        let step = makeStep(
            needsSupervisorInput: true,
            toolCalls: [askCall("Q1")],
            answerMessages: 1
        )
        XCTAssertTrue(step.hasActiveSupervisorInput)
        XCTAssertNil(step.activeSupervisorQuestionID)
    }

    // MARK: - Answer reachability

    func testAcceptsSupervisorAnswer_coversParkedAndWaiting() {
        XCTAssertTrue(StepStatus.needsSupervisorInput.acceptsSupervisorAnswer)
        XCTAssertTrue(StepStatus.paused.acceptsSupervisorAnswer)
        for status in [StepStatus.pending, .running, .needsApproval, .failed, .done] {
            XCTAssertFalse(status.acceptsSupervisorAnswer, "\(status) must not accept an answer")
        }
    }

    func testCanReceiveSupervisorAnswer_parkedWaitingStep() {
        let step = makeStep(needsSupervisorInput: true, status: .paused, toolCalls: [askCall("Q")])
        XCTAssertTrue(step.canReceiveSupervisorAnswer)
    }

    /// Waiting but mid-flight: the trailing-ask race can read as waiting while the
    /// step is still `.running`, and an answer must NOT be routed there.
    func testCanReceiveSupervisorAnswer_falseWhileRunning() {
        let step = makeStep(needsSupervisorInput: false, status: .running, toolCalls: [askCall("Q")])
        XCTAssertTrue(step.hasActiveSupervisorInput)
        XCTAssertFalse(step.canReceiveSupervisorAnswer)
    }

    // MARK: - Run rollup (parallel roles — CLAUDE.md #45)

    func testRun_rollsUpAcrossParallelSteps() {
        let quiet = makeStep(id: "a", needsSupervisorInput: false)
        let waiting = makeStep(id: "b", needsSupervisorInput: true, toolCalls: [askCall("Q")])
        var run = Run(id: 0, teamID: "t")
        run.steps = [quiet, waiting]
        XCTAssertTrue(run.hasActiveSupervisorInput)
        XCTAssertEqual(run.activeSupervisorQuestionIDs, Set([waiting.activeSupervisorQuestionID!]))
    }

    func testRun_noWaitingSteps_isEmpty() {
        var run = Run(id: 0, teamID: "t")
        run.steps = [makeStep(id: "a", needsSupervisorInput: false)]
        XCTAssertFalse(run.hasActiveSupervisorInput)
        XCTAssertTrue(run.activeSupervisorQuestionIDs.isEmpty)
    }

    // MARK: - Task rollup

    func testTask_scopedToActiveRun() {
        var stale = Run(id: 0, teamID: "t")
        stale.steps = [makeStep(needsSupervisorInput: true, toolCalls: [askCall("old")])]
        var current = Run(id: 1, teamID: "t")
        current.steps = [makeStep(needsSupervisorInput: false)]
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [stale, current])
        XCTAssertFalse(task.hasPendingSupervisorInput,
                       "a flag on a superseded run must not resurrect the indicator")
        XCTAssertTrue(task.activeSupervisorQuestionIDs.isEmpty)
    }

    func testTask_closedTaskNeverWaits() {
        var run = Run(id: 0, teamID: "t")
        run.steps = [makeStep(needsSupervisorInput: true, toolCalls: [askCall("Q")])]
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [run])
        XCTAssertTrue(task.hasPendingSupervisorInput)
        task.closedAt = Date()
        XCTAssertFalse(task.hasPendingSupervisorInput,
                       "closing is the Supervisor's explicit done, whatever the run holds")
        XCTAssertTrue(task.activeSupervisorQuestionIDs.isEmpty)
    }

    func testTask_noRuns_isNotWaiting() {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [])
        XCTAssertFalse(task.hasPendingSupervisorInput)
    }

    // MARK: - Answer scan: equivalence corner cases

    /// The scan must not stop at the first NON-answer message after the ask —
    /// only at a message older than the ask. Directly discriminates a reverse
    /// walk that breaks on "not an answer" from one that breaks on "older".
    func testAnswerScan_nonAnswerMessagesAfterTheAsk_doNotHideTheAnswer() {
        let ask = askCall("Q1")
        let noise = LLMMessage(role: .assistant, content: "thinking out loud")
        let noise2 = LLMMessage(role: .assistant, content: "still working")
        let answer = answerMessage("A1")
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [ask],
            conversation: [noise, answer, noise2]
        )
        XCTAssertFalse(step.hasActiveSupervisorInput,
                       "an answer after the ask resolves it even with later non-answer turns")
    }

    /// Strictly `>`: a message stamped at the same instant as the ask is not
    /// "after" it. `MonotonicClock` makes this unreachable in production, but the
    /// scan's break condition is written in terms of it, so it is pinned.
    func testAnswerScan_answerAtTheSameInstantAsTheAsk_doesNotResolveIt() {
        let ask = askCall("Q1")
        var answer = answerMessage("A1")
        answer.createdAt = ask.createdAt
        let step = makeStep(needsSupervisorInput: false, toolCalls: [ask], conversation: [answer])
        XCTAssertTrue(step.hasActiveSupervisorInput)
    }

    func testAnswerScan_emptyConversation_isWaiting() {
        let step = makeStep(needsSupervisorInput: false, toolCalls: [askCall("Q1")], conversation: [])
        XCTAssertTrue(step.hasActiveSupervisorInput)
    }

    func testAnswerScan_severalAnswersAfterTheAsk_resolveIt() {
        let ask = askCall("Q1")
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [ask],
            conversation: [answerMessage("A1"), answerMessage("A2"), answerMessage("A3")]
        )
        XCTAssertFalse(step.hasActiveSupervisorInput)
    }

    /// The ordering assumption the tail-bounded scan rests on, and the DIRECTION
    /// it fails in when violated. `llmConversation` is `createdAt`-ascending in
    /// production (append-only; the only re-stamps — `applyRetryNotice` and
    /// `commitStreamingContent` — move the TAIL element forward). If that ever
    /// breaks, a tail-bounded scan can stop before an out-of-place newer answer
    /// and read "still waiting" — it can never read "answered" when it is not.
    /// Waiting is the conservative direction: the composer keeps showing the
    /// question and the human can still reply. Pinned so the failure mode is a
    /// recorded property rather than an accident.
    func testAnswerScan_outOfOrderConversation_failsTowardStillWaiting() {
        let ask = askCall("Q1")
        let newerAnswer = answerMessage("A1")          // stamped after the ask
        var older = LLMMessage(role: .assistant, content: "out of place")
        older.createdAt = ask.createdAt.addingTimeInterval(-1)
        // Deliberately non-ascending: the newer answer sits BEFORE an older turn.
        let step = makeStep(
            needsSupervisorInput: false,
            toolCalls: [ask],
            conversation: [newerAnswer, older]
        )
        XCTAssertTrue(step.hasActiveSupervisorInput,
                      "a tail-bounded scan may miss an out-of-order answer; it must never "
                      + "invent one — the conservative direction is STILL WAITING")
    }

    // MARK: - Work bound

    /// The Θ(N²) defect this scan carried: `MainLayoutView.activeTaskObservation`
    /// is an `onChange` KEY, so it is evaluated on EVERY body pass, i.e. on every
    /// `mutateTask`; a forward whole-conversation scan therefore cost Θ(messages)
    /// per append and Θ(N²) across a chat session, on the MainActor.
    ///
    /// Asserted as a SCALING RATIO on a work counter rather than wall-clock —
    /// the test target runs parallel and CI hardware is thermally variable
    /// (`SearchExecutorCounterTests`), and the shape follows
    /// `TaskStreamSplitTests`' ratio-with-a-generous-constant.
    func testAnswerScan_workIsBoundedByTheTailAfterTheAsk_notByTheConversation() {
        let small = examinedScanningParkedStep(historyBefore: 100)
        let large = examinedScanningParkedStep(historyBefore: 1000)
        XCTAssertGreaterThan(
            small, 0,
            "anti-vacuum: a counter that never increments satisfies any ceiling")
        XCTAssertLessThan(
            large, small * 2,
            "10x the history must not cost 10x the scan — the answer can only be "
            + "newer than the trailing ask, so the walk is bounded by the tail after it. "
            + "got \(small) -> \(large)")
    }

    /// Builds the PARKED shape — a trailing ask with no answer after it and
    /// `historyBefore` older turns — and returns how many messages the scan
    /// examined. History is constructed FIRST so `MonotonicClock` stamps every
    /// message before the ask call.
    private func examinedScanningParkedStep(historyBefore: Int) -> Int {
        let history = (0..<historyBefore).map { LLMMessage(role: .assistant, content: "turn \($0)") }
        let ask = askCall("Q")
        let step = makeStep(needsSupervisorInput: false, toolCalls: [ask], conversation: history)
        SupervisorInputScanProbe._testResetExamined()
        XCTAssertNotNil(step.activeSupervisorQuestionID, "fixture must be in the parked shape")
        return SupervisorInputScanProbe._testExamined()
    }

    // MARK: - Fixtures

    private func askCall(_ question: String) -> StepToolCall {
        StepToolCall(name: ToolNames.askSupervisor, argumentsJSON: "{\"question\":\"\(question)\"}")
    }

    private func answerMessage(_ text: String) -> LLMMessage {
        LLMMessage(
            role: .user,
            content: "\(MessageSourceContext.supervisorAnswerPrefix)\(text)",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
    }

    /// `conversation` (when non-nil) is used verbatim so a test can control the
    /// CREATION ORDER of answers relative to ask calls — the predicate's law is
    /// "an answer landed AFTER the trailing ask", and `MonotonicClock` stamps
    /// everything at construction. The `answerMessages` count builds answers
    /// AFTER every tool call in the argument list, i.e. the asked-then-answered
    /// shape.
    private func makeStep(
        id: String = "engineer",
        needsSupervisorInput: Bool,
        status: StepStatus = .running,
        toolCalls: [StepToolCall] = [],
        answerMessages: Int = 0,
        conversation: [LLMMessage]? = nil,
        supervisorAnswer: String? = nil
    ) -> StepExecution {
        let answers = conversation ?? (0..<answerMessages).map { self.answerMessage("A\($0)") }
        return StepExecution(
            id: id,
            role: .softwareEngineer,
            title: "Step",
            status: status,
            toolCalls: toolCalls,
            needsSupervisorInput: needsSupervisorInput,
            supervisorAnswer: supervisorAnswer,
            llmConversation: answers
        )
    }
}
