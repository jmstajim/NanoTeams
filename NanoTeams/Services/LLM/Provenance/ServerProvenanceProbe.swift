import Foundation

/// Asks a server about ITSELF, so a benchmark row stays interpretable after the server is upgraded.
///
/// Separate from `LLMClient` because the SUBJECT of the fact is different. `LLMClient`'s remaining
/// question-shaped members — `fetchModels`, `modelSupportsVision`, `modelContextLength`,
/// `modelLoadDetails` — are all keyed by `config.modelName` and answered by the same endpoints
/// (the last two literally share one `/api/v0/models` fetch). Version, build and engines are keyed
/// by nothing, are answered on a different transport on LM Studio, and no part of the run loop
/// reads them. A protocol 104 types conform to is the wrong home for that.
///
/// Named for the capability rather than for the benchmark: the Settings "Model Details" card is a
/// plausible second reader of the same facts, and `BenchmarkProbe` would need renaming the day it
/// became one.
///
/// **No protocol-extension defaults, deliberately.** There are three conformers here, not 104, and
/// a default would let a provider silently report nothing where it should state that it reports
/// nothing — which is a different fact and the one a provenance record needs.
nonisolated protocol ServerProvenanceProbe: Sendable {
    /// Read-only: no generation, no model load, nothing on the server changes.
    ///
    /// Never throws, and never partial-fails: a provider that answers one question and not the
    /// other returns what it has. An unreachable server yields an EMPTY provenance, which records
    /// as absence — the measurement must still be published when its provenance could not be.
    func serverProvenance(config: LLMConfig) async -> ServerProvenance

    /// The engine that served one tiny completion on `config.modelName`, just now.
    ///
    /// Separate from `serverProvenance` because it SPENDS a generation: it is the only
    /// non-inferential way to name the runtime behind a model, and a caller that just wants to
    /// show a version must not pay a forward pass by accident. Callers must also ensure the model
    /// is already resident — see the note in `GenerationBenchmarkRunner`.
    func probeServingEngine(config: LLMConfig) async -> ServerProvenance.Engine?
}
