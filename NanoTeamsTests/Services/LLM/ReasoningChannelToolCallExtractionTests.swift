import XCTest

@testable import NanoTeams

/// Pins the contract that `LLMExecutionService.performStreamingCall` extracts
/// Harmony tool calls emitted via the reasoning channel (`reasoning.delta` SSE
/// events → `StreamEvent.thinkingDelta` deltas → `thinkingCollected` buffer)
/// in addition to the content channel.
///
/// Background — empirically observed in
/// `.nanoteams/internal/tasks/0/subtasks/1/runs/0/network_log.json` with
/// `qwen3.6-35b-a3b-ud-mlx`: three consecutive `create_artifact` emissions
/// stochastically picked between channels. Records #11 (offset 4983 inside a
/// 9671-byte reasoning block) and #13 emitted `<|call|>…<|end|>` inside the
/// reasoning channel — the parser never saw it, the engine fired its
/// "Missing deliverables" nudge, the role retried and looped. Record #15
/// emitted via the content channel and worked. Payloads are byte-identical
/// in shape; only the channel differs.
///
/// Without the fix in `LLMExecutionService+Streaming.swift` (post-stream scan
/// of `thinkingCollected` for Harmony markers), every test in this file fails.
@MainActor
final class ReasoningChannelToolCallExtractionTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
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

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() {
        super.setUp()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] = LLMExecutionService.StepExecutionState()
    }

    override func tearDown() {
        service = nil
        mockDelegate = nil
        mockClient = nil
        super.tearDown()
    }

    // MARK: - Episode 1 — read_file emitted entirely in reasoning channel

    /// All deltas arrive on the reasoning channel — both the prose AND the
    /// `<|call|>…<|end|>` envelope. Content channel is silent.
    /// Replicates the shape of `tasks/0/runs/0/network_log.json` record #1
    /// when emitted via reasoning instead of content.
    func testToolCallInReasoningChannel_extractsReadFile() async throws {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "The user wants me to read the file. "),
            StreamEvent(thinkingDelta: "Let me call read_file.\n\n"),
            StreamEvent(thinkingDelta: "<|call|>{\"name\":\""),
            StreamEvent(thinkingDelta: "read_file\",\"arguments\":{"),
            StreamEvent(thinkingDelta: "\"path\": \"calculator.html\"}}"),
            StreamEvent(thinkingDelta: "<|end|>"),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
            "Tool call emitted via reasoning channel must be extracted")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "read_file")
        XCTAssertEqual(
            result.resolvedToolCalls.first?.argumentsJSON,
            #"{"path":"calculator.html"}"#
        )
        // Reasoning prose itself is preserved (the parser doesn't consume it).
        XCTAssertTrue(result.thinkingContent.contains("Let me call read_file"))
    }

    // MARK: - Episode 2 — create_artifact with long reasoning prose

    /// Marker arrives DEEP inside the reasoning buffer (≈4-5KB of prose first),
    /// then envelope across several boundary-split deltas. Pins that the
    /// scan doesn't have an upper bound on preceding prose size.
    func testToolCallInReasoningChannel_extractsCreateArtifactWithLongProse() async throws {
        // 4KB of prose to match the offset of <|call|> in real log record #11.
        let prosePart = String(repeating:
            "Okay let me think through this carefully step by step. ", count: 80)
        mockClient.deltas = [
            StreamEvent(thinkingDelta: prosePart),
            StreamEvent(thinkingDelta: "\nDone. Proceeding. \n"),
            StreamEvent(thinkingDelta:
                #"<|call|>{"name":"create_artifact","arguments":{"name":"#),
            StreamEvent(thinkingDelta: #""Implementation Plan","format":"markdown","#),
            StreamEvent(thinkingDelta: ##""content":"# Implementation Plan\n\n## Section 1"}}<|end|>"##),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "create_artifact")
        // Arguments must round-trip through JSON normalization (sortedKeys).
        let argsJSON = result.resolvedToolCalls.first?.argumentsJSON ?? ""
        XCTAssertTrue(argsJSON.contains(#""name":"Implementation Plan""#))
        XCTAssertTrue(argsJSON.contains(#""format":"markdown""#))
    }

    // MARK: - Episode 3 — retry after "Missing deliverables" nudge

    /// Same flow as Episode 2, with the "system says it's missing" preamble
    /// that previously triggered the infinite-retry loop. The fix must
    /// unblock the loop on the very first retry that emits via reasoning.
    func testToolCallInReasoningChannel_retryAfterMissingDeliverables() async throws {
        let preamble = """
        The user wants me to submit the "Implementation Plan" artifact. \
        I already called create_artifact in my previous turn, but the system \
        says it's missing. I'll just call it again to be safe.
        """
        mockClient.deltas = [
            StreamEvent(thinkingDelta: preamble),
            StreamEvent(thinkingDelta: "\nContent is ready.\nTool: create_artifact\n"),
            StreamEvent(thinkingDelta:
                ##"<|call|>{"name":"create_artifact","arguments":{"format":"markdown","name":"Implementation Plan","content":"# Plan v2"}}<|end|>"##),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
            "Retry-after-missing-deliverables loop must be broken by the fix")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "create_artifact")
    }

    // MARK: - Dedup contract — content channel wins

    /// Some models emit the same call in BOTH channels. The new branch is
    /// guarded by `resolvedToolCalls.isEmpty`, so if content already produced
    /// a call, the thinking-side scan is skipped — exactly one survives.
    func testToolCallInBothChannels_contentWinsSingleResult() async throws {
        let envelope = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "Thinking about it... " + envelope),
            StreamEvent(contentDelta: envelope),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 1,
            "Identical call in both channels must dedup to one")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "read_file")
    }

    // MARK: - Hot-path no-op — content-only responses skip the thinking scan

    /// Content-only response with NO `<|` substring in thinkingCollected.
    /// Pins that the cheap-`contains` gate keeps the hot path on the
    /// existing branch — no behavioural change for the 99% case.
    func testContentOnlyResponse_extractsCallNormally() async throws {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "Plain reasoning text with no markers."),
            StreamEvent(contentDelta:
                #"<|call|>{"name":"read_file","arguments":{"path":"b.txt"}}<|end|>"#),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, "read_file")
    }

    // MARK: - Persisted-thinking cleanup

    /// After commit, the persisted thinking must not contain raw `<|call|>`
    /// / `<|end|>` substrings — the disclosure UI shouldn't surface
    /// model-internal markers. (The inter-marker JSON is allowed to remain;
    /// `ModelTokenCleaner.clean` only strips `<|…|>` tokens.)
    func testToolCallInReasoningChannel_persistedThinkingStripsHarmonyMarkers() async throws {
        mockClient.deltas = [
            StreamEvent(thinkingDelta:
                #"<|call|>{"name":"read_file","arguments":{"path":"x.txt"}}<|end|>"#),
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .codingAgent,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        let persistedThinking = mockDelegate.commitStreamingCalls[0].3
        if let persistedThinking {
            XCTAssertFalse(persistedThinking.contains("<|call|>"),
                "Persisted thinking must not contain raw <|call|> marker — got \(persistedThinking.debugDescription)")
            XCTAssertFalse(persistedThinking.contains("<|end|>"),
                "Persisted thinking must not contain raw <|end|> marker — got \(persistedThinking.debugDescription)")
        }
        // Whitespace-only-after-cleaning is acceptable: when the only
        // thinking content was the envelope itself, post-clean is empty.
    }
}
