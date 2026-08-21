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
/// `<think>…</think>` tags — `ThinkTagSplitter` re-routes those spans to the
/// thinking channel so downstream consumers (thinking disclosure, loop
/// detection, `HarmonyToolCallParser`) see the same content/thinking split as
/// the LM Studio path.
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

// MARK: - Think Tag Splitter

/// Re-routes an inline leading `<think>…</think>` span (emitted by reasoning
/// models whose templates Ollama doesn't parse server-side) from the content
/// channel to the thinking channel. Stateful because a tag can split across
/// stream chunks (`"<th"` + `"ink>"`): a chunk's trailing characters are held
/// back while they are still a viable prefix of the next expected tag.
///
/// The open tag is recognized ONLY before any non-whitespace content has been
/// emitted (reasoning models think first, answer second). Once real content
/// has flowed, a literal `<think>` in prose or code stays content — this
/// protects Harmony tool-call envelopes from being split across channels
/// mid-JSON, which would corrupt `HarmonyToolCallParser` extraction.
nonisolated struct ThinkTagSplitter {

    struct Output: Equatable {
        var content: String = ""
        var thinking: String = ""
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var inThink = false
    private var hasEmittedContent = false
    private var pending = ""

    mutating func feed(_ chunk: String) -> Output {
        // Fast path: past the (optional) leading think block, no further tags
        // are recognized — pass everything straight through. `pending` can
        // hold a previously held-back prefix whose tag window just closed.
        if !inThink && hasEmittedContent {
            let text = pending + chunk
            pending = ""
            var out = Output()
            emit(text, into: &out)
            return out
        }

        pending += chunk
        var out = Output()
        while true {
            // The open-tag window closes the moment real content flows — also
            // WITHIN a single chunk. Checked at the top of every loop pass
            // (not just at feed() entry) so "prose <think>…" in one buffered
            // chunk keeps the literal tag as content exactly like the same
            // bytes split across two chunks would — semantics must not depend
            // on how a server/proxy frames the deltas.
            if !inThink && hasEmittedContent {
                emit(pending, into: &out)
                pending = ""
                break
            }
            let tag = inThink ? Self.closeTag : Self.openTag
            if let range = pending.range(of: tag) {
                let before = String(pending[..<range.lowerBound])
                if !inThink && !before.allSatisfy(\.isWhitespace) {
                    // Real content precedes the tag in this same buffer — the
                    // tag is literal prose/code, not a think opener.
                    emit(pending, into: &out)
                    pending = ""
                    break
                }
                emit(before, into: &out)
                pending = String(pending[range.upperBound...])
                inThink.toggle()
                continue
            }
            // No full tag: emit everything except a trailing viable prefix of
            // the expected tag, which stays buffered for the next chunk.
            let holdCount = trailingPrefixLength(of: tag, in: pending)
            let emitEnd = pending.index(pending.endIndex, offsetBy: -holdCount)
            emit(String(pending[..<emitEnd]), into: &out)
            pending = String(pending[emitEnd...])
            break
        }
        return out
    }

    /// Emit whatever is buffered (stream end). An unfinished tag prefix is
    /// surfaced verbatim on the current channel rather than dropped.
    mutating func flush() -> Output {
        var out = Output()
        emit(pending, into: &out)
        pending = ""
        return out
    }

    private mutating func emit(_ text: String, into out: inout Output) {
        guard !text.isEmpty else { return }
        if inThink {
            out.thinking += text
        } else {
            out.content += text
            // Whitespace before the opening tag must not close the tag window
            // (models emit `\n<think>` on occasion).
            if !text.allSatisfy(\.isWhitespace) { hasEmittedContent = true }
        }
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `tag`.
    private func trailingPrefixLength(of tag: String, in s: String) -> Int {
        let maxLen = min(tag.count - 1, s.count)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            if tag.hasPrefix(s.suffix(len)) { return len }
        }
        return 0
    }
}
