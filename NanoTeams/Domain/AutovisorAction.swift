import Foundation

/// Reason a verb string failed to decode into a typed `ControlVerb` / `RoleVerb`.
/// Carries the manager-facing message the tool handler surfaces as `INVALID_ARGS`.
nonisolated struct AutovisorVerbError: Error, Hashable {
    let message: String
}

/// Task-lifecycle verbs for `control_task`. Modeling each verb (and its argument,
/// where one exists) as a case makes illegal verb/arg combinations unrepresentable:
/// `rename` always carries a non-empty title, `set_timeout` carries an optional
/// seconds value, and the no-arg verbs carry nothing. `parse(action:arg:)` is the
/// SINGLE decode boundary (the tool handler is its only caller), so the dispatch
/// switch needs no `default:` arm and the legal verb set lives in exactly one place.
nonisolated enum ControlVerb: Hashable {
    case start, pause, resume, stop, close, delete
    case rename(title: String)
    case setTimeout(seconds: TimeInterval?)

    /// `action` enum values surfaced to the LLM in the tool schema (display order).
    static let actionNames = ["start", "pause", "resume", "stop", "close", "delete", "rename", "set_timeout"]

    /// Decode a tool `action` + optional `arg` into a verb. `.failure` carries a
    /// human-readable reason (unknown action, or `rename` with an empty title).
    static func parse(action: String, arg: String?) -> Result<ControlVerb, AutovisorVerbError> {
        switch action.lowercased() {
        case "start": return .success(.start)
        case "pause": return .success(.pause)
        case "resume": return .success(.resume)
        case "stop": return .success(.stop)
        case "close": return .success(.close)
        case "delete": return .success(.delete)
        case "rename":
            let title = (arg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .failure(.init(message: "rename requires a non-empty title in `arg`."))
            }
            return .success(.rename(title: title))
        case "set_timeout":
            // > 0 seconds sets the timeout; 0 / missing / non-numeric clears it.
            let seconds = arg.flatMap(Double.init)
            return .success(.setTimeout(seconds: (seconds ?? 0) > 0 ? seconds : nil))
        default:
            return .failure(.init(message: "action must be one of: \(actionNames.joined(separator: ", "))."))
        }
    }
}

/// Role-level verbs for `manage_role`. The cases that require feedback carry it as
/// a non-optional associated value (`requestChanges`/`correct`), so "request_changes
/// with no comment" is unrepresentable past the decode boundary; `restart`'s comment
/// is optional guidance. Same single-decode-boundary contract as `ControlVerb`.
nonisolated enum RoleVerb: Hashable {
    case restart(comment: String?)
    case accept
    case requestChanges(comment: String)
    case correct(comment: String)
    case finishAdvisory

    static let actionNames = ["restart", "accept", "request_changes", "correct", "finish_advisory"]

    static func parse(action: String, comment: String?) -> Result<RoleVerb, AutovisorVerbError> {
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmpty = (trimmed?.isEmpty == false) ? trimmed : nil
        switch action.lowercased() {
        case "restart": return .success(.restart(comment: nonEmpty))
        case "accept": return .success(.accept)
        case "request_changes":
            guard let c = nonEmpty else {
                return .failure(.init(message: "request_changes requires `comment` describing what to change."))
            }
            return .success(.requestChanges(comment: c))
        case "correct":
            guard let c = nonEmpty else {
                return .failure(.init(message: "correct requires `comment` with the correction."))
            }
            return .success(.correct(comment: c))
        case "finish_advisory": return .success(.finishAdvisory)
        default:
            return .failure(.init(message: "action must be one of: \(actionNames.joined(separator: ", "))."))
        }
    }
}

/// A single write-action the Autovisor performs against the folder. The 9
/// management tools emit `ToolSignal` cases; their async handlers translate each
/// WRITE signal into one of these and call the single `performAutovisorAction`
/// delegate hook (read signals — `list_tasks`, `task_status` — read the snapshot
/// directly and never go through this type). One hook + one enum keeps the
/// `LLMStateDelegate` protocol (and its test mock) from sprouting ~16 methods.
nonisolated enum AutovisorAction: Hashable {
    /// Fire-and-forget create + start of a TOP-LEVEL visible task. `teamID` is a
    /// team id from the catalog, the `"generated"` sentinel, or nil (→ active team).
    case createManagedTask(title: String, brief: String, teamID: String?)
    /// Task lifecycle verb (`ControlVerb` carries any per-verb argument inline).
    case controlTask(taskID: Int, verb: ControlVerb)
    /// Role-level verb (`RoleVerb` carries the feedback where the verb needs it).
    case manageRole(taskID: Int, roleID: String, verb: RoleVerb)
    /// Answer a task's pending `ask_supervisor` as the folder's Supervisor.
    case answerTaskQuestion(taskID: Int, answer: String)
    /// Queue a steering message to a (running) task, optionally targeting a role.
    case messageTask(taskID: Int, text: String, roleID: String?)
    /// Set a task's review recurrence to a fixed interval. `intervalMinutes == 0`
    /// clears the recurrence.
    case scheduleTask(taskID: Int, intervalMinutes: Int)
    /// Replace the folder-wide Work Folder Context (injected into every role's prompt).
    case setWorkFolderContext(content: String)

    /// The task this action targets, if any. `nil` for folder-level actions
    /// (`createManagedTask`, `setWorkFolderContext`). Used by the orchestrator's
    /// self-guard to refuse any action aimed at the manager's own task.
    var targetTaskID: Int? {
        switch self {
        case .controlTask(let id, _),
             .manageRole(let id, _, _),
             .answerTaskQuestion(let id, _),
             .messageTask(let id, _, _),
             .scheduleTask(let id, _):
            return id
        case .createManagedTask, .setWorkFolderContext:
            return nil
        }
    }
}

/// Result of a `performAutovisorAction` call, formatted into the tool-result
/// envelope the manager LLM sees.
nonisolated struct AutovisorActionResult: Hashable {
    var ok: Bool
    var message: String
    /// Set by `createManagedTask` so the manager can reference the new task.
    var createdTaskID: Int?

    init(ok: Bool, message: String, createdTaskID: Int? = nil) {
        self.ok = ok
        self.message = message
        self.createdTaskID = createdTaskID
    }

    static func success(_ message: String, createdTaskID: Int? = nil) -> AutovisorActionResult {
        .init(ok: true, message: message, createdTaskID: createdTaskID)
    }

    static func failure(_ message: String) -> AutovisorActionResult {
        .init(ok: false, message: message)
    }
}

/// Pure derivations of a task's *own* status for the manager's `task_status` tool.
/// Kept Foundation-only + `nonisolated` so it's unit-testable without the orchestrator.
/// The live token-activity signal is injected as a parameter (never read here) so
/// the whole type stays orchestrator-free and trivially testable.
nonisolated enum AutovisorStatus {
    /// The failure detail for the inspected task, derived from its OWN latest run —
    /// NOT the global error banner (which can belong to a different task and would
    /// mislead the manager into acting on a healthy one). Returns the failed step's
    /// recorded note (`completeStepFailure` appends it as a `StepMessage`), a generic
    /// per-task fallback, or `nil` when the task hasn't failed.
    static func lastError(for task: NTMSTask) -> String? {
        guard let run = task.runs.last,
              let failed = run.steps.first(where: { $0.status == .failed })
        else { return nil }
        if let note = failed.messages.last(where: { $0.content.hasPrefix("LLM error") }) {
            return note.content
        }
        return "Role '\(failed.effectiveRoleID)' failed."
    }

    // MARK: - Timing

    /// Most recent activity timestamp for a step: the last FINALIZED message (not
    /// `llmConversation`, whose entry is pre-created at response START), the last
    /// tool call, the step's own creation, or the live token-activity timestamp.
    static func lastActivity(step: StepExecution, lastStreamActivityAt: Date?) -> Date {
        var latest = step.createdAt
        if let m = step.messages.last?.createdAt, m > latest { latest = m }
        if let t = step.toolCalls.last?.createdAt, t > latest { latest = t }
        if let s = lastStreamActivityAt, s > latest { latest = s }
        return latest
    }

    /// Seconds since the role last produced anything (message / tool call / token /
    /// progress). Clamped at 0 — `MonotonicClock` model timestamps can sit a hair
    /// ahead of wall-clock `now`.
    static func idleSeconds(step: StepExecution, now: Date, lastStreamActivityAt: Date?) -> Int {
        max(0, Int(now.timeIntervalSince(lastActivity(step: step, lastStreamActivityAt: lastStreamActivityAt))))
    }

    /// Seconds the role has been executing (to completion if finished, else to `now`).
    static func roleElapsedSeconds(step: StepExecution, now: Date) -> Int {
        max(0, Int((step.completedAt ?? now).timeIntervalSince(step.createdAt)))
    }

    /// Seconds since the run started, or nil if there is no run.
    static func taskElapsedSeconds(run: Run?, now: Date) -> Int? {
        guard let run else { return nil }
        return max(0, Int(now.timeIntervalSince(run.createdAt)))
    }

    /// True while the step's most recent tool call is still executing (result not
    /// yet recorded) — a legitimately long tool (e.g. `run_xcodebuild`) emits no
    /// tokens but the role is NOT hung. `analyze_image` / `create_team` placeholders
    /// carry a non-nil interim `resultJSON`, so they read as "done" here, not in-flight.
    static func hasToolInFlight(step: StepExecution) -> Bool {
        step.toolCalls.last.map { $0.resultJSON == nil } ?? false
    }
}
