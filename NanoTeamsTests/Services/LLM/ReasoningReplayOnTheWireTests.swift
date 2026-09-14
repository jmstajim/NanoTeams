import XCTest

@testable import NanoTeams

/// `processStreamingResult` hands the model's reasoning to the wire turn it appends — under
/// `.native` only, where the two structured wires have a slot for it (`reasoning_content` on
/// the OpenAI shape, `thinking` on Ollama's). The prompt-taught wires render assistant turns as
/// labelled text and cannot carry it, so a prompt-taught turn records none: the transcript is
/// the record of what was SENT.
///
/// Why the wire carries it at all: a server whose cache cannot be trimmed (Qwen3.5's recurrent
/// layers under LM Studio's continuous-batching kit) reuses its cache only on a byte-identical
/// continuation of prompt + generated tokens, and the template re-renders the generated turn
/// byte-identically only when handed the reasoning it generated. Measured 2026-09-14 on
/// `qwythos-9b` at 19.9k tokens: 0.39 s to first token with the field, 13.28 s without.
@MainActor
final class ReasoningReplayOnTheWireTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let step = StepExecution(id: "swe", role: .softwareEngineer, title: "Work", status: .running)
        stepID = step.id
        task = NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        task = nil
        stepID = nil
        try await super.tearDown()
    }

    private func result(
        content: String = "", thinking: String, calls: [StepToolCall] = [],
        mode: ToolCallingMode
    ) -> LLMExecutionService.StreamingResult {
        LLMExecutionService.StreamingResult(
            assistantContent: content, thinkingContent: thinking, resolvedToolCalls: calls,
            sawHarmonyMarker: false, harmonyBuffer: "", toolCallingMode: mode)
    }

    /// The one turn `processStreamingResult` appends after the user turn; a wire of any other
    /// length is a failed test, not a crash.
    private func appendedTurn(
        _ r: LLMExecutionService.StreamingResult, file: StaticString = #filePath, line: UInt = #line
    ) async -> ChatMessage {
        var wire = [ChatMessage(role: .user, content: "go")]
        await service.processStreamingResult(r, stepID: stepID, taskID: task.id, conversationMessages: &wire)
        XCTAssertEqual(wire.count, 2, "exactly one assistant turn appended", file: file, line: line)
        return wire.count == 2 ? wire[1] : ChatMessage(role: .system, content: "MISSING TURN")
    }

    // MARK: - Native: the turn is replayed as generated

    func testNative_toolCallTurn_carriesItsReasoningVerbatim() async {
        let thinking = "I need to call list_files first.\n"
        let call = StepToolCall(providerID: "7", name: "list_files", argumentsJSON: #"{"path":"App"}"#)
        let turn = await appendedTurn(result(thinking: thinking, calls: [call], mode: .native))
        XCTAssertEqual(turn.role, .assistant)
        XCTAssertEqual(turn.reasoning, thinking, "raw — no cleaning, no trimming; the template trims")
        XCTAssertEqual(turn.toolCalls?.map(\.name), ["list_files"])
        XCTAssertNil(turn.content)
    }

    func testNative_proseTurn_carriesItsReasoning() async {
        let turn = await appendedTurn(result(content: "Done.", thinking: "<think>ok", mode: .native))
        XCTAssertEqual(turn.content, "Done.")
        XCTAssertEqual(turn.reasoning, "<think>ok")
    }

    /// A turn that resolved to nothing but reasoning (the call written inside the reasoning
    /// channel, task 111 run 2) still happened, and its anchor carries the reasoning: the next
    /// request then continues the server's cache instead of restarting it.
    func testNative_anchorOnlyTurn_carriesItsReasoning() async {
        let turn = await appendedTurn(result(thinking: "<tool_call><function=list_files>…", mode: .native))
        XCTAssertNil(turn.content)
        XCTAssertNil(turn.toolCalls)
        XCTAssertEqual(turn.reasoning, "<tool_call><function=list_files>…")
    }

    /// Whitespace-only reasoning is the empty think block some models emit; it is not a turn's
    /// reasoning and is not replayed — the same rule `commitStreaming` applies to the display
    /// record.
    func testNative_whitespaceOnlyReasoning_isNotReplayed() async {
        let turn = await appendedTurn(result(content: "Done.", thinking: "\n\n  \n", mode: .native))
        XCTAssertNil(turn.reasoning)
    }

    func testNative_noReasoning_isNil_notEmpty() async {
        let turn = await appendedTurn(result(content: "Done.", thinking: "", mode: .native))
        XCTAssertNil(turn.reasoning)
    }

    // MARK: - Prompt-taught: nothing to carry it, so nothing is recorded

    func testPromptTaught_recordsNoReasoning_onAnyBranch() async {
        let call = StepToolCall(name: "list_files", argumentsJSON: "{}")
        let withCall = await appendedTurn(result(thinking: "r", calls: [call], mode: .promptTaught))
        XCTAssertNil(withCall.reasoning)
        let prose = await appendedTurn(result(content: "p", thinking: "r", mode: .promptTaught))
        XCTAssertNil(prose.reasoning)
        let anchor = await appendedTurn(result(thinking: "r", mode: .promptTaught))
        XCTAssertNil(anchor.reasoning)
    }
}
