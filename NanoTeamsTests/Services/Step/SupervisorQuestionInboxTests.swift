import XCTest

@testable import NanoTeams

/// `SupervisorQuestionInbox.pending` — the ONE producer of "which supervisor questions are
/// waiting right now", read by the docked composer, the Quick Capture panel and the
/// Watchtower.
///
/// Most of this suite came over from `ActivityFeedBuilderTests` unchanged: the predicate,
/// the question-text preference chain, the escalation branch, the ordering and the
/// ask-index seam were pinned there while the producer lived in `Views/`, and they pin the
/// same behaviour here. What is new is the last section — one test per divergence the three
/// surfaces used to have, each of which was a different answer to the same question.
@MainActor
final class SupervisorQuestionInboxTests: XCTestCase {

    private typealias TN = ToolNames

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    private func makeMessage(
        role: LLMRole = .assistant,
        content: String,
        at timestamp: Date,
        sourceRole: Role? = nil,
        sourceContext: MessageSourceContext? = nil,
        thinking: String? = nil
    ) -> LLMMessage {
        LLMMessage(
            createdAt: timestamp,
            role: role,
            content: content,
            thinking: thinking,
            sourceRole: sourceRole,
            sourceContext: sourceContext
        )
    }

    private func makeToolCall(
        name: String = "read_file",
        at timestamp: Date,
        argumentsJSON: String = "{}"
    ) -> StepToolCall {
        StepToolCall(createdAt: timestamp, name: name, argumentsJSON: argumentsJSON)
    }

    private func makeStep(
        role: Role = .softwareEngineer,
        messages: [LLMMessage] = [],
        toolCalls: [StepToolCall] = [],
        status: StepStatus = .done,
        needsSupervisorInput: Bool = false,
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil,
        updatedAt: Date? = nil
    ) -> StepExecution {
        StepExecution(
            id: role.baseID,
            role: role,
            title: "\(role.displayName) Step",
            status: status,
            updatedAt: updatedAt ?? MonotonicClock.shared.now(),
            toolCalls: toolCalls,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: supervisorQuestion,
            supervisorAnswer: supervisorAnswer,
            llmConversation: messages
        )
    }

    /// One step, TWO ask calls in its history, no stored `supervisorQuestion` —
    /// the composer chip must read the LAST ask's arguments (`last(where:)`),
    /// never the first ask of the run.
    ///
    /// RED: swap the lookup to `first(where:)` → the chip shows "Q1?" and the
    /// asked-at anchor jumps back to the first call.
    func testActiveSupervisorQuestion_twoAsksInOneStep_lastAskWins() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#)
        let step = makeStep(
            role: .productManager,
            toolCalls: [ask1, ask2],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.headline, "Q2?")
        XCTAssertEqual(questions.first?.askedAt, date(200))
    }

    /// Companion to the above: `SupervisorQuestionInbox.pending` must still surface
    /// iter 2 so the docked composer has a chip — without this fix the dock
    /// would also miss the trailing call (`supervisorAnswer != nil` guard).
    func testActiveSupervisorQuestions_returnsTrailingUnansweredEvenWithStaleAnswer() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"first?"}"#)
        let answer1 = makeMessage(role: .user, content: "Supervisor answer: yes", at: date(150),
                                  sourceContext: .supervisorAnswer)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"second?"}"#)
        let step = makeStep(
            messages: [answer1],
            toolCalls: [ask1, ask2],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: "yes"
        )

        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1, "Trailing unanswered call must be reported as active")
        XCTAssertEqual(active.first?.headline, "second?", "The TRAILING call is the active one, not the answered first")
    }

    /// `needsSupervisorInput` is an OR'd defensive backstop in the active-input
    /// predicate. This test exercises it ALONE: the engine flag is set but the
    /// trailing-unanswered count-check WOULD return false. The backstop covers
    /// any engine path that flips the flag without a matching `ask_supervisor`
    /// tool call (e.g. legacy state, recovery flow, manual question injection).
    ///
    /// Without the backstop `SupervisorQuestionInbox.pending` would return `[]` while the
    /// flag said the step was waiting — the surfaces silently disagreeing with the engine.
    func testNeedsSupervisorInputBackstop_firesAloneWithoutTrailingAsk() {
        // Tool calls present but trailing call is NOT ask_supervisor.
        let read = makeToolCall(name: TN.readFile, at: date(100), argumentsJSON: "{}")
        let ask = makeToolCall(name: TN.askSupervisor, at: date(150), argumentsJSON: #"{"question":"legacy?"}"#)
        let answer = makeMessage(role: .user, content: "Supervisor answer: yes", at: date(170),
                                 sourceContext: .supervisorAnswer)
        // ask was answered (count-check returns false), but the flag is still
        // set — a stuck-flag legacy state we want to detect, not ignore.
        let step = makeStep(
            messages: [answer],
            toolCalls: [ask, read],  // trailing = read_file, NOT ask
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorAnswer: "yes"
        )

        // The dock must report a question so the user has a chip. (Without a trailing ask
        // there is no `lastCall` to surface, so it falls back to the step's stored
        // question — this pins that fall-through. The emit-side half of the same backstop
        // is pinned in `ActivityFeedBuilderTests`.)
        // (Without ask calls there's no `lastCall` to surface, so the dock falls
        // back to the step's stored question. This test pins that fall-through.)
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1, "Backstop must surface the active question to the dock too")
    }

    func testEmptyAskCalls_activeQuestions_isEmpty_whenFlagAlsoOff() {
        let step = makeStep(toolCalls: [], status: .running, needsSupervisorInput: false)
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertTrue(active.isEmpty, "Truly idle step is not active")
    }

    /// Transient mid-stream window between rounds — the source of the visual
    /// flicker reported in the bug screenshot. Sequence:
    ///   1. Round N-1: `setNeedsSupervisorInput("Q1")` → `supervisorQuestion="Q1"`, `needsSupervisorInput=true`
    ///   2. User answers → `needsSupervisorInput=false`. `supervisorQuestion="Q1"` STAYS
    ///      (`StepMessagingService.answerSupervisorQuestion` deliberately doesn't clear it).
    ///   3. Round N starts. `appendToolCalls(ask("Q2"))` fires → `step.toolCalls.last="Q2"`
    ///      and `runDataVersion` changes (toolCalls.count grew). Recompute runs.
    ///   4. BEFORE `setNeedsSupervisorInput("Q2")` lands, the cache sees:
    ///         `needsSupervisorInput=false`, `supervisorQuestion="Q1"` (stale), trailing ask="Q2".
    ///   5. `setNeedsSupervisorInput("Q2")` → `supervisorQuestion="Q2"`, `needsSupervisorInput=true`.
    ///
    /// Without `needsSupervisorInput` as the gate, step 4 would surface the
    /// stale "Q1" briefly until step 5 lands — visible as a flash of the
    /// previous question. The preference for `step.supervisorQuestion` must
    /// fire only when `setNeedsSupervisorInput` has confirmed it as fresh.
    func testActiveSupervisorQuestions_transientWindow_staleSupervisorQuestion_doesNotShadowNewToolCall() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1 (prev round)"}"#)
        let answer1 = makeMessage(
            role: .user, content: "Supervisor answer: a1", at: date(150),
            sourceContext: .supervisorAnswer
        )
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2 (current round)"}"#)

        let step = makeStep(
            messages: [answer1],
            toolCalls: [ask1, ask2],
            status: .running,
            // KEY: false, because setNeedsSupervisorInput("Q2") hasn't landed yet.
            // Q1's `true` was flipped to `false` by the user's answer to Q1.
            needsSupervisorInput: false,
            // KEY: still Q1 — answerSupervisorQuestion doesn't clear it,
            // and setNeedsSupervisorInput("Q2") hasn't fired yet.
            supervisorQuestion: "Q1 (prev round)",
            supervisorAnswer: "a1"
        )

        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1, "Trailing-unanswered path activates the step")
        XCTAssertEqual(
            active.first?.headline, "Q2 (current round)",
            "In the trailing-unanswered transient window, the new tool-call argument is fresher than the stale supervisorQuestion — needsSupervisorInput must gate the storedQ preference, otherwise the user sees a flash of the previous question."
        )
    }

    /// Last-resort fallback: when `step.supervisorQuestion` is nil AND the
    /// trailing `ask_supervisor` tool call's `argumentsJSON` is unparseable,
    /// the chip MUST render the literal `"?"` so the user knows there's a
    /// pending question even if the text is lost. Pinning this prevents a
    /// regression to `""` (empty chip label, indistinguishable from no
    /// pending question at all) — the only path that puts a `"?"` in front
    /// of the user, otherwise untested.
    func testActiveSupervisorQuestions_nilStoredQuestion_unparseableJSON_fallsBackToQuestionMark() {
        let askWithBadJSON = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: "not valid json {"
        )
        let step = makeStep(
            toolCalls: [askWithBadJSON],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: nil
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.headline, "?",
            "Last-resort fallback MUST be \"?\" so the user sees a pending-question signal. Empty string would render an invisible chip — regression to silent failure."
        )
    }

    /// The THIRD rung: the flag is off (the transient window between the ask landing and the
    /// park being raised), the tool-call arguments do not parse, and the step still carries a
    /// stored question from the previous round. A possibly-stale sentence beats `?` — the
    /// placeholder says "a question exists and we cannot read it", which is strictly less than
    /// what is in hand.
    ///
    /// RED: fall straight to the placeholder when the flag is off → the chip reads `?` for the
    /// frames of that window, on a task whose previous question is right there.
    func testActiveSupervisorQuestions_flagOff_unparseableArgs_prefersStaleStoredTextOverPlaceholder() {
        let askWithBadJSON = makeToolCall(
            name: TN.askSupervisor, at: date(100), argumentsJSON: "not valid json {")
        let step = makeStep(
            toolCalls: [askWithBadJSON],
            status: .needsSupervisorInput,
            needsSupervisorInput: false,
            supervisorQuestion: "Which target should I build?"
        )

        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])

        XCTAssertEqual(active.count, 1, "a trailing unanswered ask is pending with or without the flag")
        XCTAssertEqual(active.first?.headline, "Which target should I build?")
    }

    /// Whitespace-only `step.supervisorQuestion` must NOT shadow the tool-call
    /// argument. Trimming + emptiness check is the gate — without it, an
    /// engine path that accidentally writes `" "` would silently override the
    /// real ask_supervisor question with a blank prompt in the activity feed
    /// while QC overlay (which has its own non-nil guard) would still show
    /// the real question — re-introducing the desync this whole layer fixes.
    func testActiveSupervisorQuestions_whitespaceOnlyStoredQuestion_fallsBackToToolCallArg() {
        let ask = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: #"{"question":"Real question from tool call"}"#
        )
        let step = makeStep(
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "   \n  \t  "
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.headline, "Real question from tool call",
            "Whitespace-only supervisorQuestion must NOT shadow the tool-call argument"
        )
    }

    /// Pre-escalation regression guard: when `step.supervisorQuestion` is nil
    /// (the normal mid-stream state right after appendToolCalls but before
    /// setNeedsSupervisorInput), the question text MUST come from the tool
    /// call's argumentsJSON. Otherwise normal `ask_supervisor` flows show "?"
    /// during the brief window when the question card materializes.
    func testActiveSupervisorQuestions_nilStoredQuestion_usesToolCallArg() {
        let ask = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: #"{"question":"What scheme should I use?"}"#
        )
        // needsSupervisorInput=true via flag, but supervisorQuestion not yet
        // persisted to the step (transient window).
        let step = makeStep(
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: nil
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.headline, "What scheme should I use?")
    }

    /// Escalation path pairs with the last assistant turn so the composer's
    /// preview shows what the LLM actually said (the refusal that triggered
    /// the cap), not just the system-generated escalation prompt. Without this,
    /// users would see only "Role X emitted 3 refusal messages…" with no
    /// context of WHAT the model said.
    func testActiveSupervisorQuestions_escalationPath_pairsWithLastAssistantMessage() {
        let refusal = makeMessage(
            role: .assistant,
            content: "I'm sorry, but I can't identify a clear task to work on.",
            at: date(50)
        )
        let step = makeStep(
            messages: [refusal],
            toolCalls: [],  // escalation path = no tool call
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Role Coding Agent emitted 3 consecutive refusal messages. Please advise."
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.paired?.id, refusal.id,
                       "Escalation must pair with last assistant turn so user sees the LLM's refusal context")
    }

    /// Mixed batch: one step with a real ask_supervisor (normal path) + one
    /// step with escalation (no tool call). Both must surface, and sort order
    /// by askedAt must be deterministic across surfaces (CLAUDE.md notes the
    /// chip-row order matters for auto-selection).
    func testActiveSupervisorQuestions_mixedNormalAndEscalation_bothSurface() {
        let ask = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: #"{"question":"Normal path question?"}"#
        )
        let stepNormal = StepExecution(
            id: "step-normal",
            role: .softwareEngineer,
            title: "SWE Step",
            status: .needsSupervisorInput,
            updatedAt: date(110),
            toolCalls: [ask],
            needsSupervisorInput: true,
            supervisorQuestion: "Normal path question?",
            llmConversation: []
        )

        let stepEscalation = StepExecution(
            id: "step-escalation",
            role: .codeReviewer,
            title: "CR Step",
            status: .needsSupervisorInput,
            updatedAt: date(200),
            toolCalls: [],
            needsSupervisorInput: true,
            supervisorQuestion: "Escalation question — please advise.",
            llmConversation: []
        )

        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [stepEscalation, stepNormal])
        XCTAssertEqual(active.count, 2, "Both normal and escalation steps must surface")
        // Sort order: askedAt ascending. Normal step has askedAt = tool call timestamp (100),
        // escalation step has askedAt = step.updatedAt (200). Normal comes first.
        XCTAssertEqual(active.first?.headline, "Normal path question?")
        XCTAssertEqual(active.last?.headline, "Escalation question — please advise.")
    }

    /// Determinism guard: two simultaneous escalation steps with identical
    /// askedAt timestamps must sort by stepID for stable chip ordering. The
    /// sort tie-breaker uses stepID per `SupervisorQuestionInbox.pending`'s
    /// comment — without this, the leftmost Answer chip could flip on each
    /// recompute and retarget user typing to a different role.
    func testActiveSupervisorQuestions_sameAskedAt_sortsByStepID() {
        let sameTimestamp = date(100)
        let stepA = StepExecution(
            id: "aaa-step",
            role: .softwareEngineer,
            title: "A", status: .needsSupervisorInput,
            updatedAt: sameTimestamp,
            toolCalls: [],
            needsSupervisorInput: true,
            supervisorQuestion: "From A",
            llmConversation: []
        )
        let stepB = StepExecution(
            id: "zzz-step",
            role: .codeReviewer,
            title: "B", status: .needsSupervisorInput,
            updatedAt: sameTimestamp,
            toolCalls: [],
            needsSupervisorInput: true,
            supervisorQuestion: "From B",
            llmConversation: []
        )

        // Pass in non-sorted input order; result must still be aaa < zzz.
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [stepB, stepA])
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active[0].stepID, "aaa-step", "Tie-break by stepID ascending")
        XCTAssertEqual(active[1].stepID, "zzz-step")
    }

    /// Escalation-after-ask: a real `ask_supervisor` tool call landed earlier,
    /// then the engine's refusal-loop / drift / parse-failure cap fired and
    /// `setNeedsSupervisorInput` overwrote `step.supervisorQuestion` with the
    /// escalation text. The activity-feed composer must surface the CURRENT
    /// (escalation) question, NOT the stale tool-call argument — otherwise it
    /// disagrees with the QuickCapture overlay (which reads
    /// `step.supervisorQuestion` directly in
    /// `DefaultQuickCaptureModeCoordinator.resolveMode`) and the user sees
    /// two different questions for the same waiting step.
    func testActiveSupervisorQuestions_prefersStepSupervisorQuestionOverStaleToolCallArg() {
        let askWithStaleQ = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"I've reviewed the repository contents, but there's no code or clear task to act on."}"#
        )
        let answer = makeMessage(
            role: .user, content: "Supervisor answer: йцу", at: date(150),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [answer],
            toolCalls: [askWithStaleQ],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            // Escalation overwrote supervisorQuestion with a different text:
            supervisorQuestion: "Role Coding Agent emitted 3 consecutive refusal messages without calling any tools. The model appears stuck — please advise how to proceed."
        )

        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.headline,
            "Role Coding Agent emitted 3 consecutive refusal messages without calling any tools. The model appears stuck — please advise how to proceed.",
            "When step.supervisorQuestion is set, it MUST win over a stale tool-call argument — setNeedsSupervisorInput is the authoritative writer for the current question text, and QC overlay reads it directly. Both surfaces must agree."
        )
    }

    /// Escalation path: when the engine calls `setNeedsSupervisorInput` from a
    /// drift cap / refusal-loop cap / parse-failure cap (in
    /// `LLMExecutionService+StepFlowControl.swift`), it sets
    /// `needsSupervisorInput=true` + `supervisorQuestion=q` but does NOT append
    /// an `ask_supervisor` tool call to `step.toolCalls`. `SupervisorQuestionInbox.pending`
    /// must surface the stored question so the composer chip + question card
    /// render — otherwise the user sees the role pause silently with no question
    /// to answer. Pinned because the engine's no-tool-call escape hatch is the
    /// ONLY path through which this state legally arises (CLAUDE.md §7's
    /// `setNeedsSupervisorInput` doc explicitly calls it out).
    func testEscalationPath_emptyAskCalls_flagSet_surfacesStoredQuestion() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Role X produced two consecutive long reasoning responses without calling any tool. Please advise."
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1, "Escalation must surface the stored question to the dock")
        XCTAssertEqual(
            active.first?.headline,
            "Role X produced two consecutive long reasoning responses without calling any tool. Please advise.",
            "Question text must come from step.supervisorQuestion when no ask_supervisor tool call exists"
        )
    }

    /// Defense-in-depth at the view layer. The companion writer at
    /// `LLMExecutionService+TaskStateMutations.swift:140` currently guards the
    /// `setNeedsSupervisorInput` path against empty question text — but future
    /// engine paths (or accidental edits) could set `needsSupervisorInput=true`
    /// with a nil/empty `supervisorQuestion` and no tool call. Today's
    /// `SupervisorQuestionInbox.pending` silently drops such steps via
    /// `guard !trimmedQ.isEmpty else { continue }`, wedging the engine in
    /// `.needsSupervisorInput` forever with no UI signal — no composer chip,
    /// no question card, no error banner. This test pins the contract that the
    /// composer MUST surface a placeholder chip so the supervisor can unblock
    /// the step instead.
    func testActiveSupervisorQuestions_emptyStoredQuestion_noToolCall_emitsPlaceholderChip() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: nil
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(
            active.count, 1,
            "Empty-question waiting step MUST surface a placeholder chip — silent drop wedges the engine forever with no UI signal."
        )
        XCTAssertEqual(
            active.first?.headline, SupervisorQuestionInbox.escalationFallbackQuestion,
            "Placeholder text must come from the canonical constant so UI/log surfaces stay in sync."
        )
    }

    /// Whitespace-only `step.supervisorQuestion` on the escalation path (no
    /// tool call) must also fall back to the placeholder rather than silently
    /// dropping the step. Without this, an engine path that writes `"  \n  "`
    /// would also wedge the step.
    func testActiveSupervisorQuestions_whitespaceOnlyStoredQuestion_noToolCall_emitsPlaceholderChip() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "   \n  \t  "
        )
        let active = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.headline, SupervisorQuestionInbox.escalationFallbackQuestion)
    }

    func testActiveSupervisorQuestions() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let step1 = makeStep(
            role: .productManager,
            toolCalls: [ask1],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#)
        let step2 = makeStep(
            role: .techLead,
            toolCalls: [ask2],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        // Answered step — should NOT appear in active questions.
        // In production both `step.supervisorAnswer` AND a matching
        // `Supervisor answer: …` LLMMessage are written together (see
        // `LLMExecutionService+StepLifecycle.swift:124-128`); the count check
        // distinguishes a real answered state from a stale-carry race window.
        let ask3 = makeToolCall(name: TN.askSupervisor, at: date(300), argumentsJSON: #"{"question":"Q3?"}"#)
        let answer3 = makeMessage(role: .user, content: "Supervisor answer: Done",
                                  at: date(350), sourceContext: .supervisorAnswer)
        let step3 = makeStep(
            role: .softwareEngineer,
            messages: [answer3],
            toolCalls: [ask3],
            supervisorAnswer: "Done"
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step1, step2, step3])
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].headline, "Q1?")
        XCTAssertEqual(questions[0].role, .productManager)
        XCTAssertEqual(questions[1].headline, "Q2?")
        XCTAssertEqual(questions[1].role, .techLead)
    }

    /// Pins FIFO fairness for the leftmost Answer chip: regardless of the order steps
    /// arrive in (Dictionary iteration of `roleStatuses` is non-deterministic), the
    /// active questions must be sorted ascending by the `ask_supervisor` timestamp.
    func testActiveSupervisorQuestions_sortsByAskedAtAscending_regardlessOfInputOrder() {
        let askLate = makeToolCall(name: TN.askSupervisor, at: date(300), argumentsJSON: #"{"question":"late?"}"#)
        let stepLate = makeStep(
            role: .softwareEngineer, toolCalls: [askLate],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )
        let askEarly = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"early?"}"#)
        let stepEarly = makeStep(
            role: .productManager, toolCalls: [askEarly],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )
        let askMid = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"mid?"}"#)
        let stepMid = makeStep(
            role: .techLead, toolCalls: [askMid],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )

        // Steps deliberately passed out of chronological order.
        let questions = SupervisorQuestionInbox.pending(
            taskID: 1,
            steps: [stepLate, stepEarly, stepMid]
        )
        XCTAssertEqual(questions.map(\.role), [.productManager, .techLead, .softwareEngineer],
                       "Expected ascending askedAt: early(PM) < mid(TL) < late(SWE)")
        let timestamps = questions.map(\.askedAt)
        XCTAssertEqual(timestamps, [date(100), date(200), date(300)])
    }

    /// `askedAt` must come from the LAST `ask_supervisor` call in the step (the active
    /// question), not from the first one. Otherwise a role that asked twice unfairly
    /// holds the leftmost slot using a stale early timestamp.
    func testActiveSupervisorQuestions_askedAtComesFromLastAskCall() {
        let firstAsk = makeToolCall(name: TN.askSupervisor, at: date(50), argumentsJSON: #"{"question":"old?"}"#)
        let lastAsk = makeToolCall(name: TN.askSupervisor, at: date(400), argumentsJSON: #"{"question":"current?"}"#)
        let step = makeStep(
            role: .productManager, toolCalls: [firstAsk, lastAsk],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].headline, "current?",
                       "Should surface the current (last) question, not the stale first one")
        XCTAssertEqual(questions[0].askedAt, date(400),
                       "askedAt must reflect the active question's timestamp, not the original ask")
    }

    /// When two pending questions share `askedAt` (same `MonotonicClock` tick or
    /// identical `Date()`), the order must be stable across recomputes — otherwise
    /// the leftmost Answer chip flips between recomputes and any user typing into
    /// the auto-selected first chip would silently retarget. We tie-break by `stepID`.
    func testActiveSupervisorQuestions_tieBreaker_isStableByStepID() {
        let sameTime = date(100)
        let askA = makeToolCall(name: TN.askSupervisor, at: sameTime, argumentsJSON: #"{"question":"A?"}"#)
        let stepA = makeStep(
            role: .productManager, toolCalls: [askA],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )
        let askB = makeToolCall(name: TN.askSupervisor, at: sameTime, argumentsJSON: #"{"question":"B?"}"#)
        let stepB = makeStep(
            role: .techLead, toolCalls: [askB],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )

        // PM step id < TL step id alphabetically (`product_manager` < `tech_lead`).
        let questionsForward = SupervisorQuestionInbox.pending(taskID: 1, steps: [stepA, stepB])
        let questionsReverse = SupervisorQuestionInbox.pending(taskID: 1, steps: [stepB, stepA])
        XCTAssertEqual(
            questionsForward.map(\.stepID), questionsReverse.map(\.stepID),
            "Same-tick questions must produce identical order regardless of input sequence"
        )
        XCTAssertEqual(
            questionsForward.map(\.stepID).sorted(), questionsForward.map(\.stepID),
            "Tie-breaker should be stepID ascending"
        )
    }

    /// The refuter's shape: the role asked, did tool work, and was THEN parked by a
    /// cap. The chip must still carry the earlier ask's identity and timestamp —
    /// `positions.last` is `lastIndex(where:)`, not "the trailing call".
    ///
    /// RED: replace `askIndex(step).lastParkedPosition(in:)` in `SupervisorQuestionInbox.pending` with
    /// `step.toolCalls.last?.name == ToolNames.askSupervisor ? step.toolCalls.count - 1 : nil`
    /// → `toolCallID` becomes a synthetic UUID and `askedAt == step.updatedAt`.
    func testActiveSupervisorQuestions_earlierAskThenToolWorkThenCapPark_findsTheEarlierAsk() {
        let ask = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let step = makeStep(
            role: .productManager,
            toolCalls: [ask, makeToolCall(at: date(200)), makeToolCall(at: date(300))],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Cap: please advise",
            updatedAt: date(400)
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.askedAt, date(100), "anchored on the ask, not on updatedAt")
        XCTAssertEqual(questions.first?.headline, "Cap: please advise",
                       "flag-true prefers the stored text over the call's argument")
        XCTAssertNil(questions.first?.paired, "no assistant turn precedes the ask")
        // The two halves come apart HERE, and deliberately. Text and time are anchored on
        // that earlier ask; the dismissal identity is not, because the trailing call is not
        // an ask and `activeSupervisorQuestionID` is nil. Handing this banner Q1's UUID
        // would key it on a question the Supervisor has already read — and possibly
        // dismissed, under which the cap park would be born dismissed.
        XCTAssertNil(questions.first?.askCallID,
                     "the cap park keys on its text, never on the earlier ask's UUID")
        XCTAssertNotEqual(questions.first?.askCallID, ask.id)
    }

    /// Pairs `paired.id` / `paired.thinking` with the assistant turn whose
    /// `createdAt <= lastCall.createdAt`. `id` drives bubble-suppression in the
    /// feed; `thinking` feeds the composer's thinking disclosure.
    func testActiveSupervisorQuestions_populatesPairedIDAndThinking() {
        let reply = makeMessage(
            content: "Explanation of findings.",
            at: date(90),
            thinking: "Reasoning."
        )
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [reply],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].paired?.id, reply.id)
        XCTAssertEqual(questions[0].paired?.thinking, "Reasoning.")
        XCTAssertEqual(questions[0].headline, "What next?")
    }

    /// In-flight window: `commitStreaming` and `appendToolCalls` have landed but
    /// `setNeedsSupervisorInput` hasn't fired yet (tool execution is still running).
    /// Without this branch the bubble would flash visible for ~50-1000ms before
    /// the composer takes over. See `replied-structured-petal.md`.
    func testActiveSupervisorQuestions_inFlight_pendingToolCallStillReturnsQuestion() {
        let reply = makeMessage(content: "Body.", at: date(90))
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [reply],
            toolCalls: [ask],
            status: .running,
            // Flag NOT yet flipped — we're between appendToolCalls and setNeedsSupervisorInput.
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(questions.count, 1, "Trailing ask_supervisor call alone must activate the chip")
        XCTAssertEqual(questions[0].paired?.id, reply.id)
    }

    /// Pairing must NOT activate when the trailing call is something other than
    /// `ask_supervisor` (e.g. the LLM asked once, supervisor answered, then the role
    /// emitted more tool calls). Without this guard, any leftover `ask_supervisor`
    /// somewhere in the call list would keep suppressing replies forever.
    func testActiveSupervisorQuestions_trailingNonAskCall_doesNotActivate() {
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"old?"}"#
        )
        let trailing = makeToolCall(name: "read_file", at: date(150))
        let step = makeStep(
            role: .productManager,
            toolCalls: [ask, trailing],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertTrue(questions.isEmpty,
                      "ask_supervisor is no longer the trailing call (a later read_file landed); chip must not appear")
    }

    // MARK: - A refused ask is not a question

    /// `QUESTIONNAIRE_REQUIRED` / `INVALID_ARGS`: the runtime refused the call and the loop
    /// went on. Read by name, the trailing call put a chip in the composer for a step that
    /// was still running (MeditationApp task 52 run 9, 2026-09-11).
    func testPending_runningStepWhoseTrailingAskWasRefused_isNotListed() {
        let refused = StepToolCall(
            createdAt: date(100), name: TN.askSupervisor,
            argumentsJSON: #"{"question":"Which one? 1. A 2. B"}"#,
            resultJSON: #"{"ok":false,"error":{"code":"QUESTIONNAIRE_REQUIRED"}}"#,
            isError: true)
        let step = makeStep(toolCalls: [refused], status: .running, needsSupervisorInput: false)
        XCTAssertTrue(SupervisorQuestionInbox.pending(taskID: 1, steps: [step]).isEmpty)
    }

    /// One batch, two calls: the form parked the step, the plain ask beside it was refused.
    /// The chip is the form's — headline from ITS arguments, `askedAt` and identity from ITS
    /// call.
    ///
    /// RED: read `lastPosition` (by name) instead of `lastParkedPosition(in:)` → the chip
    /// carries the refused question, its timestamp and its id.
    func testPending_parkedForm_thenARefusedPlainAsk_isTheForm() {
        let form = StepToolCall(
            createdAt: date(100), name: TN.askSupervisorForm,
            argumentsJSON: #"{"headline":"Direction","form":"{}"}"#,
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false)
        let refused = StepToolCall(
            createdAt: date(101), name: TN.askSupervisor,
            argumentsJSON: #"{"question":"Which? 1. A 2. B"}"#,
            resultJSON: #"{"ok":false,"error":{"code":"QUESTIONNAIRE_REQUIRED"}}"#,
            isError: true)
        let step = makeStep(
            toolCalls: [form, refused], status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: nil)

        let pending = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.headline, "Direction")
        XCTAssertEqual(pending.first?.askedAt, date(100))
        XCTAssertEqual(pending.first?.askCallID, form.id)
    }

    /// Pairs strictly by `createdAt <= lastCall.createdAt` — a stray assistant
    /// message that lands AFTER the active `ask_supervisor` (e.g. an in-flight
    /// streaming artifact written by the next iteration before suppression
    /// re-evaluates) must NOT be picked as the paired reply.
    func testActiveSupervisorQuestions_pairedLookup_excludesAssistantsAfterAskTimestamp() {
        let earlier = makeMessage(content: "Legit reply.", at: date(50))
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        // Future-timestamped assistant message — must not be the paired one.
        let later = makeMessage(content: "Stray future message.", at: date(150))
        let step = makeStep(
            role: .productManager,
            messages: [earlier, later],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].paired?.id, earlier.id,
                       "Paired message must be the most-recent assistant turn ≤ lastCall.createdAt")
    }

    /// Paired lookup is filtered to `.assistant` role. A `.user` turn (e.g. a
    /// consultation reply with `sourceContext: .consultation`) sitting right before
    /// `ask_supervisor` must not be lifted into the composer's preview — that
    /// would surface another role's words under the asking role's chip.
    func testActiveSupervisorQuestions_pairedLookup_filtersByAssistantRole() {
        let assistantReply = makeMessage(content: "Assistant's reasoning.", at: date(80))
        let userTurn = makeMessage(
            role: .user, content: "Consultation answer.", at: date(95),
            sourceRole: .productManager, sourceContext: .consultation
        )
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .softwareEngineer,
            messages: [assistantReply, userTurn],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(questions[0].paired?.id, assistantReply.id,
                       "Paired lookup must skip .user turns even when they're closer to the ask timestamp")
    }

    // MARK: - Question text and dismiss identity (re-homed from `StepExecution`)

    /// One chain for banner and retirement: the persisted text first, the LAST ask call's
    /// parsed args as the lag fallback (flag set, text not yet copied).
    ///
    /// RED: drop the `parsedSupervisorQuestion` arm in `question(taskID:step:askIndex:)`
    /// → case (b) reads the placeholder.
    /// RED: `lastParkedPosition(in:)` → `positions.first` → case (b) reads "Old" — round N's
    /// question shown during round N+1's lag window.
    func testHeadline_prefersPersistedText_fallsBackToLastAskArgs() {
        let persisted = makeStep(
            toolCalls: [askCall("Other", at: date(10))],
            needsSupervisorInput: true, supervisorQuestion: "Q")
        XCTAssertEqual(pending(persisted).first?.headline, "Q",
                       "(a) persisted text wins over the call's args")

        let lagged = makeStep(toolCalls: [askCall("Old", at: date(10)), askCall("Lagged", at: date(20))])
        XCTAssertEqual(pending(lagged).first?.headline, "Lagged",
                       "(b) no persisted text → the TRAILING ask's args, not the first")

        XCTAssertTrue(pending(makeStep()).isEmpty, "(c) nothing to show")
    }

    /// The identity the answer-time retirement removes must be the identity the banner was
    /// shown under. On a step that asked and was ANSWERED before, a flag-only escalation
    /// keys on its TEXT — the answered call's UUID names a question the user already read
    /// (and possibly dismissed), so keying on it would retire nothing.
    ///
    /// RED: in `PendingQuestion` set `askCallID: lastCall.id` instead of
    /// `step.activeSupervisorQuestionID` → the key carries Q1's UUID, not the text.
    func testDismissKey_flagOnlyEscalationOnAnsweredStep_keysOnTextNotTheStaleCall() {
        let ask = askCall("Q1", at: date(10))
        let escalated = makeStep(
            messages: [makeMessage(role: .user, content: "A", at: date(20),
                                   sourceContext: .supervisorAnswer)],
            toolCalls: [ask],
            needsSupervisorInput: true, supervisorQuestion: "Stalled — continue?")
        XCTAssertEqual(
            SupervisorQuestionInbox.dismissKey(forStep: escalated, taskID: 3),
            .supervisorInput(taskID: 3, stepID: escalated.id, toolCallID: nil,
                             question: "Stalled — continue?"))

        let quiet = makeStep(
            messages: [makeMessage(role: .user, content: "A", at: date(20),
                                   sourceContext: .supervisorAnswer)],
            toolCalls: [ask],
            needsSupervisorInput: false, supervisorQuestion: "Stalled — continue?")
        XCTAssertNil(SupervisorQuestionInbox.dismissKey(forStep: quiet, taskID: 3),
                     "no banner ⇒ no key to retire")
    }

    /// The key spells the SAME text the surfaces render. It used to be spelled from
    /// `StepExecution.supervisorQuestionText`, a second chain that agreed with the banner's
    /// only by being the same expression.
    ///
    /// RED: `question: headline` → `question: step.supervisorQuestion ?? ""` in `dismissKey`
    /// → the key names a string no surface ever showed.
    func testDismissKey_spellsTheHeadlineTheSurfacesRender() {
        let step = makeStep(toolCalls: [askCall("From the args", at: date(10))])
        let question = SupervisorQuestionInbox.pending(taskID: 7, steps: [step]).first
        XCTAssertEqual(question?.headline, "From the args")
        XCTAssertEqual(SupervisorQuestionInbox.dismissKey(forStep: step, taskID: 7),
                       question?.dismissKey)
        XCTAssertEqual(question?.dismissKey.typeID, "\(step.id)::\(question?.askCallID?.uuidString ?? "")")
    }

    // MARK: - The task-level entry point

    /// Closing a task is the Supervisor's explicit "done". `closeTask` rewrites the step's
    /// STATUS but leaves `needsSupervisorInput` standing, so without this gate the panel
    /// offered an answer field for a finished task — and `stopEngine` had already removed
    /// the engine, so the answer was persisted into a run nobody would ever read.
    ///
    /// RED: drop `task.closedAt == nil` from `pending(in:)` → the closed task still lists a
    /// question, which is what Quick Capture used to do.
    func testPendingInTask_closedTask_listsNothing() {
        let waiting = makeStep(needsSupervisorInput: true, supervisorQuestion: "Ship it?")
        XCTAssertEqual(SupervisorQuestionInbox.pending(in: makeTask(steps: [waiting])).count, 1,
                       "anti-vacuum: the same task open does list it")
        XCTAssertTrue(
            SupervisorQuestionInbox.pending(in: makeTask(steps: [waiting], closed: true)).isEmpty)
    }

    /// Scoped to the ACTIVE run, like `NTMSTask.hasPendingSupervisorInput` — a flag left on
    /// a superseded run must not resurrect a question the new run never asked.
    func testPendingInTask_readsTheLatestRunOnly() {
        let stale = makeStep(needsSupervisorInput: true, supervisorQuestion: "Old run?")
        let task = NTMSTask(
            id: 4, title: "T", supervisorTask: "S",
            runs: [Run(id: 0, steps: [stale]), Run(id: 1, steps: [makeStep()])])
        XCTAssertTrue(SupervisorQuestionInbox.pending(in: task).isEmpty)
    }

    // MARK: - The divergences the one producer removes

    /// With two roles parked, the panel used to take `run.steps.first(where:)` — array
    /// order, i.e. whichever step was CREATED first — while the composer's leftmost chip
    /// takes the earliest ASK. Two surfaces, two questions, and the later-created role's
    /// question was unreachable from the panel until the other one was answered.
    ///
    /// RED: drop the `askedAt` sort in `pending(taskID:steps:)` → the earlier-created step
    /// leads and this reads "engineer".
    func testParallelRoles_theEarliestAskLeads_notTheFirstStepInTheArray() {
        let createdFirst = makeStep(
            role: .softwareEngineer, toolCalls: [askCall("Second to ask", at: date(200))],
            needsSupervisorInput: true)
        let createdSecond = makeStep(
            role: .techLead, toolCalls: [askCall("First to ask", at: date(100))],
            needsSupervisorInput: true)
        let questions = SupervisorQuestionInbox.pending(
            taskID: 1, steps: [createdFirst, createdSecond])
        XCTAssertEqual(questions.map(\.headline), ["First to ask", "Second to ask"])
        XCTAssertEqual(questions.first?.role, .techLead)
    }

    /// The ask has landed in `toolCalls`; the park that raises the flag has not run yet —
    /// two `mutateTask` publishes sit between them, so the window renders. The panel asked
    /// the flag ALONE and went silent here; the Watchtower asked `supervisorQuestion` with
    /// no flag gate and rendered round N's already-answered text.
    ///
    /// RED: gate `pending` on `needsSupervisorInput` alone → nothing is listed.
    /// RED: prefer the stored text unconditionally → the headline reads "Round N".
    func testAskLandedBeforeThePark_isListed_withTheNewQuestionNotTheAnsweredOne() {
        let step = makeStep(
            messages: [makeMessage(role: .user, content: "A", at: date(20),
                                   sourceContext: .supervisorAnswer)],
            toolCalls: [askCall("Round N", at: date(10)), askCall("Round N+1", at: date(30))],
            needsSupervisorInput: false,
            supervisorQuestion: "Round N")
        let questions = SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
        XCTAssertEqual(questions.count, 1, "the ask is unanswered — the step is waiting")
        XCTAssertEqual(questions.first?.headline, "Round N+1")
    }

    /// The panel paired with the LAST assistant turn outright; the composer paired with the
    /// last one AT OR BEFORE the ask. On a role that kept talking after asking, those are
    /// different turns, and the panel showed the user prose the question never prompted.
    ///
    /// RED: drop the `atOrBefore` bound in `paired(in:atOrBefore:)` → this reads "After".
    func testPairing_stopsAtTheAsk_evenWhenTheRoleKeptTalking() {
        let step = makeStep(
            messages: [
                makeMessage(content: "Before", at: date(10)),
                makeMessage(content: "After", at: date(30)),
            ],
            toolCalls: [askCall("Q", at: date(20))],
            needsSupervisorInput: true)
        XCTAssertEqual(pending(step).first?.paired?.content, "Before")
    }

    // MARK: - Local fixtures for the sections above

    private func askCall(_ question: String, at timestamp: Date) -> StepToolCall {
        makeToolCall(name: TN.askSupervisor, at: timestamp,
                     argumentsJSON: #"{"question":"\#(question)"}"#)
    }

    private func pending(_ step: StepExecution) -> [SupervisorQuestionInbox.PendingQuestion] {
        SupervisorQuestionInbox.pending(taskID: 1, steps: [step])
    }

    // MARK: - waitingStepIDs — the panel's rebuild key

    /// Nothing else fires when a SECOND question parks: the derived task status does not move
    /// (the task was already waiting) and the seen-policy's observation keys on
    /// `activeSupervisorQuestionID`s. RED: key the panel on the COUNT instead of the set → the
    /// swap below (one answered, one parked, in the same tick) reads as no change at all.
    func testTheWaitingKeyIsTheSetAndNotTheCount() {
        let waitingPM = makeStep(
            role: .productManager, status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "A?")
        let waitingTL = makeStep(
            role: .techLead, status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "B?")
        let quietPM = makeStep(role: .productManager, status: .running)

        let before = SupervisorQuestionInbox.waitingStepIDs(in: makeTask(steps: [waitingPM, quietPM]))
        let after = SupervisorQuestionInbox.waitingStepIDs(
            in: makeTask(steps: [makeStep(role: .productManager, status: .running), waitingTL]))

        XCTAssertEqual(before.count, after.count, "precondition: the count cannot tell them apart")
        XCTAssertNotEqual(before, after)
    }

    func testTheWaitingKeyGrowsWhenASecondRoleParks() {
        let pm = makeStep(
            role: .productManager, status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "A?")
        let tl = makeStep(
            role: .techLead, status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "B?")
        XCTAssertEqual(SupervisorQuestionInbox.waitingStepIDs(in: makeTask(steps: [pm])), [pm.id])
        XCTAssertEqual(
            SupervisorQuestionInbox.waitingStepIDs(in: makeTask(steps: [pm, tl])), [pm.id, tl.id])
    }

    /// An escalation park has no ask call at all, which is exactly why the seen-policy's
    /// question-id observation cannot serve as the panel's key.
    func testAnEscalationParkCountsAsWaiting() {
        let escalated = makeStep(
            role: .softwareEngineer, status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "Role is stuck.")
        XCTAssertTrue(escalated.toolCalls.isEmpty, "precondition: no ask call to key on")
        XCTAssertEqual(
            SupervisorQuestionInbox.waitingStepIDs(in: makeTask(steps: [escalated])), [escalated.id])
    }

    /// The same two gates `pending(in:)` applies — closing a task is the Supervisor's explicit
    /// "done", and a panel that rebuilt for a closed task's leftover flag would be offering to
    /// answer a run whose engine is gone.
    func testAClosedTaskIsWaitingForNothing() {
        let waiting = makeStep(
            role: .productManager, status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "A?")
        XCTAssertTrue(
            SupervisorQuestionInbox.waitingStepIDs(in: makeTask(steps: [waiting], closed: true))
                .isEmpty)
    }

    private func makeTask(steps: [StepExecution], closed: Bool = false) -> NTMSTask {
        var task = NTMSTask(id: 4, title: "T", supervisorTask: "S", runs: [Run(id: 0, steps: steps)])
        if closed { task.closedAt = MonotonicClock.shared.now() }
        return task
    }

    // MARK: - Why the "answered" filter could be dropped

    /// The predicate the panel used to carry was `needsSupervisorInput &&
    /// effectiveSupervisorAnswer == nil`. The second conjunct filtered a state that cannot
    /// occur: every writer of `supervisorAnswer` settles `needsSupervisorInput` in the SAME
    /// synchronous closure, so the two are never observed disagreeing — and the multi-round
    /// window everyone reaches for as a counter-example is the opposite pairing (an answer
    /// on the step with the flag DOWN, until the next park clears the answer).
    ///
    /// Removing an unreachable filter is safe only while it stays unreachable, and that is
    /// a property of the writer set, not of any one function. So it is scanned rather than
    /// argued: a new writer that sets one field and forgets the other reds here, and the
    /// message says which line.
    ///
    /// RED: delete `needsSupervisorInput = false` from
    /// `StepMessagingService.answerSupervisorQuestion` → that closure is named as the
    /// offender, and `pending` would start listing an answered question.
    func testEveryWriterOfSupervisorAnswer_settlesTheWaitingFlagInTheSameClosure() throws {
        let root = RatchetSourceScan.repoRoot.appendingPathComponent("NanoTeams")
        // A closure is a `{ … }` block; we approximate it by the enclosing FUNCTION span,
        // which is stricter in the direction that matters: a writer that settles the flag
        // in a different function fails, and a writer that settles it a few lines away in
        // the same one passes, which is exactly the adjacency the four live writers have.
        let answerWrite = try NSRegularExpression(pattern:
            #"(?<![A-Za-z0-9_])supervisorAnswer\s*=(?!=)"#)
        let flagWrite = try NSRegularExpression(pattern:
            #"(?<![A-Za-z0-9_])needsSupervisorInput\s*=(?!=)"#)
        // `if case .supervisorAnswer = mode` is an enum-case PATTERN with the same shape as
        // an assignment — two of them live in QuickCapture and both would read as writers.
        let casePattern = try NSRegularExpression(pattern: #"\b(?:if|guard)\s+case\b|^\s*case\b"#)

        func matches(_ regex: NSRegularExpression, _ probe: String) -> Bool {
            regex.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) != nil
        }
        XCTAssertTrue(matches(answerWrite, "step.supervisorAnswer = clean"), "control: a write is seen")
        XCTAssertFalse(matches(answerWrite, "if step.supervisorAnswer == nil {"),
                       "control: a comparison is not a write")
        XCTAssertFalse(matches(answerWrite, "let supervisorAnswerWasAuto = x"),
                       "control: a different field with the same prefix is not this one")
        XCTAssertTrue(matches(flagWrite, "steps[i].needsSupervisorInput = true"), "control")
        XCTAssertTrue(matches(casePattern, "if case .supervisorAnswer = mode {"),
                      "control: an enum-case match is recognised and skipped")
        XCTAssertFalse(matches(casePattern, "task.steps[i].supervisorAnswer = clean"),
                       "control: a real write is not mistaken for one")

        // `Domain/StepExecution.swift` is the type's own storage: the memberwise init, the
        // decoder and `reset()` write every field by name, and "the same closure" is not a
        // thing a stored-property list can satisfy.
        let storage = "NanoTeams/Domain/StepExecution.swift"
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(
                of: RatchetSourceScan.repoRoot.path + "/", with: "")
            guard relative != storage else { continue }
            let source = RatchetSourceScan.strippingLineComments(
                try String(contentsOf: url, encoding: .utf8))
            let lines = source.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard answerWrite.firstMatch(in: line, range: range) != nil,
                      casePattern.firstMatch(in: line, range: range) == nil
                else { continue }
                scanned += 1
                // The enclosing function: walk out to the nearest `func` at a lower indent,
                // then forward to its closing brace at that indent.
                let indent = { (s: String) in s.prefix { $0 == " " }.count }
                var start = index
                while start > 0, !(lines[start].contains("func ") && indent(lines[start]) < indent(line)) {
                    start -= 1
                }
                let closing = String(repeating: " ", count: indent(lines[start])) + "}"
                var end = start
                while end + 1 < lines.count, lines[end] != closing { end += 1 }
                let span = lines[start...end].joined(separator: "\n")
                if flagWrite.firstMatch(in: span, range: NSRange(span.startIndex..., in: span)) == nil {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 3, "anti-vacuum: the scan found the known writers")
        XCTAssertTrue(offenders.isEmpty,
                      "a writer of supervisorAnswer that leaves needsSupervisorInput unsettled "
                          + "makes `needsSupervisorInput && answer != nil` reachable again: \(offenders)")
    }
}
