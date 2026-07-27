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
}
