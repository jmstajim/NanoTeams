import Foundation

/// What a server says about ITSELF — not about a model on it.
///
/// Every field is optional and absence is never filled in. A benchmark row that cannot say which
/// server produced it is worth less than one that says so plainly; a row that names a version the
/// server never reported is worth less than nothing, because it cannot be told from a measured one.
nonisolated struct ServerProvenance: Sendable, Equatable {
    /// The server's own version string, verbatim.
    ///
    /// Ollama answers `GET /api/version` with `{"version":"0.32.14"}`. LM Studio has no HTTP
    /// version endpoint at all — ~15 candidate paths were probed on 2026-08-19 and every one
    /// returned `{"error":"Unexpected endpoint or method"}`, with HTTP status **200**, so on that
    /// server a status code is not evidence that a path exists. Its version lives on a WebSocket
    /// RPC instead; see `LMStudioWebSocketRPC`.
    var version: String?
    /// The build number beside the version, verbatim, and deliberately NOT joined to it.
    ///
    /// LM Studio's `version` RPC answers `{version: "0.4.21", build: 2}` while its `info` RPC
    /// spells the same fact `"0.4.21+2"`. Composing our own spelling would make a formatting
    /// choice of ours indistinguishable from something the server said.
    var build: String?
    /// Inference engines the server has INSTALLED — never "the engine that served anything".
    ///
    /// LM Studio lists both `llama.cpp` and `mlx-llm`; choosing between them by the model's file
    /// format would be an inference, and an inference recorded as a measurement is exactly what
    /// this type exists to prevent. The label under which these reach a benchmark row says
    /// "installed" for that reason. For the engine that actually served a request, see
    /// `ServerProvenanceProbe.probeServingEngine`.
    var installedEngines: [Engine] = []

    var isEmpty: Bool { version == nil && build == nil && installedEngines.isEmpty }

    nonisolated struct Engine: Sendable, Equatable {
        /// Family name as the server spells it: `llama.cpp`, `mlx-llm`.
        var name: String
        var version: String
        /// The GPU framework the build targets (`Metal`), when the server says.
        var gpu: String?
        /// Model formats this engine can serve (`GGUF`, `MLX`) — the only honest way to relate an
        /// installed engine to a model, and still a relation rather than an attribution.
        var formats: [String] = []

        /// `llama.cpp 2.29.0` — one string for a provenance row, assembled from two fields the
        /// server sent separately, which is why it is computed here and never stored.
        var label: String { "\(name) \(version)" }
    }
}
