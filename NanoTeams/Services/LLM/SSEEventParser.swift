import Foundation

// MARK: - SSE Event Parser

/// Stateful parser for Server-Sent Events from the LM Studio `/api/v1/chat` endpoint.
/// Tracks `event:` lines across SSE frames and decodes `data:` payloads into typed events.
nonisolated struct SSEEventParser {

    enum ParsedEvent {
        case contentDelta(String)
        case thinkingDelta(String)
        /// `generationTokensPerSecond` is LM Studio's `tokens_per_second` — server-measured
        /// DECODE rate, verbatim, the counterpart of Ollama's `generationNs` on the other side
        /// of the same fact. `reasoningOutputTokens` is how much of the output the server
        /// attributes to thinking. Both are recorded as sent; no threshold and no guard is
        /// applied here, exactly as none is applied to `modelLoadMs`.
        case chatEnd(
            usage: TokenUsage?,
            prefill: ServerPrefillReport?,
            generationTokensPerSecond: Double?,
            reasoningOutputTokens: Int?)
        case error(String)
        case processingProgress(Double)
        case ignored
    }

    private var currentEventType: String?
    private let decoder = JSONCoderFactory.makeWireDecoder()

    /// Parse a single SSE line. Returns `nil` for non-data lines (e.g. `event:` type headers).
    /// Returns `.ignored` for unhandled event types.
    mutating func parse(line: String) -> ParsedEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Track SSE event type from `event: X` lines
        if trimmed.hasPrefix("event:") {
            currentEventType = trimmed
                .dropFirst(6)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }

        guard trimmed.hasPrefix("data:") else { return nil }

        let dataString = trimmed
            .dropFirst(5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dataString.isEmpty else { return nil }

        let data = Data(dataString.utf8)

        switch currentEventType ?? "" {
        case "message.delta":
            if let event = try? decoder.decode(NativeLMStudioClient.MessageDeltaEvent.self, from: data) {
                let content = event.content ?? ""
                if !content.isEmpty { return .contentDelta(content) }
            }
            return .ignored

        case "reasoning.delta":
            if let event = try? decoder.decode(NativeLMStudioClient.MessageDeltaEvent.self, from: data) {
                let content = event.content ?? ""
                if !content.isEmpty { return .thinkingDelta(content) }
            }
            return .ignored

        case "chat.end":
            if let event = try? decoder.decode(NativeLMStudioClient.ChatEndEvent.self, from: data) {
                let stats = event.stats
                // Built only when the server actually counted something. A `stats` object
                // carrying no token keys must NOT become `TokenUsage(0, 0)`: downstream a
                // fabricated zero is indistinguishable from a measurement, and it is what turns
                // a benchmark run that measured nothing into a finished run of dashes. Ollama's
                // parser guards the same corner.
                let usage: TokenUsage? =
                    (stats?.inputTokens == nil && stats?.outputTokens == nil)
                        ? nil
                        : TokenUsage(
                            inputTokens: stats?.inputTokens ?? 0,
                            outputTokens: stats?.outputTokens ?? 0)
                // `prefillNs` stays nil on this provider: LM Studio reports
                // `time_to_first_token_seconds`, which includes queue time, and parallel roles
                // against one model are this app's normal mode — so a queued warm request would
                // be indistinguishable from a cold one. Only the model-load signal, which needs
                // no calibration, is taken from here.
                let prefill = stats.map {
                    ServerPrefillReport(
                        modelLoadMs: $0.modelLoadTimeSeconds.map { $0 * 1000 },
                        promptTokens: $0.inputTokens)
                }
                return .chatEnd(
                    usage: usage,
                    prefill: prefill.flatMap { $0.isEmpty ? nil : $0 },
                    generationTokensPerSecond: stats?.tokensPerSecond,
                    reasoningOutputTokens: stats?.reasoningOutputTokens)
            }
            return .ignored

        case "error":
            if let event = try? decoder.decode(NativeLMStudioClient.ErrorEvent.self, from: data) {
                return .error(event.message ?? "Stream error")
            }
            return .error("Stream error")

        case "prompt_processing.start":
            return .processingProgress(0.0)

        case "prompt_processing.progress":
            if let event = try? decoder.decode(NativeLMStudioClient.PromptProcessingProgressEvent.self, from: data) {
                return .processingProgress(event.progress)
            }
            return .ignored

        case "prompt_processing.end":
            return .processingProgress(1.0)

        default:
            // Skip: chat.start, model_load.*,
            //       reasoning.start/end, message.start/end,
            //       tool_call.* (MCP server-side events, not client tools)
            return .ignored
        }
    }
}
