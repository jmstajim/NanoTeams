import Foundation

/// What the app can honestly say about the window between "request sent" and
/// "first generated token" — the phase the server spends loading the model and
/// prefilling the prompt.
///
/// Two cases, because the two providers can say different amounts and each must
/// say the most it honestly knows:
///
/// - `.indeterminate` — a request is in flight and nothing has come back yet.
///   Set by `LLMExecutionService.performStreamingCall` right after
///   `beginStreaming`, for EVERY provider. This is a fact the app owns (it just
///   issued the send), not an inference about the server.
/// - `.fraction` — the server itself narrated its progress. Today only LM Studio
///   does (`prompt_processing.start/.progress/.end` SSE frames, parsed by
///   `SSEEventParser` and carried on the wire as `StreamEvent.processingProgress`).
///   It REFINES an existing `.indeterminate`; it is never synthesized locally.
///
/// Ollama has no third state to offer: `OllamaClient.streamChat` yields nothing
/// at all between the send and the first NDJSON line carrying a token
/// (`prompt_eval_duration` / `load_duration` arrive only in the terminal
/// `done:true` chunk, i.e. retrospectively). An estimated percentage was
/// considered and rejected — it would be the product of two estimates whose
/// measured errors are 0.45×–2.58× (language-dependent, see `ContextBudgetPolicy`)
/// and up to 6.2× (`PrefixCachePolicy.estimatedColdPrefillMsPerToken`, which its
/// own doc-comment restricts to display use, never a gate), and both are worst on
/// the FIRST request of a conversation where no measurement exists yet.
///
/// Deliberately NOT a wire type: `StreamEvent.processingProgress` stays `Double?`
/// so the provider clients and their parsers are untouched. The service maps the
/// wire `Double` into `.fraction` as it forwards.
nonisolated enum PromptProcessingStatus: Hashable, Sendable {
    /// A request is in flight; this provider does not narrate its prefill.
    case indeterminate
    /// Server-reported prompt-processing progress, 0.0…1.0.
    case fraction(Double)
}
