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
            /// True when the task runs a chat-mode team (no deliverables). A chat task
            /// never reaches Review and never finishes on its own — it reads `running`
            /// until you `control_task close` it. Seeing this at triage keeps the manager
            /// from planning a `manage_role accept` that can't apply.
            var chat_mode: Bool
            /// Seconds since the task last changed — a cheap triage hint: a `running`
            /// task whose `updated_seconds_ago` is large may be hung; drill in via
            /// task_status (which has the full timing + stuck verdict).
            var updated_seconds_ago: Int
            /// Present (and `true`) only when a role on this task is still owed an answer —
            /// never `false`, so its absence cannot deny a wait the row can't prove. A task
            /// that was waiting when the app last quit reads `paused` here, so `status`
            /// alone would send you to resume it (re-asking the question) instead of
            /// answering it with answer_task_question.
            var waiting_for_supervisor: Bool?
        }
        struct ListData: Codable { var tasks: [TaskRow] }

        let now = MonotonicClock.shared.now()
        let rows = tasks.map {
            TaskRow(
                id: $0.id, title: $0.title, status: $0.status.rawValue,
                chat_mode: $0.isChatMode,
                updated_seconds_ago: max(0, Int(now.timeIntervalSince($0.updatedAt))),
                waiting_for_supervisor: $0.isWaitingForSupervisor ? true : nil
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
            /// Present (and `true`) only when `control_task resume` will actually
            /// continue this step — never `false`, so its absence cannot promise a
            /// resume the runtime would drop. Exists because a `paused` step is the
            /// one state with no `stuck` verdict, no `idle_seconds` and no
            /// `running_tool`, and an `elapsed_seconds` that counts app downtime:
            /// without this the manager infers "dead for hours" and restarts,
            /// discarding the conversation resume would have replayed.
            var resumable: Bool?
            /// `producing` | `advisory` | `observer` — how the role ends. `advisory` is
            /// the verb token (`finish_advisory`; the UI labels it "Chat"). Omitted when
            /// the team can't be resolved, so an absent value never asserts a kind the
            /// payload can't prove.
            var role_kind: String?
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
            /// True when the task runs a chat-mode team (no supervisor deliverables). A
            /// chat task never reaches Review and never derives `.done` on its own — it
            /// ends only via `control_task close`. On such a task `manage_role accept` /
            /// `finish_advisory` on an `advisory` role finishes the role and closes the
            /// task once no other role is active; neither applies to a producing role.
            var chat_mode: Bool
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
            /// Can be non-empty even on a `chat_mode` task — a chat team may still hold a
            /// producing role at a mid-pipeline acceptance gate (accept those normally).
            var roles_needing_acceptance: [String]?
            /// Task-level verdict — the first looping/hung running role, if any.
            var stuck: StuckRow?
        }

        let now = MonotonicClock.shared.now()
        // User-tunable stuck-detection thresholds (Settings → Autovisor → Stuck
        // detection), defaulting to the constants when no snapshot is loaded.
        let tuning = delegate.snapshot?.workFolder.settings.autovisorTuning ?? .default
        var steps: [StepRow] = []
        var artifacts: [ArtifactRow] = []
        var pendingQuestion: String?
        var taskStuck: StuckRow?
        let run = task.runs.last
        // Role kind per role id, from the resolved team's definitions. Empty when the
        // team can't be resolved (nil snapshot / unpinnable team) → `role_kind` is then
        // omitted per row rather than asserting a kind the payload can't prove.
        // `uniquingKeysWith` (not `uniqueKeysWithValues:`) — role ids are name-derived, so a
        // team with two same-named roles has duplicate ids; the trapping initializer would
        // crash this hot read path. Last-wins matches `Run.stepsByRoleBaseID()`.
        let roleKindByID: [String: String] = resolveTeam(task: task).map { team in
            Dictionary(team.roles.map { ($0.id, $0.completionType.rawValue) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        if let run {
            for step in run.steps {
                let live = delegate.streamLastActivityAt(stepID: step.id, taskID: task.id)
                let verdict = AutovisorStuckEvaluator.evaluate(
                    step: step, now: now, lastStreamActivityAt: live,
                    liveStreamText: delegate.streamLiveText(stepID: step.id, taskID: task.id),
                    processingStatus: delegate.streamProcessingStatus(stepID: step.id, taskID: task.id),
                    hangSeconds: tuning.stuckHangSeconds,
                    prefillHangSeconds: tuning.stuckPrefillHangSeconds,
                    loopRecencySeconds: tuning.stuckLoopRecencySeconds
                )
                let stuckRow = verdict.wireRow.map { StuckRow(kind: $0.kind, detail: $0.detail) }
                if taskStuck == nil, let stuckRow { taskStuck = stuckRow }
                let runningTool = (step.status == .running && AutovisorStatus.hasToolInFlight(step: step))
                    ? step.toolCalls.last?.name : nil

                steps.append(StepRow(
                    role_id: step.effectiveRoleID,
                    status: step.status.rawValue,
                    // `true` or omitted — see `resumable`'s doc comment.
                    resumable: AutovisorStatus.isResumable(
                        step: step,
                        roleStatus: run.roleStatuses[step.effectiveRoleID],
                        taskIsClosed: task.closedAt != nil
                    ) ? true : nil,
                    role_kind: roleKindByID[step.effectiveRoleID],
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

        let derivedStatus = task.derivedStatusFromActiveRun()
        let data = StatusData(
            task_id: taskID,
            title: task.title,
            status: derivedStatus.rawValue,
            chat_mode: task.isChatMode,
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
        // Review with NOTHING at a per-role gate: the one state whose remedy the payload
        // otherwise never names — `roles_needing_acceptance` is (deliberately) omitted when
        // empty, so the manager saw `status: "needsSupervisorAcceptance"` and nothing else,
        // then reached for `manage_role accept` and dead-ended (observed 2026-08-11). The
        // machine-copyable hint rides the envelope's `next` slot at the decision point,
        // mirroring `read_file`'s cap hint.
        // Gated on `isReadyForFinalAcceptance` — the canonical predicate the human UI's
        // review affordances key on — NOT on `rolesNeedingAcceptance == nil`: that wire
        // field is step-INTERSECTED, so an orphan `.needsAcceptance` status with no step
        // row (roster edited mid-run) reads as "no gates" there while a gate still
        // exists; the canonical predicate reads the raw role set and stays silent. The
        // same predicate gates the accept-rejection advice (`applyAcceptRole`), so the
        // two surfaces cannot disagree. No hint while a listed gate awaits (accept those
        // first — prompt §Review), for chat tasks (excluded by the predicate), or for
        // closed ones (they derive `.done`).
        let next: NextHint? = task.isReadyForFinalAcceptance
            ? NextHint(
                suggested_cmd: ToolNames.controlTask,
                suggested_args: ["task_id": String(taskID), "action": "close"],
                reason: "Task is in Review with no per-role gates; \(AutovisorStatus.closeAcceptsEverything) — or manage_role request_changes if the work falls short."
            )
            : nil
        return makeSuccessEnvelope(data: data, next: next)
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
    /// (`wait_for_events`): `.needsSupervisorInput` with the idle-park question.
    /// The caller has already written `step.wireTranscript`, so a human answer
    /// continues the SAME conversation via `ConversationReplay` on re-entry.
    /// `setNeedsSupervisorInput` also fires
    /// the queued-message backstop, so messages that arrived during the pass (after
    /// the last inject point) flush into the park immediately. A persist failure
    /// fails the step — and surfaces a banner FIRST, independently of
    /// `completeStepFailure`: the closure-short-circuit causes of `persisted ==
    /// false` (delegate gone, step not in the latest run) hit the same guards
    /// inside `completeStepFailure` and would otherwise no-op with zero signal.
    /// - Parameter question: defaults to the standard idle-park text. The thinking-loop
    ///   terminal passes its diagnostic instead, so a loop-terminated pass is not
    ///   mistaken for a healthy idle by `taskHasIdleParkStep`'s exact-equality match.
    func parkStepForEvents(
        stepID: String,
        taskID: Int,
        question: String = AutovisorConstants.idleParkQuestion
    ) async {
        let persisted = await setNeedsSupervisorInput(
            stepID: stepID,
            taskID: taskID,
            question: question)
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
