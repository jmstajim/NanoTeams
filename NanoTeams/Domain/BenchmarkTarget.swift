import Foundation

/// What the benchmark screen measures, kept SEPARATE from the app's active LLM settings.
///
/// A benchmark is a comparison tool: measuring model B must not switch the app onto model B, or
/// every comparison would silently reconfigure the workspace as a side effect. So the screen owns
/// its own provider / endpoint / model, seeded from the global settings the first time and
/// independent afterwards.
///
/// Persisted as one blob rather than three settings — the three are only meaningful together, and
/// a half-applied target (new provider, old model) is not a state the user ever chose.
nonisolated struct BenchmarkTarget: Codable, Hashable, Sendable {
    var provider: LLMProvider
    var baseURLString: String
    var modelName: String

    init(provider: LLMProvider, baseURLString: String, modelName: String) {
        self.provider = provider
        self.baseURLString = baseURLString
        self.modelName = modelName
    }

    /// The app's current settings, as a starting point.
    init(seededFrom config: LLMConfig) {
        self.provider = config.provider
        self.baseURLString = config.baseURLString
        self.modelName = config.modelName
    }

    /// Timeout and keep-alive still come from the app's settings: they are transport policy, not
    /// part of what is being compared, and a benchmark that quietly used a different timeout than
    /// real work would measure a different thing than it claims to.
    ///
    /// The output ceiling is the opposite case and therefore comes from the WORKLOAD
    /// (`BenchmarkPrompt.maxOutputTokens`), never from settings: it defines what is being
    /// compared, and a user-tunable ceiling would let two rows of the same leaderboard be measured
    /// over different sequence lengths with nothing on screen saying so.
    func llmConfig(requestTimeoutSeconds: Int, keepAliveSeconds: Int?) -> LLMConfig {
        LLMConfig(
            provider: provider,
            baseURLString: baseURLString,
            modelName: modelName,
            temperature: nil,
            maxOutputTokens: BenchmarkPrompt.maxOutputTokens,
            requestTimeoutSeconds: requestTimeoutSeconds,
            keepAliveSeconds: keepAliveSeconds)
    }

    var isRunnable: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
