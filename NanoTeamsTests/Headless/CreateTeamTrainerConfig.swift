import Foundation
@testable import NanoTeams

/// Configuration for the create_team trainer. Loaded from JSON.
struct CreateTeamTrainerConfig: Codable {
    // MARK: - LLM

    /// Decoded directly so typos like `"lmstdio"` fail at config load instead of
    /// silently falling back to the default 20 minutes into a run.
    var provider: LLMProvider?

    /// e.g. `"http://127.0.0.1:1234"`.
    var baseURL: String?

    var model: String?

    var maxTokens: Int?

    var temperature: Double?

    // MARK: - Corpus & Output

    /// Absolute path to the corpus JSON file.
    /// Shape: `{"cases": [{"tag": "...", "task": "..."}, ...]}`.
    var corpusPath: String

    /// Absolute path where the trainer writes `create_team_results.json`.
    var outputPath: String

    var caseTimeoutSeconds: Int?

    /// Bounds how long a single attempt waits for the FIRST `content` /
    /// `tool_calls` token before assuming the model is stuck in a reasoning
    /// loop (observed on qwen3.5-35b-a3b with open-ended prompts). Once any
    /// token arrives the deadline stops applying. `nil` (default 15) disables.
    var firstContentDeadlineSeconds: Double?

    /// How many times to retry a case when generation fails. First success
    /// short-circuits. Default 4. Each attempt runs under `caseTimeoutSeconds`.
    var maxAttempts: Int?

    // MARK: - Resolved Helpers

    var resolvedProvider: LLMProvider {
        provider ?? .lmStudio
    }

    var resolvedBaseURL: String {
        baseURL ?? resolvedProvider.defaultBaseURL
    }

    var resolvedModel: String {
        model ?? resolvedProvider.defaultModel
    }

    var resolvedTimeout: TimeInterval {
        TimeInterval(caseTimeoutSeconds ?? 90)
    }

    var resolvedFirstContentDeadline: Double {
        firstContentDeadlineSeconds ?? 15
    }

    var resolvedMaxAttempts: Int {
        max(1, maxAttempts ?? 4)
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(
            provider: resolvedProvider,
            baseURLString: resolvedBaseURL,
            modelName: resolvedModel,
            maxTokens: maxTokens ?? resolvedProvider.defaultMaxTokens,
            temperature: temperature
        )
    }
}

/// One entry in the corpus JSON file.
struct CreateTeamTrainerCase: Codable {
    var tag: String
    var task: String
}

struct CreateTeamTrainerCorpus: Codable {
    var cases: [CreateTeamTrainerCase]
}
