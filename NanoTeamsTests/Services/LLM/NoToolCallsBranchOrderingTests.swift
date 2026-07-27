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

    override func setUp() {
        super.setUp()
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

    override func tearDown() {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        super.tearDown()
    }

    // MARK: - Branch Ordering

    /// A real broken `<|call|>` block, carried in `harmonyBuffer` the way production does.
    /// The fixture used to be empty, which meant these tests exercised "Harmony framing
    /// with no call block" while claiming to exercise "a call block whose JSON is broken" —
    /// they only passed because both folded into `.malformedJSON`. They are now distinct
    /// cases, and this constant is what makes the assertions mean what they say.
    private static let brokenCallEnvelope =
        ##"<|call|>{"name":"write_file","arguments":{"path":"x""##

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
        // Envelope with no closing brace at all — the retry must name the
        // ACTUAL defect (playbook: re-prompt with the parse error attached)
        // instead of the generic brace/quote/comma guess list.
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
        XCTAssertTrue(retry.contains("parser error: the JSON object's braces never balance"),
                      "retry must carry the concrete parser diagnostic, got: \(retry)")
        XCTAssertFalse(retry.contains("e.g. a missing closing brace"),
                       "generic hint list must be replaced when a concrete diagnostic exists")
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

    func testGenericNudge_withAskSupervisorOnly_keepsTheOriginalText() async {
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
        XCTAssertTrue(retry.contains(ToolNames.askSupervisor))
        XCTAssertTrue(retry.contains("does not reach the Supervisor"))
    }

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
            count: 3, allowedToolNames: [ToolNames.readFile, ToolNames.updateScratchpad])
        XCTAssertFalse(withheld.contains(ToolNames.createArtifact),
                       "Planning phase withholds create_artifact, got: \(withheld)")

        let granted = LLMExecutionService.repetitiveNonToolNudge(
            count: 3, allowedToolNames: [ToolNames.createArtifact, ToolNames.askSupervisor])
        XCTAssertTrue(granted.contains(ToolNames.createArtifact))
        XCTAssertTrue(granted.contains(ToolNames.askSupervisor))
    }

    func testRepetitiveNonToolNudge_manager_steersToWaitForEvents() {
        let text = LLMExecutionService.repetitiveNonToolNudge(
            count: 4, allowedToolNames: [ToolNames.waitForEvents, ToolNames.listTasks])
        XCTAssertTrue(text.contains(ToolNames.waitForEvents))
        XCTAssertFalse(text.contains(ToolNames.askSupervisor))
        XCTAssertTrue(text.contains("last 4 responses"), "keeps the count, got: \(text)")
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

    // MARK: - Missing Tool Name Nudge (Run 13 regression)

    /// Run 13: `qwen3.6-35b-a3b-nvfp4` emitted `<|call|>{"arguments":{…}}<|end|>`
    /// with syntactically valid JSON but no top-level `name`. The old nudge said
    /// "malformed JSON" and pointed at braces/quotes/commas — the model had no
    /// idea how to fix a problem it didn't have, and looped. The new nudge must
    /// identify "missing top-level `name`" specifically and show the inferred
    /// tool in the retry example so the model can self-correct.
    func testHarmonyMarkerMissingToolName_sendsSpecificNudgeWithInferredTool() async {
        let qwenResponse = "[reasoning]\nI will create the artifact now.\n[/reasoning]\n\n<|call|>{\"arguments\":{\"content\":\"PRD\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: qwenResponse,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages
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
            "Inferred tool name must appear in the retry example, got: \(retry)"
        )
        XCTAssertFalse(
            retry.contains("missing closing brace"),
            "Must NOT blame 'malformed JSON' when the JSON parsed fine"
        )
    }

    /// Ambiguous argument shape (no `format`, not recognisable as any specific tool):
    /// the classifier still reports `.missingToolName` but with no inferred tool —
    /// the nudge uses the generic `TOOL_NAME` placeholder.
    func testHarmonyMarkerMissingToolName_unknownShape_usesPlaceholder() async {
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
        XCTAssertTrue(
            retry.contains("TOOL_NAME"),
            "Generic placeholder must appear when no inference succeeded, got: \(retry)"
        )
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

    func testMissingToolName_envelopeOnlyInThinking_recordsCardFromThinkingSource() async {
        // Reasoning-channel fallback: the envelope lands in `thinkingContent`, not
        // `harmonyBuffer`. Pins the second `envelopeSource` branch (`thinkingContent.contains("<|")`)
        // routes to the card — not just to the retry nudge.
        let thinking = "<|call|>{\"arguments\":{\"content\":\"X\",\"name\":\"Design Spec\"}}<|end|>"
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: thinking,
            harmonyBuffer: ""
        )
        let cards = latestToolCalls()
        XCTAssertEqual(cards.count, 1, "Card must be sourced from thinkingContent when harmonyBuffer is empty")
        XCTAssertEqual(cards.first?.name, "create_artifact")
        XCTAssertEqual(cards.first?.isError, true)
        XCTAssertTrue(cards.first?.resultJSON?.contains("MISSING_TOOL_NAME") == true)
        XCTAssertTrue(cards.first?.argumentsJSON.contains("Design Spec") == true,
                      "Arguments must be extracted from the thinking-channel envelope")
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
        guard case .needsSupervisorInput(let question) = stop else {
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
}
