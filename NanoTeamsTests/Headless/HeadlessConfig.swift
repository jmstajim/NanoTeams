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

    /// Team template ID: "assistant", "codingAssistant", "faang", "engineering", "startup", "questParty", "discussionClub".
    var teamTemplate: String?

    /// Timeout in seconds before the run is aborted. Default: 600 (10 min).
    var timeoutSeconds: Int?

    /// Max LLM retries on server errors. Default: 3.
    var maxLLMRetries: Int?

    /// Optional work-folder context to inject into prompts. Backed by the
    /// renamed `ProjectSettings.context` field; the legacy JSON key
    /// `projectDescription` is still accepted for old configs on disk.
    var workFolderContext: String?

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

    // MARK: - Codable (legacy field migration)

    private enum CodingKeys: String, CodingKey {
        case projectPath, taskTitle, supervisorTask
        case provider, baseURL, model, maxTokens, temperature
        case teamTemplate, timeoutSeconds, maxLLMRetries
        case workFolderContext
        case visionModel, visionBaseURL, selectedScheme
        // Legacy: pre-rename configs used `projectDescription` for the same payload.
        case legacyProjectDescription = "projectDescription"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.projectPath = try c.decode(String.self, forKey: .projectPath)
        self.taskTitle = try c.decode(String.self, forKey: .taskTitle)
        self.supervisorTask = try c.decode(String.self, forKey: .supervisorTask)
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        self.teamTemplate = try c.decodeIfPresent(String.self, forKey: .teamTemplate)
        self.timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        self.maxLLMRetries = try c.decodeIfPresent(Int.self, forKey: .maxLLMRetries)
        self.workFolderContext = try c.decodeIfPresent(String.self, forKey: .workFolderContext)
            ?? c.decodeIfPresent(String.self, forKey: .legacyProjectDescription)
        self.visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel)
        self.visionBaseURL = try c.decodeIfPresent(String.self, forKey: .visionBaseURL)
        self.selectedScheme = try c.decodeIfPresent(String.self, forKey: .selectedScheme)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectPath, forKey: .projectPath)
        try c.encode(taskTitle, forKey: .taskTitle)
        try c.encode(supervisorTask, forKey: .supervisorTask)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(teamTemplate, forKey: .teamTemplate)
        try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encodeIfPresent(maxLLMRetries, forKey: .maxLLMRetries)
        try c.encodeIfPresent(workFolderContext, forKey: .workFolderContext)
        try c.encodeIfPresent(visionModel, forKey: .visionModel)
        try c.encodeIfPresent(visionBaseURL, forKey: .visionBaseURL)
        try c.encodeIfPresent(selectedScheme, forKey: .selectedScheme)
        // Intentionally NOT writing `legacyProjectDescription` — re-encoding a
        // legacy file completes the migration in-place.
    }
}
