import XCTest
@testable import NanoTeams

/// Pin: priority order of status text in the streaming indicator. Drift
/// here changes what the user sees in the activity feed during streaming
/// — important for distinguishing "model is processing the prompt"
/// (Processing X%), "tokens flowing into invisible buffers" (Generating),
/// and "nothing happening yet" (Waiting).
final class MessageBubbleStreamingIndicatorStatusTests: XCTestCase {

    // MARK: - Not streaming → no status

    func testNotStreaming_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: false
        )
        XCTAssertNil(result, "No status row when not streaming")
    }

    func testNotStreaming_evenWithActivity_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: 0.5,
            hasStreamActivity: true
        )
        XCTAssertNil(result, "isStreaming gates everything — even latent state from a finished stream must not surface a status row")
    }

    // MARK: - Visible content / thinking → no status row

    func testHasMessageContent_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: true
        )
        XCTAssertNil(result, "Visible content makes the status row redundant — content itself is the visual indicator")
    }

    func testHasThinkingContent_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: true,
            processingProgress: nil,
            hasStreamActivity: true
        )
        XCTAssertNil(result, "Visible thinking section is its own indicator")
    }

    // MARK: - Status priorities

    /// Highest priority: prompt processing in progress. Even if the
    /// activity flag is also set (defensive — the streaming service
    /// clears progress on first delta, but a stale ordering shouldn't
    /// reverse the meaning), Processing wins.
    func testProcessingProgress_winsOverActivity() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: 0.42,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Processing")
    }

    func testProcessingProgress_alone_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: 0.99,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing")
    }

    /// Activity flag without progress → "Generating". This is the
    /// user-reported scenario: tokens flowing into harmony tool-call
    /// buffer, invisible to content/thinking previews. Pre-fix this
    /// rendered as "Waiting" — confusing because the model panel showed
    /// token count climbing.
    func testActivity_withoutProgress_returnsGenerating() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Generating")
    }

    /// Lowest priority — fall-through when truly nothing has happened.
    /// Original "Waiting" semantics: connection open, no events received.
    func testNoActivity_noProgress_noContent_returnsWaiting() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Waiting")
    }

    // MARK: - Edge cases

    /// progress=0.0 must still render "Processing" — that's prompt
    /// processing just starting. The bridge case is non-trivial because
    /// `Optional<Double>` of `0.0` is "set" not "unset"; we shouldn't
    /// treat 0.0 as "no progress yet".
    func testProcessingProgress_zero_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: 0.0,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing",
                       "progress=0.0 is 'started, 0% done' — must render Processing, not fall through to Waiting")
    }

    /// progress=1.0 also Processing — the fast-path that clears progress
    /// on first delta runs at the streaming layer; if the UI sees 1.0
    /// it means prompt_processing.end fired and content/thinking is
    /// imminent. Not Waiting.
    func testProcessingProgress_one_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingProgress: 1.0,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing")
    }

    /// Both content AND thinking visible — content wins (returns nil
    /// either way; redundant case but the early-return order matters
    /// elsewhere).
    func testBothContentAndThinking_visible_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: true,
            processingProgress: 0.5,
            hasStreamActivity: true
        )
        XCTAssertNil(result)
    }

    // MARK: - Implicit stream target (the latest committed bubble of a still-running step)
    //
    // Scenario the user reported: text bubble has committed, the LLM is now
    // streaming a tool call's arguments into invisible buffers (no preview
    // owns these tokens, so per-message `isStreaming(messageID:)` is false).
    // Without a second signal the bubble shows nothing and the user can't
    // tell the model is still working. `isImplicitStreamTarget` is that
    // second signal — flipped on for the latest LLM message in a still-
    // running step, regardless of preview ownership.

    func testImplicitTarget_withActivity_returnsGenerating() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Generating",
                       "Latest committed bubble in a still-running step must surface 'Generating' while tool-call deltas are flowing — even though content is present, that content is frozen and the activity belongs to the next emission")
    }

    func testImplicitTarget_withProcessingProgress_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: 0.42,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing",
                       "Tool-result → next-LLM-iteration prompt-processing window: implicit target shows 'Processing' even with committed content")
    }

    /// Mirrors the streaming-branch `testProcessingProgress_zero_returnsProcessing`
    /// guard: `0.0` is "started, 0% done", not "no signal" — the indicator must
    /// distinguish nil from 0.0. A future "normalize nil to zero" refactor would
    /// silently break the implicit branch the same way it would break streaming.
    func testImplicitTarget_processingProgressZero_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: 0.0,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing")
    }

    func testImplicitTarget_processingWinsOverActivity() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: 0.5,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Processing",
                       "Same priority order as the streaming branch: Processing > Generating")
    }

    /// No live signal → no indicator. We don't park a stale "Waiting" pill on
    /// a committed bubble — that would imply the model is hung when actually
    /// it's just between phases with no current activity. Different from the
    /// preview-target branch (which DOES show "Waiting" because content is
    /// empty there).
    func testImplicitTarget_noActivity_noProgress_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: false
        )
        XCTAssertNil(result,
                     "Implicit target with no live signal must NOT park a 'Waiting' pill — that's the committed steady state, not a streaming gap")
    }

    /// Regression guard for the actively-growing bubble: `isStreaming=true`
    /// with content present must still return nil — the existing logic
    /// where visible growing content IS the indicator. The implicit-target
    /// branch only kicks in when `isStreaming` is false.
    func testImplicitTarget_doesNotOverrideStreamingContentSuppression() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: nil,
            hasStreamActivity: true
        )
        XCTAssertNil(result,
                     "Active preview growing into this bubble — content IS the signal, no redundant pill")
    }

    /// Neither streaming nor implicit-target → nil (committed bubble in a
    /// done step, or any other surface that doesn't pass either flag).
    func testNeitherStreamingNorImplicitTarget_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingProgress: 0.5,
            hasStreamActivity: true
        )
        XCTAssertNil(result,
                     "Step is done (or this isn't the latest bubble) — even latent activity flags must not surface a pill")
    }
}
