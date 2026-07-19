import Foundation

/// Pure classifier for "LM Studio refused to load the model because the machine
/// is out of resources". Sibling of `ContextOverflowClassifier`; the two must
/// never overlap (pinned by a negative test on each side).
///
/// Why it exists: this failure NEVER clears by waiting, but it arrives as an
/// HTTP 500, and `LLMRetryPolicy` classifies every 5xx as transient without
/// inspecting the body. Combined with `LLMConstants.defaultMaxLLMRetries = 0`
/// (unlimited) that produced an unbounded 0.1 Hz retry loop: the step never
/// reached `.failed`, so the user never got an error bubble — just an "attempt
/// N" line forever.
///
/// The verbatim body observed in production (2026-07-19, switching the global
/// model to `google/gemma-4-26b-a4b` while two chat models were already
/// resident):
/// ```
/// {"error":{"type":"model_load_failed","message":"Failed to load LLM
///  'google/gemma-4-26b-a4b': Error: Model loading was stopped due to
///  insufficient system resources. Continuing to load the model would likely
///  overload your system and cause it to freeze. If you think this is
///  incorrect, you can adjust the model loading guardrails in settings."}}
/// ```
nonisolated enum ModelLoadFailureClassifier {

    /// The envelope's `type` field. Far more stable than the prose, which is
    /// vendor UI copy and can be reworded between LM Studio releases.
    private static let strongSignature = "model_load_failed"

    /// A weak marker ("load") is only trusted alongside one of these, so an
    /// unrelated error mentioning loading (e.g. "failed to load file") is NOT
    /// misclassified as a resource exhaustion.
    private static let loadMarker = "load"
    private static let qualifiers = [
        "insufficient",
        "overload",
        "guardrail",
        "out of memory",
        "not enough memory",
    ]

    static func isInsufficientResources(_ error: Error) -> Bool {
        guard let message = extractMessage(error) else { return false }
        return matches(message)
    }

    /// Exposed for direct message testing (the HTTP body arrives here).
    static func matches(_ rawMessage: String) -> Bool {
        let message = rawMessage.lowercased()
        if message.contains(strongSignature) { return true }
        guard message.contains(loadMarker) else { return false }
        return qualifiers.contains { message.contains($0) }
    }

    /// Pulls the model name out of `Failed to load LLM 'X'` so the user-facing
    /// message can name what failed instead of echoing the whole envelope.
    static func quotedModelName(in rawMessage: String) -> String? {
        guard let open = rawMessage.firstIndex(of: "'") else { return nil }
        let afterOpen = rawMessage.index(after: open)
        guard afterOpen < rawMessage.endIndex,
              let close = rawMessage[afterOpen...].firstIndex(of: "'")
        else { return nil }
        let name = String(rawMessage[afterOpen..<close])
        return name.isEmpty ? nil : name
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
