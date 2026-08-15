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
            // Absent or "0" CLEARS the timeout — that is the documented way to remove it.
            // A present-but-unparseable `arg` ("600s", "10 minutes") must be REJECTED, not
            // silently treated as a clear: that did the opposite of what the manager asked
            // and reported ok:true, leaving it no signal to act on. `rename` above already
            // rejects an unusable `arg`; this is the same rule.
            let raw = (arg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return .success(.setTimeout(seconds: nil)) }
            guard let seconds = Double(raw), seconds.isFinite, seconds >= 0 else {
                return .failure(.init(
                    message: "set_timeout needs a number of SECONDS in `arg` (or omit it / pass \"0\" to clear). Got '\(raw)'."
                ))
            }
            return .success(.setTimeout(seconds: seconds > 0 ? seconds : nil))
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

    /// Every wire spelling, written ONCE. Three sites need them — the legal-set message,
    /// the reverse mapping for error text, and `parse` — and before this each spelled its
    /// own literals, so a renamed verb could be accepted by `parse`, absent from the
    /// "must be one of" list, and reported back under a fourth name.
    enum Wire {
        static let restart = "restart"
        static let accept = "accept"
        static let requestChanges = "request_changes"
        static let correct = "correct"
        static let finishAdvisory = "finish_advisory"
    }

    static let actionNames = [
        Wire.restart, Wire.accept, Wire.requestChanges, Wire.correct, Wire.finishAdvisory,
    ]

    /// The wire spelling of this verb, for error text that has to name it back.
    var autovisorVerbName: String {
        switch self {
        case .restart: Wire.restart
        case .accept: Wire.accept
        case .requestChanges: Wire.requestChanges
        case .correct: Wire.correct
        case .finishAdvisory: Wire.finishAdvisory
        }
    }

    static func parse(action: String, comment: String?) -> Result<RoleVerb, AutovisorVerbError> {
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmpty = (trimmed?.isEmpty == false) ? trimmed : nil
        switch action.lowercased() {
        case Wire.restart: return .success(.restart(comment: nonEmpty))
        case Wire.accept: return .success(.accept)
        case Wire.requestChanges:
            guard let c = nonEmpty else {
                return .failure(.init(message: "\(Wire.requestChanges) requires `comment` describing what to change."))
            }
            return .success(.requestChanges(comment: c))
        case Wire.correct:
            guard let c = nonEmpty else {
                return .failure(.init(message: "\(Wire.correct) requires `comment` with the correction."))
            }
            return .success(.correct(comment: c))
        case Wire.finishAdvisory: return .success(.finishAdvisory)
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
        // Failures that never ran through the role tool loop write their detail into the
        // tool call's error ENVELOPE, not as an `"LLM error"`-prefixed `StepMessage` —
        // `runTeamGeneration` is the one that matters (`makeErrorEnvelope(message:)`).
        // Without this the manager was handed the tautology `Role '…' failed.` for a
        // decode error the harness held in full. Observed 2026-08-07: it noticed
        // ("The failure message is vague"), asked for the diagnosis, got none, and
        // restarted blind — which then destroyed the envelope it had asked for.
        if let envelopeError = failed.toolCalls.reversed()
            .lazy
            .filter({ $0.isError == true })
            .compactMap(\.errorMessage)
            .first
        {
            return envelopeError
        }
        // The synthetic generation step's id is an opaque UUID that names no role, so the
        // tautology below would hand the manager `Role 'team_generation_<uuid>' failed.`
        // Say what actually happened and what fixes it — `control_task resume` and
        // `manage_role restart` on that id both re-enter generation.
        if failed.isTeamGenerationStep {
            return "Team generation failed for this task; its record carries no detail. "
                + "Retry generation before the team can run."
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
    /// progress).
    ///
    /// **`now` MUST be a `MonotonicClock` stamp** — every source `lastActivity` reads
    /// is stamped with `MonotonicClock.shared.now()`, which runs ahead of wall clock
    /// by the drift accumulated at stamp time (measured: p99 37s, max 40s in a live
    /// parallel test worker). A wall-clock `now` understates idle by exactly that
    /// drift, and the `max(0, ...)` clamp turns the shortfall into a hard 0 — which
    /// silently suppresses the HANG verdict. Defaulted so callers cannot get it wrong;
    /// pinned by `AutovisorStatusTimingTests.testIdleSeconds_isMeasuredOnTheStampingClock_notWallClock`.
    static func idleSeconds(
        step: StepExecution,
        now: Date = MonotonicClock.shared.now(),
        lastStreamActivityAt: Date?
    ) -> Int {
        max(0, Int(now.timeIntervalSince(lastActivity(step: step, lastStreamActivityAt: lastStreamActivityAt))))
    }

    /// Seconds the role has been executing (to completion if finished, else to `now`).
    /// Same clock contract as `idleSeconds`: `now` is compared against
    /// `step.createdAt`/`completedAt`, both `MonotonicClock` stamps.
    static func roleElapsedSeconds(step: StepExecution, now: Date = MonotonicClock.shared.now()) -> Int {
        max(0, Int((step.completedAt ?? now).timeIntervalSince(step.createdAt)))
    }

    /// Seconds since the run started, or nil if there is no run.
    ///
    /// Same clock contract as the two above, and for the same operand: `run.createdAt` is a
    /// `MonotonicClock` stamp, so a wall-clock `now` understates the age by the accumulated
    /// drift and `max(0, ...)` clamps the shortfall to a flat 0. It was the one member of this
    /// trio without the default — inert only because its single caller happens to pass the
    /// right clock, which is precisely the state a second caller would end.
    static func taskElapsedSeconds(run: Run?, now: Date = MonotonicClock.shared.now()) -> Int? {
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

    // MARK: - Resumability

    /// Whether `control_task resume` will genuinely continue this step.
    ///
    /// Names an AFFORDANCE, not a diagnosis — a paused step is the one state the
    /// manager's triage has no verdict for: `AutovisorStuckEvaluator` returns
    /// `.notStuck` for anything that isn't `.running`, so `stuck`, `idle_seconds`
    /// and `running_tool` are all structurally absent, and `elapsed_seconds` keeps
    /// counting through app downtime (`StatusRecoveryService` never sets
    /// `completedAt`). Left to infer, a manager reads "hours with nothing
    /// happening" and reaches for `manage_role restart`, which wipes the
    /// conversation and every tool call it was about to continue from.
    ///
    /// Mirrors `resumeRun` branch 3 exactly: a `.paused` step whose role is still
    /// `.working` (deliberate pause) or is `.idle` with preserved history (the
    /// app-quit shape `StatusRecoveryService` produces — it is the only writer of
    /// `.idle` alongside a `.paused` step). **Keep in lock-step with
    /// `NTMSOrchestrator.resumeRun`**: drift here promises the manager a resume the
    /// runtime would silently drop.
    static func isResumable(
        step: StepExecution,
        roleStatus: RoleExecutionStatus?,
        taskIsClosed: Bool
    ) -> Bool {
        guard !taskIsClosed, step.status == .paused else { return false }
        // The synthetic generation step belongs to no roster, so it has no `roleStatuses`
        // entry and neither arm below could ever fire — but `resumeRun` short-circuits to
        // `spawnTeamGeneration` for it, ahead of branch 3, so `.paused` IS resumable.
        // Step-local and exact: the success arm writes `.done`, so a task that adopted a
        // team never carries a `.paused` generation step.
        if step.isTeamGenerationStep { return true }
        if roleStatus == .working { return true }
        return roleStatus == .idle && !(step.messages.isEmpty && step.llmConversation.isEmpty)
    }

    // MARK: - Accept-rejection advice

    /// The one sentence explaining WHY `control_task close` finalizes a Review task.
    /// Shared by the accept-rejection advice below and `handleTaskStatus`'s close hint
    /// so the two channels a manager reads in one pass cannot drift apart (a third,
    /// hand-authored copy lives in the manager prompt's §Review line, which is pinned).
    static let closeAcceptsEverything = "close accepts every role's output"

    /// Manager-facing remedy appended (never substituted) to a `manage_role accept`
    /// rejection in `applyAcceptRole`'s `.reject` arm. The raw `acceptanceErrors`
    /// string names the fact ("Role already completed") but not the way out, and the
    /// manager has no other recovery channel — `ToolErrorNotePolicy.direction` never runs for
    /// collaboration-path tools, and the Autovisor error funnel passes no `next` hint
    /// (the envelope has the slot; `applyAutovisorAction` leaves it empty). Observed
    /// 2026-08-11: a manager facing a Review task tried `accept` on the `.done` role,
    /// got the bare fact, and stalled instead of `control_task close`.
    ///
    /// String-only ON PURPOSE: returning a `NextHint` here would make `AutovisorStatus`
    /// the first Domain type to reference one from `Services/Tools` — the boundary the
    /// `StepToolCall.errorMessage` placement deliberately kept. The machine-copyable
    /// close hint rides the `task_status` success envelope instead (`handleTaskStatus`).
    ///
    /// `taskReadyToClose` MUST be `NTMSTask.isReadyForFinalAcceptance` — the canonical
    /// "Review with nothing left at a per-role gate" predicate every review affordance
    /// keys on. A bare "derives Review" test is NOT it: the `onlyAcceptanceOrComplete`
    /// arm of `derivedStatusFromActiveRun` also derives Review while a sibling still
    /// holds a live `.needsAcceptance` gate, and advising close there sweeps that
    /// role's output past the Supervisor unreviewed (`finalizeRoleStatusesForClose`
    /// rewrites the gate to `.done` — the silent acceptance `RoleStepReconciler`
    /// refuses to perform). `isChatModeTask` covers the branch that predicate can never
    /// reach (chat is excluded from it by definition): a chat task's completed
    /// producing role rejects here too, and its honest exit is also close — a chat
    /// task runs until closed. `.needsAcceptance` returns nil — `routeAccept` never
    /// rejects it. Every tool named must survive `AutovisorGoalLint.scanStrict`
    /// (pinned by `AutovisorActionTests.testAcceptAdvice_namesOnlyManagerTools`).
    static func acceptRejectionAdvice(
        roleStatus: RoleExecutionStatus?,
        isChatModeTask: Bool,
        taskReadyToClose: Bool
    ) -> String? {
        guard let roleStatus else {
            return "call task_status for each role's current status"
        }
        switch roleStatus {
        case .needsAcceptance:
            return nil
        case .done, .accepted:
            // Deliberately does NOT repeat the table facts ("already completed" /
            // "already accepted"): the composed message would read the fact twice, and
            // the duplicate substring let the replace-not-append mutation slip past the
            // existing `failsWithSpecificReason` pin (its needle matched the advice alone).
            if taskReadyToClose {
                return "nothing further awaits per-role acceptance; finalize with control_task close (\(closeAcceptsEverything))"
            }
            if isChatModeTask {
                return "nothing awaits acceptance on it; a chat task runs until control_task close ends it"
            }
            return "no acceptance is pending for it; other roles may still be active — check task_status"
        case .working:
            return "wait for it to finish, or steer it with message_task"
        case .failed:
            // Names the RECOVERABLE verbs only — `delete` is an irreversible cascade
            // (removes delegated children too) and must not ride an error string a
            // small model may obey verbatim; the prompt's Failed triage owns that call.
            return "restart it with manage_role restart plus guidance, or control_task stop if the task no longer serves the goal"
        case .revisionRequested:
            return "a revision is already in flight; check task_status for its progress"
        case .idle, .ready:
            return "it has not produced work to accept yet; task_status shows its progress"
        case .skipped:
            // Restart is not free: it cascades. Say so, so the manager weighs it against
            // downstream roles whose accepted work the reset would discard.
            return "it was skipped; manage_role restart re-runs it and resets its downstream roles"
        }
    }
}
