import Foundation

/// Pure classifier for "the prompt didn't fit the model's context window"
/// errors from LM Studio. Used by `WorkFolderContextService` to decide whether
/// a failed generation is worth retrying with a smaller (re-trimmed) prompt.
///
/// The verbatim message observed in production (folder CastleSurvivors) is:
/// *"The number of tokens to keep from the initial prompt is greater than the
/// context length. Try to load the model with a larger context length, or
/// provide a shorter input"*. It arrives either mid-stream as an SSE `error`
/// event (`LLMClientError.providerError`) or, if the server rejects before the
/// stream opens, as a non-2xx body (`LLMClientError.badHTTPStatus`).
nonisolated enum ContextOverflowClassifier {

    /// A strong, unambiguous signature — the exact LM Studio phrasing.
    private static let strongSignature = "context overflow"

    /// A weaker signal ("context length") that we only trust when paired with
    /// one of these qualifiers, so unrelated errors mentioning "context"
    /// (e.g. "context deadline exceeded") are NOT misclassified.
    private static let contextLengthMarker = "context length"
    private static let qualifiers = [
        "greater than",
        "exceed",
        "larger",
        "shorter input",
        "tokens to keep",
    ]

    static func isContextOverflow(_ error: Error) -> Bool {
        guard let message = extractMessage(error) else { return false }
        return matches(message)
    }

    /// Exposed for direct message testing (the SSE/HTTP text arrives here).
    static func matches(_ rawMessage: String) -> Bool {
        let message = rawMessage.lowercased()
        if message.contains(strongSignature) { return true }
        guard message.contains(contextLengthMarker) else { return false }
        return qualifiers.contains { message.contains($0) }
    }

    private static func extractMessage(_ error: Error) -> String? {
        switch error {
        case let LLMClientError.providerError(message):
            return message
        case let LLMClientError.badHTTPStatus(_, body):
            return body
        default:
            return nil
        }
    }
}
