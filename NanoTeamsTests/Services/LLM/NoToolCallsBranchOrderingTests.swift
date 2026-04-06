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
}
