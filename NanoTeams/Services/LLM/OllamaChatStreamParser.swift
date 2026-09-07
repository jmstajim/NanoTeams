import Foundation

// MARK: - Ollama Chat Stream Parser

/// Stateful parser for Ollama's `/api/chat` streaming responses — NDJSON, one
/// JSON object per line (not SSE; there are no `event:` / `data:` frames).
///
/// Chunk shape:
///   `{"model":"…","created_at":"…","message":{"role":"assistant","content":"…","thinking":"…"},"done":false}`
/// Final chunk:
///   `{"model":"…","done":true,"done_reason":"stop","prompt_eval_count":N,"eval_count":M,…}`
/// Error (mid-stream or as the whole body):
///   `{"error":"…"}`
///
/// Reasoning routing: newer Ollama builds separate reasoning into
/// `message.thinking` for models whose chat templates they know. For models
/// where they don't, reasoning arrives inline in `content` wrapped in
/// `<think>…</think>` tags — `ThinkTagSplitter` (its own file; `SSEEventParser`
/// runs the same one on LM Studio's `message.delta`) re-routes those spans to
/// the thinking channel so downstream consumers (thinking disclosure, loop
/// detection, `HarmonyToolCallParser`) see one content/thinking split on both
/// providers.
nonisolated struct OllamaChatStreamParser {

    /// Everything the terminal `done:true` chunk said, as one value.
    ///
    /// A struct rather than a widening list of associated values. `chatEnd` carried three and
    /// would now carry five, and every growth silently reshapes every destructuring
    /// `case .chatEnd(_, let prefill, _)` in the tree while wildcard matches keep compiling
    /// (CLAUDE.md #25). Named fields also make the difference between reading `nil, nil, 42` and
    /// reading what the 42 is.
    ///
    /// The parser applies no threshold and no guard to any of these — recording what the server
    /// actually said is what lets a policy be re-derived from a real log later. A zero is carried
    /// through as a zero.
    struct TerminalReport: Equatable {
        var usage: TokenUsage?
        var prefill: ServerPrefillReport?
        /// Ollama `eval_duration` — server-measured DECODE time.
        var generationNs: Double?
        /// Ollama `total_duration` — the server's own clock on the whole request, the only
        /// cross-check the app's end-to-end measurement has.
        var totalNs: Double?
        /// Ollama `done_reason` — `"stop"` or `"length"`. The direct answer to "was this cut off
        /// at the token ceiling", which nothing else on the wire gives.
        var doneReason: String?

        init(
            usage: TokenUsage? = nil,
            prefill: ServerPrefillReport? = nil,
            generationNs: Double? = nil,
            totalNs: Double? = nil,
            doneReason: String? = nil
        ) {
            self.usage = usage
            self.prefill = prefill
            self.generationNs = generationNs
            self.totalNs = totalNs
            self.doneReason = doneReason
        }
    }

    enum ParsedEvent: Equatable {
        case contentDelta(String)
        case thinkingDelta(String)
        case chatEnd(TerminalReport)
        case error(String)
    }

    private let decoder = JSONCoderFactory.makeWireDecoder()
    private var splitter = ThinkTagSplitter()

    /// Parse one NDJSON line. A single line can produce several events (e.g. a
    /// content chunk that closes a `<think>` span yields a thinking delta AND a
    /// content delta). Blank / non-JSON lines are skipped — NDJSON has no
    /// comment or header frames, so anything undecodable is transport noise.
    mutating func parse(line: String) -> [ParsedEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let chunk = try? decoder.decode(OllamaClient.ChatChunk.self, from: Data(trimmed.utf8)) else {
            return []
        }
        if let error = chunk.error { return [.error(error)] }

        var events: [ParsedEvent] = []
        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
            events.append(.thinkingDelta(thinking))
        }
        if let content = chunk.message?.content, !content.isEmpty {
            events.append(contentsOf: route(splitter.feed(content)))
        }
        if chunk.done == true {
            // Drain any held-back partial tag prefix BEFORE the end event so
            // no trailing text is lost on the final line.
            events.append(contentsOf: route(splitter.flush()))
            let usage: TokenUsage?
            if chunk.promptEvalCount != nil || chunk.evalCount != nil {
                usage = TokenUsage(
                    inputTokens: chunk.promptEvalCount ?? 0,
                    outputTokens: chunk.evalCount ?? 0)
            } else {
                usage = nil
            }
            // Ollama is the provider that CAN answer "did you actually re-prefill":
            // `prompt_eval_duration` is server-measured and excludes decode.
            let prefill = ServerPrefillReport(
                modelLoadMs: chunk.loadDurationNs.map { $0 / 1_000_000 },
                prefillNs: chunk.promptEvalDurationNs,
                promptTokens: chunk.promptEvalCount)
            events.append(.chatEnd(TerminalReport(
                usage: usage,
                prefill: prefill.isEmpty ? nil : prefill,
                generationNs: chunk.evalDurationNs,
                totalNs: chunk.totalDurationNs,
                doneReason: chunk.doneReason)))
        }
        return events
    }

    /// Drain at transport end — covers streams that die without a `done:true`
    /// line (connection drop): the splitter's held-back tag prefix must not
    /// silently vanish.
    mutating func finalize() -> [ParsedEvent] {
        route(splitter.flush())
    }

    private func route(_ split: ThinkTagSplitter.Output) -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        if !split.thinking.isEmpty { events.append(.thinkingDelta(split.thinking)) }
        if !split.content.isEmpty { events.append(.contentDelta(split.content)) }
        return events
    }
}
