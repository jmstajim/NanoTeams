import Foundation

/// The JSON body a benchmark sample posts, rendered for reading.
///
/// The prompt text answers "what is the model asked"; this answers "what is actually sent". They
/// are different questions, and the second one is the only one that can prove the negatives the
/// benchmark rests on — no system prompt, no tools, no temperature, an output ceiling. Those were
/// documented in a comment and asserted in a facts line; here they are visible as bytes.
///
/// Built by calling the SAME `buildRequest` the two clients call and the same wire encoder, so
/// "this is what is sent" is true by construction rather than by care. Nothing here re-spells a
/// request shape, and nothing re-spells an endpoint path — a second copy of either is where the
/// screen and the wire would drift apart.
nonisolated enum BenchmarkWireBody {

    /// The request body for one sample, pretty-print-free.
    ///
    /// Compact on purpose: pretty-printing produces a different byte sequence than the wire, and a
    /// pane whose claim is "byte-for-byte" cannot reformat what it shows.
    ///
    /// `nil` only when the body cannot be encoded at all — reachable through a non-finite
    /// temperature, which `JSONEncoder` refuses. The caller says so rather than showing an empty
    /// pane that reads as "nothing is sent".
    static func json(config: LLMConfig, nonce: String = BenchmarkPrompt.noncePlaceholder) -> String? {
        let messages = BenchmarkPrompt.messages(nonce: nonce)
        let encoder = JSONCoderFactory.makeWireEncoder()
        let data: Data?
        switch config.provider {
        case .lmStudio:
            data = try? encoder.encode(
                NativeLMStudioClient.buildRequest(config: config, messages: messages, tools: []))
        case .ollama:
            data = try? encoder.encode(
                OllamaClient.buildRequest(config: config, messages: messages, tools: []))
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Shown in place of the body when it cannot be rendered. Never an empty pane: "nothing could
    /// be encoded" and "nothing is sent" must not look the same.
    static let unavailable =
        "This request could not be encoded, so there is nothing to show that would be true."
}
