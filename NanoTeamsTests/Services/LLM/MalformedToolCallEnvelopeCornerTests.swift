import XCTest

@testable import NanoTeams

/// Corner-case map for `performStreamingCall`'s tool-call extraction under the
/// structurally-malformed Harmony envelopes that small local models actually
/// emit. Every shape here is verbatim (or minimized) from a real
/// `google/gemma-4-e4b` FAANG run where the model garbled almost every
/// `<|call|>` envelope.
///
/// The point is to PIN which shapes the runtime salvages (→ a tool call, so a
/// feed card) versus which it silently drops (→ no card, the "only Thinking"
/// symptom). The drops are the motivation for surfacing unparsed attempts in
/// the feed.
@MainActor
final class MalformedToolCallEnvelopeCornerTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []
        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "step0"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        mockClient = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    private func resolve(content: String, reasoning: String = "Reasoning prose.\n") async throws -> [StepToolCall] {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: reasoning),
            StreamEvent(contentDelta: content),
        ]
        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codeReviewer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil
        )
        return result.resolvedToolCalls
    }

    // MARK: - Shapes the runtime SALVAGES (→ a card)

    /// Missing the outer closing brace + no `<|end|>` (UX Designer `BF2AD303`:
    /// `…"name":"Design Spec"}` — one `}` closes `arguments`, the call object's
    /// `}` is absent). Depth-1 imbalance → `maxSalvageDepth` repairs it. Executed
    /// in production.
    func testMissingOuterBrace_noEndMarker_salvages() async throws {
        let envelope = ##"<|call|>{"name":"create_artifact","arguments":{"name":"Design Spec","content":"# Spec","format":"markdown"}"##
        let calls = try await resolve(content: envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact)
    }

    /// Tool name emitted OUTSIDE the JSON object (SWE first `write_file`:
    /// `<|call|>write_file{…}</|end|>`). Executed in production (`<§W1§>` success).
    func testToolNameOutsideJSON_trailingSlashEnd_salvages() async throws {
        let envelope = #"<|call|>write_file{"path":"a.py","content":"x = 1"}</|end|>"#
        let calls = try await resolve(content: envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.writeFile)
    }

    /// Balanced object followed by `<tool_call|><afthought>…` junk (SRE
    /// `create_artifact`). The brace walker exits at the first depth-0 close;
    /// trailing junk is ignored.
    func testTrailingTagSoup_afterBalancedObject_salvages() async throws {
        let envelope = #"<|call|>{"name":"create_artifact","arguments":{"name":"Production Readiness","content":"x","format":"markdown"}}<tool_call|><afthought>I think I am done.</afthought>"#
        let calls = try await resolve(content: envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact)
    }

    /// Trailing `</|end|>` (a `</` mangling of `<|end|>`) after a balanced object.
    func testTrailingMangledEndMarker_salvages() async throws {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}</|end|>"#
        let calls = try await resolve(content: envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    // MARK: - Shapes the runtime DROPS (→ no card; "only Thinking")

    /// Garbled marker `<|tool_call>call|>` (Tech Lead `update_scratchpad`) — the model
    /// spliced its own `<|tool_call|>` sentinel into the `<|call|>` the prompt teaches.
    ///
    /// This used to belong under "shapes the runtime DROPS" and asserted `calls.isEmpty`
    /// as the documented silent-drop case. It is not a shape worth dropping: the intent
    /// is unambiguous and the payload is intact, so `HarmonySentinelNormalizer`
    /// canonicalises the sentinel and the call is dispatched. Left in this file next to
    /// the shapes that genuinely stay dropped, because the contrast is the point.
    func testGarbledCallMarker_nowResolves() async throws {
        let envelope = #"<|tool_call>call|>{"name":"update_scratchpad","arguments":{"content":"1. plan"}}"/>"#
        let calls = try await resolve(content: envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.updateScratchpad)
    }

    /// Whole deliverable written as prose with NO `<|call|>` at all (UX Designer
    /// `898623EB` wrote the entire Design Spec as markdown). No tool call.
    func testProseOnly_noMarker_doesNotResolve() async throws {
        let calls = try await resolve(
            content: "# Design Specification\n\nThis is the full spec written as prose, no tool call.")
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Degenerate / boundary inputs

    /// `<|call|>` followed by only whitespace — nothing to parse.
    func testCallMarkerThenWhitespace_doesNotResolve() async throws {
        let calls = try await resolve(content: "<|call|>   \n  ")
        XCTAssertTrue(calls.isEmpty)
    }

    /// Empty object — no top-level `name`, nothing to dispatch.
    func testEmptyObject_doesNotResolve() async throws {
        let calls = try await resolve(content: "<|call|>{}<|end|>")
        XCTAssertTrue(calls.isEmpty)
    }

    /// `arguments` present but top-level `name` missing — can't identify the tool.
    func testMissingTopLevelName_doesNotResolve() async throws {
        let calls = try await resolve(content: #"<|call|>{"arguments":{"path":"a.txt"}}<|end|>"#)
        XCTAssertTrue(calls.isEmpty)
    }

    /// Completely empty stream (no thinking, no content) — no crash, no calls.
    func testEmptyStream_doesNotResolveAndDoesNotCrash() async throws {
        mockClient.deltas = []
        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codeReviewer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil
        )
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
    }

    /// Well-formed `update_scratchpad` split across many small content deltas
    /// (boundary-split markers + JSON) — the real stream never arrives in one
    /// chunk. Must still resolve.
    func testWellFormedScratchpad_splitAcrossDeltas_resolves() async throws {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "Planning.\n"),
            StreamEvent(contentDelta: "<|ca"),
            StreamEvent(contentDelta: "ll|>{\"name\":\"upda"),
            StreamEvent(contentDelta: "te_scratchpad\",\"arguments\":{\"con"),
            StreamEvent(contentDelta: "tent\":\"1. plan\\n2. do\"}}"),
            StreamEvent(contentDelta: "<|end|>"),
        ]
        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codeReviewer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil
        )
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.updateScratchpad)
    }

    // MARK: - Classification: no call block is not malformed JSON

    /// Harmony framing that never opens a `<|call|>` block has no JSON, so calling it
    /// malformed is a misdiagnosis — one that reaches the HUMAN, since three of them
    /// escalate with a question naming unescaped quotes as the likely cause.
    func testClassify_channelFramingWithNoCallBlock_isNoCallEnvelope() {
        for buffer in [
            "<|channel|>commentary<|message|>Let me think.",
            "<|channel|>final<|message|>I'll wait for the task to finish.",
            "<|channel|>commentary to=commentary<|message|>",  // reserved recipient
        ] {
            XCTAssertEqual(
                ToolCallParsingHelpers.classifyHarmonyCallIssue(in: buffer), .noCallEnvelope,
                "no `<|call|>` block was opened in: \(buffer)")
        }
    }

    /// The other side of the split: a block that WAS opened and whose payload really is
    /// broken keeps `.malformedJSON`, so the parse-failure cap and its diagnostic stay
    /// aimed at the defect they describe.
    func testClassify_openedCallBlockWithBrokenPayload_staysMalformedJSON() {
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(
                in: ##"<|call|>{"name":"write_file","arguments":{"path":"x""##),
            .malformedJSON, "unbalanced braces after `<|call|>` is a genuine parse failure")
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: "<|call|>not an object"),
            .malformedJSON, "a `<|call|>` block whose payload isn't an object is too")
    }
}
