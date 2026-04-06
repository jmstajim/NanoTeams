import Foundation
@testable import NanoTeams

/// Configuration for headless NanoTeams runs. Loaded from a JSON file.
struct HeadlessConfig: Codable {
    // MARK: - Task

    /// Absolute path to the project folder the team will work on.
    var projectPath: String

    /// Human-readable task title.
    var taskTitle: String

    /// Supervisor task — the brief for the team.
    var supervisorTask: String

    // MARK: - LLM

    /// LLM provider raw value: "lmStudio".
    var provider: String?

    /// Base URL override (e.g. "http://127.0.0.1:1234").
    var baseURL: String?

    /// Model name override (e.g. "openai/gpt-oss-20b").
    var model: String?

    /// Max tokens per response.
    var maxTokens: Int?

    /// Temperature (0.0–2.0).
    var temperature: Double?

    // MARK: - Execution

    /// Team template ID: "startup", "faang", "questParty", "discussionClub".
    var teamTemplate: String?

    /// Timeout in seconds before the run is aborted. Default: 600 (10 min).
    var timeoutSeconds: Int?

    /// Max LLM retries on server errors. Default: 3.
    var maxLLMRetries: Int?

    /// Optional project description to inject into prompts.
    var projectDescription: String?

    /// Vision model name. When set, enables the analyze_image tool.
    /// Uses the same server as the main model unless visionBaseURL is specified.
    var visionModel: String?

    /// Vision model base URL override. Defaults to the main baseURL if empty.
    var visionBaseURL: String?

    /// Xcode scheme name. Used for both run_xcodebuild and run_xcodetests tools.
    var selectedScheme: String?

    // MARK: - Resolved Helpers

    var resolvedProvider: LLMProvider {
        provider.flatMap(LLMProvider.init(rawValue:)) ?? .lmStudio
    }

    var resolvedBaseURL: String {
        baseURL ?? resolvedProvider.defaultBaseURL
    }

    var resolvedModel: String {
        model ?? resolvedProvider.defaultModel
    }

    var resolvedTimeout: TimeInterval {
        TimeInterval(timeoutSeconds ?? 600)
    }
}
