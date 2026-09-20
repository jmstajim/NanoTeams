import Foundation

/// How the warm-up sample is bounded — and why it is bounded by the SERVER.
///
/// The warm-up exists to pay what only the FIRST request pays: loading the model where the app is
/// not allowed to load it explicitly (Ollama owns its own residency), materialising the KV cache
/// for the prompt (`BenchmarkPrompt.measuredPromptTokens`), and compiling or warming whatever
/// the engine compiles on its first decode. Every one of those is behind us once the model has
/// produced tokens — nothing later in the answer is a cost the measured samples would inherit.
///
/// What it is NOT for is producing an answer. Nobody reads it, `BenchmarkMetricsPolicy` drops it
/// from every median, and before anything bounded it a thinking model decided on its own how long
/// the sample ran. Measured on LM Studio 0.4.21 / qwen3.5-9b, read to the end: **233 seconds,
/// 12 040 output tokens, 11 561 of them reasoning** — four minutes of generation whose only
/// destination was the discard pile, against a prompt whose prefill takes a few seconds.
///
/// **The bound is `outputCeiling`, sent on the wire — a change from the original design
/// (2026-09-20).** The warm-up used to be cut by the APP: read sixteen deltas, drop the iterator,
/// let the stream's `onTermination` cancel the request. That worked, and it left one thing
/// unverified (DEBTS D-B1 §3): whether the server stops generating when the client disconnects.
/// Under LM Studio's continuous-batching kit an abandoned generation that keeps decoding shares
/// the GPU with the first measured sample and depresses that sample's own `tokens_per_second` —
/// and a five-sample median is not far from one contaminated sample. Rather than measure whether
/// that happens, the cause is gone: nothing is abandoned, because the server is told how much to
/// write and the app reads through to the terminal frame.
///
/// Two things fall out of that, both improvements. The warm-up now RECEIVES its terminal frame, so
/// its row carries real token counts and the server's own model-load time instead of nothing. And
/// `BenchmarkVoidReason.stoppedEarly` goes back to meaning only what it says — a stream somebody
/// really cut off — instead of being the expected state of every healthy run.
nonisolated enum BenchmarkWarmUpPolicy {

    /// Tokens the warm-up asks the server for.
    ///
    /// Sixteen, for the reason the old delta count was sixteen: one would be defensible — the
    /// model is loaded, the prompt is in the KV cache, and the first decode step is the one that
    /// compiles a decode graph — and sixteen is a margin bought at roughly a third of a second on
    /// a 50 tok/s model, which leaves the decode loop unambiguously in steady state rather than
    /// one token past its start.
    ///
    /// Spelled as a ceiling rather than as a delta count because that is now who enforces it.
    static let outputCeiling = 16

    /// The hard ceiling on a warm-up, enforced by cancelling the request.
    ///
    /// `outputCeiling` is the normal exit and fires within a second of the first token. This is
    /// the OTHER exit, for the case where that never happens: a model still loading, a prefill
    /// that will not end, a server that accepted the request and went quiet. A token ceiling
    /// bounds how much the model may WRITE and nothing else, so a request that never reaches its
    /// first token is still bounded by nothing the app controls. That gap is what this is for.
    ///
    /// Twenty seconds, raised from ten on 2026-09-20 by a measurement that nearly tripped it: a
    /// warm-up against an idle `qwen3.8-27b-splash` on LM Studio 0.4.25 reported **TTFT 9.29 s**,
    /// where the measured samples that followed it reported 5.0–5.6 s. The warm-up is by
    /// definition the first request after an idle period — pages cold, caches empty — so it is
    /// the one sample that pays that difference, and a bound set against the WARM figure would
    /// fire on a healthy run and hand the load to the first measured sample instead.
    ///
    /// The asymmetry is what decides the value. Firing wrongly costs a real warm-up; firing late
    /// costs ten extra seconds once, on a run that was already broken. So the bound is set clear
    /// of the worst healthy reading rather than close to the typical one.
    ///
    /// A warm-up cut here has done less than one the server ended — it may have stopped mid-load.
    /// That is recorded, not hidden: the row keeps whatever it managed to measure, its `void` reads
    /// `stoppedEarly`, and its absent token counts are what say how far it got.
    static let deadline: Duration = .seconds(20)
}
