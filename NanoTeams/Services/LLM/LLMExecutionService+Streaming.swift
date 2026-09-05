import Foundation

/// Extension containing LLM streaming call logic, token collection, and post-stream processing.
extension LLMExecutionService {

    // MARK: - Streaming Result

    /// Encapsulates the result of a single LLM streaming call.
    struct StreamingResult {
        var assistantContent: String
        var thinkingContent: String
        var resolvedToolCalls: [StepToolCall]
        var sawHarmonyMarker: Bool
        var harmonyBuffer: String
        var tokenUsage: TokenUsage?
        /// What the server reported about how it processed this request's prompt. Used to tell
        /// a prompt-prefix cache hit from a silent re-prefill; absent on providers or versions
        /// that report nothing, which is never treated as evidence either way.
        var serverPrefill: ServerPrefillReport?
        /// What THIS APP did to the model's residency for this request — the complement of
        /// `serverPrefill` on the provider whose residency the app manages. See
        /// `ClientResidencyFacts`.
        var clientResidency: ClientResidencyFacts?
        /// Non-nil iff the stream was broken by an in-stream thinking loop on a
        /// TOP-LEVEL task. Drives `handleStreamLoopBreak` (clean-retry / terminal).
        /// The looping generation is discarded — `assistantContent`/`thinkingContent`/
        /// `resolvedToolCalls` are empty when this is set.
        var thinkingLoopSignal: LoopSignal?
    }

    // MARK: - Stream-content helpers

    /// Drops leading Unicode whitespace. Callers gate on
    /// `assistantCollected.isEmpty` so internal and trailing whitespace
    /// are preserved once the first non-whitespace char has been recorded.
    /// Post-commit cleanup (`ModelTokenCleaner.clean`) trims both ends —
    /// this strip only protects the live `SelectableMessageText` preview
    /// from the `[/reasoning]\n\n\n\n…` gap during streaming.
    ///
    /// The GROWTH path only. A buffer that is still growing may legitimately
    /// end in whitespace the next delta continues from, so the tail is not
    /// this function's business — see `stripSurroundingWhitespace` for the
    /// rewind, where the content is final.
    static func stripLeadingWhitespace(_ s: String) -> String {
        String(s.drop(while: \.isWhitespace))
    }

    /// Trims BOTH ends, for the marker rewind only.
    ///
    /// At the rewind the prose is FINAL for the rest of the turn — every later
    /// delta routes to the thinking pipe — so a trailing `\n\n` is not
    /// "formatting between paragraphs" that the next token will continue, it
    /// is a hanging tail before an envelope the user never sees. Rendered
    /// verbatim by `SelectableMessageText` it becomes real empty line
    /// fragments: the blank band under a streaming bubble for the whole
    /// envelope-assembly window (measured ~29 s on a 4-call turn).
    ///
    /// Deliberately the SAME character set `ModelTokenCleaner.clean` uses, so
    /// the preview is byte-identical to the value commit will produce and the
    /// bubble cannot shift when the turn lands. Widening it past whitespace
    /// would eat the prose's own last character —
    /// `testRewind_noWhitespaceBeforeEnvelope_isUnchanged` is that guard.
    ///
    /// Internal whitespace is untouched — `testInternalNewlines_preservedAfterFirstNonWhitespaceChar`
    /// pins that paragraph breaks inside the body still round-trip.
    ///
    /// Safe against `StreamingPreviewManager.replaceContent`, whose empty-guard
    /// covers only the CREATE branch (an existing preview is overwritten
    /// unconditionally): this can never empty a non-empty `preMarker`, because
    /// the leading strip already ran, so the value either is empty or starts
    /// with a non-whitespace character. Both ends of that are pinned end-to-end —
    /// `testHarmonyEnvelope_pureToolCallAfterReasoning_stripsGapToEmpty` for the
    /// all-whitespace case, `testRewind_tokensOnlyProse_staysDetectableAsTokensOnly`
    /// for the all-tokens one.
    static func stripSurroundingWhitespace(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLM Streaming

    /// Executes a single LLM streaming call and collects assistant content, thinking, and tool calls.
    /// Uses inline streaming: pre-creates an LLMMessage at stream start, streams content into it,
    /// and commits final content on completion (or partial content on cancellation).
    func performStreamingCall(
        stepID: String,
        taskID: Int,
        roleForMessage: Role,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        conversationMessages: [ChatMessage],
        networkLogger: NetworkLogger?,
        roleName: String? = nil
    ) async throws -> StreamingResult {
        guard let delegate else {
            return StreamingResult(
                assistantContent: "", thinkingContent: "",
                resolvedToolCalls: [], sawHarmonyMarker: false, harmonyBuffer: "")
        }

        let streamingMessageID = UUID()
        var assistantCollected = ""
        var thinkingCollected = ""
        // Cadence from delta sizes, never from re-counting the buffers: the old
        // `thinkingCollected.count + assistantCollected.count` here walked every
        // grapheme of both buffers per stream event — O(buffer) per delta,
        // quadratic across the stream, and unsaveable by the throttle because
        // the count WAS the throttle's input. Every buffer mutation below
        // reports its size to the gate (two `+=` sites, one truncation).
        // `.everyChars` is legal here because the probe behind it —
        // `LoopScanner.scanStreaming` — truncates each channel to a fixed tail
        // window before scanning, so its cost is constant in the accumulated
        // length. The case name is that claim; see `StreamProbeCadence`.
        var loopScanGate = StreamProbeGate(
            cadence: .everyChars(LLMConstants.streamLoopScanCadenceChars))
        // Same principle for the CANONICAL duplicate-call probe: its input is the
        // growing args blob, so running it per `toolCallDeltas` event was O(args)
        // JSON work per delta (the raw fast path short-circuits only when a
        // duplicate EXISTS — the healthy two-distinct-calls stream fell through
        // to a full canonical pass every delta). The cheap byte-identity probe
        // (`hasRawDuplicate`, fed by running hashes) still runs per delta and
        // catches every observed loop; the canonical pass runs on this cadence.
        // GEOMETRIC, not arithmetic. The probe behind this one re-reads the WHOLE
        // accumulated args blob (parse + canonicalize + hash, ~8 passes), so an
        // arithmetic cadence summed to Θ(A²/cadence) across a stream — the exact
        // asymmetry the harmony branch never had. Latent today (no shipping client
        // emits `toolCallDeltas`), fixed here rather than left as a trap the first
        // OpenAI-compatible client would spring. No unit clause here (`firstAtUnits:
        // 0`, no `noteUnit()`): byte growth alone bounds Σ parse work at 3× the
        // final blob, and there is no "many tiny envelopes" shape on this path —
        // the per-delta byte-identity probe already catches it.
        var toolDeltaScanGate = StreamProbeGate(
            cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 0))

        // Pre-create empty LLMMessage for inline streaming (no visual jump on commit)
        if isExecutionLive(stepID: stepID, taskID: taskID) {
            await delegate.beginStreaming(
                stepID: stepID, taskID: taskID,
                messageID: streamingMessageID, role: roleForMessage)
            #if DEBUG
            // The end of the submit's silence: from here the bubble says `Processing…`.
            // A no-op unless a submit measurement is open and still awaiting its first
            // stream frame, so ordinary mid-run turns cost nothing.
            SubmitLatencyProbe.markStream()
            #endif
            // Claim the prompt-processing window for EVERY provider, strictly
            // AFTER `beginStreaming` (which resets the status to nil). This is a
            // fact we own — we are about to issue the send — not an inference
            // about the server, so it needs no provider gate. LM Studio REFINES
            // it to `.fraction` below when its `prompt_processing.*` frames
            // arrive; Ollama has nothing further to say (its stream yields
            // nothing at all until the first token), so `.indeterminate` stands
            // for the whole load+prefill window. Without this the bubble reads
            // "Waiting…" — which the user reports as "nothing is happening" —
            // for a window measured in tens of seconds on large prompts.
            delegate.updateStreamingProcessingStatus(
                stepID: stepID, taskID: taskID, status: .indeterminate)
        }

        func appendAssistant(_ text: String) {
            guard !text.isEmpty else { return }
            // Strip leading whitespace while the buffer is still empty so the
            // `[/reasoning]\n\n\n\n…` gap doesn't survive into the live preview.
            let delta = assistantCollected.isEmpty
                ? Self.stripLeadingWhitespace(text)
                : text
            guard !delta.isEmpty else { return }
            assistantCollected += delta
            loopScanGate.noteDelta(count: delta.count)
            delegate.appendStreamingPreview(
                stepID: stepID, taskID: taskID,
                messageID: streamingMessageID, role: roleForMessage, content: delta)
        }

        let uiFlushInterval: TimeInterval = 0.2
        let uiFlushCharThreshold = LLMConstants.uiFlushCharThreshold
        var pendingUI = ""
        var lastUIFlush = Date()

        func flushPendingUI(force: Bool = false) {
            guard !pendingUI.isEmpty else { return }
            let now = Date()
            if force || pendingUI.count >= uiFlushCharThreshold
                || now.timeIntervalSince(lastUIFlush) >= uiFlushInterval
            {
                appendAssistant(pendingUI)
                pendingUI.removeAll(keepingCapacity: true)
                lastUIFlush = now
            }
        }

        var toolAccumulator = ToolCallAccumulator()
        var sawHarmonyMarker = false
        var harmonyBuffer = ""
        var uiBuffer = ""
        var capturedUsage: TokenUsage?
        var capturedPrefill: ServerPrefillReport?
        var capturedResidency: ClientResidencyFacts?

        /// Commits streaming content (final or partial on cancellation).
        func commitStreamingContent() async {
            flushPendingUI(force: true)
            // `isExecutionLive` is the post-teardown barrier: this runs from the
            // cancellation catch path too, and an orphan whose executionStates
            // entry was already removed (bulk cancel / timed-out cancel) must NOT
            // commit into whatever now answers to the captured taskID.
            if isExecutionLive(stepID: stepID, taskID: taskID) {
                let cleanedContent = ModelTokenCleaner.clean(assistantCollected)
                // Reasoning is persisted RAW — no `stripTokens`, no `clean`. The
                // channel's whole job now is to show what the model actually wrote,
                // and a `<|call|>{...}<|end|>` it rehearsed there is precisely the
                // thing a reader needs to SEE unaltered to understand why no tool ran
                // (nothing reads reasoning for tool calls — see the route list in
                // `performStreamingCall`). Stripping also disagreed with the live
                // preview, which never stripped (`StreamingPreviewManager.appendThinking`):
                // the envelope streamed on screen and then vanished at commit.
                //
                // Safe for the wire by construction: `thinking` never leaves the display
                // record — `ConversationReplay.rebuildFromDisplayRecord` builds
                // `ChatMessage`s from `content` alone — and `TaskMutationService
                // .commitStreamingContent` stores this value verbatim.
                //
                // Drop whitespace-only reasoning (some models emit an empty
                // `[reasoning]...[/reasoning]` block with just newlines) so we don't
                // persist a thinking disclosure that expands to nothing.
                let thinkingToCommit: String? =
                    thinkingCollected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : thinkingCollected
                await delegate.commitStreaming(
                    stepID: stepID, taskID: taskID,
                    content: cleanedContent, thinking: thinkingToCommit)
            }
        }

        // Tracks whether we've already cleared `processingProgress` after the
        // first generation delta arrived. Once either thinking or content
        // starts streaming, prompt processing is implicitly done — clear the
        // indicator so it doesn't visually freeze at "Processing 99%". LM
        // Studio doesn't always emit a `prompt_processing.end` event (the
        // last `prompt_processing.progress` can be 0.99, then generation
        // starts without a terminating event); without this fallback the
        // UI shows "Processing 99%" alongside the model actively producing
        // tokens until the whole stream completes.
        var processingProgressCleared = false
        /// Resolved inside the `do` block, before the turn is committed. Declared out here
        /// so the return can read it; the cancellation path throws, so it stays empty there.
        var resolvedToolCalls: [StepToolCall] = []

        // In-stream loop detection — the single point that replaces both the old
        // `DelegationLoopWatcher.considerStreamingBuffer` AND the orchestrator's
        // `considerStreamingForLoopDetection` dispatcher. Routed by task kind:
        //   - top-level → set `thinkingLoopSignal` + break; recovery in `runOneLLMToolIteration`.
        //   - child     → `noteStreamLoop` (parent interrupt, no break).
        // Resolved once (`parentTaskID` is step-invariant). `performStreamingCall` is
        // `@MainActor`, so the `delegate` calls below are synchronous on the actor —
        // that's what lets `noteStreamLoop` return the I4 throttle decision in-line.
        let loopScanTask = delegate.loadedTask(taskID)
        let loopScanEnabled = loopScanTask != nil
        let loopScanIsTopLevel = loopScanTask?.parentTaskID == nil
        var thinkingLoopSignal: LoopSignal?
        /// Returns `true` when the caller should break the stream (top-level loop).
        func scanForStreamLoop() -> Bool {
            guard loopScanEnabled else { return false }
            guard loopScanGate.isDue else { return false }
            if loopScanIsTopLevel {
                guard let signal = LoopScanner.scanStreaming(
                    thinking: thinkingCollected, content: "", scope: .thinkingOnly
                ) else { loopScanGate.recordProbe(); return false }
                thinkingLoopSignal = signal
                return true
            }
            guard let signal = LoopScanner.scanStreaming(
                thinking: thinkingCollected, content: assistantCollected, scope: .thinkingAndContent
            ) else { loopScanGate.recordProbe(); return false }
            // Advance the throttle baseline only when the watcher says so (fired or
            // in cooldown). On the no-waiter race it returns false → hold so the next
            // growth window re-scans until the parent awaiter registers (I4).
            if delegate.noteStreamLoop(taskID: taskID, stepID: stepID, signal: signal) {
                loopScanGate.recordProbe()
            }
            return false
        }

        // Gates the (expensive, whole-buffer) `harmonyParser.extractAllToolCalls(...)`
        // duplicate probe: first fire at the second close marker (before that dedup is
        // impossible by definition), then geometric re-probes so the total parse work
        // stays amortized-linear in the stream. See `harmonyProbeGate` (:279).
        var harmonyProbeGate = StreamProbeGate(
            cadence: .geometric(growthNumerator: 3, growthDenominator: 2, firstAtUnits: 2))
        // Three sites below `break` out of the for-await the moment the parser sees two
        // identical tool calls in one stream (canonical `name`+sortedKeys(args) signature).
        // The `break` IS the whole mechanism — the AsyncThrowingStream's `onTermination`
        // handler in `NativeLMStudioClient` cancels the underlying URLSession bytes stream,
        // so the model isn't allowed to keep emitting more duplicates. Nothing downstream
        // distinguishes this exit from a normal end: the dedup below runs unconditionally
        // either way, and the partial turn is committed by the same `commitStreamingContent`.
        do {
            // prefix-cache-owner: the role step itself — `runOneLLMToolIteration` records
            // `.step(taskID:stepID:)` before this send and resolves the verdict after it.
            for try await event in client.streamChat(
                config: config, messages: conversationMessages, tools: tools,
                logger: networkLogger, stepID: stepID, roleName: roleName)
            {
                if Task.isCancelled { throw CancellationError() }

                if !event.thinkingDelta.isEmpty {
                    thinkingCollected += event.thinkingDelta
                    loopScanGate.noteDelta(count: event.thinkingDelta.count)
                    delegate.appendStreamingThinking(stepID: stepID, taskID: taskID, content: event.thinkingDelta)
                    delegate.markStreamActivity(stepID: stepID, taskID: taskID)
                    if !processingProgressCleared {
                        delegate.clearStreamingProcessingStatus(stepID: stepID, taskID: taskID)
                        processingProgressCleared = true
                    }
                }

                // Forward processing progress to UI — but only while we're
                // genuinely in the prompt-processing phase. Once any generation
                // delta has arrived (`processingProgressCleared == true`),
                // ignore late `prompt_processing.*` events that would re-flash
                // the indicator. This is defensive — in practice the events
                // arrive monotonically before any generation, but we don't
                // want a stale event to revive the "Processing X%" status
                // after the user is already seeing tokens.
                if !processingProgressCleared, let progress = event.processingProgress {
                    delegate.updateStreamingProcessingStatus(
                        stepID: stepID, taskID: taskID, status: .fraction(progress))
                }

                if !event.contentDelta.isEmpty {
                    if !processingProgressCleared {
                        delegate.clearStreamingProcessingStatus(stepID: stepID, taskID: taskID)
                        processingProgressCleared = true
                    }
                    // Mark stream activity even when content lands in
                    // `harmonyBuffer` (invisible to the UI's content preview).
                    // Without this the bubble shows "Waiting" while the
                    // model is actively emitting a long tool-call argument.
                    delegate.markStreamActivity(stepID: stepID, taskID: taskID)
                    let delta = event.contentDelta
                    if sawHarmonyMarker {
                        harmonyBuffer += delta
                        harmonyProbeGate.noteDelta(count: delta.count)
                        // Surface the envelope text AS THINKING — UI preview
                        // only: this pipe never touches `thinkingCollected`,
                        // and commit persists its token-stripped form. The
                        // user watches the tool call being typed in the live
                        // Thinking section instead of staring at a frozen
                        // bubble.
                        delegate.appendStreamingThinking(stepID: stepID, taskID: taskID, content: delta)
                        // Whole-buffer re-extract & dedup only when the growth
                        // gate says a probe is due — see the `harmonyProbeGate`
                        // declaration above (`:279` was `loopScanGate`'s
                        // neighbourhood; the gate this branch reads is declared
                        // ~60 lines up, and three baseline `why`s copied the wrong
                        // number from here — CLAUDE.md #111) for why the per-close
                        // probe was O(segments × buffer) and why a cursor cannot
                        // replace the whole-buffer parse.
                        if delta.contains(HarmonyToolCallParser.callMarker) || delta.contains("<|end|>") {
                            harmonyProbeGate.noteUnit()
                            if harmonyProbeGate.probeIsDue() {
                                let extracted = harmonyParser.extractAllToolCalls(from: harmonyBuffer)
                                if Self.containsDuplicateToolCalls(extracted) {
                                    break
                                }
                            }
                        }
                    } else {
                        uiBuffer += delta
                        pendingUI += delta
                        let harmonyMarkers = HarmonyToolCallParser.harmonyMarkers
                        // Windowed detection: the delta plus a needle-sized overlap is all
                        // a marker or a mangled sentinel (see `HarmonySentinelNormalizer` —
                        // `gemma-4-e4b` splices `<|tool_call|>` into the `<|call|>` this
                        // prompt teaches) can newly complete. Scanning the WHOLE buffer
                        // here was CLAUDE.md #106: ≥4 full-buffer searches per delta,
                        // quadratic across every plain-prose reply. The full normalize +
                        // range(of:) below run at most once per stream, on detection.
                        if StreamMarkerWindow.harmonyNeedleArrived(
                            buffer: uiBuffer, newDeltaCount: delta.count) {
                            let normalizedBuffer = HarmonySentinelNormalizer.normalize(uiBuffer)
                            // Adopt the normalized buffer WHOLESALE rather than keeping it
                            // local. Everything below indexes into `uiBuffer`
                            // (`range(of: marker)`, `uiBuffer[..<lower]`, `uiBuffer[lower...]`)
                            // and normalization changes length, so two strings here would
                            // desynchronize by exactly the repaired span. The single
                            // assignment is also what makes the three downstream consumers
                            // agree: this detection, `harmonyBuffer` (route 2 at the tail of
                            // this method), and `envelopeSource` in `classifyHarmonyCallIssue`.
                            uiBuffer = normalizedBuffer
                            sawHarmonyMarker = true
                            // The stream just committed to an envelope:
                            // visible PROSE freezes here and raw tokens flow
                            // into `harmonyBuffer`; the deltas re-surface in
                            // the THINKING preview (pipe below + the
                            // sawHarmonyMarker branch above), whose animated
                            // row becomes the live indicator. Flag the
                            // tool-call state so (a) the Thinking loader
                            // keeps animating despite frozen prose and
                            // (b) the indicator can fall back to "Generating"
                            // while the thinking preview is still empty.
                            delegate.markStreamingToolCall(stepID: stepID, taskID: taskID)
                            harmonyBuffer = uiBuffer
                            // Seed the close-marker count from what THIS delta already
                            // carried. Counting only inside the `sawHarmonyMarker` branch
                            // above under-counted by exactly the detection delta, so the
                            // gate was chunking-dependent: two byte-identical envelopes
                            // framed as two deltas left the counter at 1, and framed as one
                            // coalesced delta never reached the check at all. Either way the
                            // break never fired — and back then the post-loop dedup only ran
                            // when it HAD fired, so BOTH identical calls were dispatched.
                            harmonyProbeGate.seed(
                                adoptedLength: harmonyBuffer.count,
                                units: Self.closeMarkerCount(in: harmonyBuffer))
                            if harmonyProbeGate.probeIsDue(),
                               Self.containsDuplicateToolCalls(
                                   harmonyParser.extractAllToolCalls(from: harmonyBuffer)) {
                                break
                            }
                            // Truncate to content before the earliest marker.
                            // uiBuffer is the complete record of all deltas — use it as
                            // source of truth to handle markers split across flush boundaries.
                            var earliestLower: String.Index?
                            for marker in harmonyMarkers {
                                if let range = uiBuffer.range(of: marker) {
                                    if earliestLower == nil || range.lowerBound < earliestLower! {
                                        earliestLower = range.lowerBound
                                    }
                                }
                            }
                            if let lower = earliestLower {
                                // Trim BOTH ends of the rewind buffer — this is a
                                // separate funnel into `assistantCollected`, so the
                                // same gap can sneak through if the marker arrives in
                                // the same chunk as the `[/reasoning]\n\n\n\n` tail,
                                // and the model's own `\n\n` before `<|call|>` would
                                // otherwise sit on screen as blank lines for the whole
                                // envelope assembly.
                                //
                                // WHITESPACE only here. Do NOT fold
                                // `ModelTokenCleaner.stripTokens` into this value:
                                // `+StepFlowControl`'s tokens-only retry fires on
                                // `!assistantContent.isEmpty && clean(assistantContent).isEmpty`,
                                // so handing it pre-cleaned content makes that
                                // diagnostic unreachable. The preview gets the
                                // token-stripped copy below; the wire is unaffected
                                // either way (`clean(trim(x)) == clean(x)`).
                                let preMarker = Self.stripSurroundingWhitespace(String(uiBuffer[..<lower]))
                                loopScanGate.noteReplacement(
                                    oldCount: assistantCollected.count,
                                    newCount: preMarker.count)
                                assistantCollected = preMarker
                                // Rewind the on-screen preview so partial marker
                                // prefixes (e.g. `<`, `<|`) that were flushed by
                                // the time/size heuristic don't linger — see
                                // ModelTokenCleaner.containsModelTokens which only
                                // strips once both `<|` and `|>` are present.
                                //
                                // `uiBuffer` holds RAW deltas while the append path
                                // strips tokens per delta, so without this the rewind
                                // puts a `<|…|>` back on screen that was already gone
                                // (`<|end|>` is not in `harmonyMarkers`, so it can
                                // precede the earliest one). Strip THEN re-trim:
                                // removing a token can expose fresh trailing space.
                                let previewContent = Self.stripSurroundingWhitespace(
                                    ModelTokenCleaner.stripTokens(preMarker)
                                )
                                delegate.replaceStreamingPreview(
                                    stepID: stepID,
                                    taskID: taskID,
                                    messageID: streamingMessageID,
                                    role: roleForMessage,
                                    content: previewContent
                                )
                                // The post-marker slice the rewind just removed
                                // from the content preview re-surfaces as live
                                // THINKING (preview-only, not persisted) so no
                                // streamed text ever just vanishes from screen.
                                delegate.appendStreamingThinking(
                                    stepID: stepID, taskID: taskID, content: String(uiBuffer[lower...]))
                            }
                            pendingUI = ""
                            continue
                        }
                        flushPendingUI()
                    }
                }

                if !event.toolCallDeltas.isEmpty {
                    toolAccumulator.absorb(event.toolCallDeltas)
                    // OpenAI-style tool-call deltas don't materialize in the
                    // content preview — the UI only renders the call card
                    // after the stream ends. Mark activity, flag tool-call
                    // streaming, and surface the fragments AS THINKING
                    // (preview-only) so the user watches the call being
                    // typed instead of staring at a frozen bubble.
                    if !processingProgressCleared {
                        delegate.clearStreamingProcessingStatus(stepID: stepID, taskID: taskID)
                        processingProgressCleared = true
                    }
                    delegate.markStreamActivity(stepID: stepID, taskID: taskID)
                    delegate.markStreamingToolCall(stepID: stepID, taskID: taskID)
                    for toolDelta in event.toolCallDeltas {
                        let fragment = (toolDelta.name ?? "") + (toolDelta.argumentsDelta ?? "")
                        if !fragment.isEmpty {
                            delegate.appendStreamingThinking(stepID: stepID, taskID: taskID, content: fragment)
                        }
                    }

                    // Two-tier duplicate detection (CLAUDE.md #106 — the gate must
                    // not cost the work it gates): byte-identical duplicates surface
                    // per delta from running hashes, O(#calls); the canonical
                    // whitespace/key-order comparison — a full JSON parse of every
                    // args blob — fires on the cadence gate only.
                    if toolAccumulator.hasRawDuplicate {
                        break
                    }
                    toolDeltaScanGate.noteDelta(count: event.toolCallDeltas.reduce(0) {
                        $0 + ($1.argumentsDelta?.count ?? 0) + ($1.name?.count ?? 0)
                    })
                    if toolDeltaScanGate.probeIsDue() {
                        if Self.containsDuplicateToolCalls(toolAccumulator.finalize()) {
                            break
                        }
                    }
                }

                if let u = event.tokenUsage { capturedUsage = u }
                if let p = event.serverPrefill { capturedPrefill = p }
                if let r = event.clientResidency { capturedResidency = r }

                // In-stream loop scan (cadence-throttled). For child tasks this fires
                // the parent interrupt and returns false (no break). For top-level it
                // sets `thinkingLoopSignal` and returns true → break + discard + retry.
                if scanForStreamLoop() { break }
            }

            if Task.isCancelled { throw CancellationError() }

            // Clear processing progress (stream completed successfully OR was
            // broken early by loop detection — either way, generation is done
            // from this iteration's perspective).
            delegate.clearStreamingProcessingStatus(stepID: stepID, taskID: taskID)

            // Resolve tool calls BEFORE the turn is committed. Every input below is final
            // once the stream loop exits, so the position is free — and it has to be
            // here, because route 3 can move text out of the content channel. Resolving
            // after the commit would fork the display record from the wire permanently:
            // the raw payload would already be in `step.llmConversation`, and since
            // `HarmonyToolCallEnvelope.appendedWireText` re-materializes the call on top
            // of non-empty content, every stateless resend would carry that call twice.
            flushPendingUI(force: true)

            // 1. Provider-native `tool_calls` deltas always win.
            resolvedToolCalls = toolAccumulator.finalize()
            // 2. Harmony envelope in the content channel.
            if resolvedToolCalls.isEmpty, sawHarmonyMarker {
                resolvedToolCalls = harmonyParser.extractAllToolCalls(from: harmonyBuffer)
            }
            //
            // There is NO route out of `thinkingCollected`. A reasoning channel carrying
            // `<|call|>{...}<|end|>` is the model REHEARSING a call, not making one, and
            // this app answers it by leaving the text where the model wrote it: the
            // envelope stays visible in the Thinking disclosure (raw, see
            // `commitStreamingContent`) and the turn resolves zero calls, so the ordinary
            // no-tool-call handling in `+StepFlowControl` drives the next iteration.
            // A route reading reasoning DID exist (added for qwen3.6-mlx, which
            // stochastically emitted whole envelopes on `reasoning.delta`); it executed
            // deliberation as if it were action, which is the defect, not the recovery.
            //
            // `thinkingCollected` IS read once more, downstream and for DIAGNOSIS only:
            // `handleNoToolCalls` asks `ConversationRepairService.reasoningChannelToolCallNames`
            // what the model wrote there, so the nudge for a turn that resolved nothing can
            // name the channel that swallowed it. That reader dispatches nothing and must not
            // grow into a route.
            //
            // 3. Last resort: a reply carrying no sentinel at all. Gated on
            // `!sawHarmonyMarker` — once a marker was seen, recovery belongs to route 2
            // and `classifyHarmonyCallIssue`, which can name the defect. See
            // `BareToolCallSalvage` for why this is the only place that accepts an
            // unframed call, and what it refuses to infer.
            if resolvedToolCalls.isEmpty, !sawHarmonyMarker,
               let salvaged = BareToolCallSalvage.salvage(
                   from: assistantCollected, advertised: tools)
            {
                resolvedToolCalls = [salvaged]
                // The promoted text leaves the content channel — otherwise the turn
                // renders twice, once as a raw-JSON bubble and once as a tool card, and
                // the wire carries the call twice for the same reason. It re-surfaces as
                // live THINKING (preview-only, not persisted), exactly as the mid-stream
                // Harmony rewind does, so no streamed text ever just vanishes from screen.
                let promoted = assistantCollected
                assistantCollected = ""
                delegate.replaceStreamingPreview(
                    stepID: stepID, taskID: taskID, messageID: streamingMessageID,
                    role: roleForMessage, content: "")
                delegate.appendStreamingThinking(
                    stepID: stepID, taskID: taskID, content: promoted)
            }
            // Drop later occurrences of any duplicated (name, args) signature — only the
            // first instance of each is kept and executed.
            //
            // UNCONDITIONAL, not gated on whether a streaming `break` fired. That gate
            // assumed a duplicate could only arrive that way, but the break has its own
            // preconditions (native deltas, or Harmony with the probe gate due) and
            // a reply can carry an exact repeat without tripping any of them: measured on
            // a real run, a byte-identical 2795-byte `edit_file` executed twice inside one
            // 56-call response. Re-running an identical call cannot produce a different
            // result — the second is pure cost, and for a mutating tool it is a second
            // write attempt against state the first one already changed.
            resolvedToolCalls = Self.deduplicateToolCalls(resolvedToolCalls)

            if thinkingLoopSignal != nil {
                // Top-level thinking-loop break: DISCARD the looping generation —
                // do NOT commit it as a turn. Removes the pre-created empty assistant
                // message (no orphan bubble) and clears the preview. The recovery in
                // `runOneLLMToolIteration` retries the same request statelessly.
                await delegate.discardStreaming(
                    stepID: stepID, messageID: streamingMessageID, taskID: taskID)
            } else {
                // Commit content streamed so far (full on normal end; partial when
                // we broke out on a duplicate tool call).
                await commitStreamingContent()
            }
        } catch is CancellationError {
            // Commit partial content on cancellation
            delegate.clearStreamingProcessingStatus(stepID: stepID, taskID: taskID)
            await commitStreamingContent()
            throw CancellationError()
        } catch {
            // Transport/server failure mid-stream. The retry lives in
            // `+StepLifecycle`, which posts an "LLM server error … Retrying in Ns…"
            // notice and then SLEEPS (`retryDelaySeconds`, 10s by default) before
            // re-entering — and only that re-entry's `beginStreaming` resets the
            // status. Without this clear the bubble spends the whole sleep
            // insisting the server is processing our prompt while nothing is in
            // flight: a frozen "Processing 47%" on LM Studio, a frozen
            // "Processing…" on Ollama. Cleared, the resolver falls through to
            // "Waiting…", which is exactly what is happening — we are waiting to
            // retry. No commit here: the do-block's success path and the
            // cancellation arm above own that, and a failed stream has no turn to
            // commit. Errors that arrive mid-GENERATION are unaffected (the first
            // delta already cleared the status, so this is a no-op for them).
            delegate.clearStreamingProcessingStatus(stepID: stepID, taskID: taskID)
            throw error
        }

        return StreamingResult(
            assistantContent: assistantCollected,
            thinkingContent: thinkingCollected,
            resolvedToolCalls: resolvedToolCalls,
            sawHarmonyMarker: sawHarmonyMarker,
            harmonyBuffer: harmonyBuffer,
            tokenUsage: capturedUsage,
            serverPrefill: capturedPrefill,
            clientResidency: capturedResidency,
            thinkingLoopSignal: thinkingLoopSignal
        )
    }

    // MARK: - Streaming-time loop detection helpers

    /// Canonical `(name, sortedKeysJSON(arguments))` signature for a streamed tool call.
    /// Returns `nil` if `argumentsJSON` is not yet valid JSON (during incremental streaming
    /// of a partial argument blob) — caller treats nil as "skip, not yet comparable".
    nonisolated static func canonicalToolCallSignature(_ call: StepToolCall) -> String? {
        guard let dict = ToolCallDataUtils.parseJSON(call.argumentsJSON),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let canonical = String(data: data, encoding: .utf8)
        else { return nil }
        return "\(call.name)\u{1F}\(canonical)"
    }

    /// Returns `true` if `calls` contains two distinct entries whose canonical signature
    /// matches. Calls whose arguments aren't yet parseable are ignored (incremental streaming).
    ///
    /// Cost note (2026-08-21): a single tool call's args can grow into the hundreds of
    /// KB, and the raw fast path below short-circuits only when a duplicate EXISTS — a
    /// healthy stream with two DISTINCT calls falls through to the canonical loop, a
    /// full JSON parse of every blob. That is why the streaming loop no longer calls
    /// this per `toolCallDeltas` event: byte-identical duplicates are caught per delta
    /// by `ToolCallAccumulator.hasRawDuplicate` (running hashes, O(#calls)), and this
    /// function runs behind `toolDeltaScanGate` — plus at the gated harmony re-extract
    /// sites and once post-stream, where the inputs are final.
    /// How many tool-call envelopes a buffer could hold, for the cheap gate in front of
    /// the (expensive) re-parse. `max` rather than a sum because one envelope commonly
    /// carries BOTH terminators — summing would report 2 for a single call and re-parse
    /// on every stream.
    nonisolated static func closeMarkerCount(in buffer: String) -> Int {
        max(buffer.components(separatedBy: HarmonyToolCallParser.callMarker).count - 1,
            buffer.components(separatedBy: "<|end|>").count - 1)
    }

    nonisolated static func containsDuplicateToolCalls(_ calls: [StepToolCall]) -> Bool {
        guard calls.count >= 2 else { return false }

        var rawSeen = Set<String>()
        for call in calls {
            let raw = "\(call.name)\u{1F}\(call.argumentsJSON)"
            if !rawSeen.insert(raw).inserted { return true }
        }

        var canonicalSeen = Set<String>()
        for call in calls {
            guard let sig = canonicalToolCallSignature(call) else { continue }
            if !canonicalSeen.insert(sig).inserted { return true }
        }
        return false
    }

    /// Drops later occurrences of any tool call whose canonical signature already appeared
    /// — preserves the FIRST occurrence per signature. Calls with non-parseable arguments
    /// pass through unchanged (we cannot prove they are duplicates).
    nonisolated static func deduplicateToolCalls(_ calls: [StepToolCall]) -> [StepToolCall] {
        var seen = Set<String>()
        var unique: [StepToolCall] = []
        for call in calls {
            guard let sig = canonicalToolCallSignature(call) else {
                unique.append(call)
                continue
            }
            if seen.insert(sig).inserted { unique.append(call) }
        }
        return unique
    }

    /// Longest unresolved Harmony buffer replayed back to the model. Big enough for any
    /// real tool call (the largest observed `create_artifact` envelope is well under it),
    /// small enough that a model stuck emitting a wall of text cannot pin a huge block
    /// into every subsequent request's prefix.
    nonisolated static let maxUnresolvedEnvelopeAnchorLength = 2000

    /// What an assistant turn carries when its Harmony envelope resolved to no tool call:
    /// the raw bytes, capped, or nil when there were none.
    ///
    /// Nil rather than `""` for an empty buffer — `content: nil` is the existing "the turn
    /// happened but said nothing" anchor, and fabricating content the model never emitted
    /// would be a different lie from the one this fixes.
    nonisolated static func unresolvedEnvelopeAnchor(_ harmonyBuffer: String) -> String? {
        let trimmed = harmonyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxUnresolvedEnvelopeAnchorLength else { return trimmed }
        return String(trimmed.prefix(maxUnresolvedEnvelopeAnchorLength)) + "… [truncated]"
    }

    // MARK: - Post-Stream Processing

    /// Appends the assistant/tool-call turn to the conversation and the persisted log.
    ///
    /// Returns nothing, and used to claim otherwise: the signature was `-> LLMStepStop?` with the
    /// doc "returns `.completed` if the LLM signaled task completion", but the body's only
    /// function-level return was `return nil`, so the caller's `if let completionStop` could not
    /// fire on any input. There is no such signal to detect — a step ends through
    /// `checkArtifactCompleteness` after `create_artifact`, or through `handleNoToolCalls` — so
    /// the honest fix is to delete the promise rather than invent a producer for it. Removing the
    /// optional also turned two `XCTAssertNil(stop)` assertions into compile errors, which is what
    /// they deserved: they could never have failed.
    func processStreamingResult(
        _ result: StreamingResult,
        stepID: String,
        taskID: Int,
        conversationMessages: inout [ChatMessage]
    ) async {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        let hasContent = !result.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasToolCalls = !result.resolvedToolCalls.isEmpty

        // Append the assistant turn to the in-memory conversation — the conversation
        // IS the request on every iteration (stateless full history), so a turn the
        // model produced must be recorded here or the next call shows it tool results
        // for calls it has no record of making.
        // NOTE: The LLMMessage and StepMessage are already committed by commitStreaming()
        // in performStreamingCall(), so we only update conversationMessages here.
        if hasContent || hasToolCalls {
            let cleanedContent = hasContent ? ModelTokenCleaner.clean(result.assistantContent) : nil
            if hasToolCalls {
                let toolCallMessages = result.resolvedToolCalls.map { call in
                    ChatToolCall(
                        id: call.providerID ?? UUID().uuidString,
                        name: call.name,
                        argumentsJSON: call.argumentsJSON
                    )
                }
                appendAssistantTurn(
                    ChatMessage(
                        role: .assistant,
                        content: cleanedContent,
                        toolCalls: toolCallMessages
                    ),
                    stepKey: stepKey, to: &conversationMessages)
            } else {
                // Zero resolved calls. Content truncation at the marker exists so resolved
                // calls can re-materialize from `toolCalls` — but with none resolved,
                // nothing re-materializes the envelope, so the turn must ALSO carry the
                // unresolved buffer verbatim. The prose-less shape already does (the anchor
                // branch below); this covers the model that narrates a line BEFORE
                // `<|call|>` — CubeCraft task 8 run 0: the resent turn held only "Now I
                // have enough context…" while the retry nudge claimed the attempt was
                // "quoted verbatim in your previous turn". Same cap, same rationale as the
                // anchor branch.
                var content = cleanedContent
                if let anchor = Self.unresolvedEnvelopeAnchor(result.harmonyBuffer) {
                    content = [cleanedContent, anchor]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                }
                appendAssistantTurn(
                    ChatMessage(role: .assistant, content: content),
                    stepKey: stepKey, to: &conversationMessages)
            }
        } else {
            // The model produced a turn that yields no assistant content and no resolved
            // tool calls — typically a Harmony tool-call envelope the parser consumed but
            // couldn't resolve (malformed JSON). The turn DID happen, so record an empty
            // anchor for it: it keeps the transcript's turn structure honest (the retry
            // nudge that follows is a reply to SOMETHING) and keeps the conversation
            // growing, so a malformed iteration can't leave the array byte-identical to
            // the previous one. `conversationMessages` is in-memory wire state only — any
            // user-visible LLMMessage/StepMessage commit is owned by commitStreaming()
            // (the streaming LLMMessage is pre-created at stream start), so appending this
            // anchor has no UI or persistence effect.
            //
            // When there IS a Harmony buffer, the anchor carries it VERBATIM instead of
            // being empty. Truncating content at the first marker exists so the envelope
            // can be re-materialized from `toolCalls` — but with zero resolved calls
            // there is nothing to re-materialize, so the truncation only erases the one
            // thing the model needs. The 2026-08-13 gemma run shows the cost: it was told
            // "your JSON could not be parsed" while its own turn replayed as a bare
            // `[Assistant]`, and spent a 19-second reasoning block insisting it had sent
            // the arguments — which it had. Capped, because a runaway buffer must not
            // become a permanent prefix.
            appendAssistantTurn(
                ChatMessage(
                    role: .assistant,
                    content: Self.unresolvedEnvelopeAnchor(result.harmonyBuffer)),
                stepKey: stepKey, to: &conversationMessages)
        }

        if hasToolCalls {
            // Re-stamp so tool calls appear after the assistant/thinking message in timeline
            let restamped = result.resolvedToolCalls.map { call in
                var c = call
                c.createdAt = MonotonicClock.shared.now()
                return c
            }
            await appendToolCalls(stepID: stepID, taskID: taskID, toolCalls: restamped)
        }
    }

    /// Appends `turn` to the wire and, when it qualifies, pushes its WIRE content onto the
    /// step's message-loop ring.
    ///
    /// This is the only production site that appends a `.assistant` `ChatMessage` to the wire
    /// (grep-pinned by `ConversationAppendInvariantTests.testTheWireHasOneAssistantAppendSite`),
    /// which is what makes one push site sufficient (CLAUDE.md #51). Membership is decided by
    /// `ConversationRepairService.qualifiesForMessageLoop` on the message ACTUALLY appended —
    /// so the tool-call branch never qualifies, and the anchor-only branch does whenever the
    /// anchor is non-empty: an anchor turn has content and no tool calls, exactly what the
    /// detector's walk counted before the ring existed. The pushed string is the wire content
    /// (`cleanedContent` plus the optional anchor, or the anchor alone), never
    /// `result.assistantContent`, because the ring must equal the walk over the wire.
    private func appendAssistantTurn(
        _ turn: ChatMessage, stepKey: TaskStepKey, to conversationMessages: inout [ChatMessage]
    ) {
        conversationMessages.append(turn)
        guard ConversationRepairService.qualifiesForMessageLoop(turn),
              let content = turn.content,
              var ring = executionStates[stepKey]?.recentNoToolAssistantContents
        else { return }
        ConversationRepairService.pushMessageLoopContent(content, into: &ring)
        executionStates[stepKey]?.recentNoToolAssistantContents = ring
    }

}
