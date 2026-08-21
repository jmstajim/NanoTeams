import Foundation

/// When the warm-up sample has done its job and the rest of its answer is pure waiting.
///
/// The warm-up exists to pay what only the FIRST request pays: loading the model where the app is
/// not allowed to load it explicitly (Ollama owns its own residency), materialising the KV cache
/// for the prompt (`BenchmarkPrompt.measuredPromptTokens`), and compiling or warming whatever
/// the engine compiles on its first decode. Every one of those is behind us once the model has
/// produced tokens — nothing later in
/// the answer is a cost the measured samples would otherwise inherit.
///
/// What it is NOT for is producing an answer. Nobody reads it, `BenchmarkMetricsPolicy` drops it
/// from every median, and until `BenchmarkPrompt.maxOutputTokens` shipped nothing bounded its
/// length at all — a thinking model decided on its own how long the sample ran. Measured on
/// LM Studio 0.4.21 / qwen3.5-9b in that regime, read to the end: **233 seconds, 12 040 output
/// tokens, 11 561 of them reasoning** — four minutes of generation whose only destination was the
/// discard pile, against a prompt whose prefill takes a few seconds. The ceiling now cuts that to
/// 512 tokens, which is still ten seconds of answer nobody reads.
///
/// So the runner stops reading, and the stream's `onTermination` cancels the request. That is the
/// same seam in-stream loop detection already uses (`LLMExecutionService+Streaming`), on the same
/// two clients, for the same reason: the model must not be left emitting tokens nobody will read.
///
/// The cost of stopping is that no terminal frame arrives, so a truncated warm-up reports no token
/// counts and no server-side model-load time. Both were already excluded from every figure the
/// benchmark shows — see `GenerationBenchmarkRunner`, which takes residency from the preparer that
/// looked at the server directly rather than inferring it from the warm-up's timings.
nonisolated enum BenchmarkWarmUpPolicy {

    /// Generation deltas to see before the warm-up is considered finished.
    ///
    /// One would be defensible — the model is loaded, the prompt is in the KV cache, and the first
    /// decode step is the one that compiles a decode graph. Sixteen is a margin bought at roughly
    /// a third of a second on a 50 tok/s model, which is nothing beside the 233 seconds it
    /// replaces, and it means the decode loop is unambiguously in steady state rather than one
    /// token past its start.
    static let sufficientDeltas = 16

    /// The hard ceiling on a warm-up, enforced by cancelling the request.
    ///
    /// `sufficientDeltas` is the normal exit and fires within a second of the first token. This is
    /// the OTHER exit, for the case where that never happens: a model still loading, a prefill
    /// that will not end, a server that accepted the request and went quiet. `maxOutputTokens`
    /// bounds how much the model may WRITE and nothing else, so a request that never reaches its
    /// first token is still bounded by nothing the app controls. That gap is what this is for.
    ///
    /// Ten seconds is chosen against the measured shape of the work it bounds: the prefill of
    /// `BenchmarkPrompt.measuredPromptTokens` runs a few seconds at the ~450 tok/s this prompt was
    /// sized to reach, so a warm-up
    /// that has not produced tokens by then is not one worth waiting out.
    ///
    /// A warm-up cut here has done less than one that reached `sufficientDeltas` — it may have
    /// stopped mid-load. That is recorded, not hidden: the row keeps whatever it managed to
    /// measure, and its absent token counts are what say how far it got.
    static let deadline: Duration = .seconds(10)

    /// Whether a warm-up that has produced this many deltas can be stopped.
    ///
    /// A predicate rather than a bare comparison at the call site: this is the whole policy, and
    /// it is the thing a test has to be able to hold still while the runner is exercised.
    static func isSatisfied(deltaCount: Int) -> Bool {
        deltaCount >= sufficientDeltas
    }
}
