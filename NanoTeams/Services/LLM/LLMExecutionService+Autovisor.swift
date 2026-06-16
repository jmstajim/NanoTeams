import Foundation

/// Service-layer handlers for the 9 Autovisor management tools. Invoked from
/// `appendCollaborationResult` when a manager tool's `ToolSignal` is dispatched.
/// Reads (`list_tasks`, `task_status`) read the delegate's snapshot / load a task;
/// writes translate to a `AutovisorAction` and apply it via the single
/// `performAutovisorAction` hook. Each returns the JSON envelope the LLM sees.
extension LLMExecutionService {

    // MARK: - Manager-step detection

    /// True when `stepID` belongs to the Autovisor task — detected via the
    /// step's resolved team templateID (robust against role-id resolution quirks;
    /// the manager team has exactly one executing role). Drives the memory
    /// write-through and goal/memory prompt injection.
    func isAutovisorStep(stepID: String, taskID: Int) -> Bool {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID),
              let task = delegate.loadedTask(taskID),
              let team = resolveTeam(task: task) else { return false }
        return team.templateID == AutovisorConstants.teamTemplateID
    }

    /// The standing-memory block injected into the manager's system prompt (via
    /// globalContext) on every run. Empty for non-manager steps. The GOAL is NOT
    /// here — it's the manager's brief (the "Supervisor Task" artifact, rendered as
    /// "## Supervisor Goal" by `PromptBuilder`), kept in lock-step with
    /// `settings.autovisorGoal`. Keeping the goal in two prompt sections would
    /// duplicate it.
    func autovisorPromptBlock() -> String {
        guard let settings = delegate?.snapshot?.workFolder.settings else { return "" }
        let memory = settings.autovisorMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memory.isEmpty else { return "" }
        return "## Current Memory (your standing notes from prior reviews)\n" + memory
    }

    // MARK: - Reads

    func handleListTasks() async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "Autovisor unavailable.")
        }
        let snap = delegate.snapshot
        let managerID = snap?.workFolder.state.autovisorTaskID
        let tasks = (snap?.tasksIndex.tasks ?? [])
            .filter { $0.parentTaskID == nil && $0.id != managerID }
            .sorted { $0.updatedAt > $1.updatedAt }

        struct TaskRow: Codable {
            var id: Int
            var title: String
            var status: String
            /// Seconds since the task last changed — a cheap triage hint: a `running`
            /// task whose `updated_seconds_ago` is large may be hung; drill in via
            /// task_status (which has the full timing + stuck verdict).
            var updated_seconds_ago: Int
        }
        struct ListData: Codable { var tasks: [TaskRow] }

        let now = Date()
        let rows = tasks.map {
            TaskRow(
                id: $0.id, title: $0.title, status: $0.status.rawValue,
                updated_seconds_ago: max(0, Int(now.timeIntervalSince($0.updatedAt)))
            )
        }
        return makeSuccessEnvelope(data: ListData(tasks: rows))
    }

    func handleTaskStatus(taskID: Int) async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "Autovisor unavailable.")
        }
        guard let task = await delegate.autovisorLoadTask(taskID) else {
            return makeErrorEnvelope(code: .commandFailed, message: "Task #\(taskID) not found.")
        }

        /// A `{kind, detail}` row when a role is looping or hung; absent otherwise.
        struct StuckRow: Codable { var kind: String; var detail: String? }
        struct StepRow: Codable {
            var role_id: String
            var status: String
            /// Seconds the role has been executing (to completion if finished).
            var elapsed_seconds: Int
            /// Seconds since the role last produced a token / message / tool call
            /// (or since it started, if it hasn't produced anything yet). Only present
            /// while `running`. Large + running may mean a long single response OR a
            /// hang — check `stuck`.
            var idle_seconds: Int?
            var message_count: Int
            var tool_call_count: Int
            /// Name of the tool currently executing (result not yet in), if any —
            /// a role mid-tool is working, not stuck.
            var running_tool: String?
            var stuck: StuckRow?
        }
        struct ArtifactRow: Codable { var name: String; var path: String? }
        struct StatusData: Codable {
            var task_id: Int
            var title: String
            var status: String
            /// Seconds since the current run started.
            var elapsed_seconds: Int?
            var run_timeout_seconds: Int?
            var timed_out: Bool
            var steps: [StepRow]
            var artifacts: [ArtifactRow]
            var pending_question: String?
            var last_error: String?
            /// Role ids genuinely awaiting acceptance (`.needsAcceptance`). Omitted when none —
            /// a finished task whose roles are all `.done` needs `control_task close` (which
            /// accepts everything), NOT a per-role `manage_role accept`. Ids match `steps[].role_id`.
            var roles_needing_acceptance: [String]?
            /// Task-level verdict — the first looping/hung running role, if any.
            var stuck: StuckRow?
        }

        let now = Date()
        // User-tunable stuck-detection thresholds (Settings → Autovisor → Stuck
        // detection), defaulting to the constants when no snapshot is loaded.
        let tuning = delegate.snapshot?.workFolder.settings.autovisorTuning ?? .default
        var steps: [StepRow] = []
        var artifacts: [ArtifactRow] = []
        var pendingQuestion: String?
        var taskStuck: StuckRow?
        let run = task.runs.last
        if let run {
            for step in run.steps {
                let live = delegate.streamLastActivityAt(stepID: step.id, taskID: task.id)
                let verdict = AutovisorStuckEvaluator.evaluate(
                    step: step, now: now, lastStreamActivityAt: live,
                    liveStreamText: delegate.streamLiveText(stepID: step.id, taskID: task.id),
                    hangSeconds: tuning.stuckHangSeconds,
                    loopRecencySeconds: tuning.stuckLoopRecencySeconds
                )
                let stuckRow = verdict.wireRow.map { StuckRow(kind: $0.kind, detail: $0.detail) }
                if taskStuck == nil, let stuckRow { taskStuck = stuckRow }
                let runningTool = (step.status == .running && AutovisorStatus.hasToolInFlight(step: step))
                    ? step.toolCalls.last?.name : nil

                steps.append(StepRow(
                    role_id: step.effectiveRoleID,
                    status: step.status.rawValue,
                    elapsed_seconds: AutovisorStatus.roleElapsedSeconds(step: step, now: now),
                    idle_seconds: step.status == .running
                        ? AutovisorStatus.idleSeconds(step: step, now: now, lastStreamActivityAt: live)
                        : nil,
                    message_count: step.messages.count,
                    tool_call_count: step.toolCalls.count,
                    running_tool: runningTool,
                    stuck: stuckRow
                ))
                if step.needsSupervisorInput, let q = step.supervisorQuestion, !q.isEmpty {
                    pendingQuestion = q
                }
                for art in step.artifacts {
                    // `task_status` hands back a `read_file`-able path (not inlined content)
                    // so the manager pulls the FULL artifact on demand — no snippet cap, no
                    // re-read that can fail with `[unreadable]`. nil → row omits `path`.
                    artifacts.append(ArtifactRow(name: art.name, path: art.llmReadablePath))
                }
            }
        }

        // Surface which roles actually await acceptance — RoleExecutionStatus is otherwise
        // invisible to the manager (steps only expose StepStatus). Sorted for a deterministic
        // wire payload; omitted entirely when none. Intersected with the step ids so every
        // listed id is actionable via `manage_role accept` (which resolves a step) — an orphan
        // `.needsAcceptance` status with no step row would be un-actionable and would break the
        // "ids match steps[].role_id" contract this field promises.
        var rolesNeedingAcceptance: [String]?
        if let run {
            let stepRoleIDs = Set(run.steps.map(\.effectiveRoleID))
            let ids = AcceptanceService.getPendingAcceptances(roleStatuses: run.roleStatuses)
                .filter { stepRoleIDs.contains($0) }
                .sorted()
            if !ids.isEmpty { rolesNeedingAcceptance = ids }
        }

        let data = StatusData(
            task_id: taskID,
            title: task.title,
            status: task.derivedStatusFromActiveRun().rawValue,
            elapsed_seconds: AutovisorStatus.taskElapsedSeconds(run: run, now: now),
            run_timeout_seconds: task.runTimeoutSeconds.map { Int($0) },
            timed_out: run?.timedOutAt != nil,
            steps: steps,
            artifacts: artifacts,
            pending_question: pendingQuestion,
            last_error: delegate.lastErrorMessageForTask(taskID),
            roles_needing_acceptance: rolesNeedingAcceptance,
            stuck: taskStuck
        )
        return makeSuccessEnvelope(data: data)
    }

    // MARK: - Writes (translate signal → AutovisorAction → single hook)

    func handleCreateManagedTask(title: String, brief: String, teamID: String?) async -> String {
        await applyAutovisorAction(.createManagedTask(title: title, brief: brief, teamID: teamID))
    }

    func handleControlTask(taskID: Int, verb: ControlVerb) async -> String {
        await applyAutovisorAction(.controlTask(taskID: taskID, verb: verb))
    }

    func handleManageRole(taskID: Int, roleID: String, verb: RoleVerb) async -> String {
        await applyAutovisorAction(.manageRole(taskID: taskID, roleID: roleID, verb: verb))
    }

    func handleAnswerTaskQuestion(taskID: Int, answer: String) async -> String {
        await applyAutovisorAction(.answerTaskQuestion(taskID: taskID, answer: answer))
    }

    func handleMessageTask(taskID: Int, text: String, roleID: String?) async -> String {
        await applyAutovisorAction(.messageTask(taskID: taskID, text: text, roleID: roleID))
    }

    func handleScheduleTask(taskID: Int, intervalMinutes: Int) async -> String {
        await applyAutovisorAction(.scheduleTask(taskID: taskID, intervalMinutes: intervalMinutes))
    }

    func handleSetWorkFolderContext(content: String) async -> String {
        await applyAutovisorAction(.setWorkFolderContext(content: content))
    }

    /// `wait_for_events` — the manager has nothing left to do this pass. Flip the
    /// step's `parkForEventsRequested` flag; the tool loop checks it at the top of
    /// the next iteration (no extra LLM round-trip) and parks the step at
    /// `.needsSupervisorInput` with the session preserved, so a human message
    /// continues the SAME conversation (event/recurrence wakes supersede the park
    /// with a fresh pass). Unlike the other manager tools this does NOT route
    /// through `performAutovisorAction` — it mutates execution state, not task state.
    func handleWaitForEvents(stepID: String, taskID: Int) async -> String {
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        // The optional-chained flag write silently no-ops when the execution
        // state was concurrently torn down (`cancelExecutions` on pause/stop) —
        // returning the success envelope then would tell the model it parked
        // when nothing was recorded. Guard so the contract stays honest; if the
        // loop is genuinely dead the envelope never ships anyway.
        guard executionStates[stepKey] != nil else {
            return makeErrorEnvelope(code: .commandFailed, message: "Step is no longer running.")
        }
        executionStates[stepKey]?.parkForEventsRequested = true
        struct IdleData: Codable { var status: String }
        return makeSuccessEnvelope(data: IdleData(status: "idle — will resume on supervisor message or events"))
    }

    /// Parks a step whose `parkForEventsRequested` flag was consumed
    /// (`wait_for_events`): `.needsSupervisorInput` with the idle-park question and
    /// the live session id preserved, so a human answer continues the SAME
    /// conversation via stateful continuation. `setNeedsSupervisorInput` also fires
    /// the queued-message backstop, so messages that arrived during the pass (after
    /// the last inject point) flush into the park immediately. A persist failure
    /// fails the step — and surfaces a banner FIRST, independently of
    /// `completeStepFailure`: the closure-short-circuit causes of `persisted ==
    /// false` (delegate gone, step not in the latest run) hit the same guards
    /// inside `completeStepFailure` and would otherwise no-op with zero signal.
    func parkStepForEvents(stepID: String, taskID: Int, sessionID: String?) async {
        let persisted = await setNeedsSupervisorInput(
            stepID: stepID,
            taskID: taskID,
            question: AutovisorConstants.idleParkQuestion,
            sessionID: sessionID)
        if !persisted {
            delegate?.setLastErrorMessageForUI(
                "Autovisor: failed to park for events (step \(stepID)) — failing the step.")
            await completeStepFailure(
                stepID: stepID,
                taskID: taskID,
                errorMessage: "Failed to persist idle park; step aborted.")
        }
    }

    // MARK: - Private

    private func applyAutovisorAction(_ action: AutovisorAction) async -> String {
        guard let delegate else {
            return makeErrorEnvelope(code: .commandFailed, message: "Autovisor unavailable.")
        }
        let result = await delegate.performAutovisorAction(action)
        if result.ok {
            struct OKData: Codable { var status: String; var message: String; var task_id: Int? }
            return makeSuccessEnvelope(data: OKData(status: "ok", message: result.message, task_id: result.createdTaskID))
        }
        return makeErrorEnvelope(code: .commandFailed, message: result.message)
    }

}
