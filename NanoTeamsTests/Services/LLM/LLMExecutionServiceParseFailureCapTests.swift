import XCTest

@testable import NanoTeams

/// Verifies the per-step cap on consecutive Harmony parse failures.
///
/// Regression: in run `tasks/5/subtasks/6` the child team's UI Designer step
/// looped silently for 6+ iterations because `qwen3.5-9b-mlx` consistently emitted
/// the SAME malformed tool call every retry — `onclick=\"appendOperator('-')">` with
/// the closing `\"` un-escaped. The generic `.malformedJSON` retry nudge can't fix
/// what the model can't see, and pre-fix nothing capped the loop. The Harmony
/// streaming rewind dropped the visible content while preserving thinking, so the
/// activity feed showed a wall of "Thinking" bubbles with no signal what was wrong.
///
/// Post-fix: after 3 consecutive `.malformedJSON` parse failures, escalate to the
/// Supervisor with an actionable question instead of looping until
/// `delegate_to_team`'s 30-min timeout. Mirrors the existing `consecutiveDriftTurnCount`
/// pattern at `LLMExecutionService+StepFlowControl.swift:46-60`.
@MainActor
final class LLMExecutionServiceParseFailureCapTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    /// Verbatim malformed payload from run `tasks/5/subtasks/6` correlation 3AF0CBF5.
    /// The bare `"` after `appendOperator('-')` (no escape) closes the JSON string
    /// mid-value. `ToolCallParsingHelpers.classifyHarmonyCallIssue` returns
    /// `.malformedJSON` for this shape.
    private static let malformedHarmonyPayload = """
    [reasoning]
    Creating the calculator HTML.
    [/reasoning]

    <|call|>{"name":"create_artifact","arguments":{"content":"<button onclick=\\"appendOperator('-')">-</button>","name":"index.html"}}<|end|>
    """

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: "ui_designer_step", role: .softwareEngineer, title: "UI Designer", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "Calculator", supervisorTask: "build a calculator site", runs: [run])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        super.tearDown()
    }

    // MARK: - Below threshold: continueLoop with retry nudge

    func testFirstMalformedJSONFailure_continuesLoopAndIncrementsCounter() async {
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 0)
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.malformedHarmonyPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("First parse failure should continueLoop, got \(stop)")
            return
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(
            (messages[0].content ?? "").contains("malformed JSON"),
            "Below threshold should still send the existing retry nudge"
        )
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 1)
    }

    func testSecondMalformedJSONFailure_continuesLoopAndCounterReachesTwo() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.malformedHarmonyPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 1)

        var messages2: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.malformedHarmonyPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages2
        )
        guard case .continueLoop = stop else {
            XCTFail("Second parse failure should still continueLoop, got \(stop)")
            return
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)
    }

    // MARK: - At threshold: escalate to Supervisor

    func testThirdConsecutiveMalformedJSON_escalatesToSupervisorAndResetsCounter() async {
        // Prime to 2 by replaying the payload twice.
        for _ in 0..<2 {
            var msgs: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: Self.malformedHarmonyPayload,
                sawHarmonyMarker: true,
                task: task,
                roleDefinition: nil,
                conversationMessages: &msgs
            )
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)

        // Third failure must escalate.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.malformedHarmonyPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .needsSupervisorInput(let question) = stop else {
            XCTFail("Third parse failure must escalate to supervisor, got \(stop)")
            return
        }
        XCTAssertTrue(
            question.contains("3 consecutive malformed"),
            "Escalation question should name the failure mode, got: \(question)"
        )
        XCTAssertTrue(
            question.contains("restart the role with a different model")
            || question.contains("simplify the brief")
            || question.contains("mark the step failed"),
            "Escalation should give actionable options, got: \(question)"
        )
        // Counter reset so a post-supervisor restart starts clean (matches drift pattern).
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 0)
        // No retry nudge appended on escalation — only setNeedsSupervisorInput fires.
        XCTAssertTrue(
            messages.isEmpty,
            "Escalation should NOT append another retry nudge to conversationMessages"
        )
        // T3: persistence assertion — `setNeedsSupervisorInput` must have actually
        // set the step's `supervisorQuestion` field via `mutateTask`. Without this,
        // a future swap to a logger-only path would silently break the user-visible
        // escalation while still passing the `.needsSupervisorInput(question:)`
        // signature check above.
        let persistedQuestion = mockDelegate.taskToMutate?.runs[0].steps[0].supervisorQuestion
        XCTAssertEqual(
            persistedQuestion, question,
            "Cap escalation must persist the supervisor question on the step (regression: silent no-op leaves UI without a question)"
        )
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs[0].steps[0].needsSupervisorInput, true,
            "Cap escalation must mark the step `needsSupervisorInput`"
        )
    }

    // MARK: - T1: Production reset point exercised end-to-end

    /// Pins that `resetCountersOnParseableToolCall` (called from
    /// `runOneLLMToolIteration` immediately before `executeToolCalls`) actually
    /// resets the malformed-JSON counter. Pre-fix the test exercised only the
    /// `_testResetHarmonyParseFailureCounter` helper — a refactor that moved the
    /// production reset (e.g. into `cleanup()` only, or behind an early-return)
    /// would not have failed any test. This test calls the real production
    /// method directly, then verifies the counter zeroed.
    func testProductionResetMethod_clearsParseFailureCounter() async {
        // Pre-arm the counter to 2.
        for _ in 0..<2 {
            var msgs: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: Self.malformedHarmonyPayload,
                sawHarmonyMarker: true,
                task: task,
                roleDefinition: nil,
                conversationMessages: &msgs
            )
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)

        // Hit the production reset path directly (the same method
        // `runOneLLMToolIteration` calls before executing tool calls).
        service._testResetCountersOnParseableToolCall(stepID: stepID)

        XCTAssertEqual(
            service._testHarmonyParseFailureCounter(stepID: stepID), 0,
            "Production reset method must zero the malformed-JSON counter"
        )
        // Drift counter is also part of the reset cluster — verify it stays
        // at the same code path so a future split doesn't silently regress.
        XCTAssertEqual(
            service._testDriftCounter(stepID: stepID), 0,
            "Production reset method must zero the drift counter (same cluster)"
        )
    }

    // MARK: - Counter reset on successful tool execution

    func testCounterReset_betweenFailures_thirdFailureDoesNotEscalate() async {
        // Two failures, counter → 2.
        for _ in 0..<2 {
            var msgs: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: Self.malformedHarmonyPayload,
                sawHarmonyMarker: true,
                task: task,
                roleDefinition: nil,
                conversationMessages: &msgs
            )
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)

        // Simulate a successful tool call landing between failures (production reset
        // happens immediately before `executeToolCalls` in `runOneLLMToolIteration`).
        service._testResetHarmonyParseFailureCounter(stepID: stepID)
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 0)

        // Two more failures → counter back at 2, NOT escalation.
        for _ in 0..<2 {
            var msgs: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: Self.malformedHarmonyPayload,
                sawHarmonyMarker: true,
                task: task,
                roleDefinition: nil,
                conversationMessages: &msgs
            )
            if case .needsSupervisorInput = stop {
                XCTFail("After reset, two more failures must NOT escalate")
                return
            }
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)
    }

    // MARK: - missingToolName does NOT increment

    /// `.missingToolName` is a different recoverable defect — the existing inferred-name
    /// nudge usually self-corrects on the next attempt. Counting it against the cap would
    /// prematurely escalate roles that hit one missing-name turn while otherwise
    /// producing valid JSON.
    func testMissingToolNameFailure_doesNotIncrementParseFailureCounter() async {
        // From `NoToolCallsBranchOrderingTests` — valid JSON, no top-level `name`.
        let missingNamePayload = "[reasoning]\nCreating PRD.\n[/reasoning]\n\n<|call|>{\"arguments\":{\"content\":\"PRD\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: missingNamePayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("missingToolName should continueLoop, got \(stop)")
            return
        }
        XCTAssertTrue(
            (messages[0].content ?? "").contains("missing the top-level `name` field"),
            "Should still send the missing-name-specific nudge"
        )
        // Counter stays at 0 — only .malformedJSON increments it.
        XCTAssertEqual(
            service._testHarmonyParseFailureCounter(stepID: stepID), 0,
            "missingToolName must NOT count against the malformed-JSON cap"
        )
    }

    // MARK: - Revision mode skips the cap

    /// Mirrors the drift detector's revision-mode skip. When the supervisor is already
    /// driving via the revision flow, the cap escalation would create a recursion
    /// (escalate → supervisor responds → fail again → escalate). Revision-mode parse
    /// failures must continueLoop and the counter must RESET (mirroring the drift
    /// counter's reset-on-revision symmetry — an accumulated pre-revision counter
    /// should not pre-trigger a post-revision escalation on the very first new turn).
    func testParseFailureDuringRevision_resetsCounterAndDoesNotEscalate() async {
        // Pre-arm the counter to 2 (simulating two pre-revision failures).
        for _ in 0..<2 {
            var msgs: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: Self.malformedHarmonyPayload,
                sawHarmonyMarker: true,
                task: task,
                roleDefinition: nil,
                conversationMessages: &msgs
            )
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)

        // Activate revision on the step.
        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "Please redo X"

        // Third failure during revision MUST NOT escalate.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.malformedHarmonyPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        if case .needsSupervisorInput = stop {
            XCTFail("Parse failure during revision must NOT escalate")
            return
        }
        // Counter RESET on entry to revision branch (mirrors drift-counter pattern).
        XCTAssertEqual(
            service._testHarmonyParseFailureCounter(stepID: stepID), 0,
            "Counter must reset on revision-mode entry so a pre-revision streak doesn't pre-trigger post-revision escalation"
        )
        XCTAssertTrue(
            (messages[0].content ?? "").contains("malformed JSON"),
            "Revision-mode failure should still send the retry nudge"
        )
    }

    /// Pin the second leg of the symmetry: when the model recovers from
    /// `.malformedJSON` to `.missingToolName` (parseable-but-no-name shape), the
    /// counter must reset. Without this, an old streak would carry over across
    /// the recovery and pre-trigger escalation on the next .malformedJSON turn.
    func testMissingToolNameTurn_resetsParseFailureCounter() async {
        // Pre-arm to 2.
        for _ in 0..<2 {
            var msgs: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: Self.malformedHarmonyPayload,
                sawHarmonyMarker: true,
                task: task,
                roleDefinition: nil,
                conversationMessages: &msgs
            )
        }
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: stepID), 2)

        // Now feed a `.missingToolName` shape — valid JSON, no top-level `name`.
        let missingNamePayload = "[reasoning]\nCreating PRD.\n[/reasoning]\n\n<|call|>{\"arguments\":{\"content\":\"PRD\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: missingNamePayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        XCTAssertEqual(
            service._testHarmonyParseFailureCounter(stepID: stepID), 0,
            "missingToolName recovery must reset the malformed-JSON counter"
        )
    }
}
