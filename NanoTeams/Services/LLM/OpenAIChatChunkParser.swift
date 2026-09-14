import Foundation

// MARK: - OpenAI Chat Chunk Parser

/// Stateful parser for the OpenAI-shaped `/v1/chat/completions` stream LM Studio serves:
/// SSE frames whose every payload is `data: <json>` and whose terminator is `data: [DONE]`.
/// There are no `event:` lines — the chunk's own fields say what it carries.
///
/// Chunk shapes, all measured on LM Studio 0.4.21 (2026-09-13, `probes/*.sse`):
///   `{"choices":[{"delta":{"role":"assistant","reasoning_content":"…"}}]}` — reasoning
///   `{"choices":[{"delta":{"content":"…"}}]}` — prose
///   `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"…","type":"function","function":{"name":"…","arguments":""}}]}}]}`
///   `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{…}"}}]}}]}` — the pieces
///   `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` — or `"stop"` / `"length"`
///   `{"choices":[],"usage":{"prompt_tokens":…,"completion_tokens":…,"completion_tokens_details":{"reasoning_tokens":…}}}`
///
/// Reasoning routing: the server puts reasoning on `reasoning_content` (its own default app
/// setting) or `reasoning` (gpt-oss-class models) — both read. When it puts NONE there — the
/// setting off, or a model the build has no parser for — reasoning arrives inline in
/// `content` wrapped in `<think>…</think>`, and `ThinkTagSplitter` re-routes it exactly as
/// the two sibling parsers do (`ThinkTagRoutingParityTests` holds all three side by side).
nonisolated struct OpenAIChatChunkParser {

    enum ParsedEvent: Equatable {
        case contentDelta(String)
        case thinkingDelta(String)
        case toolCallDeltas([StreamEvent.ToolCallDelta])
        /// `finish_reason`, verbatim — `stop`, `tool_calls`, `length`.
        case finish(reason: String)
        case usage(TokenUsage, reasoningTokens: Int?)
        case error(String)
        /// `data: [DONE]`.
        case done
    }

    private let decoder = JSONCoderFactory.makeWireDecoder()
    private var splitter = ThinkTagSplitter()

    /// Parse one line of the stream. Blank lines and non-`data:` lines are SSE framing and
    /// yield nothing; a `data:` payload that does not decode is transport noise and yields
    /// nothing either, exactly as the NDJSON parser treats an undecodable line.
    mutating func parse(line: String) -> [ParsedEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" {
            return route(splitter.flush()) + [.done]
        }
        guard let chunk = try? decoder.decode(
            OpenAICompatLMStudioClient.ChatCompletionChunk.self, from: Data(payload.utf8))
        else { return [] }

        if let error = chunk.error {
            return [.error(error.message ?? "Stream error")]
        }

        var events: [ParsedEvent] = []
        for choice in chunk.choices {
            if let delta = choice.delta {
                if let reasoning = delta.reasoningDelta, !reasoning.isEmpty {
                    events.append(.thinkingDelta(reasoning))
                }
                if let content = delta.content, !content.isEmpty {
                    events.append(contentsOf: route(splitter.feed(content)))
                }
                if let calls = delta.toolCalls, !calls.isEmpty {
                    events.append(.toolCallDeltas(calls.enumerated().map { offset, call in
                        StreamEvent.ToolCallDelta(
                            index: call.index ?? offset,
                            id: call.id,
                            name: call.function?.name,
                            argumentsDelta: call.function?.arguments)
                    }))
                }
            }
            if let reason = choice.finishReason, !reason.isEmpty {
                // Drain a held-back tag prefix before the turn is declared over.
                events.append(contentsOf: route(splitter.flush()))
                events.append(.finish(reason: reason))
            }
        }
        if let usage = chunk.usage,
           usage.promptTokens != nil || usage.completionTokens != nil
        {
            events.append(.usage(
                TokenUsage(
                    inputTokens: usage.promptTokens ?? 0,
                    outputTokens: usage.completionTokens ?? 0),
                reasoningTokens: usage.reasoningTokens))
        }
        return events
    }

    /// Drain at transport end — a stream that dies without `[DONE]` must not lose the
    /// splitter's held-back tag prefix.
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
