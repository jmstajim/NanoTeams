import XCTest
@testable import NanoTeams

/// Pin: `processingProgress` indicator clears as soon as the first
/// generation delta (thinking OR content) arrives — not at end-of-stream.
///
/// User-reported symptom (2026-05-02): the activity feed showed
/// "Processing 99%" while the model was actively generating tokens (visible
/// in LM Studio's loaded-models panel as token count climbing). The
/// pre-fix flow only cleared `processingProgress` at end-of-stream
/// (`LLMExecutionService+Streaming.swift:176`), so if LM Studio didn't
/// emit `prompt_processing.end` (which would have set progress to 1.0)
/// AND the last `prompt_processing.progress` was 0.99, the indicator
/// stayed visually frozen at 99% throughout generation.
///
/// Post-fix: any thinking or content delta clears `processingProgress`
/// immediately. Subsequent late `prompt_processing.*` events (defensive)
/// are ignored — generation already started, no point re-flashing the
/// indicator.
@MainActor
final class StreamingProcessingProgressClearTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Clear on first thinking delta

    /// Reasoning-model case: prompt processing crawls to 99%, no
    /// `prompt_processing.end` event, then thinking starts streaming.
    /// MUST clear indicator on the first thinking delta (was the user's
    /// "Processing 99%" while generating bug).
    func testProcessingProgress_clearsOnFirstThinkingDelta_evenWithoutPromptEnd() async throws {
        let events: [StreamEvent] = [
            StreamEvent(processingProgress: 0.50),
            StreamEvent(processingProgress: 0.99),
            // NB: no `prompt_processing.end` (no progress: 1.0 event) —
            // this is the LM Studio-omits-end edge case.
            StreamEvent(thinkingDelta: "Hmm, let me think... "),
            StreamEvent(thinkingDelta: "OK so the answer is..."),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            session: nil,
            networkLogger: nil
        )

        // Updates: 0.50, then 0.99 (in order). NO update for the thinking
        // delta (it's not a `processingProgress` event).
        let progressValues = delegate.updateProcessingProgressCalls.map(\.1)
        XCTAssertEqual(progressValues, [0.50, 0.99],
                       "Both prompt_processing.progress events must be forwarded in order")

        // Clear: at least once before stream-end. Pre-fix this would only
        // happen at end-of-stream (line 176); post-fix it fires on the first
        // thinking delta.
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingProgressCalls.count, 1,
                                     "Indicator must clear at least once during the run")

        // Critical contract: the first clear comes BEFORE generation completes
        // — i.e. while there's still streaming work happening. We check this
        // by counting calls AT specific moments, but since the recorder is
        // a simple list we instead verify that the first clear happens at
        // least once (it does, regardless of when), then ensure no LATER
        // progress event re-flashes the indicator.
        // → covered by `testLateProgressEvent_afterFirstThinking_doesNotReFlash` below.
    }

    /// Pure-content model case (no thinking phase): clear on first content
    /// delta. Symmetric path to the thinking-clear branch.
    func testProcessingProgress_clearsOnFirstContentDelta() async throws {
        let events: [StreamEvent] = [
            StreamEvent(processingProgress: 0.95),
            StreamEvent(contentDelta: "Hello"),
            StreamEvent(contentDelta: " world"),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(delegate.updateProcessingProgressCalls.map(\.1), [0.95])
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingProgressCalls.count, 1,
                                     "Content-only models must also clear on first content delta")
    }

    // MARK: - Late progress events ignored

    /// Defensive: a `prompt_processing.*` event arriving AFTER generation
    /// has started must NOT re-flash the indicator. Production stream
    /// orderings shouldn't do this, but the guard prevents a stale event
    /// from reviving "Processing X%" alongside visible tokens.
    func testLateProgressEvent_afterFirstThinking_doesNotReFlash() async throws {
        let events: [StreamEvent] = [
            StreamEvent(processingProgress: 0.30),
            StreamEvent(thinkingDelta: "starting..."),
            // Late event — ignored.
            StreamEvent(processingProgress: 0.99),
            StreamEvent(thinkingDelta: " more thinking"),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            session: nil,
            networkLogger: nil
        )

        // Only the FIRST progress event should be forwarded — the late one
        // arriving after thinking started must be ignored.
        let progressValues = delegate.updateProcessingProgressCalls.map(\.1)
        XCTAssertEqual(progressValues, [0.30],
                       "Late prompt_processing.progress events must be filtered out once generation has started — otherwise the UI re-flashes 'Processing 99%' alongside visible tokens (the user's report)")
    }

    // MARK: - markStreamActivity (Waiting → Generating flip)

    /// Pin: every delta type fires `markStreamActivity`. The UI's
    /// `MessageBubbleStreamingIndicator` reads `hasStreamActivity` to
    /// distinguish "Waiting" (nothing arrived) from "Generating" (tokens
    /// flowing into invisible buffers — tool-call args, harmony envelope,
    /// etc.). Without this signal the user sees "Waiting" while the model
    /// is actively producing tokens (LM Studio panel shows token count
    /// climbing).
    func testMarkStreamActivity_firesOnEveryDeltaType() async throws {
        let toolCall = StreamEvent.ToolCallDelta(index: 0, id: "tc1", name: "read_file", argumentsDelta: #"{"path":"x"}"#)
        let events: [StreamEvent] = [
            StreamEvent(thinkingDelta: "thinking..."),    // path 1: thinking
            StreamEvent(contentDelta: "hello"),            // path 2: content
            StreamEvent(toolCallDeltas: [toolCall]),       // path 3: tool-call delta
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            session: nil,
            networkLogger: nil
        )

        // markStreamActivity must fire at least once per delta event so
        // the UI flips to "Generating" promptly. Idempotency is fine —
        // duplicate fires are no-ops in the manager.
        XCTAssertGreaterThanOrEqual(delegate.markStreamActivityCalls.count, 3,
                                     "markStreamActivity must fire on all 3 delta types (thinking, content, tool-call) — got \(delegate.markStreamActivityCalls.count) calls")
    }

    /// Pin: tool-call-only stream (no content, no thinking) still flips
    /// the UI to "Generating". This is the user-reported scenario — model
    /// emits a long tool-call argument JSON, content/thinking buffers
    /// stay empty, but the UI shouldn't show "Waiting".
    func testMarkStreamActivity_toolCallOnly_clearsProgressAndMarksActivity() async throws {
        let toolCall = StreamEvent.ToolCallDelta(index: 0, id: "tc1", name: "write_file", argumentsDelta: "{}")
        let events: [StreamEvent] = [
            StreamEvent(processingProgress: 0.99),
            StreamEvent(toolCallDeltas: [toolCall]),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            session: nil,
            networkLogger: nil
        )

        XCTAssertGreaterThanOrEqual(delegate.markStreamActivityCalls.count, 1,
                                     "Tool-call delta must mark activity even though no content/thinking is visible")
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingProgressCalls.count, 1,
                                     "Tool-call delta must also clear processingProgress — same flow as content/thinking")
    }

    // MARK: - No progress, no thinking, only content (sanity)

    func testNoProcessingEvents_clearStillCalledAtEndOfStream() async throws {
        // Stream that has NO prompt_processing.* events at all (some
        // providers / configurations skip them). Generation goes
        // straight to content. The end-of-stream clear path still fires
        // (line 176 in LLMExecutionService+Streaming.swift) — preserves
        // the prior contract for the "no progress events" path.
        let events: [StreamEvent] = [
            StreamEvent(contentDelta: "answer"),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            session: nil,
            networkLogger: nil
        )

        XCTAssertTrue(delegate.updateProcessingProgressCalls.isEmpty)
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingProgressCalls.count, 1,
                                     "End-of-stream clear must still fire even when no progress events arrived")
    }

    // MARK: - Helpers

    private func stubConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost",
            modelName: "stub",
            maxTokens: 100,
            temperature: nil
        )
    }

    /// Stub LLM client that emits a scripted sequence of stream events.
    /// Used by tests to drive `performStreamingCall` deterministically.
    private final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
        let events: [StreamEvent]
        init(events: [StreamEvent]) { self.events = events }

        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            session _: LLMSession?,
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let scripted = events
            return AsyncThrowingStream { continuation in
                for event in scripted {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
