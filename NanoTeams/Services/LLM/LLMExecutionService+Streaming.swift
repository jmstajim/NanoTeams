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
        var session: LLMSession?
        var tokenUsage: TokenUsage?
    }

    // MARK: - Stream-content helpers

    /// Drops leading Unicode whitespace. Callers gate on
    /// `assistantCollected.isEmpty` so internal and trailing whitespace
    /// are preserved once the first non-whitespace char has been recorded.
    /// Post-commit cleanup (`ModelTokenCleaner.clean`) trims both ends —
    /// this strip only protects the live `SelectableMessageText` preview
    /// from the `[/reasoning]\n\n\n\n…` gap during streaming.
    static func stripLeadingWhitespace(_ s: String) -> String {
        String(s.drop(while: \.isWhitespace))
    }

    // MARK: - LLM Streaming

    /// Executes a single LLM streaming call and collects assistant content, thinking, and tool calls.
    /// Uses inline streaming: pre-creates an LLMMessage at stream start, streams content into it,
    /// and commits final content on completion (or partial content on cancellation).
    func performStreamingCall(
        stepID: String,
        roleForMessage: Role,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        conversationMessages: [ChatMessage],
        session: LLMSession?,
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

        // Pre-create empty LLMMessage for inline streaming (no visual jump on commit)
        if let tid = taskIDForStep(stepID) {
            await delegate.beginStreaming(
                stepID: stepID, messageID: streamingMessageID,
                role: roleForMessage, taskID: tid)
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
            delegate.appendStreamingPreview(
                stepID: stepID, messageID: streamingMessageID, role: roleForMessage, content: delta)
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
        var capturedSession: LLMSession?
        var capturedUsage: TokenUsage?

        /// Commits streaming content (final or partial on cancellation).
        func commitStreamingContent() async {
            flushPendingUI(force: true)
            if let tid = taskIDForStep(stepID) {
                let cleanedContent = ModelTokenCleaner.clean(assistantCollected)
                // Strip `<|...|>` markers from persisted thinking too — some
                // models (qwen-style) emit `<|call|>{...}<|end|>` inside the
                // reasoning channel; the call itself is now extracted by the
                // post-stream thinking scan below, but the disclosure must
                // not surface raw model-internal tokens. Use `stripTokens`
                // (NOT `clean`) so internal whitespace / paragraph breaks
                // in the reasoning prose round-trip — pinned by
                // `testHarmonyEnvelope_pureToolCallAfterReasoning_stripsGapToEmpty`.
                let strippedThinking = ModelTokenCleaner.stripTokens(thinkingCollected)
                // Drop whitespace-only reasoning (some models emit an empty
                // `[reasoning]...[/reasoning]` block with just newlines, OR
                // a reasoning channel containing ONLY a tool-call envelope —
                // post-strip both collapse to whitespace-only) so we don't
                // persist a thinking disclosure that expands to nothing.
                let thinkingToCommit: String? =
                    strippedThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : strippedThinking
                await delegate.commitStreaming(
                    stepID: stepID, taskID: tid,
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
        // Set when the parser detects two identical tool calls in the same stream
        // (canonical `name`+sortedKeys(args) signature). On detection we `break` out
        // of the for-await — the AsyncThrowingStream's `onTermination` handler in
        // `NativeLMStudioClient` cancels the underlying URLSession bytes stream so
        // the model isn't allowed to keep emitting more duplicates. The captured
        // session is dropped (`responseID` only arrives at `chatEnd`, which we
        // never reach here), forcing the next iteration onto the existing
        // stateless fallback path — same code path HTTP 400 already exercises.
        var loopDetected = false
        // Number of Harmony tool-call close markers seen in the buffer so far.
        // Gates the (relatively expensive) `harmonyParser.extractAllToolCalls(...)`
        // re-parse of the whole buffer to fire only once 2+ tool calls could
        // possibly be present — until then dedup is impossible by definition.
        var harmonyCloseCount = 0
        do {
            for try await event in client.streamChat(
                config: config, messages: conversationMessages, tools: tools,
                session: session, logger: networkLogger, stepID: stepID, roleName: roleName)
            {
                if Task.isCancelled { throw CancellationError() }

                if !event.thinkingDelta.isEmpty {
                    thinkingCollected += event.thinkingDelta
                    delegate.appendStreamingThinking(stepID: stepID, content: event.thinkingDelta)
                    delegate.markStreamActivity(stepID: stepID)
                    if !processingProgressCleared {
                        delegate.clearStreamingProcessingProgress(stepID: stepID)
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
                    delegate.updateStreamingProcessingProgress(stepID: stepID, progress: progress)
                }

                if !event.contentDelta.isEmpty {
                    if !processingProgressCleared {
                        delegate.clearStreamingProcessingProgress(stepID: stepID)
                        processingProgressCleared = true
                    }
                    // Mark stream activity even when content lands in
                    // `harmonyBuffer` (invisible to the UI's content preview).
                    // Without this the bubble shows "Waiting" while the
                    // model is actively emitting a long tool-call argument.
                    delegate.markStreamActivity(stepID: stepID)
                    let delta = event.contentDelta
                    if sawHarmonyMarker {
                        harmonyBuffer += delta
                        // Cheap counter increment — only re-extract & dedup once at
                        // least 2 close markers have appeared in the stream (single
                        // tool call has nothing to dedup against).
                        if delta.contains(HarmonyToolCallParser.callMarker) || delta.contains("<|end|>") {
                            harmonyCloseCount += 1
                            if harmonyCloseCount >= 2 {
                                let extracted = harmonyParser.extractAllToolCalls(from: harmonyBuffer)
                                if Self.containsDuplicateToolCalls(extracted) {
                                    loopDetected = true
                                    break
                                }
                            }
                        }
                    } else {
                        uiBuffer += delta
                        pendingUI += delta
                        let harmonyMarkers = HarmonyToolCallParser.harmonyMarkers
                        if harmonyMarkers.contains(where: { uiBuffer.contains($0) }) {
                            sawHarmonyMarker = true
                            harmonyBuffer = uiBuffer
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
                                // Strip leading whitespace from the rewind buffer
                                // too — this is a separate funnel into
                                // `assistantCollected`, so the same gap can
                                // sneak through if the marker arrives in the
                                // same chunk as the `[/reasoning]\n\n\n\n` tail.
                                let preMarker = Self.stripLeadingWhitespace(String(uiBuffer[..<lower]))
                                assistantCollected = preMarker
                                // Rewind the on-screen preview so partial marker
                                // prefixes (e.g. `<`, `<|`) that were flushed by
                                // the time/size heuristic don't linger — see
                                // ModelTokenCleaner.containsModelTokens which only
                                // strips once both `<|` and `|>` are present.
                                delegate.replaceStreamingPreview(
                                    stepID: stepID,
                                    messageID: streamingMessageID,
                                    role: roleForMessage,
                                    content: preMarker
                                )
                            }
                            pendingUI = ""
                            continue
                        }
                        flushPendingUI()
                    }
                }

                if !event.toolCallDeltas.isEmpty {
                    toolAccumulator.absorb(event.toolCallDeltas)
                    // OpenAI-style tool-call deltas don't go through any
                    // visible preview — the UI only renders the call after
                    // the stream ends. Mark activity so "Waiting" flips to
                    // "Generating" while the model emits the JSON args.
                    if !processingProgressCleared {
                        delegate.clearStreamingProcessingProgress(stepID: stepID)
                        processingProgressCleared = true
                    }
                    delegate.markStreamActivity(stepID: stepID)

                    if Self.containsDuplicateToolCalls(toolAccumulator.finalize()) {
                        loopDetected = true
                        break
                    }
                }

                if let s = event.session { capturedSession = s }
                if let u = event.tokenUsage { capturedUsage = u }
            }

            if Task.isCancelled { throw CancellationError() }

            // Clear processing progress (stream completed successfully OR was
            // broken early by loop detection — either way, generation is done
            // from this iteration's perspective).
            delegate.clearStreamingProcessingProgress(stepID: stepID)

            // Commit content streamed so far (full on normal end; partial when
            // we broke out due to `loopDetected`).
            await commitStreamingContent()
        } catch is CancellationError {
            // Commit partial content on cancellation
            delegate.clearStreamingProcessingProgress(stepID: stepID)
            await commitStreamingContent()
            throw CancellationError()
        }

        // Reconstruct tool calls
        var resolvedToolCalls = toolAccumulator.finalize()
        if resolvedToolCalls.isEmpty, sawHarmonyMarker {
            resolvedToolCalls = harmonyParser.extractAllToolCalls(from: harmonyBuffer)
        }
        // Reasoning-channel fallback: some local models (observed: qwen3.6-mlx
        // family) stochastically emit `<|call|>{...}<|end|>` envelopes inside
        // `reasoning.delta` SSE events instead of `chunk.delta` content. Those
        // deltas land in `thinkingCollected` and never reach `harmonyBuffer`.
        // Empirical evidence in
        // `.nanoteams/internal/tasks/0/subtasks/1/runs/0/network_log.json`
        // records #11/#13 (FAIL — call in reasoning) vs #15 (OK — call in
        // content); byte-identical envelope shapes, only the channel differs.
        // Cheap `contains("<|")` gate keeps the hot path on the existing
        // branch — only fires when reasoning text actually carries a marker.
        if resolvedToolCalls.isEmpty, thinkingCollected.contains("<|") {
            let fromThinking = harmonyParser.extractAllToolCalls(from: thinkingCollected)
            if !fromThinking.isEmpty {
                resolvedToolCalls = fromThinking
            }
        }

        // Loop break: drop later occurrences of any duplicated (name, args) signature
        // — only the first instance of each is kept and executed. Drop the captured
        // session so the next iteration sends stateless (full conversation + system
        // prompt). `capturedSession` is normally nil here anyway because `responseID`
        // only arrives at `chatEnd` which we never reached, but we defensively force
        // nil to keep the contract explicit.
        if loopDetected {
            resolvedToolCalls = Self.deduplicateToolCalls(resolvedToolCalls)
            capturedSession = nil
        }

        return StreamingResult(
            assistantContent: assistantCollected,
            thinkingContent: thinkingCollected,
            resolvedToolCalls: resolvedToolCalls,
            sawHarmonyMarker: sawHarmonyMarker,
            harmonyBuffer: harmonyBuffer,
            session: capturedSession,
            tokenUsage: capturedUsage
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
    /// Hot-path optimization: with fewer than 2 calls there can be no duplicate, so we
    /// short-circuit BEFORE doing any JSON parsing — this matters because the streaming
    /// loop calls us on every `toolCallDeltas` event (potentially thousands per stream)
    /// and a single tool call's args can grow into the hundreds of KB. Without the
    /// short-circuit, every delta would re-parse and re-canonicalize the entire growing
    /// args blob on the main thread.
    ///
    /// When 2+ calls are present we first try a raw `(name, argumentsJSON)` string
    /// compare — most observed loops emit byte-identical args, so this fast path catches
    /// them without JSON work. Only if the raw fast path doesn't hit do we fall back to
    /// canonicalized comparison (handles whitespace / key-order differences).
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

    // MARK: - Post-Stream Processing

    /// Appends the assistant/tool-call messages to the conversation and persisted LLM log.
    /// Returns `.completed` if the LLM signaled task completion, `nil` otherwise.
    func processStreamingResult(
        _ result: StreamingResult,
        stepID: String,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop? {
        let hasContent = !result.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasToolCalls = !result.resolvedToolCalls.isEmpty

        // Append assistant message to in-memory conversation for session slicing.
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
                conversationMessages.append(
                    ChatMessage(
                        role: .assistant,
                        content: cleanedContent,
                        toolCalls: toolCallMessages
                    ))
            } else {
                conversationMessages.append(
                    ChatMessage(role: .assistant, content: cleanedContent))
            }
        } else {
            // The model produced a turn that yields no assistant content and no resolved
            // tool calls — typically a Harmony tool-call envelope the parser consumed but
            // couldn't resolve (malformed JSON). The turn DID happen and is in the server's
            // stateful response chain (store:true + previous_response_id). Record an anchor
            // assistant turn so the next stateful slice — lastIndex(where: .assistant) in
            // runOneLLMToolIteration — advances past the already-delivered tool result(s)
            // and prior retry nudges. Without this, the slice re-sends the previous tool
            // result and every accumulated nudge on each malformed iteration (chain
            // corruption + exponential input growth; CLAUDE.md "Stateful Session
            // Invariants" #2). conversationMessages is in-memory slicing state only — any
            // user-visible LLMMessage/StepMessage commit is owned by commitStreaming() (the
            // streaming LLMMessage is pre-created at stream start), so appending this anchor
            // has no UI or persistence effect, and in stateful mode the anchor is never
            // transmitted (NativeLMStudioClient+RequestBuilder skips .assistant on
            // continuations).
            conversationMessages.append(ChatMessage(role: .assistant, content: nil))
        }

        if hasToolCalls {
            // Re-stamp so tool calls appear after the assistant/thinking message in timeline
            let restamped = result.resolvedToolCalls.map { call in
                var c = call
                c.createdAt = MonotonicClock.shared.now()
                return c
            }
            await appendToolCalls(stepID: stepID, toolCalls: restamped)
        }

        return nil
    }

}
