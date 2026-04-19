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
            conversationMessages: &messages
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
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop")
            return
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("malformed JSON") == true)
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
            conversationMessages: &messages
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
    /// retries against the same `previous_response_id`).
    ///
    /// Fix: persist the assistant text as the implicit plan (so applyPlanningPhase
    /// transitions to implementation on the next iteration) and append a user nudge so
    /// the stateful continuation has non-empty input.
    func testPlanningPhaseNoToolCall_appendsUserNudgeAndPersistsScratchpad() async {
        let planningPrompt = """
        You are Software Engineer.

        PLANNING PHASE
        ==============
        Call update_scratchpad with your plan.
        """
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: planningPrompt),
            ChatMessage(role: .user, content: "Build a calculator")
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
        XCTAssertEqual(userMessages.count, 2, "Expected original user + new nudge")
        let nudge = userMessages.last?.content ?? ""
        XCTAssertTrue(
            nudge.contains("IMPLEMENTATION PHASE"),
            "Expected implementation-phase nudge, got: \(nudge)"
        )

        // Scratchpad must be persisted so applyPlanningPhase transitions on the next iteration.
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
            retry.lowercased().contains("do not add file extensions"),
            "Nudge must forbid extensions; got: \(retry)"
        )
    }
}
