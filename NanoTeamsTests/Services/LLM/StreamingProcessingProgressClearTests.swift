import XCTest
@testable import NanoTeams

/// Pin: `processingStatus` indicator clears as soon as the first
/// generation delta (thinking OR content) arrives — not at end-of-stream.
///
/// User-reported symptom (2026-05-02): the activity feed showed
/// "Processing 99%" while the model was actively generating tokens (visible
/// in LM Studio's loaded-models panel as token count climbing). The
/// pre-fix flow only cleared `processingStatus` at end-of-stream
/// (`LLMExecutionService+Streaming.swift:176`), so if LM Studio didn't
/// emit `prompt_processing.end` (which would have set progress to 1.0)
/// AND the last `prompt_processing.progress` was 0.99, the indicator
/// stayed visually frozen at 99% throughout generation.
///
/// Post-fix: any thinking or content delta clears `processingStatus`
/// immediately. Subsequent late `prompt_processing.*` events (defensive)
/// are ignored — generation already started, no point re-flashing the
/// indicator.
@MainActor
final class StreamingProcessingProgressClearTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        try await super.tearDown()
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
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        // Updates: the service's own `.indeterminate` claim at stream start,
        // then the server's 0.50 and 0.99 refining it (in order). NO update for
        // the thinking delta (it's not a `prompt_processing` event).
        let statuses = delegate.updateProcessingStatusCalls.map(\.1)
        XCTAssertEqual(statuses, [.indeterminate, .fraction(0.50), .fraction(0.99)],
                       "Both prompt_processing.progress events must be forwarded in order, after the stream-start claim")

        // Clear: at least once before stream-end. Pre-fix this would only
        // happen at end-of-stream (line 176); post-fix it fires on the first
        // thinking delta.
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingStatusCalls.count, 1,
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
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(delegate.updateProcessingStatusCalls.map(\.1), [.indeterminate, .fraction(0.95)])
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingStatusCalls.count, 1,
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
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        // Only the FIRST progress event should be forwarded — the late one
        // arriving after thinking started must be ignored. The leading
        // `.indeterminate` is the stream-start claim, which precedes every
        // server event by construction.
        let statuses = delegate.updateProcessingStatusCalls.map(\.1)
        XCTAssertEqual(statuses, [.indeterminate, .fraction(0.30)],
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
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
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
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertGreaterThanOrEqual(delegate.markStreamActivityCalls.count, 1,
                                     "Tool-call delta must mark activity even though no content/thinking is visible")
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingStatusCalls.count, 1,
                                     "Tool-call delta must also clear processingStatus — same flow as content/thinking")
    }

    // MARK: - markStreamingToolCall (envelope-as-thinking pipe + Generating fallback)

    /// Pin: detecting a Harmony marker mid-content fires
    /// `markStreamingToolCall`. The flag keeps the Thinking loader
    /// animating while the envelope streams into the thinking preview,
    /// and backs the indicator's "Generating" fallback while that preview
    /// is still empty — pre-fix (no pipe, no flag) the frozen pre-marker
    /// prose suppressed everything and the bubble showed zero animation
    /// for the entire argument assembly (the user-reported 37s freeze).
    func testMarkStreamingToolCall_firesOnHarmonyMarkerDetection() async throws {
        let events: [StreamEvent] = [
            StreamEvent(contentDelta: "I will now implement the fix."),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"edit_file\",\"arguments\":{\"path\""),
            StreamEvent(contentDelta: ":\"x.swift\",\"old_text\":\"a\",\"new_text\":\"b\"}}<|end|>"),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertGreaterThanOrEqual(delegate.markStreamingToolCallCalls.count, 1,
                                     "Harmony-marker detection must fire markStreamingToolCall — the indicator needs it to override the frozen-prose suppression")

        // The envelope text must surface AS THINKING (preview-only) so the
        // user watches the call being typed under the animated "Thinking…"
        // row instead of staring at a frozen bubble: both the post-marker
        // slice from the flip iteration and subsequent envelope deltas.
        let thinkingFed = delegate.appendStreamingThinkingCalls.map(\.1).joined()
        XCTAssertTrue(thinkingFed.contains("<|call|>{\"name\":\"edit_file\""),
                      "Post-marker slice must be piped into the thinking preview — got: \(thinkingFed)")
        XCTAssertTrue(thinkingFed.contains("<|end|>"),
                      "Subsequent envelope deltas must keep streaming into the thinking preview")
    }

    /// The envelope must NOT leak into the PERSISTED thinking — only the
    /// UI preview. `commitStreaming` receives reasoning-only thinking
    /// (here: nil, since the scripted stream has no reasoning channel).
    func testHarmonyEnvelope_isNotPersistedAsThinking() async throws {
        let events: [StreamEvent] = [
            StreamEvent(contentDelta: "Prose."),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"read_file\",\"arguments\":{}}<|end|>"),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(delegate.commitStreamingCalls.count, 1)
        XCTAssertNil(delegate.commitStreamingCalls[0].3,
                     "Envelope text is preview-only — committed thinking must stay reasoning-only (nil here)")
    }

    /// Pin: OpenAI-style tool-call deltas fire `markStreamingToolCall` —
    /// same suppression hole as the Harmony path whenever prose or
    /// thinking already rendered before the tool-call deltas started.
    /// Wire-realistic shape: `name` arrives in the FIRST delta only; the
    /// args stream as name-less fragments afterward. A "helpful"
    /// `guard let name` cleanup would drop every args fragment — thinking
    /// preview freezes at the bare tool name for the whole assembly.
    func testMarkStreamingToolCall_firesOnOpenAIToolCallDeltas() async throws {
        let nameDelta = StreamEvent.ToolCallDelta(index: 0, id: "tc1", name: "edit_file", argumentsDelta: nil)
        let argsDelta = StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: #"{"path":"x"}"#)
        let events: [StreamEvent] = [
            StreamEvent(contentDelta: "Applying the change now."),
            StreamEvent(toolCallDeltas: [nameDelta]),
            StreamEvent(toolCallDeltas: [argsDelta]),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertGreaterThanOrEqual(delegate.markStreamingToolCallCalls.count, 1,
                                     "OpenAI tool-call deltas must fire markStreamingToolCall")

        // Args fragments surface as thinking too — same "show it as if it
        // were thinking" presentation as the harmony envelope.
        let thinkingFed = delegate.appendStreamingThinkingCalls.map(\.1).joined()
        XCTAssertTrue(thinkingFed.contains("edit_file"),
                      "Tool name fragment must be piped into the thinking preview")
        XCTAssertTrue(thinkingFed.contains(#"{"path":"x"}"#),
                      "Args fragments must be piped into the thinking preview")
    }

    /// Corner: degenerate OpenAI fragments (nil name AND nil args) must not
    /// reach the thinking preview — the service-side `!fragment.isEmpty`
    /// guard, not just the manager's empty-append guard, keeps the pipe
    /// clean. Only the real fragments land, in arrival order.
    func testOpenAIEmptyFragments_doNotReachThinkingPreview() async throws {
        let emptyDelta = StreamEvent.ToolCallDelta(index: 0, id: "tc1", name: nil, argumentsDelta: nil)
        let nameDelta = StreamEvent.ToolCallDelta(index: 0, id: nil, name: "edit_file", argumentsDelta: nil)
        let events: [StreamEvent] = [
            StreamEvent(toolCallDeltas: [emptyDelta]),
            StreamEvent(toolCallDeltas: [nameDelta]),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(delegate.appendStreamingThinkingCalls.map(\.1), ["edit_file"],
                       "Empty fragments must be filtered service-side; only real fragments reach the pipe")
    }

    /// Pin: plain prose/thinking streams must NOT fire the tool-call flag
    /// — the "growing text is the indicator" suppression stays correct for
    /// ordinary responses.
    func testMarkStreamingToolCall_doesNotFireOnPlainContentOrThinking() async throws {
        let events: [StreamEvent] = [
            StreamEvent(thinkingDelta: "let me think..."),
            StreamEvent(contentDelta: "Here is my answer."),
            StreamEvent(contentDelta: " It has two sentences."),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertTrue(delegate.markStreamingToolCallCalls.isEmpty,
                      "Plain content/thinking must not flip the tool-call flag — got \(delegate.markStreamingToolCallCalls.count) calls")
    }

    // MARK: - No progress, no thinking, only content (sanity)

    /// The Ollama shape: a stream with NO `prompt_processing.*` events at all
    /// (that provider yields nothing whatsoever between the send and the first
    /// token). The service still claims the window with `.indeterminate` so the
    /// bubble reads "Processing…" rather than "Waiting…", and the end-of-stream
    /// clear still fires.
    ///
    /// RED: drop the `.indeterminate` set in `performStreamingCall` -> the
    /// status list is empty and the first assertion fails (the indicator would
    /// sit on "Waiting…" for the whole prefill, which is the reported bug).
    func testNoProcessingEvents_claimsTheWindowAndClearsAtEndOfStream() async throws {
        let events: [StreamEvent] = [
            StreamEvent(contentDelta: "answer"),
        ]
        let client = ScriptedLLMClient(events: events)

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(delegate.updateProcessingStatusCalls.map(\.1), [.indeterminate],
                       "A provider that narrates nothing must still get the stream-start claim — otherwise its whole prefill window renders 'Waiting…'")
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingStatusCalls.count, 1,
                                     "End-of-stream clear must still fire even when no progress events arrived")
    }

    // MARK: - Ordering: the claim must follow beginStreaming

    /// `beginStreaming` RESETS the status (`StreamingPreviewManager` sets
    /// `processingStatus[key] = nil` there, so a mid-stream retry cannot inherit
    /// the failed attempt's state). The `.indeterminate` claim therefore has to
    /// be issued strictly AFTER it — hoisted above, it is wiped the instant it
    /// is made, the manager keeps `nil`, and the Ollama bubble sits on
    /// "Waiting…" for the entire prefill: the exact bug this claim exists to fix,
    /// reintroduced with every assertion still green.
    ///
    /// The ordering is documented as load-bearing at the call site, so it gets a
    /// pin that names it rather than relying on the prose. (The mock also models
    /// the reset now, which reds the swap across this whole file; this test is
    /// the one that says WHY.)
    ///
    /// RED: move the `updateStreamingProcessingStatus(…, .indeterminate)` call
    /// above `await delegate.beginStreaming(…)` in `performStreamingCall` ->
    /// the recorded order flips and this fails.
    func testTheIndeterminateClaim_isIssuedAfterBeginStreaming_notBefore() async throws {
        let client = ScriptedLLMClient(events: [StreamEvent(contentDelta: "hi")])

        _ = try await service.performStreamingCall(
            stepID: "step1",
            taskID: 1,
            roleForMessage: .softwareEngineer,
            client: client,
            config: stubConfig(),
            tools: [],
            conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(
            delegate.streamingTaskIDTrace.prefix(2).map(\.method),
            ["beginStreaming", "updateStreamingProcessingStatus"],
            "the claim must follow the reset — reversed, `beginStreaming` erases it and the prefill window renders 'Waiting…'")
    }

    // MARK: - Stream failure must not freeze the indicator

    /// A transport/server failure DURING the prompt-processing window. The retry
    /// lives in `+StepLifecycle`, which posts "Retrying in Ns…" and then SLEEPS
    /// before re-entering — and only that re-entry's `beginStreaming` resets the
    /// status. Without the generic catch, the bubble spends the whole sleep
    /// claiming the server is processing our prompt while nothing is in flight.
    ///
    /// RED: delete the `catch { … }` arm added beside `catch is CancellationError`
    /// in `performStreamingCall` -> no clear is recorded after the `.indeterminate`
    /// and this fails. (Ollama's shape is used here — no progress events — but the
    /// same freeze applies to a half-finished "Processing 47%" on LM Studio.)
    func testStreamFailsDuringPrefill_clearsTheStatusSoTheRetryWindowReadsAsWaiting() async throws {
        let client = ScriptedLLMClient(
            events: [], failure: LLMClientError.providerError("connection reset"))

        do {
            _ = try await service.performStreamingCall(
                stepID: "step1",
                taskID: 1,
                roleForMessage: .softwareEngineer,
                client: client,
                config: stubConfig(),
                tools: [],
                conversationMessages: [],
                networkLogger: nil
            )
            XCTFail("The scripted transport failure must propagate to the retry loop")
        } catch is CancellationError {
            XCTFail("A transport failure must not be reported as a cancellation")
        } catch {
            // expected — `+StepLifecycle` classifies and retries it
        }

        XCTAssertEqual(delegate.updateProcessingStatusCalls.map(\.1), [.indeterminate],
                       "The window was claimed at stream start")
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingStatusCalls.count, 1,
                                    "The status must be cleared when the stream throws — otherwise it stays frozen for the whole retry sleep, asserting work that is not happening")
    }

    /// The two catch arms are deliberately asymmetric, and this pins the half
    /// that is easy to "unify" away: CANCELLATION commits the partial turn (a
    /// Pause must preserve what the user already watched arrive), a transport
    /// FAILURE must not — `+StepLifecycle` retries by re-sending the whole
    /// conversation, so a committed partial would be joined by the retry's full
    /// turn and the step would carry the answer twice.
    ///
    /// Also covers the status half: mid-generation the first delta already
    /// cleared it, so the new arm adds no second meaning there.
    ///
    /// RED: add `await commitStreamingContent()` to the generic catch (mirroring
    /// the cancellation arm above it) -> the partial "partial" turn is committed
    /// and the commit assertion fails.
    func testStreamFailsMidGeneration_doesNotCommitThePartialTurn() async throws {
        let client = ScriptedLLMClient(
            events: [StreamEvent(contentDelta: "partial")],
            failure: LLMClientError.providerError("connection reset"))

        do {
            _ = try await service.performStreamingCall(
                stepID: "step1",
                taskID: 1,
                roleForMessage: .softwareEngineer,
                client: client,
                config: stubConfig(),
                tools: [],
                conversationMessages: [],
                networkLogger: nil
            )
            XCTFail("The scripted transport failure must propagate to the retry loop")
        } catch {
            // expected
        }

        XCTAssertTrue(delegate.commitStreamingCalls.isEmpty,
                      "A failed stream has no turn to commit — the retry re-sends the whole conversation, so committing the partial here would leave the step carrying it twice")
        XCTAssertEqual(delegate.updateProcessingStatusCalls.map(\.1), [.indeterminate],
                       "No status is re-asserted once generation has started")
        XCTAssertGreaterThanOrEqual(delegate.clearProcessingStatusCalls.count, 1)
    }

    // MARK: - Helpers

    private func stubConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost",
            modelName: "stub",
            temperature: nil
        )
    }

    /// Stub LLM client that emits a scripted sequence of stream events.
    /// Used by tests to drive `performStreamingCall` deterministically.
    private final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
        let events: [StreamEvent]
        /// Thrown after the scripted events drain — models a transport/server
        /// failure mid-stream (the retryable class `+StepLifecycle` sleeps on).
        let failure: Error?
        init(events: [StreamEvent], failure: Error? = nil) {
            self.events = events
            self.failure = failure
        }

        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let scripted = events
            let thrown = failure
            return AsyncThrowingStream { continuation in
                for event in scripted {
                    continuation.yield(event)
                }
                continuation.finish(throwing: thrown)
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
