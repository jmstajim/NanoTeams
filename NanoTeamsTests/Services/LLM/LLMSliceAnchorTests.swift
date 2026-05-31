import XCTest

@testable import NanoTeams

/// Verifies that a model turn which yields neither assistant content nor a resolved
/// tool call (the consumed-but-unparsed Harmony-envelope case — e.g. malformed JSON)
/// still advances the in-memory stateful-continuation slice anchor.
///
/// Regression (Engineering Team / Software Engineer headless run, model
/// `google/gemma-4-26b-a4b`, network_log.json responses 27DF1B2F → 8DDAC74C): after a
/// malformed `write_file` call the next request re-sent the already-delivered `<§W2§>`
/// tool result PLUS every accumulated retry nudge. Root cause: `processStreamingResult`
/// only appended an assistant message when `hasContent || hasToolCalls`, so a consumed
/// envelope (empty content + no resolved call) left `lastIndex(where: .assistant)` pinned
/// at the prior valid turn, and the slice `conversationMessages[(lastAssistantIdx+1)...]`
/// kept re-emitting the stale tool result. In stateful mode (`previous_response_id`)
/// re-sending a delivered result corrupts the chain and grows input exponentially
/// (CLAUDE.md "Stateful Session Invariants" #2).
@MainActor
final class LLMSliceAnchorTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Scaffold", status: .running)
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

    /// The verbatim malformed-JSON retry nudge `handleNoToolCalls` appends — copied
    /// from `LLMExecutionService+StepFlowControl.swift` (and seen twice in the log's
    /// request A2AC64E2 because the anchor never advanced).
    private static let realNudge =
        "Your previous tool call had malformed JSON and could not be parsed (e.g. a missing closing brace `}`, an unescaped quote inside a string, or a trailing comma). Retry with valid JSON, e.g. `<|call|>{\"name\":\"TOOL_NAME\",\"arguments\":{…}}<|end|>` — note the two closing braces before `<|end|>`."

    /// The new messages a stateful continuation would transmit (system is sent separately /
    /// omitted on the wire). Calls the REAL production slice — `statefulContinuationSlice` —
    /// rather than a replica, so this test can never drift from `runOneLLMToolIteration`.
    private func statefulNewMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        LLMExecutionService.statefulContinuationSlice(conversationMessages: messages, isStateful: true)
            .messages.filter { $0.role != .system }
    }

    // MARK: - The wire symptom (RC2)

    func testMalformedTurn_advancesAnchor_soSliceDropsStaleToolResult() async {
        // Real prior state implied by the log just before request 8DDAC74C: the role had
        // written src/core/__init__.py (valid assistant turn + tool call) and received the
        // <§W2§> tool result (the new message that request 84B7B63F delivered).
        let realToolResult =
            #"{"tag":"<§W2§>","status":"success","path":"src\/core\/__init__.py","lines":2}"#
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system prompt"),
            ChatMessage(
                role: .assistant,
                content: nil,
                toolCalls: [ChatToolCall(
                    id: "call_core",
                    name: "write_file",
                    argumentsJSON: #"{"path":"src/core/__init__.py","content":"x"}"#)]),
            ChatMessage(role: .tool, content: realToolResult, toolCallID: "call_core"),
        ]
        let assistantsBefore = messages.filter { $0.role == .assistant }.count

        // The model's next turn (response 27DF1B2F) is a malformed Harmony envelope: the
        // parser consumed it but resolved no tool call → empty assistantContent,
        // sawHarmonyMarker == true.
        _ = await service._testProcessStreamingResult(
            stepID: stepID,
            assistantContent: "",
            sawHarmonyMarker: true,
            conversationMessages: &messages
        )

        // RC2 fix: exactly one assistant anchor must be appended so the slice advances.
        XCTAssertEqual(
            messages.filter { $0.role == .assistant }.count, assistantsBefore + 1,
            "A consumed-but-unparsed turn must append exactly one assistant anchor")
        // The anchor must be EMPTY (nil content, no tool calls) — it exists only to advance
        // the slice cursor, never to carry stale content into the chain.
        let anchor = messages.last
        XCTAssertEqual(anchor?.role, .assistant)
        XCTAssertNil(anchor?.content, "Anchor must carry no content")
        XCTAssertNil(anchor?.toolCalls, "Anchor must carry no tool calls")

        // handleNoToolCalls then appends the real malformed-JSON nudge (a user message).
        messages.append(ChatMessage(role: .user, content: Self.realNudge))

        // The slice for the NEXT request (8DDAC74C) must be the nudge ALONE — the
        // already-delivered <§W2§> tool result must NOT be re-sent.
        let slice = statefulNewMessages(messages)
        XCTAssertFalse(
            slice.contains { ($0.content ?? "").contains("<§W2§>") },
            "Stale tool result must not be re-sent on the malformed retry; slice roles=\(slice.map(\.role))")
        XCTAssertEqual(slice.count, 1, "Slice must contain only the nudge")
        XCTAssertEqual(slice.first?.role, .user)
    }

    func testTwoConsecutiveMalformedTurns_doNotAccumulateNudges() async {
        // Reproduces request A2AC64E2 (the nudge appeared TWICE): two malformed turns in a
        // row since the last valid assistant turn. With the anchor advancing on each turn,
        // each next slice carries exactly one nudge — never an accumulation.
        let realToolResult =
            #"{"tag":"<§W1§>","status":"success","path":"src\/__init__.py","lines":2}"#
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system prompt"),
            ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(
                    id: "call_init", name: "write_file",
                    argumentsJSON: #"{"path":"src/__init__.py","content":"x"}"#)]),
            ChatMessage(role: .tool, content: realToolResult, toolCallID: "call_init"),
        ]

        // Malformed turn #1
        _ = await service._testProcessStreamingResult(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: true,
            conversationMessages: &messages)
        messages.append(ChatMessage(role: .user, content: Self.realNudge))

        // Malformed turn #2: processStreamingResult appends the anchor, then handleNoToolCalls
        // appends the nudge (real flow — the anchor is never the last message in production).
        _ = await service._testProcessStreamingResult(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: true,
            conversationMessages: &messages)
        messages.append(ChatMessage(role: .user, content: Self.realNudge))

        // The request built here is A2AC64E2 in the log.
        let sliceForSecondRetry = statefulNewMessages(messages)

        let nudgeCount = sliceForSecondRetry.filter {
            ($0.content ?? "").contains("malformed JSON")
        }.count
        XCTAssertEqual(
            nudgeCount, 1,
            "Exactly the LATEST nudge — prior nudges sit behind the new anchor (no accumulation to 2). slice=\(sliceForSecondRetry.map(\.role))")
        XCTAssertFalse(
            sliceForSecondRetry.contains { ($0.content ?? "").contains("<§W1§>") },
            "The original tool result must not be re-sent two iterations later")
    }

    // MARK: - Happy path must be unchanged (no spurious / double anchor)

    func testContentfulTurn_appendsSingleAssistantWithContent() async {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "sys")]
        _ = await service._testProcessStreamingResult(
            stepID: stepID,
            assistantContent: "Here is my reasoning and answer.",
            conversationMessages: &messages)
        let assistants = messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "A contentful turn appends exactly one assistant message")
        XCTAssertEqual(assistants.first?.content, "Here is my reasoning and answer.")
        XCTAssertNil(assistants.first?.toolCalls)
    }

    func testToolCallTurn_appendsAssistantWithToolCalls_notAnEmptyAnchor() async {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "sys")]
        let call = StepToolCall(
            providerID: "p1", name: "write_file",
            argumentsJSON: #"{"path":"a.txt","content":"x"}"#)
        _ = await service._testProcessStreamingResult(
            stepID: stepID,
            assistantContent: "",
            resolvedToolCalls: [call],
            sawHarmonyMarker: true,
            conversationMessages: &messages)
        let assistants = messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "A tool-call turn appends exactly one assistant message")
        XCTAssertEqual(
            assistants.first?.toolCalls?.count, 1,
            "The assistant message carries the resolved tool call, not an empty anchor")
    }

    // MARK: - statefulContinuationSlice: direct unit coverage (incl. branches the wire tests skip)

    func testSlice_statefulAfterAnchor_sendsOnlyNewMessages() {
        // [system, assistant(anchor), tool, user(nudge)] → slice keeps system + everything
        // after the last assistant (the tool result + nudge), drops nothing stale.
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: nil),
            ChatMessage(role: .tool, content: "result", toolCallID: "c1"),
            ChatMessage(role: .user, content: "nudge"),
        ]
        let slice = LLMExecutionService.statefulContinuationSlice(
            conversationMessages: messages, isStateful: true)
        XCTAssertFalse(slice.fallBackToStateless, "Non-empty new content → stay stateful")
        XCTAssertEqual(slice.messages.map(\.role), [.system, .tool, .user])
    }

    func testSlice_statefulButNoNonEmptyNewContent_fallsBackToStateless() {
        // The empty-slice defense the replica never modeled: last turn is the assistant, and
        // the only thing after it is an empty-content message → must fall back to a full
        // stateless send (clear session) rather than fire an HTTP-400 empty input.
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "ok"),
            ChatMessage(role: .assistant, content: nil),  // trailing anchor, no following nudge
        ]
        let slice = LLMExecutionService.statefulContinuationSlice(
            conversationMessages: messages, isStateful: true)
        XCTAssertTrue(slice.fallBackToStateless, "Empty new-message slice → fall back to stateless")
        XCTAssertEqual(slice.messages.count, messages.count, "Stateless fallback resends the full conversation")
    }

    func testSlice_statelessOrNoAssistant_sendsFullConversation() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "hi"),
        ]
        // isStateful=false → full conversation, no fallback flag.
        let stateless = LLMExecutionService.statefulContinuationSlice(
            conversationMessages: messages, isStateful: false)
        XCTAssertFalse(stateless.fallBackToStateless)
        XCTAssertEqual(stateless.messages.count, messages.count)
        // isStateful=true but no assistant turn yet (first call) → also full conversation.
        let firstCall = LLMExecutionService.statefulContinuationSlice(
            conversationMessages: messages, isStateful: true)
        XCTAssertEqual(firstCall.messages.count, messages.count)
    }
}
