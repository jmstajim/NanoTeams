import Foundation
@testable import NanoTeams

/// Configuration for the Autovisor continuation trainer (REC.10). Loaded from JSON.
///
/// The trainer builds the real system prompt and tool schemas via `PromptBuilder` and
/// `LLMExecutionService.resolveToolSchemas` (for the Autovisor Manager on scenarios 1–5
/// and for Coding Agent on scenario 6), replays a fixed conversation fixture up to the
/// target tool-result slot, injects Variant A ("before") or Variant B ("after"), and
/// runs `runs` continuations against a live LLM server to classify the model's next turn.
struct AutovisorContinuationTrainerConfig: Codable {

    // MARK: - LLM

    var provider: LLMProvider?
    var baseURL: String?
    var model: String?
    var toolCallingPreference: ToolCallingPreference?

    // MARK: - Run

    var outputPath: String
    var runs: Int?
    var caseTimeoutSeconds: Int?
    var variant: AutovisorContinuationVariant?
    var scenarios: [AutovisorContinuationScenario]?

    // MARK: - Resolved

    var resolvedProvider: LLMProvider { provider ?? .lmStudio }
    var resolvedBaseURL: String { baseURL ?? resolvedProvider.defaultBaseURL }
    var resolvedModel: String { model ?? resolvedProvider.defaultModel }
    var resolvedToolCallingPreference: ToolCallingPreference { toolCallingPreference ?? .auto }
    var resolvedRuns: Int { max(1, runs ?? 2) }
    var resolvedCaseTimeout: TimeInterval { TimeInterval(max(1, caseTimeoutSeconds ?? 120)) }
    var resolvedVariant: AutovisorContinuationVariant { variant ?? .before }

    var resolvedScenarios: [AutovisorContinuationScenario] {
        guard let scenarios, !scenarios.isEmpty else {
            return AutovisorContinuationScenario.allCases
        }
        let wanted = Set(scenarios)
        return AutovisorContinuationScenario.allCases.filter { wanted.contains($0) }
    }

    func toLLMConfig(toolCallingMode: ToolCallingMode = .promptTaught) -> LLMConfig {
        LLMConfig(
            provider: resolvedProvider,
            baseURLString: resolvedBaseURL,
            modelName: resolvedModel,
            toolCallingMode: toolCallingMode
        )
    }
}

/// Which envelope arm(s) the trainer injects at the target tool-result slot.
enum AutovisorContinuationVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case before
    case after
    case both

    var activeArms: [AutovisorContinuationArm] {
        switch self {
        case .before: [.before]
        case .after: [.after]
        case .both: [.before, .after]
        }
    }
}

/// A single measured arm ("before" = Variant A, "after" = Variant B).
enum AutovisorContinuationArm: String, Codable, CaseIterable, Hashable, Sendable {
    case before
    case after
}

/// The six REC.10 continuation scenarios from `Планы/external-autovisor.md` Ш1 / §13.3.
enum AutovisorContinuationScenario: String, Codable, CaseIterable, Hashable, Sendable {
    /// 1. `control_task pause` on a task with no running engine.
    case pauseNoEngine = "pause_no_engine"
    /// 2. `control_task close` on an already-closed task.
    case repeatedClose = "repeated_close"
    /// 3. `message_task` on a task in Review (`needsSupervisorAcceptance`).
    case messageTaskInReview = "message_task_in_review"
    /// 4. `message_task` on a paused task.
    case messageTaskOnPaused = "message_task_on_paused"
    /// 5. `list_tasks` / `task_status` when a task has two roles waiting on `ask_supervisor` (D-42).
    case rosterTwoQuestions = "roster_two_questions"
    /// 6. `delegate_to_team` when the child task pauses on its own run timeout (after-only).
    case delegationChildPausedTimeout = "delegation_child_paused_timeout"

    /// Scenario 6 introduces a brand-new envelope (before Ш6 the awaiter hung until the
    /// 30-minute wall timeout and never returned a pause envelope), so it has no `.before` arm.
    var supportsBeforeArm: Bool {
        switch self {
        case .delegationChildPausedTimeout: false
        case .pauseNoEngine, .repeatedClose, .messageTaskInReview, .messageTaskOnPaused, .rosterTwoQuestions:
            true
        }
    }
}
