import XCTest

@testable import NanoTeams

/// Reproduction for: a planning-phase `update_scratchpad` executes (`ok:true`,
/// "✅ Plan recorded") but its tool-call card never appears in the TeamActivity
/// feed — the turn shows only "Thinking".
///
/// Observed with `google/gemma-4-e4b` (and `qwen3.5`): the model emits the
/// envelope in the CONTENT channel with trailing garbage and NO `<|end|>`, e.g.
/// `<|call|>{"name":"update_scratchpad","arguments":{"content":"…"}} maximale}}`.
/// Verbatim from `tasks/4` Code Reviewer step `faang_team_code_reviewer`,
/// response `8642D338`.
///
/// These tests bisect the pipeline:
///   1. `performStreamingCall` — does the malformed envelope resolve to a tool call?
///   2. `ActivityFeedBuilder` — does an `update_scratchpad` StepToolCall render a card?
@MainActor
final class PlanningScratchpadCardTests: XCTestCase {

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
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "faang_team_code_reviewer"
    private let taskID = 0

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() {
        service = nil
        mockDelegate = nil
        mockClient = nil
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    /// Verbatim shape of Code Reviewer response `8642D38FC`: content-channel
    /// `<|call|>{…}} maximale}}` — trailing junk, NO `<|end|>`. The runtime DID
    /// execute it (`content_length:489, updated:true, ok:true`), so the parser
    /// MUST resolve it here too.
    func testUpdateScratchpad_contentChannel_trailingJunk_noEndMarker_resolves() async throws {
        let envelope = #"<|call|>{"name":"update_scratchpad","arguments":{"content":"1. Review the artifacts provided.\n2. Analyze the scope.\n3. Critique the limitations.\n4. Structure the review findings."}} maximale}}"#
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "I will start by creating a plan to approach this review comprehensively.\n"),
            StreamEvent(contentDelta: envelope),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codeReviewer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
            "Malformed (trailing-junk, no <|end|>) update_scratchpad envelope must still resolve to a tool call — it executes in production (ok:true)")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.updateScratchpad)
    }

    /// The feed must render a tool-call card for an `update_scratchpad` call that
    /// landed in `step.toolCalls` (same as any other tool). Pins that the builder
    /// does NOT silently drop scratchpad cards.
    func testActivityFeed_rendersUpdateScratchpadToolCallCard() {
        let scratchpadCall = StepToolCall(
            createdAt: MonotonicClock.shared.now(),
            name: ToolNames.updateScratchpad,
            argumentsJSON: #"{"content":"1. Review.\n2. Analyze."}"#,
            resultJSON: #"{"data":{"content_length":489,"updated":true},"ok":true}"#,
            isError: false
        )
        let thinkingMsg = LLMMessage(
            createdAt: MonotonicClock.shared.now(),
            role: .assistant,
            content: "",
            thinking: "I will start by creating a plan."
        )
        let step = StepExecution(
            id: stepID,
            role: .codeReviewer,
            title: "Code Reviewer Step",
            status: .done,
            toolCalls: [scratchpadCall],
            llmConversation: [thinkingMsg]
        )

        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )

        XCTAssertTrue(toolCallNames(items).contains(ToolNames.updateScratchpad),
            "TeamActivity feed must render a tool-call card for update_scratchpad in step.toolCalls")
    }

    // MARK: - Builder corner cases

    /// A planning `update_scratchpad` whose result hasn't been written yet
    /// (resultJSON nil) must still render a card — the card exists from
    /// `appendToolCalls`, the result is filled in later.
    func testActivityFeed_rendersScratchpadCard_withNilResult() {
        let call = StepToolCall(name: ToolNames.updateScratchpad,
                                argumentsJSON: #"{"content":"1. plan"}"#, resultJSON: nil)
        let items = buildTimeline(step: stepWith(toolCalls: [call]))
        XCTAssertTrue(toolCallNames(items).contains(ToolNames.updateScratchpad))
    }

    /// An errored `update_scratchpad` (e.g. failed memory persist) still renders.
    func testActivityFeed_rendersScratchpadCard_whenIsError() {
        let call = StepToolCall(name: ToolNames.updateScratchpad,
                                argumentsJSON: #"{"content":"x"}"#,
                                resultJSON: #"{"ok":false}"#, isError: true)
        let items = buildTimeline(step: stepWith(toolCalls: [call]))
        XCTAssertTrue(toolCallNames(items).contains(ToolNames.updateScratchpad))
    }

    /// The exact Code Reviewer shape: a content-empty assistant message carrying
    /// reasoning (renders as a "Thinking" bubble) followed by the
    /// `update_scratchpad` card. Both must be present, and the thinking bubble
    /// must precede the card (createdAt order).
    func testActivityFeed_thinkingBubbleAndScratchpadCard_bothPresent_thinkingFirst() {
        let thinkingAt = MonotonicClock.shared.now()
        let callAt = MonotonicClock.shared.now()  // strictly later (monotonic)
        let thinkingMsg = LLMMessage(createdAt: thinkingAt, role: .assistant, content: "",
                                     thinking: "I will start by creating a plan.")
        let call = StepToolCall(createdAt: callAt, name: ToolNames.updateScratchpad,
                                argumentsJSON: #"{"content":"1. plan"}"#)
        let items = buildTimeline(step: stepWith(toolCalls: [call], messages: [thinkingMsg]))

        var sawThinkingMessage = false
        var thinkingIndex: Int?
        var cardIndex: Int?
        for (i, tagged) in items.enumerated() {
            if case .llmMessage(let msg, _, _, _) = tagged.item, msg.id == thinkingMsg.id {
                sawThinkingMessage = true
                thinkingIndex = i
            }
            if case .toolCall(let c, _, _, _) = tagged.item, c.name == ToolNames.updateScratchpad {
                cardIndex = i
            }
        }
        XCTAssertTrue(sawThinkingMessage, "Content-empty thinking message must still render (hasThinking)")
        let ti = try? XCTUnwrap(thinkingIndex)
        let ci = try? XCTUnwrap(cardIndex)
        if let ti, let ci { XCTAssertLessThan(ti, ci, "Thinking bubble must precede the tool-call card") }
    }

    /// A bare `update_scratchpad` call with no accompanying message still renders.
    func testActivityFeed_rendersScratchpadCard_aloneWithNoMessage() {
        let call = StepToolCall(name: ToolNames.updateScratchpad, argumentsJSON: #"{"content":"x"}"#)
        let items = buildTimeline(step: stepWith(toolCalls: [call], messages: []))
        XCTAssertTrue(toolCallNames(items).contains(ToolNames.updateScratchpad))
    }

    /// Multiple tool calls in one step (planning scratchpad + a later artifact)
    /// must all render — pins that scratchpad isn't singled out for suppression.
    func testActivityFeed_rendersMultipleToolCalls_scratchpadAndArtifact() {
        let scratchpad = StepToolCall(createdAt: MonotonicClock.shared.now(),
                                      name: ToolNames.updateScratchpad, argumentsJSON: #"{"content":"x"}"#)
        let artifact = StepToolCall(createdAt: MonotonicClock.shared.now(),
                                    name: ToolNames.createArtifact,
                                    argumentsJSON: #"{"name":"Code Review Summary","content":"y"}"#)
        let items = buildTimeline(step: stepWith(toolCalls: [scratchpad, artifact]))
        let names = toolCallNames(items)
        XCTAssertTrue(names.contains(ToolNames.updateScratchpad))
        XCTAssertTrue(names.contains(ToolNames.createArtifact))
    }

    // MARK: - Builder helpers

    private func stepWith(toolCalls: [StepToolCall], messages: [LLMMessage] = []) -> StepExecution {
        StepExecution(
            id: stepID,
            role: .codeReviewer,
            title: "Code Reviewer Step",
            status: .done,
            toolCalls: toolCalls,
            llmConversation: messages
        )
    }

    private func buildTimeline(step: StepExecution) -> [ActivityFeedBuilder.TaggedItem] {
        ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
    }

    private func toolCallNames(_ items: [ActivityFeedBuilder.TaggedItem]) -> [String] {
        items.compactMap { tagged in
            if case .toolCall(let call, _, _, _) = tagged.item { return call.name }
            return nil
        }
    }
}
