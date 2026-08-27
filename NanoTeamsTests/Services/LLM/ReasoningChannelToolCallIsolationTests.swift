import XCTest

@testable import NanoTeams

/// Pins the contract that `LLMExecutionService.performStreamingCall` **never** turns text
/// on the reasoning channel (`reasoning.delta` SSE events → `StreamEvent.thinkingDelta`
/// deltas → `thinkingCollected` buffer) into an executable tool call — framed in a Harmony
/// envelope or not — and instead leaves it visible, verbatim, in the Thinking disclosure.
///
/// History, because the opposite route existed and its motivation was real. Observed in
/// `.nanoteams/internal/tasks/0/subtasks/1/runs/0/network_log.json` with
/// `qwen3.6-35b-a3b-ud-mlx`: three consecutive `create_artifact` emissions stochastically
/// picked between channels. Records #11 (offset 4983 inside a 9671-byte reasoning block)
/// and #13 emitted `<|call|>…<|end|>` inside the reasoning channel; record #15 emitted via
/// content and worked. A post-stream scan of `thinkingCollected` was added so the two
/// behaved alike — which fixed the stall by executing what the model had only rehearsed.
/// The channel is itself part of the intent signal: a model writing in `reasoning.delta`
/// is CONSIDERING a call, and a `<|…|>` marker does not upgrade deliberation into action.
/// A reasoning-only turn now resolves nothing and falls through to the ordinary
/// no-tool-call handling in `+StepFlowControl` (thinking-drift nudge, then escalation).
///
/// The two content-channel tests at the bottom are the anti-vacuum: they must stay GREEN,
/// or these tests are pinning "no tool call ever resolves" rather than the channel rule.
@MainActor
final class ReasoningChannelToolCallIsolationTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] = LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        mockClient = nil
        try await super.tearDown()
    }

    /// The thinking text this turn committed, or `nil` when the commit dropped it.
    private var committedThinking: String? {
        mockDelegate.commitStreamingCalls.first?.3
    }

    private func stream(_ deltas: [StreamEvent], role: Role = .codingAgent) async throws
        -> LLMExecutionService.StreamingResult
    {
        mockClient.deltas = deltas
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: role,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )
    }

    // MARK: - Episode 1 — read_file emitted entirely in reasoning channel

    /// All deltas arrive on the reasoning channel — both the prose AND the
    /// `<|call|>…<|end|>` envelope. Content channel is silent. Nothing is dispatched, and
    /// the envelope survives into the persisted Thinking disclosure byte for byte.
    func testToolCallInReasoningChannel_isNotExecuted() async throws {
        let result = try await stream([
            StreamEvent(thinkingDelta: "The user wants me to read the file. "),
            StreamEvent(thinkingDelta: "Let me call read_file.\n\n"),
            StreamEvent(thinkingDelta: "<|call|>{\"name\":\""),
            StreamEvent(thinkingDelta: "read_file\",\"arguments\":{"),
            StreamEvent(thinkingDelta: "\"path\": \"calculator.html\"}}"),
            StreamEvent(thinkingDelta: "<|end|>"),
        ])

        XCTAssertTrue(result.resolvedToolCalls.isEmpty,
                      "A call written in the reasoning channel is deliberation, not action")
        XCTAssertFalse(result.sawHarmonyMarker,
                       "The marker never touched the content channel")
        // Reasoning prose AND the rehearsed envelope both survive, raw.
        XCTAssertTrue(result.thinkingContent.contains("Let me call read_file"))
        XCTAssertTrue(result.thinkingContent.contains("<|call|>"))
        let committed = try XCTUnwrap(committedThinking)
        XCTAssertTrue(committed.contains("<|call|>"),
                      "Sentinels are shown verbatim — got \(committed.debugDescription)")
        XCTAssertTrue(committed.contains("<|end|>"))
        XCTAssertTrue(committed.contains(#""path": "calculator.html""#))
    }

    // MARK: - Episode 2 — create_artifact with long reasoning prose

    /// Marker arrives DEEP inside the reasoning buffer (≈4KB of prose first), then the
    /// envelope across several boundary-split deltas. Pins that no amount of preceding
    /// prose makes the scan reappear, and that the whole block still commits.
    func testToolCallInReasoningChannel_longProse_isNotExecuted() async throws {
        let prose = String(repeating: "Considering the requirements carefully. ", count: 100)
        let result = try await stream([
            StreamEvent(thinkingDelta: prose),
            StreamEvent(thinkingDelta: ##"<|call|>{"name":"create_artifact","arguments":"##),
            StreamEvent(thinkingDelta: ##"{"format":"markdown","name":"Design Spec","##),
            StreamEvent(thinkingDelta: ##""content":"# Spec"}}<|end|>"##),
        ])

        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        let committed = try XCTUnwrap(committedThinking)
        XCTAssertTrue(committed.hasPrefix(prose))
        XCTAssertTrue(committed.hasSuffix("<|end|>"))
    }

    // MARK: - Episode 3 — the artifact-completeness loop this route was added to break

    /// The original motivating episode: a producing role told "deliverables are missing"
    /// re-emits `create_artifact` into its reasoning. That does NOT satisfy the step — the
    /// artifact is not submitted, and the turn carries no tool call to satisfy it with.
    func testToolCallInReasoningChannel_missingDeliverables_reasoningCallDoesNotSatisfy() async throws {
        let preamble = """
        The user wants me to submit the "Implementation Plan" artifact. \
        I already called create_artifact in my previous turn, but the system \
        says it's missing. I'll just call it again to be safe.
        """
        let result = try await stream([
            StreamEvent(thinkingDelta: preamble),
            StreamEvent(thinkingDelta: "\nContent is ready.\nTool: create_artifact\n"),
            StreamEvent(thinkingDelta:
                ##"<|call|>{"name":"create_artifact","arguments":{"format":"markdown","name":"Implementation Plan","content":"# Plan v2"}}<|end|>"##),
        ])

        XCTAssertTrue(result.resolvedToolCalls.isEmpty,
                      "Rehearsing create_artifact must not count as submitting it")
        XCTAssertTrue(result.assistantContent.isEmpty,
                      "Nothing was said on the content channel either — this is the no-tool-call turn")
    }

    // MARK: - Corner cases

    /// Several envelopes in one reasoning block: zero calls, not "the first one ran".
    func testMultipleEnvelopesInReasoning_resolveNothing() async throws {
        let result = try await stream([
            StreamEvent(thinkingDelta: #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#),
            StreamEvent(thinkingDelta: " and then "),
            StreamEvent(thinkingDelta: #"<|call|>{"name":"read_file","arguments":{"path":"b.txt"}}<|end|>"#),
        ])

        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        let committed = try XCTUnwrap(committedThinking)
        XCTAssertEqual(committed.components(separatedBy: "<|call|>").count - 1, 2,
                       "Both rehearsals stay on screen")
    }

    /// A MALFORMED envelope in reasoning is not a failed tool call either: `sawHarmonyMarker`
    /// is a content-channel fact, so `+StepFlowControl`'s classify-and-surface branch is
    /// unreachable and no errored `StepToolCall` card is recorded.
    func testMalformedEnvelopeInReasoning_isNotDiagnosedAsAFailedCall() async throws {
        let result = try await stream([
            StreamEvent(thinkingDelta: ##"<|call|>{"name":"read_file","arguments":{"path":"##),
        ])

        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        XCTAssertFalse(result.sawHarmonyMarker,
                       "Nothing in the content channel — the failed-attempt card must not fire")
        XCTAssertTrue(result.harmonyBuffer.isEmpty)
    }

    /// Reasoning made of nothing but model-internal tokens now persists RAW. This is the
    /// behavioural consequence of dropping `stripTokens` from the commit: before, it
    /// collapsed to whitespace and committed as `nil`.
    func testTokensOnlyReasoning_persistsRaw() async throws {
        _ = try await stream([StreamEvent(thinkingDelta: "<|channel|>analysis")])

        XCTAssertEqual(committedThinking, "<|channel|>analysis")
    }

    /// The whitespace guard survives the strip removal: an empty `[reasoning]` block must
    /// not become an expandable-but-blank section.
    func testWhitespaceOnlyReasoning_stillCommitsAsNil() async throws {
        _ = try await stream([StreamEvent(thinkingDelta: "\n\n   \n")])

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertNil(committedThinking)
    }

    // MARK: - Anti-vacuum — the content channel is untouched

    /// Same call in BOTH channels: the content one resolves, exactly once. If this goes
    /// red, the change broke tool calling rather than scoping it.
    func testToolCallInBothChannels_contentStillResolves() async throws {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#
        let result = try await stream([
            StreamEvent(thinkingDelta: "Thinking about it... " + envelope),
            StreamEvent(contentDelta: envelope),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
                       "The content channel still commits a call")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "read_file")
    }

    /// Content-only response with no `<|` in the reasoning at all — the ordinary case.
    ///
    /// Also pins `sawHarmonyMarker ⟹ !harmonyBuffer.isEmpty`. That implication is what
    /// makes `+StepFlowControl`'s `envelopeSource` safe to read `harmonyBuffer` alone: the
    /// flag is raised in one place, together with `harmonyBuffer = uiBuffer`, and `uiBuffer`
    /// holds at least the marker that raised it. Without the implication, deleting the
    /// reasoning arm from `envelopeSource` would leave a turn diagnosed off `assistantContent`
    /// — which by then holds only the pre-marker prose. No behavioural test can cover that
    /// arm directly (it needs `(true, "")`, a pair this method cannot produce), so the
    /// invariant is the pin.
    func testContentOnlyResponse_extractsCallNormally() async throws {
        let result = try await stream([
            StreamEvent(thinkingDelta: "Plain reasoning text with no markers."),
            StreamEvent(contentDelta:
                #"<|call|>{"name":"read_file","arguments":{"path":"b.txt"}}<|end|>"#),
        ])

        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "read_file")
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertFalse(result.harmonyBuffer.isEmpty,
                       "A raised marker flag always comes with the buffer that raised it")
        XCTAssertTrue(result.harmonyBuffer.contains("<|call|>"))
    }
}
