import Foundation

// MARK: - SSE Event Parser

/// Stateful parser for Server-Sent Events from the LM Studio `/api/v1/chat` endpoint.
/// Tracks `event:` lines across SSE frames and decodes `data:` payloads into typed events.
struct SSEEventParser {

    enum ParsedEvent {
        case contentDelta(String)
        case thinkingDelta(String)
        case chatEnd(responseID: String?, usage: TokenUsage?)
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
                let usage = event.stats.map {
                    TokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens)
                }
                return .chatEnd(responseID: event.responseID, usage: usage)
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
