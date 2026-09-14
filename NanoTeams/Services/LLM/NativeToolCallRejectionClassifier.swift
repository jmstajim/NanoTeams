import Foundation

/// Tells a server's "I could not parse the model's tool call" apart from every other
/// mid-stream error, for a `.native` request.
///
/// Ollama's llama-server constrains a native call with a lazy grammar and, when the model's
/// text still does not fit it, sends an error CHUNK on the already-open 200 stream instead of
/// a transport failure (llama.cpp #24807: "does not match the expected peg-native format").
/// Reaching `LLMExecutionService+StepLifecycle` as a plain `providerError` that error was
/// retryable, so the step resent the identical prompt up to `maxLLMRetries` times for a
/// defect no resend can address — the model's own turn.
///
/// Three rules, in order. A server OUTAGE wording — the model-load family
/// (`ModelLoadFailureClassifier`), a runner that died mid-reply, an unload — is never a
/// rejection, whatever streamed before it: those are the server's health, and the retry
/// policy owns them. Then the documented substring. Then the signal that survives a reworded
/// message: generated tokens BEFORE the error, on a request that DECLARED tools — a server
/// that has already streamed thinking or a call and then errors is reporting on the reply,
/// but only a request carrying `tools` armed a grammar there was a call to reject; a
/// tool-less request stamped `.native` (the auto-answer, a meeting speaker with no tools) has
/// no call to reject and keeps the old meaning. Nothing here names a model or a family — the
/// classifier reads what the server said, when, and what the request asked for. The
/// unconditional timing rule turned an Ollama runner crash after the first token into three
/// "your call syntax is wrong" nudges (review of 2026-09-13).
///
/// The exact string is documented from the upstream issue and pinned on it; the first field
/// occurrence is to be recorded here (DEBTS). `nonisolated` because the app target defaults
/// types to `@MainActor`; pure value-in / value-out.
nonisolated enum NativeToolCallRejectionClassifier {

    /// Lowercased substrings of a server outage reported on an open stream — checked BEFORE
    /// everything else. Server wordings, not model ones: Ollama's runner death and LM Studio's
    /// mid-reply unload, as each spells it.
    static let outagePhrases: [String] = [
        "error was encountered while running the model",
        "model runner has unexpectedly stopped",
        "out of memory",
        "model unloaded",
        "model is not loaded",
    ]

    /// Lowercased substrings of a rejection. Kept short and DISTINCTIVE rather than
    /// exhaustive: a false negative costs a retry loop the step already bounds, a false
    /// positive would turn a real outage into a nudge to the model.
    static let rejectionPhrases: [String] = [
        "peg-native",
        "does not match the expected",
        "failed to parse tool call",
        "invalid tool call",
    ]

    static func isRejection(message: String, sawGeneration: Bool, toolsDeclared: Bool) -> Bool {
        let lowered = message.lowercased()
        if ModelLoadFailureClassifier.matches(message)
            || outagePhrases.contains(where: { lowered.contains($0) })
        {
            return false
        }
        if rejectionPhrases.contains(where: { lowered.contains($0) }) { return true }
        return sawGeneration && toolsDeclared
    }
}
