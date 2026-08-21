import Foundation

/// Human-readable snapshot of the parameters a model is (or would be) loaded
/// with, as the provider's metadata endpoints report them. Surfaced by the
/// Settings → LLM "Model Details" card so the user can SEE the effective load
/// state (context window, quantization, residency) instead of guessing.
///
/// Provider sources:
/// - LM Studio: `GET /api/v0/models` (state, `loaded_context_length` vs
///   `max_context_length`, quantization, arch). Sampling parameters are NOT
///   reported over LM Studio's REST API (per-model config is server-side
///   only) — the card's footer says so instead of pretending.
/// - Ollama: `POST /api/show` (modelfile parameters incl. `num_ctx`,
///   quantization, family, capabilities) + `GET /api/ps` (loaded state, VRAM,
///   keep-alive expiry).
nonisolated struct ModelLoadDetails: Sendable, Equatable {
    struct Field: Sendable, Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let fields: [Field]

    // MARK: - Well-known labels

    /// The labels BOTH provider clients report these facts under — the single spelling shared by
    /// the writers (`NativeLMStudioClient.modelLoadDetails`, `OllamaClient.parseShowLoadFields`)
    /// and every typed reader. They are also persistence-frozen: historical benchmark rows carry
    /// them verbatim as `GenerationBenchmarkRun.serverFields` keys, so renaming one here without
    /// keeping the legacy-decode fallback in `GenerationBenchmarkRun` on the OLD spelling would
    /// orphan every row already on disk.
    static let formatLabel = "Format"
    static let quantizationLabel = "Quantization"
    /// Ollama's `/api/show` sampling block (`temperature 1\ntop_k 20\n…`), parsed by
    /// `BenchmarkProvenance.samplingParameters`.
    static let modelfileParametersLabel = "Modelfile parameters"

    // MARK: - Typed access

    /// The model's file format as the server reports it, verbatim — `gguf`, `mlx`, `safetensors`.
    /// LM Studio: `compatibility_type` from `/api/v0/models`; Ollama: `details.format` from
    /// `/api/show`. What the benchmark promotes into `GenerationBenchmarkRun.modelFormat`.
    var format: String? { value(for: Self.formatLabel) }

    /// The quantization as the server reports it, verbatim — `Q4_K_M`, `4bit`, `MXFP4`.
    /// LM Studio: `quantization`; Ollama: `details.quantization_level`. What the benchmark
    /// promotes into `GenerationBenchmarkRun.quantization`.
    var quantization: String? { value(for: Self.quantizationLabel) }

    func value(for label: String) -> String? {
        fields.first(where: { $0.label == label })?.value
    }
}
