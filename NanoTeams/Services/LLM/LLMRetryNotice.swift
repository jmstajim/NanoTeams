import Foundation

/// The notice a step posts while it retries a model request that failed — the one live bubble of
/// the feed (`TaskMutationService.appendOrReplaceRetryNotice`) and the external agent's
/// `task_status.steps[].llm_retry`.
///
/// One composer, because the sentence joins text it does not own: the error's description, which
/// Foundation already ends with a period («Could not connect to the server.»). Composed inline in
/// the retry loop until 2026-11-12 (F6 L5), it read «…server.. Retrying in 10s…» on every live
/// retry against a server that was down.
nonisolated enum LLMRetryNotice {

    /// `attempt` of `maxRetries` (`0` = unlimited, printed without a bound), the error the server
    /// failed with, and the delay before the next attempt.
    /// runtime-prompt
    static func text(attempt: Int, maxRetries: Int, errorDescription: String, delaySeconds: UInt64) -> String {
        let bound = maxRetries > 0 ? "/\(maxRetries)" : ""
        return "\(LLMConstants.llmServerErrorRetryNotePrefix) \(attempt)\(bound)): "
            + "\(sentence(errorDescription)) Retrying in \(delaySeconds)s…"
    }

    /// `text` ended as a sentence: its own closing mark kept, a period added only where it has
    /// none, surrounding whitespace dropped.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return Self.sentenceEnds.contains(last) ? trimmed : trimmed + "."
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
}
