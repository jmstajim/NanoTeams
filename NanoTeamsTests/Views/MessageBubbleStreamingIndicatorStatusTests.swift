import XCTest
@testable import NanoTeams

/// Pin: priority order of status text in the streaming indicator. Drift
/// here changes what the user sees in the activity feed during streaming
/// — important for distinguishing "model is processing the prompt"
/// (Processing X%), "tokens flowing into invisible buffers" (Generating),
/// and "nothing happening yet" (Waiting).
@MainActor
final class MessageBubbleStreamingIndicatorStatusTests: XCTestCase {

    // MARK: - Not streaming → no status

    func testNotStreaming_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: nil,
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
            processingStatus: .fraction(0.5),
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
            processingStatus: nil,
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
            processingStatus: nil,
            hasStreamActivity: true
        )
        XCTAssertNil(result, "Visible thinking section is its own indicator")
    }

    // MARK: - Status priorities

    /// Highest priority: prompt processing in progress. Even if the
    /// activity flag is also set (defensive — the streaming service
    /// clears progress on first delta, but a stale ordering shouldn't
    /// reverse the meaning), Processing wins. % is embedded by the
    /// resolver — view-side suffixing was removed when the format was
    /// unified with `Generating…`/`Waiting…`.
    func testProcessingProgress_winsOverActivity() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .fraction(0.42),
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Processing 42%")
    }

    func testProcessingProgress_alone_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .fraction(0.99),
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing 99%")
    }

    /// The indeterminate window — a provider that narrates nothing about its
    /// prefill (Ollama) still says the server has the request. Renders the verb
    /// with the "in progress" ellipsis rather than a number, because the only
    /// number available would be an estimate whose measured error runs 2–6×.
    ///
    /// RED: return "Waiting…" (or nil) for `.indeterminate` -> fails. This is
    /// the reported bug: a prefill window measured in tens of seconds reading
    /// as "Waiting…", which users take to mean nothing is happening.
    func testIndeterminate_returnsProcessingWithoutANumber() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .indeterminate,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing…")
    }

    /// `.indeterminate` outranks the activity fallback exactly as `.fraction`
    /// does — its position in the ladder is the status slot, not a new tier.
    func testIndeterminate_winsOverActivity() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .indeterminate,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Processing…")
    }

    /// …and loses to a live tool-call stream, for the same reason a stale
    /// fraction does: tokens ARE flowing, so nothing may relabel that window as
    /// prompt processing.
    func testStreamingToolCall_winsOverIndeterminate() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .indeterminate,
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertEqual(result, "Generating…")
    }

    /// Activity flag without progress → "Generating…". This is the
    /// user-reported scenario: tokens flowing into harmony tool-call
    /// buffer, invisible to content/thinking previews. Pre-fix this
    /// rendered as "Waiting…" — confusing because the model panel showed
    /// token count climbing. Trailing `…` carries the "live" signal
    /// since there's no numeric counter to tick (mirrors
    /// `MessageThinkingSection`'s `Thinking…`).
    func testActivity_withoutProgress_returnsGenerating() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: nil,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Generating…")
    }

    /// Lowest priority — fall-through when truly nothing has happened.
    /// Original "Waiting…" semantics: connection open, no events received.
    /// Trailing `…` matches `Generating…` / `Thinking…` for "in progress".
    func testNoActivity_noProgress_noContent_returnsWaiting() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: nil,
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Waiting…")
    }

    // MARK: - Edge cases

    /// progress=0.0 must still render "Processing 0%" — that's prompt
    /// processing just starting. The bridge case is non-trivial because
    /// `Optional<Double>` of `0.0` is "set" not "unset"; we shouldn't
    /// treat 0.0 as "no progress yet".
    func testProcessingProgress_zero_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .fraction(0.0),
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing 0%",
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
            processingStatus: .fraction(1.0),
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing 100%")
    }

    /// Both content AND thinking visible — thinking wins (returns nil
    /// either way; redundant case but the early-return order matters
    /// for the tool-call fallback, which thinking outranks).
    func testBothContentAndThinking_visible_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: true,
            processingStatus: .fraction(0.5),
            hasStreamActivity: true
        )
        XCTAssertNil(result)
    }

    // MARK: - Streaming tool call (harmony envelope / OpenAI tool-call deltas mid-stream)
    //
    // The user-reported scenario this flag exists for: reasoning → short
    // prose → large Harmony `<|call|>{…}` envelope. The prose froze the
    // moment the marker was detected and the bubble showed ZERO animation
    // for the entire assembly. Design: the envelope text streams into the
    // THINKING preview (shown "as if it were thinking" — animated
    // "Thinking…" row, watchable live), so `hasThinkingContent` suppression
    // handles the normal case; `isStreamingToolCall` is the FALLBACK that
    // overrides the frozen-prose suppression when the thinking preview is
    // still empty.

    /// Fallback regression: visible (frozen) prose + tool call assembling
    /// + nothing in the thinking preview yet → must show "Generating…",
    /// not nil.
    func testStreamingToolCall_withVisibleContent_returnsGenerating() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingStatus: nil,
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertEqual(result, "Generating…",
                       "Pre-marker prose is frozen once the tool-call envelope starts — it is no longer 'the indicator'. With an empty thinking preview the status row must surface Generating.")
    }

    /// Normal envelope case: the envelope text has landed in the thinking
    /// preview → the (animated) Thinking row is the indicator; no status
    /// row. (`MessageBubbleView.isThinkingStreaming` includes
    /// `isStreamingToolCall`, so the loader keeps spinning.)
    func testStreamingToolCall_withVisibleThinking_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: true,
            processingStatus: nil,
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertNil(result,
                     "Envelope text streams into the thinking preview — the animated Thinking row is the indicator, a Generating pill would be redundant.")
    }

    func testStreamingToolCall_withBothContentAndThinking_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: true,
            processingStatus: nil,
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertNil(result,
                     "Thinking-as-indicator wins over the fallback even with frozen prose present.")
    }

    /// Defensive priority pin: if a stale `processingStatus` coexists
    /// with the tool-call flag (shouldn't happen — progress clears on the
    /// first delta, and the marker arrives via content deltas), the flag
    /// wins: tokens ARE flowing, "Processing N%" would be a lie.
    func testStreamingToolCall_winsOverProcessingProgress() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: false,
            hasThinkingContent: false,
            processingStatus: .fraction(0.99),
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertEqual(result, "Generating…")
    }

    /// Worst-case pile-up: thinking visible + stale progress + activity +
    /// tool-call flag all at once → thinking still wins (nil). Pins that the
    /// thinking suppression sits ABOVE every other signal, so no status row
    /// can ever double up with the animated Thinking row.
    func testStreamingToolCall_thinkingWins_evenWithProgressAndActivity() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: true,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: true,
            processingStatus: .fraction(0.99),
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertNil(result)
    }

    /// The implicit-target branch (committed bubble of a still-running step)
    /// does NOT consult the tool-call flag — a stale flag must not animate a
    /// committed bubble. (Also structurally unreachable: `BubbleInputs.committed`
    /// zeroes the flag — this is the resolver-level defense.)
    func testImplicitTarget_ignoresStreamingToolCall() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingStatus: nil,
            hasStreamActivity: false,
            isStreamingToolCall: true
        )
        XCTAssertNil(result)
    }

    /// The `isStreaming` gate still rules: a stale flag on a non-streaming
    /// bubble must not surface a status row. (Structurally unreachable —
    /// `BubbleInputs.committed` zeroes streaming fields — defense in depth.)
    func testNotStreaming_withStreamingToolCall_returnsNil() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: false,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingStatus: nil,
            hasStreamActivity: false,
            isStreamingToolCall: true
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
            processingStatus: nil,
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Generating…",
                       "Latest committed bubble in a still-running step must surface 'Generating…' while tool-call deltas are flowing — even though content is present, that content is frozen and the activity belongs to the next emission")
    }

    func testImplicitTarget_withProcessingProgress_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingStatus: .fraction(0.42),
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing 42%",
                       "Tool-result → next-LLM-iteration prompt-processing window: implicit target shows 'Processing N%' even with committed content")
    }

    /// Mirrors the streaming-branch `testProcessingProgress_zero_returnsProcessing`
    /// guard: `0.0` is "started, 0% done", not "no signal" — the indicator must
    /// distinguish nil from 0.0. A future "normalize nil to zero" refactor would
    /// silently break the implicit branch the same way it would break streaming.
    func testImplicitTarget_processingStatusZero_returnsProcessing() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingStatus: .fraction(0.0),
            hasStreamActivity: false
        )
        XCTAssertEqual(result, "Processing 0%")
    }

    func testImplicitTarget_processingWinsOverActivity() {
        let result = MessageBubbleStreamingIndicator.resolveStatusText(
            isStreaming: false,
            isImplicitStreamTarget: true,
            hasMessageContent: true,
            hasThinkingContent: false,
            processingStatus: .fraction(0.5),
            hasStreamActivity: true
        )
        XCTAssertEqual(result, "Processing 50%",
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
            processingStatus: nil,
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
            processingStatus: nil,
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
            processingStatus: .fraction(0.5),
            hasStreamActivity: true
        )
        XCTAssertNil(result,
                     "Step is done (or this isn't the latest bubble) — even latent activity flags must not surface a pill")
    }
    // MARK: - Compaction outranks everything

    /// Before the first delta the status row IS the epoch's only signal — nothing has landed
    /// in the disclosure yet — so it outranks every other rule here, including the ones that
    /// would otherwise resolve to "no status row".
    func testCompacting_beforeFirstDelta_isTheStatusRow() {
        for hasContent in [true, false] {
            for toolCall in [true, false] {
                for progress in [nil, .indeterminate, .fraction(0.5)] as [PromptProcessingStatus?] {
                    for activity in [true, false] {
                        XCTAssertEqual(
                            MessageBubbleStreamingIndicator.resolveStatusText(
                                isStreaming: true,
                                isImplicitStreamTarget: false,
                                hasMessageContent: hasContent,
                                hasThinkingContent: false,
                                processingStatus: progress,
                                hasStreamActivity: activity,
                                isStreamingToolCall: toolCall,
                                isCompacting: true),
                            "Compacting…",
                            "content=\(hasContent) toolCall=\(toolCall) "
                                + "progress=\(String(describing: progress)) activity=\(activity)")
                    }
                }
            }
        }
    }

    /// Once the disclosure has text it renders its OWN animated "Compacting…" row
    /// (`MessageThinkingSection.label`), and a status row saying the same thing would stack a
    /// second identical row under the first — which is what shipped in `ef8a1cc0`. This is the
    /// state the epoch is in for all but its first tick.
    func testCompacting_afterFirstDelta_yieldsTheRowToTheDisclosure() {
        for toolCall in [true, false] {
            for progress in [nil, .indeterminate, .fraction(0.5)] as [PromptProcessingStatus?] {
                for activity in [true, false] {
                    XCTAssertNil(
                        MessageBubbleStreamingIndicator.resolveStatusText(
                            isStreaming: true,
                            isImplicitStreamTarget: false,
                            hasMessageContent: false,
                            hasThinkingContent: true,
                            processingStatus: progress,
                            hasStreamActivity: activity,
                            isStreamingToolCall: toolCall,
                            isCompacting: true),
                        "toolCall=\(toolCall) progress=\(String(describing: progress)) "
                            + "activity=\(activity)")
                }
            }
        }
    }

    /// The rule yields to an ANIMATING disclosure row, not to a present one — a static row is
    /// not a live signal. Both arms below are unreachable for a real epoch (which writes no
    /// prose and raises no tool call); they exist because nothing at this seam states that,
    /// and the earlier `!hasMessageContent` shape silently produced a zero-animation bubble in
    /// the first of them.
    func testCompacting_withProse_followsWhichDisclosureRowIsLive() {
        XCTAssertNil(
            MessageBubbleStreamingIndicator.resolveStatusText(
                isStreaming: true,
                isImplicitStreamTarget: false,
                hasMessageContent: true,
                hasThinkingContent: true,
                processingStatus: nil,
                hasStreamActivity: true,
                isStreamingToolCall: true,
                isCompacting: true),
            "the TRAILING disclosure row animates here — it is the live signal")

        XCTAssertEqual(
            MessageBubbleStreamingIndicator.resolveStatusText(
                isStreaming: true,
                isImplicitStreamTarget: false,
                hasMessageContent: true,
                hasThinkingContent: true,
                processingStatus: nil,
                hasStreamActivity: true,
                isStreamingToolCall: false,
                isCompacting: true),
            "Compacting…",
            "neither disclosure row animates — yielding would leave zero animation")
    }

    /// The epoch's content preview is empty for its whole life, so the reservation — which is
    /// gated ON content — never fires and no blank keeper row appears under the disclosure.
    func testCompacting_neverReservesABlankSlot() {
        XCTAssertFalse(
            MessageBubbleStreamingIndicator.reservesStatusSlot(
                isStreaming: true,
                hasMessageContent: false,
                hasThinkingContent: true,
                isStreamingToolCall: false))
    }

    /// The flag is not gated on `isStreaming`: an epoch on a PARKED step has no live stream by
    /// that definition, and the row still has to say what is happening.
    func testCompacting_showsEvenWithoutALiveStream() {
        XCTAssertEqual(
            MessageBubbleStreamingIndicator.resolveStatusText(
                isStreaming: false,
                isImplicitStreamTarget: false,
                hasMessageContent: false,
                hasThinkingContent: false,
                processingStatus: nil,
                hasStreamActivity: false,
                isCompacting: true),
            "Compacting…")
    }

    /// …and it keeps the wording even with a full disclosure, because with no live stream
    /// that row is static: nothing else on the bubble is moving.
    func testCompacting_withoutALiveStream_keepsTheRowEvenWithADisclosure() {
        XCTAssertEqual(
            MessageBubbleStreamingIndicator.resolveStatusText(
                isStreaming: false,
                isImplicitStreamTarget: false,
                hasMessageContent: false,
                hasThinkingContent: true,
                processingStatus: nil,
                hasStreamActivity: false,
                isCompacting: true),
            "Compacting…")
    }

    /// The state the epoch actually reaches: no prose, nothing in the disclosure yet.
    func testCompacting_rendersARow() {
        XCTAssertTrue(
            MessageBubbleStreamingIndicator.rendersRow(
                isStreaming: true,
                isImplicitStreamTarget: false,
                hasMessageContent: false,
                hasThinkingContent: false,
                processingStatus: nil,
                hasStreamActivity: true,
                isStreamingToolCall: false,
                isCompacting: true))
    }

    /// Default off: every existing call site keeps its behaviour unchanged.
    func testCompactingDefaultsToOff() {
        XCTAssertNil(
            MessageBubbleStreamingIndicator.resolveStatusText(
                isStreaming: true,
                isImplicitStreamTarget: false,
                hasMessageContent: true,
                hasThinkingContent: false,
                processingStatus: nil,
                hasStreamActivity: false))
    }

    // MARK: - The thinking row's own label

    /// The two rows describe the SAME stream, so a bubble whose status says "Compacting…"
    /// while its disclosure says "Thinking…" is telling the user two different stories about
    /// one thing.
    func testThinkingSectionLabel_followsTheEpoch() {
        XCTAssertEqual(
            MessageThinkingSection.label(isStreaming: true, isCompacting: false), "Thinking…")
        XCTAssertEqual(
            MessageThinkingSection.label(isStreaming: false, isCompacting: false), "Thinking")
        XCTAssertEqual(
            MessageThinkingSection.label(isStreaming: true, isCompacting: true), "Compacting…")
        XCTAssertEqual(
            MessageThinkingSection.label(isStreaming: false, isCompacting: true), "Compacting")
    }

    /// The row and the window it opens must name the same thing: an epoch's disclosure holds
    /// the model re-reading its own transcript, and the summary it wrote — not deliberation
    /// about the task, which is what a window headed "Thinking" claims.
    func testThinkingSectionWindow_followsTheEpoch() {
        let id = UUID()
        let thinking = MessageThinkingSection.detailWindow(
            isCompacting: false, messageID: id, roleName: "Engineer", text: "t")
        let compacting = MessageThinkingSection.detailWindow(
            isCompacting: true, messageID: id, roleName: "Engineer", text: "t")

        guard case .thinking = thinking else { return XCTFail("Expected .thinking") }
        guard case .compaction = compacting else { return XCTFail("Expected .compaction") }
        XCTAssertNotEqual(thinking, compacting,
                          "same message id, separate dedup namespaces — one turn can own both")
    }

}
