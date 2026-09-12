import XCTest

@testable import NanoTeams

/// Verifies the branch ordering in `LLMExecutionService.handleNoToolCalls`.
///
/// Regression: a Code Reviewer step retried 11 times because
/// `qwen3.5-4b-mlx` emitted `<|call|>{…}<|end|>` with an unbalanced outer brace.
/// The parser dropped the call silently (`sawHarmonyMarker=true`, no resolved calls).
/// Since the pre-marker content was just whitespace, the "only model-internal tokens"
/// branch fired ahead of the "malformed tool call" branch, so the model got a
/// misleading retry message and never corrected the JSON.
///
/// These tests lock in: when `sawHarmonyMarker == true`, the malformed-JSON retry
/// message MUST win regardless of what pre-marker whitespace is in `assistantContent`.
@MainActor
final class NoToolCallsBranchOrderingTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        // Task with one step so appendLLMMessage has somewhere to write.
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Review", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "goal", runs: [run])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        try await super.tearDown()
    }

    // MARK: - Branch Ordering

    /// A real broken `<|call|>` block, carried in `harmonyBuffer` the way production does.
    /// The fixture used to be empty, which meant these tests exercised "Harmony framing
    /// with no call block" while claiming to exercise "a call block whose JSON is broken" —
    /// they only passed because both folded into `.malformedJSON`. They are now distinct
    /// cases, and this constant is what makes the assertions mean what they say.
    private static let brokenCallEnvelope =
        ##"<|call|>{"name":"write_file","arguments":{"path":"x""##

    /// The reasoning-envelope cap escalates through `setNeedsSupervisorInput`; when that
    /// mutation does not persist there is no question for anyone to answer, so the step
    /// FAILS naming the cause instead of looping on a nudge nobody reads. Every cap carries
    /// this arm; this is the reasoning-channel one, first envelope nudged, second refused.
    func testReasoningEnvelopeCap_whenTheEscalationDoesNotPersist_failsTheStepNamingIt() async {
        let envelope = "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.swift\"}}<|end|>"
        var messages: [ChatMessage] = []
        let first = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages, thinkingContent: "I will read it. " + envelope,
            allowedToolNames: [ToolNames.readFile])
        guard case .continueLoop = first else { return XCTFail("the first envelope is nudged, got \(first)") }
        XCTAssertEqual(messages.count, 1)

        mockDelegate.refuseMutations = true
        let second = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages, thinkingContent: "Still reasoning. " + envelope,
            allowedToolNames: [ToolNames.readFile])
        guard case .toolFailure(let message) = second else {
            return XCTFail("an escalation that did not persist must fail the step, got \(second)")
        }
        XCTAssertTrue(message.contains("Reasoning-channel cap exceeded"), message)
        XCTAssertTrue(message.contains("escalation failed to persist"), message)
        XCTAssertTrue(mockDelegate.eventLog.contains { $0.hasPrefix("mutate-refused") })
    }

    func testHarmonyMarkerWithWhitespaceOnlyContent_sendsMalformedJSONRetry() async {
        // Repro of run EAE23A6D: pre-marker content is just "\n\n" from `[reasoning]` tail,
        // `sawHarmonyMarker == true` because parser saw `<|call|>` but failed to extract args.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "\n\n",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: Self.brokenCallEnvelope
        )

        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertTrue(
            retry.contains("malformed JSON"),
            "Expected malformed-JSON retry, got: \(retry)"
        )
        XCTAssertFalse(
            retry.contains("only model-internal tokens"),
            "Must NOT fall into the tokens-only branch when sawHarmonyMarker is true"
        )
    }

    func testHarmonyMarkerWithEmptyContent_sendsMalformedJSONRetry() async {
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: Self.brokenCallEnvelope
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop")
            return
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("malformed JSON") == true)
    }

    /// Harmony framing with NO call block — the shape the wedged Autovisor pass actually
    /// produced. It must not be described as malformed JSON: there is no JSON to malform,
    /// the advice about braces and quotes is unactionable, and charging the parse-failure
    /// cap escalates to the human with a misdiagnosis attached.
    func testChannelFramingWithNoCallBlock_doesNotClaimMalformedJSON() async {
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: "<|channel|>commentary<|message|>Let me think about this.",
            allowedToolNames: [ToolNames.readFile]
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        let retry = messages.last?.content ?? ""
        XCTAssertFalse(retry.contains("malformed JSON"),
                       "no `<|call|>` block was opened, so nothing failed to parse: \(retry)")
        XCTAssertFalse(retry.contains("closing brace"),
                       "advice about braces is unactionable for an envelope with none")
        XCTAssertTrue(retry.contains("never made a tool call"),
                      "the nudge must name the defect that actually occurred: \(retry)")
        XCTAssertTrue(retry.contains("to=read_file"),
                      "and it must name the CHANNEL form the model is actually emitting, "
                          + "with a tool the role really holds: \(retry)")
        XCTAssertEqual(
            service._testHarmonyParseFailureCounter(stepID: stepID, taskID: task.id), 0,
            "a missing call block is not a parse failure and must not charge that cap")
    }

    func testMalformedJSONRetry_attachesConcreteParserDiagnostic() async {
        // Envelope with no closing brace AND no `<|end|>` — a cut-off stream, the one state
        // `.unbalanced` still covers. The retry must name the ACTUAL defect (playbook R5.2.5:
        // re-prompt with the parse error attached) instead of the generic guess list.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "<|call|>{\"name\":\"write_file\",\"arguments\":{\"path\":\"x\"",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("malformed JSON"))
        XCTAssertTrue(
            retry.contains("parser error: the `<|call|>` block never closed — no `<|end|>`"),
            "retry must carry the concrete parser diagnostic, got: \(retry)")
        XCTAssertFalse(retry.contains("e.g. a missing closing brace"),
                       "generic hint list must be replaced when a concrete diagnostic exists")
        XCTAssertFalse(
            retry.contains("two closing braces"),
            "prescribing ONE repair for every parse failure is a false diagnosis for the "
                + "shapes it does not fit (R1.8.5 / R3.8.2 / R3.8.7): \(retry)")
    }

    /// A transposed closing quote after a numeric value (`"end_line":"588,`) is repaired by
    /// the parser, so this branch must not run at all: the call dispatches and no nudge is
    /// appended. Verbatim payload from `ornith-1.0-35b`, CastleSurvivors task 5 run 0,
    /// 2026-09-08 — where it cost a `malformed_tool_call` card and one round trip.
    func testTransposedQuoteEnvelope_isRepairedBeforeThisBranchIsReached() {
        let reply = "<|call|>{\"name\":\"read_lines\",\"arguments\":{\"end_line\":\"588,"
            + "\"include_line_numbers\":false,\"path\":\"a.gd\",\"start_line\":\"501\"}}<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: reply)
        XCTAssertEqual(calls.map(\.name), [ToolNames.readLines],
                       "the repair must dispatch this call, leaving `handleNoToolCalls` unreached")
    }

    func testTokensOnlyWithoutHarmonyMarker_sendsTokensOnlyRetry() async {
        // Different scenario: content had some stray `<|foo|>` tokens but no actual
        // tool call marker. Should still send the tokens-only retry.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "<|foo|>",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop")
            return
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("only model-internal tokens") == true)
    }

    func testPlainTextNoMarker_nilRoleDefinition_sendsGenericNudge() async {
        // No roleDefinition → skips producing-role branch entirely → falls through to
        // the generic "you didn't call any tools" nudge.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I think we're done here.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertTrue(
            retry.contains("did not call any tools"),
            "Expected generic tool-use nudge, got: \(retry)"
        )
    }

    // MARK: - Tool-Aware Nudges
    //
    // Every nudge that names a tool must filter through the role's CURRENT schema.
    // The defect these pin: the generic nudge unconditionally said "send it via
    // ask_supervisor", but `resolveToolSchemas` strips that tool from the Autovisor
    // manager entirely — so the one role most likely to reply with plain text was told
    // to call a tool that can only ever answer `tool_not_authorized`.

    func testGenericNudge_withWaitForEvents_namesItAndDropsTheUnreachableClaim() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I think we're done here.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.waitForEvents, ToolNames.listTasks]
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains(ToolNames.waitForEvents),
                      "Must name the role's actual completion channel, got: \(retry)")
        XCTAssertFalse(retry.contains(ToolNames.askSupervisor),
                       "Must NOT name a tool the manager does not have, got: \(retry)")
        // The manager's plain text DOES reach its Supervisor — the human reads that
        // very chat, and its system prompt calls it "your only reply channel".
        XCTAssertFalse(retry.contains("does not reach the Supervisor"),
                       "Must not tell the manager its reply went nowhere, got: \(retry)")
    }

    /// The `ask_supervisor` arm names the reply channel AND the field the reply goes in,
    /// as the `## Final reminder` does — and nothing else. Until 2026-09-11 it read "If the
    /// reply is complete, send it via ask_supervisor; otherwise call the next tool you need
    /// to continue": a model that could not decide whether its reply was complete resolved
    /// the predicate by asking, and "the tool you need to continue" is where it put the
    /// questionnaire (`Ratchet/NudgeTextPinTests` Rule 6). The dropped "plain text does not
    /// reach the Supervisor" was the manager's false claim (the test above) for every other
    /// role too: the human reads the feed; only the park does not happen.
    func testGenericNudge_withAskSupervisorOnly_namesTheReplyChannelAndItsField() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I think we're done here.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.askSupervisor, ToolNames.readFile]
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains(ToolNames.askSupervisor), "got: \(retry)")
        XCTAssertTrue(retry.contains("`question`"),
                      "the field the reply goes in, as the Final reminder names it; got: \(retry)")
        XCTAssertFalse(retry.contains("does not reach the Supervisor"), "got: \(retry)")
        XCTAssertFalse(retry.contains("If the reply is complete"), "got: \(retry)")
        XCTAssertFalse(retry.contains("otherwise"),
                       "no second branch for the model to put a questionnaire in; got: \(retry)")
    }

    /// The turn's own TEXT decides between the two ask channels, because the gate reads the
    /// same predicate: a prose reply carrying several questions (or one with its options)
    /// belongs in `ask_supervisor_form`, and naming the plain ask sent run 10 of MeditationApp
    /// task 52 through nudge → `QUESTIONNAIRE_REQUIRED` → form, two turns for one reply.
    ///
    /// RED: drop the `questionnaire:` argument at the call site → the plain-ask arm again.
    func testGenericNudge_questionnaireProse_withTheFormHeld_namesTheForm() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.questionnaireProse,
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.askSupervisor, ToolNames.askSupervisorForm, ToolNames.readFile]
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains(ToolNames.askSupervisorForm), "got: \(retry)")
        XCTAssertTrue(retry.contains("one `questions` entry per question"), "got: \(retry)")
        XCTAssertFalse(retry.contains("in its `question` field"),
                       "the plain ask's field, on a text the gate would refuse; got: \(retry)")
    }

    /// The same text with the form withheld keeps the plain-ask arm: the numbered list is
    /// the sanctioned fallback there, and a nudge naming a tool the role lacks is the
    /// 2026-07-25 defect.
    func testGenericNudge_questionnaireProse_withoutTheForm_namesThePlainAsk() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.questionnaireProse,
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.askSupervisor, ToolNames.readFile]
        )
        let retry = messages[0].content ?? ""
        XCTAssertFalse(retry.contains(ToolNames.askSupervisorForm), "got: \(retry)")
        XCTAssertTrue(retry.contains("in its `question` field"), "got: \(retry)")
    }

    /// A one-question reply keeps the plain ask even with the form held — the form arm is
    /// keyed on the SHAPE, not on the schema alone (R3.8.2: one nudge shape per failure shape).
    func testGenericNudge_oneQuestion_withTheFormHeld_staysOnThePlainAsk() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Done. Shall I commit this?",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.askSupervisor, ToolNames.askSupervisorForm]
        )
        let retry = messages[0].content ?? ""
        XCTAssertFalse(retry.contains(ToolNames.askSupervisorForm), "got: \(retry)")
        XCTAssertTrue(retry.contains("in its `question` field"), "got: \(retry)")
    }

    /// The shape the field run sent: one question, five enumerated options, a `(recommended)`
    /// mark — refused by the gate through the plain ask.
    private static let questionnaireProse = """
    Изучил структуру приложения. Предлагаю 5 направлений:
    
    1. Мини-редизайн (recommended) — тёмная тема + карточки из материала.
    2. Тёмная медитативная тема — атмосфера меняется.
    3. Пастельные градиенты + glassmorphism.
    4. Hero-секция на Today.
    5. Новый плеер с дыхательным кругом.
    
    Какой вариант выбираем?
    """

    func testGenericNudge_withNeitherTool_namesNoToolAtAll() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I think we're done here.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.readFile, ToolNames.search]
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("did not call any tools"), "still nudges, got: \(retry)")
        XCTAssertFalse(retry.contains(ToolNames.askSupervisor))
        XCTAssertFalse(retry.contains(ToolNames.waitForEvents))
    }

    /// `.repetitiveNonTool` discriminates on the SCHEMA, not `producesArtifacts`: this
    /// branch runs ABOVE the planning-phase handler, and the phase withholds
    /// `create_artifact` — so the config signal would steer a producing role straight
    /// into the phase's `plan_required` rejection.
    func testRepetitiveNonToolNudge_producingRoleWithArtifactToolWithheld_doesNotNameIt() {
        let withheld = LLMExecutionService.repetitiveNonToolNudge(
            count: 3, allowedToolNames: [ToolNames.readFile, ToolNames.updateScratchpad],
            questionnaire: false)
        XCTAssertFalse(withheld.contains(ToolNames.createArtifact),
                       "Planning phase withholds create_artifact, got: \(withheld)")

        let granted = LLMExecutionService.repetitiveNonToolNudge(
            count: 3, allowedToolNames: [ToolNames.createArtifact, ToolNames.askSupervisor],
            questionnaire: false)
        XCTAssertTrue(granted.contains(ToolNames.createArtifact))
        XCTAssertTrue(granted.contains(ToolNames.askSupervisor))
    }

    func testRepetitiveNonToolNudge_manager_steersToWaitForEvents() {
        let text = LLMExecutionService.repetitiveNonToolNudge(
            count: 4, allowedToolNames: [ToolNames.waitForEvents, ToolNames.listTasks],
            questionnaire: false)
        XCTAssertTrue(text.contains(ToolNames.waitForEvents))
        XCTAssertFalse(text.contains(ToolNames.askSupervisor))
        XCTAssertTrue(text.contains("The 4 turns immediately before this note"),
                      "keeps the count, anchored to the note rather than to the reader's now (playbook §3.8), got: \(text)")
    }

    func testToolNameExamples_filtersToSchema_andNilsOutWhenNoneSurvive() {
        XCTAssertNil(LLMExecutionService.toolNameExamples(allowedToolNames: []))
        XCTAssertNil(LLMExecutionService.toolNameExamples(allowedToolNames: [ToolNames.gitStatus]))

        let managerOnly = LLMExecutionService.toolNameExamples(
            allowedToolNames: [ToolNames.waitForEvents, ToolNames.listTasks])
        XCTAssertEqual(managerOnly, "\"wait_for_events\"")

        // Capped at three so the explainer stays short.
        let many = LLMExecutionService.toolNameExamples(allowedToolNames: [
            ToolNames.createArtifact, ToolNames.writeFile, ToolNames.askSupervisor,
            ToolNames.readFile, ToolNames.updateScratchpad,
        ])
        XCTAssertEqual(many?.components(separatedBy: ", ").count, 3, "got: \(many ?? "nil")")
    }

    // MARK: - Producing Role Interaction (the real run EAE23A6D scenario)

    /// Builds a `TeamRoleDefinition` with `producesArtifacts = [name]` — matches the
    /// Code Reviewer config from run EAE23A6D where the bug surfaced.
    private func makeProducingRole(artifactName: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "code_reviewer",
            name: "Code Reviewer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: [artifactName]
            ),
            llmOverride: nil,
            isSystemRole: true,
            systemRoleID: "codeReviewer",
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testProducingRoleWithHarmonyMarker_sendsMalformedJSONRetryNotArtifactNudge() async {
        // Exact repro of run EAE23A6D: Code Reviewer is a producing role with
        // producesArtifacts = ["Code Review"]. It emits a broken `<|call|>create_artifact`
        // with unbalanced JSON. The branch order MUST send the JSON-fix retry, not the
        // misleading "missing deliverables" nudge.
        let role = makeProducingRole(artifactName: "Code Review")
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "\n\n",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages,
            harmonyBuffer: Self.brokenCallEnvelope
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertTrue(
            retry.contains("malformed JSON"),
            "Producing role + harmony marker must send malformed-JSON retry, got: \(retry)"
        )
        XCTAssertFalse(
            retry.contains("Missing deliverables"),
            "Must NOT fall through to producing-role artifact nudge when JSON parse failed"
        )
    }

    // MARK: - Planning Phase No-Tool-Call (regression EA190834)

    /// Regression: when an LLM in planning phase responds with prose instead of calling
    /// `update_scratchpad`, the prior implementation returned `.continueLoop` without
    /// appending any user message. The next iteration's stateful slice produced an empty
    /// `newMessages` array → `{"input":""}` → HTTP 400 from LM Studio. Code Reviewer hit
    /// this 6+ times in run EA190834 (seen as repeated "input must not be an empty string"
    /// retries against the same unchanged prompt prefix).
    ///
    /// Fix: persist the assistant text as the implicit plan (so applyPlanningPhase
    /// transitions to implementation on the next iteration) and append a user nudge so
    /// the stateful continuation has non-empty input.
    func testPlanningPhaseNoToolCall_appendsUserNudgeAndPersistsScratchpad() async {
        // The phase is detected from the WIRE's brief turn, not from the system
        // prompt — which the planning phase deliberately never touches.
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are Software Engineer."),
            ChatMessage(role: .user, content: "Build a calculator"),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.search], expectedArtifacts: []))
        ]
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I'll start by reading the requirements then writing the evaluator.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        // CRITICAL: a user message MUST be appended so the next stateful continuation
        // produces non-empty `input`.
        let userMessages = messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 3, "Expected original user + brief + new nudge")
        let nudge = userMessages.last?.content ?? ""
        XCTAssertTrue(
            nudge.contains("implementation phase"),
            "Expected implementation-phase nudge, got: \(nudge)"
        )

        // Scratchpad must be persisted so applyPlanningPhase crosses the boundary next iteration.
        let scratchpad = mockDelegate.taskToMutate?.runs[0].steps[0].scratchpad
        XCTAssertNotNil(scratchpad, "Expected scratchpad to be set from assistant text")
        XCTAssertTrue(
            scratchpad?.contains("evaluator") == true,
            "Scratchpad should contain the assistant's text, got: \(scratchpad ?? "nil")"
        )
    }

    /// The prose-plan branch reads the phase verdict the iteration already derived
    /// (`Authorization.wireIsMidPlanning`) instead of rescanning the wire. The probe lives inside
    /// the two scan closures (`briefIndex`, `wireCarriesClosedMarker`), so a rescan here cannot
    /// hide behind an unchanged answer.
    ///
    /// RED: revert the branch to `if PlanningPhasePolicy.isMidPlanning(conversationMessages) {`
    /// → `examined()` reads ≥ 600 (one brief scan stopping at index 2 plus a full closed-marker
    /// scan) while the scratchpad is still recorded.
    func testProsePlanBranch_doesNotRescanTheWire() async {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are Software Engineer."),
            ChatMessage(role: .user, content: "Build a calculator"),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.search], expectedArtifacts: [])),
        ]
        for i in 0..<300 {
            messages.append(ChatMessage(role: .assistant, content: "finding \(i)"))
            messages.append(ChatMessage(role: .user, content: "go on"))
        }
        XCTAssertGreaterThanOrEqual(messages.count, 600, "premise: a long mid-planning wire")

        PlanningWireScanProbe.reset()
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I'll read ContentView.swift, then add the evaluator.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            wireIsMidPlanning: true
        )

        guard case .continueLoop = stop else {
            return XCTFail("Expected .continueLoop, got \(stop)")
        }
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs[0].steps[0].scratchpad,
            "I'll read ContentView.swift, then add the evaluator.",
            "anti-vacuum: the prose-plan branch must have been reached")
        XCTAssertEqual(PlanningWireScanProbe.examined(), 0,
                       "the branch must read the carried verdict, not rescan the wire — "
                           + "two O(conversation) passes per no-tool turn")
    }

    /// Loop detection reads the step's ring, not the wire. The shape where the old reversed
    /// walk was Θ(N): a tool-heavy conversation whose only qualifying assistant turn is the
    /// last one, so the walk never found its three matches and examined everything.
    ///
    /// The seed is the one honest Θ(N) and is paid explicitly BEFORE the probe is reset;
    /// `seedMessageLoopRing: false` keeps the helper from paying it again on the test's behalf.
    ///
    /// RED: revert the classifier call in `handleNoToolCalls` to
    /// `detectMessageLoop(conversationMessages: conversationMessages)` → `examined()` reads ≥ 2000.
    func testLoopDetection_doesNotWalkTheWire_whenTheRingIsSeeded() async {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "s")]
        for i in 0..<1_000 {
            messages.append(ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(id: "c\(i)", name: ToolNames.readFile, argumentsJSON: "{}")]))
            messages.append(ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "c\(i)"))
        }
        messages.append(ChatMessage(role: .assistant, content: "I think we are done here."))
        service._testSeedMessageLoopRing(stepID: stepID, taskID: task.id, from: messages)
        XCTAssertEqual(service._testMessageLoopRing(stepID: stepID, taskID: task.id),
                       ["I think we are done here."], "premise: one qualifying turn, seeded")

        MessageLoopScanProbe.reset()
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I think we are done here.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            seedMessageLoopRing: false
        )

        guard case .continueLoop = stop else {
            return XCTFail("Expected .continueLoop, got \(stop)")
        }
        XCTAssertTrue((messages.last?.content ?? "").contains("did not call any tools"),
                      "anti-vacuum: loop detection ran and answered `.noLoop`, so the generic "
                          + "nudge follows; got: \(messages.last?.content ?? "nil")")
        XCTAssertEqual(MessageLoopScanProbe.examined(), 0,
                       "the detector must classify the ring, not walk 2000 wire messages per turn")
    }

    /// The companion that proves the classifier ran on the RING. The sibling above cannot
    /// tell `.noLoop` from "the block did not run" — its generic nudge follows on both — so
    /// here the ring is seeded from a SEPARATE wire of three identical prose turns while the
    /// 2001-message wire the helper is driven on holds ONE qualifying turn. A `.repetitiveNonTool`
    /// verdict is one the wire cannot produce: it proves the ring was the classifier's input,
    /// and `examined() == 0` proves the walk did not run beside it.
    ///
    /// RED: revert the classifier call to `detectMessageLoop(conversationMessages:)` → the
    /// generic nudge replaces `near-identical` AND `examined()` reads ≥ 2000; delete the whole
    /// `if !isStepInRevision { switch classifyMessageLoop … }` block → the generic nudge replaces
    /// `near-identical`.
    func testLoopDetection_classifiesTheRing_notTheWire() async {
        let repeated = "I think we are done here."
        let seedWire: [ChatMessage] = (0..<3).flatMap { _ in
            [ChatMessage(role: .assistant, content: repeated),
             ChatMessage(role: .user, content: "go on")]
        }
        service._testSeedMessageLoopRing(stepID: stepID, taskID: task.id, from: seedWire)
        XCTAssertEqual(service._testMessageLoopRing(stepID: stepID, taskID: task.id),
                       [repeated, repeated, repeated], "premise: three identical turns in the ring")

        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "s")]
        for i in 0..<1_000 {
            messages.append(ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(id: "c\(i)", name: ToolNames.readFile, argumentsJSON: "{}")]))
            messages.append(ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "c\(i)"))
        }
        messages.append(ChatMessage(role: .assistant, content: "A different closing remark."))
        XCTAssertEqual(ConversationRepairService.detectMessageLoop(conversationMessages: messages),
                       .noLoop, "premise: the wire holds one qualifying turn and cannot be a loop")

        MessageLoopScanProbe.reset()
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "A different closing remark.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            seedMessageLoopRing: false
        )

        guard case .continueLoop = stop else {
            return XCTFail("Expected .continueLoop, got \(stop)")
        }
        XCTAssertTrue((messages.last?.content ?? "").contains("near-identical"),
                      "a repetitive verdict the wire cannot produce — the ring was the input; "
                          + "got: \(messages.last?.content ?? "nil")")
        XCTAssertEqual(MessageLoopScanProbe.examined(), 0,
                       "the ring answered, so the 2001-message walk must not have run beside it")
    }

    // MARK: - Planning phase: a failed tool call is not a plan (regression 2026-08-07)

    /// The observed defect, end to end: `gemma-4-e4b` emitted a bare tool call in a
    /// planning-phase step, the parser dropped it (no sentinel), and the prose fallback
    /// wrote the raw JSON into `step.scratchpad` — which `implementationWire` then keeps as
    /// the SOLE surviving turn across the phase boundary, so the implementation phase began
    /// with `{"name":"list_files",…}|` as its plan. The user saw it as a chat bubble
    /// followed by "Plan recorded from your text response."
    ///
    /// The guard is the only production consumer of `BareToolCallSalvage.looksLikeToolCallAttempt`,
    /// and it had no behavioural pin: `&& false` on it left the whole suite green.
    func testPlanningPhase_failedToolCallIsNotRecordedAsThePlan() async {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are Software Engineer."),
            ChatMessage(role: .user, content: "Build a calculator"),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.search], expectedArtifacts: [])),
        ]
        // Verbatim from the run, trailing sentinel byte included.
        let leaked = #"{"name":"list_files","arguments":{"path":"MeditationApp"}}|"#

        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: leaked,
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )

        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)"); return
        }
        // The phase must stay OPEN for a real plan.
        XCTAssertNil(
            mockDelegate.taskToMutate?.runs[0].steps[0].scratchpad,
            "a tool call the parser dropped must not become the step's durable plan")

        let nudge = messages.last(where: { $0.role == .user })?.content ?? ""
        XCTAssertTrue(nudge.contains("looked like a tool call"), nudge)
        XCTAssertFalse(
            nudge.contains("Plan recorded"),
            "the prose fallback's nudge would tell the model its failed call was accepted")
    }

    /// The negative that keeps the guard narrow: ordinary prose in the same position still
    /// takes the plan-recording path, or the phase could never end.
    func testPlanningPhase_proseStillRecordsThePlan() async {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are Software Engineer."),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.search], expectedArtifacts: [])),
        ]
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I'll read ContentView.swift, then add the evaluator.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs[0].steps[0].scratchpad,
            "I'll read ContentView.swift, then add the evaluator.")
    }

    func testProducingRoleWithoutHarmonyMarker_sendsMissingArtifactsNudge() async {
        // Negative of the previous test: same producing role, but no harmony marker
        // and the content is plain text. Should fall through to the producing-role
        // artifact-missing branch (unchanged behavior).
        let role = makeProducingRole(artifactName: "Code Review")
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Let me think about this.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertTrue(
            retry.contains("Missing deliverables") && retry.contains("Code Review"),
            "Expected producing-role artifact-missing nudge, got: \(retry)"
        )
    }

    /// A role that has submitted one of two deliverables is told about the OTHER one only.
    /// Until 2026-09-06 the nudge quoted the role definition's whole `producesArtifacts`,
    /// so "Research Report" was reported missing on every no-tool turn after it had been
    /// submitted — a false fact re-sent until the step ended, and one that disagreed with
    /// `checkArtifactCompleteness`, which reads the STEP. Both now read
    /// `StepExecution.missingArtifactNames`.
    func testProducingRoleWithPartialSubmission_namesOnlyTheOutstandingDeliverable() async {
        var step = StepExecution(
            id: stepID, role: .uxDesigner, title: "Design",
            expectedArtifacts: ["Research Report", "Design Spec"], status: .running)
        step.artifacts = [Artifact(name: "Research Report")]
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        let role = TeamRoleDefinition(
            id: "ux_designer", name: "UX Designer", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [],
                                           producesArtifacts: ["Research Report", "Design Spec"]),
            llmOverride: nil, isSystemRole: true, systemRoleID: "uxDesigner",
            createdAt: Date(), updatedAt: Date())
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Working on the spec now.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        let retry = messages.last?.content ?? ""
        XCTAssertTrue(retry.contains("Missing deliverables as of that turn: \"Design Spec\"."), retry)
        XCTAssertFalse(retry.contains("Research Report"),
                       "the submitted deliverable must not be reported missing: \(retry)")
    }

    // MARK: - Missing Tool Name Nudge (Run 13 regression)

    /// Run 13: `qwen3.6-35b-a3b-nvfp4` emitted `<|call|>{"arguments":{…}}<|end|>`
    /// with syntactically valid JSON but no top-level `name`. The old nudge said
    /// "malformed JSON" and pointed at braces/quotes/commas — the model had no
    /// idea how to fix a problem it didn't have, and looped. The new nudge must
    /// identify "missing top-level `name`" specifically and show the inferred
    /// tool in the retry example so the model can self-correct.
    /// Was `…sendsSpecificNudgeWithInferredTool` until 2026-09-08. The example id used to
    /// come from schema-blind shape inference; now every id in the text comes from the
    /// role's own schema (R3.3.5, R3.8.3), so the tool is named because the role HOLDS it.
    func testHarmonyMarkerMissingToolName_namesATheRoleHoldsInTheExample() async {
        let qwenResponse = "[reasoning]\nI will create the artifact now.\n[/reasoning]\n\n<|call|>{\"arguments\":{\"content\":\"PRD\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: qwenResponse,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.createArtifact]
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertTrue(
            retry.contains("missing the top-level `name` field"),
            "Expected missing-tool-name nudge, got: \(retry)"
        )
        XCTAssertTrue(
            retry.contains("create_artifact"),
            "A tool the role holds must appear in the retry example, got: \(retry)"
        )
        XCTAssertFalse(
            retry.contains("missing closing brace"),
            "Must NOT blame 'malformed JSON' when the JSON parsed fine"
        )
    }

    /// The leak this arm shipped until 2026-09-08: `inferToolNameFromShape` is schema-blind
    /// and resolves `{name, content}` to `create_artifact`, which the PLANNING PHASE
    /// withholds — so a producing role mid-planning was shown an envelope naming a tool that
    /// iteration would have rejected. RED before the fix.
    func testMissingToolName_inferredToolOutsideTheSchema_isNotNamed() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "<|call|>{\"arguments\":{\"content\":\"PRD\",\"name\":\"Product Requirements\"}}<|end|>",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.readFile, ToolNames.updateScratchpad]
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("missing the top-level `name` field"))
        XCTAssertFalse(
            retry.contains(ToolNames.createArtifact),
            "the inferred tool is outside this role's schema and must not be taught: \(retry)")
        XCTAssertTrue(
            retry.contains(ToolNames.readFile),
            "the illustration must come from the role's own tools: \(retry)")
    }

    /// Ambiguous argument shape and an empty schema: the classifier still reports
    /// `.missingToolName`, and the nudge carries its instruction with NO illustration.
    ///
    /// Was `…usesPlaceholder` until 2026-09-08, when it asserted the literal `TOOL_NAME`.
    /// A placeholder is copyable — the same corpus shows a model pasting `{"param":"value"}`
    /// verbatim into `read_file` and earning `INVALID_ARGS` about a key no schema has — and
    /// `TOOL_NAME` itself dispatches to `tool_not_found`. Dropping the example costs the
    /// instruction nothing.
    func testHarmonyMarkerMissingToolName_emptySchema_carriesNoExample() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "<|call|>{\"arguments\":{\"foo\":\"bar\"}}<|end|>",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("missing the top-level `name` field"))
        XCTAssertFalse(retry.contains("TOOL_NAME"), "no copyable placeholder id: \(retry)")
        XCTAssertFalse(retry.contains("<|call|>"), "no illustration without a real id: \(retry)")
        XCTAssertFalse(retry.contains("\"param\""), "no copyable placeholder args: \(retry)")
    }

    /// The card is named after what the model actually wrote — the id was there, one level
    /// too deep, so `unknown_tool` was false. The CODE stays `MISSING_TOOL_NAME` because the
    /// `jq` audits in `.claude/skills/train-app` match on it.
    func testToolNameInsideArguments_cardIsNamedAfterTheNestedId() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent:
            "<|call|>{\"arguments\":{\"name\":\"git_show\",\"path\":\"a.gd\"}}<|end|>",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
        )
        let cards = latestToolCalls()
        XCTAssertEqual(cards.map(\.name), ["git_show"])
        XCTAssertEqual(cards.first?.isError, true)
        XCTAssertTrue(cards.first?.resultJSON?.contains("MISSING_TOOL_NAME") == true)
        XCTAssertTrue(cards.first?.resultJSON?.contains("inside `arguments`") == true)
    }

    /// The residual shape after the parser learned the nested envelope: the id was written
    /// inside `arguments` AND names no registered tool. Two faults, and the nudge states
    /// both without echoing the bad id (R3.8.3).
    func testToolNameInsideArguments_nudgeStatesBothFaults_andNamesNoForeignTool() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent:
            "<|call|>{\"arguments\":{\"name\":\"git_show\",\"path\":\"a.gd\",\"rev\":\"dbce2bb\"}}<|end|>",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.readFile]
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("inside `arguments`"), "the position fault: \(retry)")
        XCTAssertTrue(retry.contains("names no tool"), "the unknown-id fault: \(retry)")
        XCTAssertFalse(retry.contains("git_show"), "must not teach the bad id: \(retry)")
        XCTAssertTrue(retry.contains(ToolNames.readFile), "example from the schema: \(retry)")
    }

    /// Regression EA190834: UX Designer made up alias names ("CalculatorDesignSpec.md",
    /// "DesignSpec.md", "design_spec.md") chasing the missing-deliverables nudge because
    /// the message didn't show the exact name the system expected. Quote the names verbatim
    /// and forbid extensions/rewordings.
    func testMissingArtifactsNudge_quotesNameAndForbidsExtensions() async {
        let role = makeProducingRole(artifactName: "Design Spec")
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Here's the design...",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages
        )
        let retry = messages[0].content ?? ""
        XCTAssertTrue(
            retry.contains(#""Design Spec""#),
            "Nudge must quote the exact artifact name; got: \(retry)"
        )
        XCTAssertTrue(
            retry.lowercased().contains("exactly as shown"),
            "Nudge must demand the quoted name verbatim (positive form); got: \(retry)"
        )
    }

    // MARK: - Failed Tool-Call Card Surfacing
    //
    // Symptom report: «были ошибки в tool call, но в Team Activity они не показываются»
    // ("there were errors in the tool call, but they don't show in Team Activity"). When a
    // Harmony tool-call envelope can't be parsed into a dispatched call, no StepToolCall was
    // ever created — so the feed had nothing to render and the error was invisible. These
    // pin that an unparseable / name-missing attempt now leaves a visible, errored card.
    //
    // Real-flow shape: once a Harmony marker is seen mid-stream the envelope is routed to
    // `harmonyBuffer` (not `assistantContent`), so the card source reads harmonyBuffer.

    private func latestToolCalls() -> [StepToolCall] {
        mockDelegate.taskToMutate?.runs.last?.steps.first?.toolCalls ?? []
    }

    func testMalformedHarmonyCall_recordsErroredToolCallCard() async {
        // gemma-4-26b-a4b shape: a create_artifact envelope with a dropped comma after the
        // tool name — robustly unrecoverable (no repair targets it, no content re-escape can
        // bridge a missing structural comma). assistantContent is whitespace (the reasoning
        // tail), the envelope lives in harmonyBuffer — exactly the real streaming shape.
        let envelope = "<|call|>{\"name\":\"create_artifact\" \"arguments\":{\"name\":\"Engineering Notes\",\"content\":\"notes\"}}<|end|>"
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "\n\n",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: envelope
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        // The existing malformed-JSON retry nudge is still sent (card is additive).
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("malformed JSON") == true)
        // The new visible card:
        let cards = latestToolCalls()
        XCTAssertEqual(cards.count, 1, "Exactly one failed-attempt card recorded")
        XCTAssertEqual(cards.first?.name, "malformed_tool_call")
        XCTAssertEqual(cards.first?.isError, true)
        // Structured result envelope (not just a substring): ok:false + the parse-failure code.
        let result = JSONUtilities.parseJSONDictionary(cards.first?.resultJSON ?? "")
        XCTAssertEqual(result?["ok"] as? Bool, false)
        XCTAssertEqual((result?["error"] as? [String: Any])?["code"] as? String, "MALFORMED_TOOL_CALL")
        // The extracted `{…}` call body is stored verbatim (the braced span, markers stripped) —
        // asserting the exact string distinguishes the extract path from the raw-buffer fallback.
        XCTAssertEqual(cards.first?.argumentsJSON,
                       #"{"name":"create_artifact" "arguments":{"name":"Engineering Notes","content":"notes"}}"#,
                       "argumentsJSON must be the exact extracted call envelope, not the raw <|call|>…<|end|> buffer")
    }

    func testMissingToolNameHarmonyCall_recordsCardNamedAfterInferredTool() async {
        // Valid JSON, no top-level `name` (the qwen `{"arguments":{…}}` shape) → inferred as
        // create_artifact. The card names the inferred tool so the user sees what was attempted.
        let envelope = "<|call|>{\"arguments\":{\"content\":\"PRD\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: envelope
        )
        let cards = latestToolCalls()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.name, "create_artifact",
                       "Card names the inferred tool for a name-missing attempt")
        XCTAssertEqual(cards.first?.isError, true)
        XCTAssertTrue(cards.first?.resultJSON?.contains("MISSING_TOOL_NAME") == true)
    }

    func testChannelOnlyResponse_recordsNoCard() async {
        // gemma sometimes emits a `<|channel|>` with no `<|call|>` block — a formatting
        // hiccup, NOT a tool-call attempt. Must not spawn a noise card.
        let buffer = "<|channel|>commentary<|message|>Let me consider the next step."
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: buffer
        )
        XCTAssertTrue(latestToolCalls().isEmpty,
                      "A channel-only response is not a tool-call attempt → no card")
    }

    func testInlinedRoleTurn_recordsNoCard() async {
        // `.noEnvelopeAttempt`: the model emitted an inlined role turn, not a tool call.
        let buffer = "<|start|>userPlease continue<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: buffer
        )
        XCTAssertTrue(latestToolCalls().isEmpty,
                      "An inlined role turn is not a tool-call attempt → no card")
    }

    func testMalformedCall_noBracedBody_storesRawBufferVerbatim() async {
        // `<|call|>` present but no `{` follows (truncated / garbled body) → extractCallEnvelope
        // returns nil and the card falls back to storing the RAW buffer verbatim. Pins the
        // `?? envelope` fallback contract (the riskiest single line: a regression in
        // extractCallEnvelope would silently change what's stored).
        let buffer = "<|call|>\n\nnot json at all<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "\n\n",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: buffer
        )
        let cards = latestToolCalls()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.name, "malformed_tool_call")
        XCTAssertEqual(cards.first?.isError, true)
        XCTAssertEqual(cards.first?.argumentsJSON, buffer,
                       "No braced body → the whole raw buffer is stored verbatim (fallback path)")
    }

    /// Re-aimed pin (CLAUDE.md #104). It used to assert the opposite — that an envelope
    /// found only in `thinkingContent` was sourced into an errored card — which pinned the
    /// `envelopeSource` arm that read reasoning. That arm is gone with the reasoning-channel
    /// route, and its fixture was never production-faithful anyway: `sawHarmonyMarker` is
    /// raised only together with `harmonyBuffer = uiBuffer`, so `(true, "")` cannot occur.
    /// What survives the deletion is the property worth pinning — a rehearsed call in the
    /// reasoning channel produces NO failed-attempt card, because nothing was attempted on
    /// the channel that dispatches.
    func testMissingToolName_envelopeOnlyInThinking_recordsNoCard() async {
        let thinking = "<|call|>{\"arguments\":{\"content\":\"X\",\"name\":\"Design Spec\"}}<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: thinking,
            harmonyBuffer: ""
        )
        XCTAssertTrue(latestToolCalls().isEmpty,
                      "A reasoning-channel envelope is deliberation — it must not surface as a failed call")
        XCTAssertEqual(messages.count, 1, "…but the turn still nudges")
    }

    func testMissingToolName_unrecognizableShape_recordsUnknownToolCard() async {
        // Valid JSON, no top-level `name`, and a shape `inferToolNameFromShape` cannot
        // recognize → `.missingToolName(nil)` → the `"unknown_tool"` fallback literal that
        // ships to the UI card. Pins the `inferred ?? "unknown_tool"` coalescing.
        let buffer = "<|call|>{\"arguments\":{\"unrecognized\":\"x\"}}<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: buffer
        )
        let cards = latestToolCalls()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.name, "unknown_tool",
                       "An unrecognizable name-missing shape falls back to the unknown_tool literal")
        XCTAssertEqual(cards.first?.isError, true)
        XCTAssertTrue(cards.first?.resultJSON?.contains("MISSING_TOOL_NAME") == true)
    }

    // MARK: - Thinking-Drift Escalation (Run 13 regression)

    /// Run 13 symptom: qwen3.5-35b-a3b SWE emitted a 61,630-char `thinking`
    /// trace with empty `content` and zero tool calls, consuming 215s on a
    /// single turn. Pre-fix: no detector, nothing stopped it.
    /// Post-fix: first drift → targeted single-shot nudge, drift counter becomes 1.
    func testFirstThinkingDrift_sendsTargetedNudgeAndIncrementsCounter() async {
        let hugeThinking = String(repeating: "a", count: 20_000)
        var messages: [ChatMessage] = []
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0)

        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: hugeThinking
        )
        guard case .continueLoop = stop else {
            XCTFail("First drift should continue loop with nudge, got \(stop)")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let nudge = messages[0].content ?? ""
        XCTAssertTrue(
            nudge.contains("reasoning alone cannot"),
            "Expected drift-specific nudge, got: \(nudge)"
        )
        XCTAssertTrue(
            nudge.contains("20k characters"),
            "Nudge should report approximate thinking length, got: \(nudge)"
        )
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 1)
    }

    /// Second consecutive drift escalates to the supervisor. The engine has no
    /// way to un-stick a model that reasons without acting twice in a row after
    /// being nudged once.
    func testSecondThinkingDrift_escalatesToSupervisor() async {
        let hugeThinking = String(repeating: "b", count: 15_000)
        var messages: [ChatMessage] = []

        // First drift: nudge, counter → 1
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: hugeThinking
        )
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 1)

        // Second drift: escalate
        var messages2: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages2,
            thinkingContent: hugeThinking
        )
        guard case .needsSupervisorInput(let question, _) = stop else {
            XCTFail("Second drift should escalate, got \(stop)")
            return
        }
        XCTAssertTrue(
            question.contains("reasoning instead of acting"),
            "Escalation should describe the drift pattern, got: \(question)"
        )
        XCTAssertTrue(
            question.contains("two consecutive"),
            "Escalation should mention the consecutive trigger, got: \(question)"
        )
        // Counter reset so a supervisor-driven restart starts clean.
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0)
    }

    /// Short thinking (below threshold) must not trip drift detection — falls
    /// through to the existing branches. Using a producing role so we can see
    /// the artifact-missing nudge instead of the drift nudge.
    func testShortThinking_doesNotTripDriftDetector() async {
        let role = makeProducingRole(artifactName: "Design Spec")
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages,
            thinkingContent: String(repeating: "c", count: 1_000)
        )
        let retry = messages[0].content ?? ""
        XCTAssertFalse(
            retry.contains("reasoning alone cannot"),
            "Short thinking must not trip drift; got: \(retry)"
        )
        XCTAssertTrue(
            retry.contains("Missing deliverables"),
            "Short thinking + producing role should fall through to artifact nudge; got: \(retry)"
        )
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0)
    }

    /// Long thinking AND user-visible content is not drift — model is at least
    /// surfacing something. Falls through to other branches.
    func testLongThinkingWithContent_doesNotTripDriftDetector() async {
        let role = makeProducingRole(artifactName: "Design Spec")
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Here is my draft of the design spec body.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages,
            thinkingContent: String(repeating: "d", count: 20_000)
        )
        let retry = messages[0].content ?? ""
        XCTAssertFalse(
            retry.contains("reasoning alone cannot"),
            "Drift should require empty content; got: \(retry)"
        )
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0)
    }

    // After a tool call executes between two drift turns, the second drift must
    // start fresh (counter=1 → nudge), not pre-armed (counter=2 → escalate).
    // Production reset point: `LLMExecutionService.swift:286` immediately before
    // `executeToolCalls`. Without this reset, a model alternating between
    // reasoning-heavy turns and productive tool calls would prematurely escalate
    // to the supervisor on its second drift even though it had been making
    // progress in between.
    func testDriftCounter_resetAfterToolExecution_secondDriftIsNudge() async {
        let huge = String(repeating: "a", count: 15_000)
        var messages: [ChatMessage] = []

        // First drift → counter = 1, nudge.
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil,
            conversationMessages: &messages, thinkingContent: huge
        )
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 1)

        // Simulate tool-call execution between drifts.
        service._testResetDriftCounter(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0)

        // Second drift after reset → counter = 1 again, NUDGE not escalation.
        var messages2: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil,
            conversationMessages: &messages2, thinkingContent: huge
        )
        guard case .continueLoop = stop else {
            XCTFail("After reset, second drift must nudge (continueLoop), not escalate. Got \(stop)")
            return
        }
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 1)
        XCTAssertTrue(
            (messages2[0].content ?? "").contains("reasoning alone cannot"),
            "Should send drift nudge, not escalation message"
        )
    }

    // Drift detector is gated on `!isStepInRevision`. When revision is active, the
    // supervisor is already driving the model — letting drift escalate again would
    // create a recursion (escalate → supervisor responds → drift fires → escalate).
    // The revision-mode drift turn must also reset any pre-revision counter so a
    // post-revision drift sequence starts fresh.
    func testDriftDetector_skippedDuringRevision_counterReset() async {
        let role = makeProducingRole(artifactName: "Design Spec")
        let huge = String(repeating: "b", count: 20_000)

        // Pre-arm the counter to simulate a drift that happened before revision.
        var pre: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: role,
            conversationMessages: &pre, thinkingContent: huge
        )
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 1)

        // Now activate revision on the step.
        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "Please redo X"

        // Drift turn during revision → must NOT escalate, must NOT increment.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: role,
            conversationMessages: &messages, thinkingContent: huge
        )
        if case .needsSupervisorInput = stop {
            XCTFail("Drift during revision must NOT trigger supervisor escalation")
            return
        }
        XCTAssertEqual(
            service._testDriftCounter(stepID: stepID, taskID: task.id), 0,
            "Counter must reset on revision-mode drift to prevent post-revision pre-arming"
        )
        XCTAssertFalse(
            (messages.first?.content ?? "").contains("reasoning alone cannot"),
            "Drift nudge must not be sent during revision"
        )
    }

    // MARK: - Reasoning-channel envelopes are not tool-call attempts

    /// A `<|call|>` envelope that lived only in the reasoning channel arrives here with
    /// `sawHarmonyMarker == false` (a content-channel fact) and empty `assistantContent`.
    /// The Harmony classify-and-nudge branch must NOT fire: nothing was attempted on the
    /// channel that dispatches, so telling the model its JSON was malformed would blame a
    /// defect that does not exist. The turn takes the ordinary no-tool-call path.
    ///
    /// This is the pin for dropping `thinkingContent` from `envelopeSource` — with that arm
    /// restored the classifier would read the reasoning buffer instead.
    func testReasoningOnlyEnvelope_takesGenericNudge_notTheHarmonyBranch() async {
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: ##"Let me try. <|call|>{"name":"write_file","arguments":{"path":"x""##,
            allowedToolNames: [ToolNames.askSupervisor]
        )

        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertFalse(retry.contains("malformed JSON"),
                       "A rehearsed call is not a broken call — got: \(retry)")
        XCTAssertFalse(retry.contains("missing the top-level `name` field"),
                       "Harmony classification must not run for a reasoning-only envelope")
        XCTAssertTrue(retry.contains("did not call any tools"),
                      "Expected the generic no-tool-call nudge, got: \(retry)")
    }

    /// A tokens-only CONTENT channel takes its own branch: that diagnosis reads `content`
    /// and nothing else, so reasoning-channel prose — however tool-shaped — cannot steer it.
    ///
    /// The fixture deliberately carries a TRUNCATED envelope in reasoning. A well-formed one
    /// is claimed by the reasoning-channel branch above (see the sibling test below), so
    /// using one here would pin branch ORDER while pretending to pin channel independence.
    func testTokensOnlyContent_withUnparseableReasoningEnvelope_takesTokensOnlyBranch() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "<|foo|>",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: ##"<|call|>{"name":"write_file","arguments":{"path":"x"##
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue((messages[0].content ?? "").contains("only model-internal tokens"),
                      "got: \(messages[0].content ?? "")")
    }

    // MARK: - Reasoning-channel envelope: the nudge that names the channel

    // Measured across 291 network logs of the MeditationApp work folder (9–25 Aug 2026):
    // 33 responses carried a `<|call|>` envelope inside `[reasoning]`, and before the
    // reasoning ROUTE was removed 39 such envelopes really executed — 15 of them mutating.
    // The route is gone and stays gone; these tests pin the replacement, which only changes
    // WHAT the model is told once the turn has already resolved zero calls.

    /// A well-formed envelope in reasoning while `content` is empty. Short thinking, so the
    /// drift branch cannot fire — this is the 28-of-30 case from the logs, which until now
    /// fell all the way through to a nudge that could say nothing about channels.
    ///
    /// Uses a PRODUCING role: the artifact-missing nudge is what this turn would otherwise
    /// get, so seeing the channel nudge instead pins that the branch runs above it.
    func testReasoningEnvelope_shortThinking_sendsChannelNudgeAndIncrementsCounter() async {
        let role = makeProducingRole(artifactName: "Design Spec")
        var messages: [ChatMessage] = []
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 0)

        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages,
            thinkingContent: ##"""
            I should record the plan now.
            <|call|>{"name":"update_scratchpad","arguments":{"content":"# ledger"}}<|end|>
            """##,
            allowedToolNames: [ToolNames.updateScratchpad, ToolNames.readFile]
        )

        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop, got \(stop)")
            return
        }
        XCTAssertEqual(messages.count, 1)
        let nudge = messages[0].content ?? ""
        XCTAssertTrue(nudge.contains("inside your reasoning"),
                      "Nudge must name the channel that swallowed the call, got: \(nudge)")
        XCTAssertTrue(nudge.contains("`update_scratchpad`"),
                      "Nudge should quote the name the model wrote, got: \(nudge)")
        XCTAssertFalse(nudge.contains("Missing deliverables"),
                       "Channel nudge must pre-empt the producing-role artifact nudge")
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 1)
    }

    /// Verbatim shape of `tasks/0/runs/273` #43 (2026-08-25) — the one well-formed
    /// reasoning-channel turn observed AFTER the route was removed: two envelopes
    /// (`manage_role`, `update_scratchpad`), empty content, and 11,789 chars of reasoning,
    /// which is OVER `thinkingDriftLengthThreshold`. Both diagnoses are true at once
    /// (CLAUDE.md #95); the specific one must win the branch.
    func testReasoningEnvelope_overDriftThreshold_takesChannelNudge_notDriftNudge() async {
        let padding = String(repeating: "The worker's claim needs verifying. ", count: 330)
        let thinking = padding + ##"""
        
        Let me write the request_changes comment.
        <|call|>{"name":"manage_role","arguments":{"task_id":35,"action":"request_changes"}}<|end|>
        <|call|>{"name":"update_scratchpad","arguments":{"content":"# ledger"}}<|end|>
        """##
        XCTAssertGreaterThan(
            thinking.trimmingCharacters(in: .whitespacesAndNewlines).count,
            ConversationRepairService.thinkingDriftLengthThreshold,
            "Fixture must clear the drift threshold, or this pins nothing about precedence")

        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: thinking,
            allowedToolNames: [ToolNames.updateScratchpad]
        )

        let nudge = messages[0].content ?? ""
        XCTAssertTrue(nudge.contains("inside your reasoning"), "got: \(nudge)")
        XCTAssertFalse(nudge.contains("reasoning alone cannot"),
                       "The drift nudge must not win over the specific channel diagnosis")
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0,
                       "Drift streak is untouched when the channel branch claims the turn")
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 1)
    }

    /// Two consecutive turns of the same shape: the model is not moving the call into its
    /// reply on its own, and a third identical nudge would not change that.
    func testSecondReasoningEnvelope_escalatesToSupervisor() async {
        let thinking = ##"<|call|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>"##
        var first: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil,
            conversationMessages: &first, thinkingContent: thinking)
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 1)

        var second: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil,
            conversationMessages: &second, thinkingContent: thinking)

        guard case .needsSupervisorInput(let question, _) = stop else {
            XCTFail("Second consecutive reasoning-channel turn should escalate, got \(stop)")
            return
        }
        XCTAssertTrue(question.contains("inside its reasoning"), "got: \(question)")
        XCTAssertTrue(question.contains("two consecutive"), "got: \(question)")
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 0,
                       "Counter resets so a supervisor-driven restart starts clean")
    }

    /// During revision the Supervisor is already driving, so escalating would recurse. The
    /// nudge is still cheap and still accurate, so it is still sent — and the pre-revision
    /// streak is cleared so the first post-revision turn cannot start pre-armed.
    func testReasoningEnvelope_duringRevision_nudgesWithoutEscalating_counterReset() async {
        let thinking = ##"<|call|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>"##
        var pre: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil,
            conversationMessages: &pre, thinkingContent: thinking)
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 1)

        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "Please redo X"

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil,
            conversationMessages: &messages, thinkingContent: thinking)

        if case .needsSupervisorInput = stop {
            XCTFail("Reasoning-channel turn during revision must not escalate")
            return
        }
        XCTAssertTrue((messages.first?.content ?? "").contains("inside your reasoning"),
                      "The nudge itself is still correct during revision")
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 0,
                       "Pre-revision streak must not pre-arm the post-revision one")
    }

    /// The model rehearsed a tool the role does not hold. Confirming that name back to it
    /// would teach a vocabulary the runtime rejects — the same reason the Harmony arms filter
    /// their examples. The nudge survives without the list; only the list is dropped.
    func testReasoningEnvelopeNudge_omitsToolNamesTheRoleDoesNotHold() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: ##"<|call|>{"name":"launch_missiles","arguments":{}}<|end|>"##,
            allowedToolNames: [ToolNames.readFile]
        )

        let nudge = messages[0].content ?? ""
        XCTAssertTrue(nudge.contains("inside your reasoning"),
                      "The diagnosis holds even when the rehearsed tool is unknown")
        XCTAssertFalse(nudge.contains("launch_missiles"),
                       "A tool the role does not hold must not be confirmed back, got: \(nudge)")
    }

    /// A content-channel marker means the model DID aim at the dispatching channel and its
    /// envelope failed there. Blaming the reasoning channel would name the wrong defect, so
    /// the gate hands the turn to the Harmony classifier even though a reasoning envelope
    /// also exists.
    func testHarmonyMarkerInContent_withReasoningEnvelope_takesHarmonyBranch() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: ##"<|call|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>"##,
            harmonyBuffer: ##"<|call|>{"arguments":{"path":"a.swift"}}<|end|>"##,
            allowedToolNames: [ToolNames.readFile]
        )

        let nudge = messages[0].content ?? ""
        XCTAssertTrue(nudge.contains("missing the top-level `name` field"),
                      "Expected the content-channel diagnosis, got: \(nudge)")
        XCTAssertFalse(nudge.contains("inside your reasoning"),
                       "Must not blame the reasoning channel when content carried the attempt")
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 0)
    }

    /// Reasoning that only TALKS about tools is the ordinary case for every thinking model —
    /// it must keep taking the ordinary path, or the nudge fires on healthy turns.
    func testReasoningProseWithoutEnvelope_takesGenericNudge() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: "I should call read_file on ContentView.swift, then run the build.",
            allowedToolNames: [ToolNames.askSupervisor]
        )

        let nudge = messages[0].content ?? ""
        XCTAssertFalse(nudge.contains("inside your reasoning"), "got: \(nudge)")
        XCTAssertTrue(nudge.contains("did not call any tools"), "got: \(nudge)")
        XCTAssertEqual(service._testReasoningEnvelopeCounter(stepID: stepID, taskID: task.id), 0)
    }

    // MARK: - Near-miss sentinel (MeditationApp task 39 run 8, 2026-09-06)

    /// A shape the normalizer refuses to REPAIR but that is plainly a call attempt:
    /// `<|call|` with a debris run before the payload. `sawHarmonyMarker` never closes on
    /// it, so branch 4 (`classifyHarmonyCallIssue`) cannot run — and before this branch
    /// existed a producing role fell through to the artifact nudge and was told, once per
    /// turn, that it had not submitted its deliverables. In run 8 that happened 16 times.
    ///
    /// The repair and the diagnosis are complementary, not alternatives: the repair keeps
    /// getting narrower shapes wrong until a run proves the next one, and this branch is
    /// what makes that next one LOUD instead of silent.
    private static let nearMissEnvelope =
        ##"<|call|read_file{"path":"MeditationApp/SessionPlayer.swift"}"##

    func testNearMissSentinel_producingRole_namesTheFormNotTheArtifacts() async {
        let role = makeProducingRole(artifactName: "Engineering Notes")
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Let me read the player.\n" + Self.nearMissEnvelope,
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.readFile, ToolNames.createArtifact])
        guard case .continueLoop = stop else { return XCTFail("Expected .continueLoop, got \(stop)") }
        XCTAssertEqual(messages.count, 1)
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("<|call|>"), "the nudge must show the canonical shape, got: \(retry)")
        XCTAssertFalse(
            retry.contains("Missing deliverables"),
            "a format defect must not be diagnosed as a missing artifact, got: \(retry)")
    }

    /// R3.8.3: a nudge names only tools the role's schema holds, and never quotes the
    /// model's own bytes back — a nudge is never retired, so a quoted path would ride the
    /// prefix of every later request of the step.
    func testNearMissSentinel_nudgeIsSchemaCleanAndQuotesNothing() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.nearMissEnvelope,
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: makeProducingRole(artifactName: "Engineering Notes"),
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.readFile])
        let retry = messages[0].content ?? ""
        XCTAssertFalse(retry.contains("SessionPlayer.swift"),
                       "the model's own bytes must not be quoted back, got: \(retry)")
        XCTAssertFalse(retry.contains(ToolNames.writeFile),
                       "the nudge must not name a tool the role does not hold, got: \(retry)")
    }

    /// The counter this branch shares with `.malformedJSON` is the whole point: before it,
    /// the ONLY bound on this shape was `maxNonProductiveTurns = 20`, and run 8 reached 16
    /// consecutive nudges without tripping anything.
    func testNearMissSentinel_thirdConsecutive_escalatesToSupervisor() async {
        let role = makeProducingRole(artifactName: "Engineering Notes")
        var messages: [ChatMessage] = []
        for turn in 1...2 {
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: Self.nearMissEnvelope, sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages, allowedToolNames: [ToolNames.readFile])
            guard case .continueLoop = stop else { return XCTFail("turn \(turn): got \(stop)") }
        }
        let third = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: Self.nearMissEnvelope, sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages, allowedToolNames: [ToolNames.readFile])
        guard case .needsSupervisorInput(let question, _) = third else {
            return XCTFail("the third consecutive near-miss must escalate, got \(third)")
        }
        XCTAssertTrue(question.contains("<|call|>"), question)
    }

    /// **The seed-turn poisoning.** In planning phase an unparsed turn is recorded as the
    /// step's durable plan and carried across the boundary into the implementation wire's
    /// first USER turn. Run 8's record 60 was exactly this, and the broken marker then rode
    /// every request of the next phase as the most authoritative example in the context.
    /// `looksLikeToolCallAttempt` missed it because that predicate requires the WHOLE reply
    /// to be one JSON object, and this reply is prose followed by a sentinel.
    func testNearMissSentinel_inPlanningPhase_isNotRecordedAsThePlan() async {
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "TodayModel and TodayView are untracked leftovers.\n"
                + ##"<|call|search{"query":": View"}"##,
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.search, ToolNames.updateScratchpad],
            wireIsMidPlanning: true)
        guard case .continueLoop = stop else { return XCTFail("Expected .continueLoop, got \(stop)") }
        XCTAssertNil(
            mockDelegate.taskToMutate?.runs[0].steps[0].scratchpad,
            "a failed tool call is not a plan — recording it carries the defect across the boundary")
        let retry = messages[0].content ?? ""
        XCTAssertTrue(retry.contains("did not parse"), retry)
        XCTAssertFalse(retry.contains("Plan recorded"), retry)
    }

    /// A step whose deliverables are all in is DONE however its last turn was framed. The
    /// near-miss branch stands ABOVE the arm that says so, so without repeating the
    /// completeness check a near-miss on a turn after the final `create_artifact` would nudge
    /// a step with nothing left to do — and the only thing that ends THAT is the twenty-turn
    /// cap, which is the exact shape the branch exists to remove.
    ///
    /// RED: drop `checkArtifactCompleteness(...) == nil` from the branch condition →
    /// `.continueLoop` with a form nudge instead of `.completed`.
    func testNearMissSentinel_afterTheArtifactIsIn_completesRatherThanNudging() async {
        var completed = StepExecution(
            id: stepID, role: .softwareEngineer, title: "Eng",
            expectedArtifacts: ["Engineering Notes"], status: .running)
        completed.artifacts = [Artifact(name: "Engineering Notes")]
        var finished = task!
        finished.runs[0].steps = [completed]
        mockDelegate.taskToMutate = finished

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Done.\n" + Self.nearMissEnvelope,
            sawHarmonyMarker: false,
            task: finished,
            roleDefinition: makeProducingRole(artifactName: "Engineering Notes"),
            conversationMessages: &messages,
            allowedToolNames: [ToolNames.createArtifact])
        guard case .completed = stop else {
            return XCTFail("a step with every deliverable in must complete, got \(stop)")
        }
        XCTAssertTrue(messages.isEmpty, "a completed step must not also be nudged")
    }
}
