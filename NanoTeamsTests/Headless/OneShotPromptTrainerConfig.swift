import Foundation
@testable import NanoTeams

/// Configuration for the one-shot prompt trainer. Loaded from JSON.
///
/// The trainer drives the app's ONE-SHOT LLM services — the two judges, the command
/// explainer, prompt improvement, vision, work-folder context and the Supervisor
/// auto-answer — against a live server with fixed inputs, so a prompt edit on any of
/// them can be measured before/after at the deployment quantization (playbook REC.10)
/// without a full headless run that may never reach the surface.
struct OneShotPromptTrainerConfig: Codable {
    // MARK: - LLM

    /// Decoded directly so typos like `"ollma"` fail at config load instead of
    /// silently running against the default provider.
    var provider: LLMProvider?
    /// e.g. `"http://127.0.0.1:11434"`.
    var baseURL: String?
    var model: String?
    /// The model the vision case sends the image to. `nil` → `model` (the chat model must
    /// then be multimodal; Ollama reports `vision` under `capabilities`).
    var visionModel: String?

    // MARK: - Run

    /// Absolute path where the trainer writes the results JSON. Its directory also receives
    /// `network_log.jsonl`, holding every request that goes through a service the trainer can
    /// hand a logger — which is six of the seven: `WorkFolderContextService` builds its own
    /// client and takes none, so the work-folder-context call is in the results file only.
    /// The log is a plain wire log for reading, not a work folder: `--from-logs` resolves
    /// runs under `.nanoteams/internal/tasks/…` and will not find it.
    var outputPath: String
    /// Folder the work-folder-context case describes. `nil` → a scratch folder with three
    /// small files the trainer creates and removes.
    var workFolderPath: String?
    /// Identical-config repetitions per case. Default 2 — the REC.10 floor.
    var runs: Int?
    var caseTimeoutSeconds: Int?
    /// Subset of `OneShotPromptService` raw values. `nil` → every service.
    var services: [OneShotPromptService]?

    // MARK: - Resolved

    var resolvedProvider: LLMProvider { provider ?? .lmStudio }
    var resolvedBaseURL: String { baseURL ?? resolvedProvider.defaultBaseURL }
    var resolvedModel: String { model ?? resolvedProvider.defaultModel }
    var resolvedVisionModel: String { visionModel ?? resolvedModel }
    var resolvedRuns: Int { max(1, runs ?? 2) }
    /// Clamped: a `0` or negative value would time every case out before its first token
    /// and write a results file of nothing but timeouts.
    var resolvedCaseTimeout: TimeInterval { TimeInterval(max(1, caseTimeoutSeconds ?? 120)) }
    /// Declaration order regardless of the config's order, so two runs with the same
    /// set produce comparable result files. An empty list means unset — a run of zero
    /// cases would report a vacuous success.
    var resolvedServices: [OneShotPromptService] {
        guard let services, !services.isEmpty else { return OneShotPromptService.allCases }
        let wanted = Set(services)
        return OneShotPromptService.allCases.filter { wanted.contains($0) }
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(provider: resolvedProvider, baseURLString: resolvedBaseURL, modelName: resolvedModel)
    }

    func toVisionConfig() -> LLMConfig {
        LLMConfig(provider: resolvedProvider, baseURLString: resolvedBaseURL, modelName: resolvedVisionModel)
    }
}

/// The one-shot surfaces the trainer can exercise. Raw values are the config spelling.
/// `TeamGenerationService` is deliberately absent — it has its own trainer
/// (`./run_create_team_trainer.sh`) over a corpus.
enum OneShotPromptService: String, Codable, CaseIterable, Hashable {
    case bashJudge = "bash_judge"
    case computerUseJudge = "computer_use_judge"
    case bashExplain = "bash_explain"
    case promptImprovement = "prompt_improvement"
    case vision
    case workFolderContext = "work_folder_context"
    case supervisorAutoAnswer = "supervisor_auto_answer"
}
