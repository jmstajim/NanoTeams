import Foundation

/// Ollama's answers about itself: a version, and no engines.
nonisolated struct OllamaServerProvenanceProbe: ServerProvenanceProbe {

    let session: any NetworkSession
    let tokenResolver: any LLMTokenResolver

    init(
        session: any NetworkSession = URLSession.shared,
        tokenResolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) {
        self.session = session
        self.tokenResolver = tokenResolver
    }

    /// `GET /api/version` → `{"version":"0.32.14"}`. Measured against a live server.
    ///
    /// Never throws: a benchmark must still record its measurements when the version probe fails,
    /// and an absent version is honest where a fabricated one would not be. Short timeout for the
    /// same reason — this is provenance, not the measurement.
    func serverProvenance(config: LLMConfig) async -> ServerProvenance {
        ServerProvenance(version: await version(config: config))
    }

    /// Ollama reports no engine anywhere — measured 2026-08-19 across `/api/version`, `/api/ps`,
    /// `/api/tags` and `/api/show`: not one of them contains the strings `llama.cpp`, `ggml`,
    /// `engine` or `runner`. So this spends no request at all rather than issuing one that could
    /// only come back empty; the honest record is that this provider does not say.
    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? { nil }

    private func version(config: LLMConfig) async -> String? {
        guard let baseURL = URL(string: config.baseURLString) else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)

        guard let (data, response) = try? await session.sessionData(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONCoderFactory.makeWireDecoder()
              .decode(VersionResponse.self, from: data)
        else { return nil }
        let trimmed = decoded.version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `GET /api/version` → `{"version":"0.32.14"}`. The one endpoint either provider offers that
    /// names the server itself rather than a model.
    struct VersionResponse: Decodable {
        var version: String
    }
}
