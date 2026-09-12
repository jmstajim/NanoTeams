import Foundation
@testable import NanoTeams

/// Configuration for the `ask_supervisor_form` trainer. Loaded from JSON.
///
/// The trainer asks one fixed question N times, each time in a FRESH run, and scores what the
/// model emitted for the questionnaire — the REC.10 before/after measurement for an edit to
/// the form's schema, description or repair ladder.
///
/// It drives the FULL stack rather than the handler, and that is the whole point: two of the
/// seven field emissions of 2026-09-12 never reached the handler at all — they died on the
/// outer `<|call|>` envelope — so a harness that called the handler directly would have scored
/// those runs as clean.
struct AskSupervisorFormTrainerConfig: Codable {

    // MARK: - LLM

    /// Decoded directly so a typo like `"ollma"` fails at config load instead of silently
    /// measuring against the default provider.
    var provider: LLMProvider?
    /// e.g. `"http://127.0.0.1:11434"`.
    var baseURL: String?
    var model: String?

    // MARK: - Run

    /// The work folder to run in. Required: the measurement is of a model answering in a real
    /// folder, and which folder it is changes the prompt (agent instructions, work-folder
    /// context, the skills a role carries).
    var projectPath: String
    /// `templateID` or display name of the team to run. `nil` → whatever the folder has active.
    var teamTemplate: String?
    var taskTitle: String?
    /// The one question every run asks. Defaulted rather than required so a bare config
    /// reproduces the measurement byte-for-byte — a trainer whose input drifts between runs
    /// measures the input, not the change.
    var supervisorTask: String?
    /// Identical repetitions. Default 20 — enough for a rate rather than an anecdote, since
    /// what is being measured is a proportion of emissions.
    var runs: Int?
    var runTimeoutSeconds: Int?
    /// Absolute path where the trainer writes the results JSON.
    var outputPath: String

    // MARK: - Resolved

    var resolvedProvider: LLMProvider { provider ?? .lmStudio }
    var resolvedBaseURL: String { baseURL ?? resolvedProvider.defaultBaseURL }
    var resolvedModel: String { model ?? resolvedProvider.defaultModel }
    var resolvedTaskTitle: String { taskTitle ?? "ask_supervisor_form trainer" }
    var resolvedSupervisorTask: String {
        supervisorTask ?? Self.defaultSupervisorTask
    }
    var resolvedRuns: Int { max(1, runs ?? 20) }
    /// Clamped: a `0` would time every run out before its first token and write a results file
    /// of nothing but timeouts.
    var resolvedRunTimeout: TimeInterval { TimeInterval(max(1, runTimeoutSeconds ?? 180)) }

    /// The question the field runs of 2026-09-12 were reproduced from. Deliberately short and
    /// deliberately naming the tool: what is being measured is how the questionnaire is
    /// ENCODED, not whether the model decides to reach for it.
    static let defaultSupervisorTask = "как дела? используй ask_supervisor_form"

    func toLLMConfig() -> LLMConfig {
        LLMConfig(provider: resolvedProvider, baseURLString: resolvedBaseURL, modelName: resolvedModel)
    }
}
