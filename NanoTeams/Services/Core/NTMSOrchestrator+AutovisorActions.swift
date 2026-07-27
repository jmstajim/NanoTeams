import Foundation

// Autovisor action hook (LLMStateDelegate): performAutovisorAction and its
// control_task / manage_role verb dispatchers + the memory/stream delegate
// hooks. Self-contained private helpers (verb appliers, team classifier).
extension NTMSOrchestrator {

    // MARK: - Action hook (LLMStateDelegate)

    /// Applies one Autovisor write-action by dispatching to the matching
    /// orchestrator operation. Enforces the self-guard up front. See
    /// `AutovisorAction`.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func performAutovisorAction(_ action: AutovisorAction) async -> AutovisorActionResult {
        // Self-guard: the manager must never act on its own task (would deadlock /
        // self-destruct). Folder-level actions (createManagedTask, setWorkFolderContext)
        // have no target and pass through. A task-targeted action against a task that
        // doesn't exist fails loudly here instead of silently no-op'ing downstream.
        if let target = action.targetTaskID {
            if target == autovisorTaskID {
                return .failure("Refused: the manager cannot act on its own task (#\(target)).")
            }
            await ensureTaskLoaded(target)
            guard loadedTask(target) != nil else {
                return .failure("Task #\(target) not found — call list_tasks for current task ids.")
            }
        }

        switch action {
        case .createManagedTask(let title, let brief, let teamID):
            // User-tunable caps (Settings → Autovisor → Limits); fall back to the
            // constant defaults when no snapshot is loaded.
            let tuning = snapshot?.workFolder.settings.autovisorTuning ?? .default
            // Runaway guard (dive-deeper finding 7): bound concurrent in-flight work.
            let runningNonManager = taskEngineStates.filter {
                $0.value == .running && $0.key != autovisorTaskID
            }.count
            if runningNonManager >= tuning.maxConcurrentManagedTasks {
                return .failure("Too many tasks already running (\(runningNonManager)). Wait for some to finish before creating more.")
            }
            // Per-review cap: bound how many NEW tasks one review pass may spawn
            // (reset on each manager run start in `startRun`). The concurrent cap
            // alone wouldn't stop a burst of immediately-idle creations.
            if autovisorCreationsThisReview >= tuning.maxManagedTasksPerReview {
                return .failure("Per-review task-creation limit (\(tuning.maxManagedTasksPerReview)) reached this pass — review or finish existing tasks before creating more.")
            }
            // Resolve the team BEFORE creating anything: a provided-but-unresolvable
            // team_id must fail loudly, not silently fall back to the active team.
            let resolvedTeamID: NTMSID?
            switch classifyManagedTeamID(teamID) {
            case .useActiveTeam:
                resolvedTeamID = nil
            case .team(let id):
                resolvedTeamID = id
            case .generated:
                resolvedTeamID = await ensureGeneratedTeamID()
            case .generationDisabled:
                return .failure("Team generation is disabled for the Autovisor in this folder. Pick an existing team from the catalog in create_managed_task's description, or omit team_id to use the active team.")
            case .activeTeamIsChat(let name):
                return .failure("The folder's active team \"\(name)\" is a chat team — a managed task on it never finishes on its own. Pass a pipeline team_id from the catalog in create_managed_task's description explicitly.")
            case .unknown(let raw):
                return .failure("Unknown team_id '\(raw)'. Pick one from the catalog in create_managed_task's description, omit it for the active team, or use 'generated'.")
            }
            guard let id = await createTask(
                title: title, supervisorTask: brief, preferredTeamID: resolvedTeamID, makeActive: false
            ) else {
                return .failure(lastErrorMessage ?? "Failed to create task.")
            }
            autovisorCreationsThisReview += 1
            // Pre-mark the new task as seen so the manager's OWN creation can't trip the
            // `onTaskCreated` self-wake before the next event-wake overwrites the seen-set.
            autovisorSeenTaskIDs.insert(id)
            await ensureTaskLoaded(id)
            await startRun(taskID: id)
            return .success("Created and started task #\(id): \(title)", createdTaskID: id)

        case .controlTask(let taskID, let verb):
            return await applyControlTask(taskID: taskID, verb: verb)

        case .manageRole(let taskID, let roleID, let verb):
            return await applyManageRole(taskID: taskID, roleID: roleID, verb: verb)

        case .answerTaskQuestion(let taskID, let answer):
            guard let stepID = loadedTask(taskID)?.runs.last?.steps
                .first(where: { $0.needsSupervisorInput })?.id else {
                return .failure("Task #\(taskID) is not waiting for supervisor input.")
            }
            // On failure, `answerSupervisorQuestion` already set a specific
            // `lastErrorMessage` (race / attachment-finalize) — surface it to the
            // manager rather than a generic string so it learns WHY delivery failed.
            // `isAutoAnswer: true` — the Autovisor (an LLM) is the one answering.
            let before = lastErrorMessage
            let ok = await answerSupervisorQuestion(
                stepID: stepID, taskID: taskID, answer: answer, isAutoAnswer: true)
            if ok { return .success("Answered task #\(taskID).") }
            let detail = (lastErrorMessage != before ? lastErrorMessage : nil)
                ?? "Failed to deliver answer to task #\(taskID)."
            return .failure(detail)

        case .messageTask(let taskID, let text, let roleID):
            guard let formState = quickCaptureFormState,
                  let message = QuickCaptureFormState.QueuedChatMessage(
                      text: text, attachments: [], clippedTexts: [], targetRoleID: roleID,
                      // The Autovisor (an LLM) authored this — if the backstop
                      // delivers it as a question ANSWER, the feed must show the
                      // "Auto-answered" badge, not the human checkmark.
                      isFromAutomatedSupervisor: true
                  ) else {
                return .failure("Could not queue message for task #\(taskID).")
            }
            formState.appendQueuedMessage(message, for: taskID)
            // Wake an idle task so it consumes the message promptly (a fresh run
            // drains the queue on iteration 1); a running task picks it up next iteration.
            if taskEngineStates[taskID] != .running {
                await startRun(taskID: taskID)
            }
            return .success("Queued message for task #\(taskID).")

        case .scheduleTask(let taskID, let intervalMinutes):
            if intervalMinutes <= 0 {
                await setTaskRecurrence(taskID: taskID, recurrence: nil)
                return .success("Cleared schedule for task #\(taskID).")
            }
            let seconds = TimeInterval(max(1, intervalMinutes) * 60)
            let recurrence = TaskRecurrence(rule: .interval(seconds: seconds), isEnabled: true)
            await setTaskRecurrence(taskID: taskID, recurrence: recurrence)
            return .success("Task #\(taskID) will now run every \(intervalMinutes) min.")

        case .setWorkFolderContext(let content):
            return await reportingError("Updated the Work Folder Context.") {
                await self.updateWorkFolderContext(content)
            }
        }
    }

    /// Write-through of the manager's standing memory (from `update_scratchpad`).
    /// Returns `false` if the underlying `settings.json` write failed, so the
    /// caller can surface a persistence failure to the manager (its memory is its
    /// only cross-run state — a silent failure means it silently forgets).
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func persistAutovisorMemory(_ text: String) async -> Bool {
        let before = lastErrorMessage
        await updateAutovisorMemory(text)
        return lastErrorMessage == before
    }

    /// Loads a task (background tasks aren't always in `loadedTasks`) for `task_status`.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func autovisorLoadTask(_ taskID: Int) async -> NTMSTask? {
        await ensureTaskLoaded(taskID)
        return loadedTask(taskID)
    }

    /// Live token-activity timestamp for a step, sourced from the streaming
    /// preview manager. Feeds the Autovisor stuck-detector's hang check.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func streamLastActivityAt(stepID: String, taskID: Int) -> Date? {
        streamingPreviewManager.lastStreamActivity(stepID: stepID, taskID: taskID)
    }

    /// The step's current (uncommitted) streaming thinking+content buffer, combined
    /// the same way `DelegationLoopWatcher` combines them. Feeds the stuck-detector's
    /// within-message (thinking-loop) check. Returns nil when nothing is buffered.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func streamLiveText(stepID: String, taskID: Int) -> String? {
        let thinking = streamingPreviewManager.streamingThinking(stepID: stepID, taskID: taskID) ?? ""
        let content = streamingPreviewManager.streamingContent(stepID: stepID, taskID: taskID) ?? ""
        guard !thinking.isEmpty || !content.isEmpty else { return nil }
        return thinking + "\n" + content
    }

    // MARK: - Private

    private func applyControlTask(taskID: Int, verb: ControlVerb) async -> AutovisorActionResult {
        switch verb {
        case .start:
            // `startRun` silently returns when the engine is already active /
            // generating, so report that as a failure instead of a false success.
            if managerTaskEngineActive(taskID) || isGeneratingTeam(taskID: taskID) {
                return .failure("Task #\(taskID) is already running.")
            }
            let runsBefore = loadedTask(taskID)?.runs.count ?? 0
            await startRun(taskID: taskID)
            let started = (loadedTask(taskID)?.runs.count ?? 0) > runsBefore
                || managerTaskEngineActive(taskID) || isGeneratingTeam(taskID: taskID)
            return started ? .success("Started task #\(taskID).")
                           : .failure(lastErrorMessage ?? "Task #\(taskID) could not start.")
        case .pause:
            return await reportingError("Paused task #\(taskID).") { await self.pauseRun(taskID: taskID) }
        case .resume:
            return await reportingError("Resumed task #\(taskID).") { await self.resumeRun(taskID: taskID) }
        case .stop:
            stopEngineForTask(taskID)
            return .success("Stopped task #\(taskID).")
        case .close:
            // Recursive stop FIRST so in-flight delegation children aren't orphaned
            // (dive-deeper finding 12b — closeTask's own stopEngine is non-recursive).
            stopEngineForTask(taskID)
            let ok = await closeTask(taskID: taskID)
            return ok ? .success("Closed task #\(taskID).")
                      : .failure(lastErrorMessage ?? "Failed to close task #\(taskID).")
        case .delete:
            return await reportingError("Deleted task #\(taskID).") { await self.removeTask(taskID) }
        case .rename(let title):
            return await reportingError("Renamed task #\(taskID) to \"\(title)\".") {
                await self.updateTaskTitle(id: taskID, title: title)
            }
        case .setTimeout(let seconds):
            let msg = seconds == nil ? "Cleared run timeout for task #\(taskID)." : "Set run timeout for task #\(taskID)."
            return await reportingError(msg) { await self.setTaskRunTimeout(taskID: taskID, seconds: seconds) }
        }
    }

    private func applyManageRole(taskID: Int, roleID: String, verb: RoleVerb) async -> AutovisorActionResult {
        // Every role verb needs a real role in the task's latest run. A hallucinated
        // role_id would otherwise set a status for a nonexistent role (a §7 no-op)
        // and report success. `accept`'s own Bool already covers this AND rejects a role
        // that isn't `.needsAcceptance` (via `acceptRole`'s status guard), but validating
        // existence up front gives a clearer message for all verbs.
        guard resolveManagedRoleStep(taskID: taskID, roleID: roleID) != nil else {
            return .failure("Task #\(taskID) has no role '\(roleID)' — call task_status for valid role_ids.")
        }
        switch verb {
        case .restart(let comment):
            // `restartRole` → `StepExecution.reset` destroys the conversation, tool
            // calls and artifacts of this role AND every transitive downstream one.
            // On a PAUSED task that is almost never what the manager meant: pause is
            // the state with no `stuck` verdict and an `elapsed_seconds` that counts
            // app downtime, so a wedged-looking task is usually just an app that was
            // closed mid-run — and `resume` replays the very transcript restart would
            // erase. Reject and name the alternatives rather than warn-and-do: the
            // manager cannot undo the wipe, so a warning is a receipt, not honesty.
            // Deliberate discard stays available via `control_task stop` first, which
            // drops the engine state and lifts this guard.
            if taskEngineStates[taskID] == .paused,
               let step = resolveManagedRoleStep(taskID: taskID, roleID: roleID),
               step.hasCommittedWork {
                return .failure(
                    "restart would discard \(step.toolCalls.count) tool call(s) and the conversation of "
                        + "role \(roleID) on paused task #\(taskID). Use manage_role correct to steer it, "
                        + "control_task resume to continue it, or control_task stop first to discard deliberately.")
            }
            return await reportingError("Restarted role \(roleID) on task #\(taskID).") {
                await self.restartRole(taskID: taskID, roleID: roleID, comment: comment)
            }
        case .accept:
            return await applyAcceptRole(taskID: taskID, roleID: roleID)
        case .requestChanges(let comment):
            return await reportingError("Requested changes from role \(roleID) on task #\(taskID).") {
                await self.requestRevision(taskID: taskID, roleID: roleID, comment: comment)
            }
        case .correct(let comment):
            // `correctRole` hard-requires the task to be paused; pre-check so the
            // manager gets an actionable message instead of a false success.
            guard taskEngineStates[taskID] == .paused else {
                return .failure("correct requires task #\(taskID) to be paused first (use control_task pause).")
            }
            return await reportingError("Sent correction to role \(roleID) on task #\(taskID).") {
                await self.correctRole(taskID: taskID, roleID: roleID, comment: comment)
            }
        case .finishAdvisory:
            // Already-closed short-circuit — `finishRoleAndMaybeClose` can call `closeTask`,
            // so without this a finish_advisory on a closed task would re-stamp `closedAt`
            // and report a fresh "closed" success (mirrors `applyAcceptRole`'s guard, which
            // protects the `.finishChatRole` route into the same method).
            guard loadedTask(taskID)?.closedAt == nil else {
                return .failure("Task #\(taskID) is already closed.")
            }
            // Producing roles own artifact deliverables; force-finishing one strands the
            // pipeline (the engine then deadlocks with a misattributed "check Team Editor"
            // error). Reject at this seam — the manager's finish_advisory is the only
            // untrusted caller of the finish path (the UI wrapper is view-gated).
            if resolvedTeam(for: loadedTask(taskID)).completionType(forRoleID: roleID) == .producing {
                return .failure("finish_advisory only applies to chat/advisory roles; \(roleID) on task #\(taskID) is a producing role — accept it when task_status lists it in roles_needing_acceptance, or restart it with guidance.")
            }
            return await finishRoleAndMaybeClose(taskID: taskID, roleID: roleID)
        }
    }

    /// `manage_role accept` dispatch. `AcceptanceService.routeAccept` decides between
    /// ordinary acceptance, the chat-mode finish-and-maybe-close exit, and rejection.
    private func applyAcceptRole(taskID: Int, roleID: String) async -> AutovisorActionResult {
        // Idempotence: a closed task's accept must report "already closed", not re-stamp
        // closedAt and report a fresh success (which would invite a third call).
        guard loadedTask(taskID)?.closedAt == nil else {
            return .failure("Task #\(taskID) is already closed.")
        }
        guard let task = loadedTask(taskID), let run = task.runs.last else {
            return .failure("Task #\(taskID) has no active run.")
        }
        // `isChatModeTask` reads `task.isChatMode` — NOT `resolvedTeam.isChatMode`. The
        // predicate we need is "can this task reach .done without closeTask?", decided by
        // task.isChatMode at NTMSTask.derivedStatusFromActiveRun; the two agree where they
        // diverge (team edited post-creation). Role kind lives only on the definition, so
        // `resolvedTeam` is the only source for `roleIsProducing`.
        let isChatModeTask = task.isChatMode
        let roleIsProducing = resolvedTeam(for: task).completionType(forRoleID: roleID) == .producing

        switch AcceptanceService.routeAccept(
            roleID: roleID,
            roleStatuses: run.roleStatuses,
            isChatModeTask: isChatModeTask,
            roleIsProducing: roleIsProducing
        ) {
        case .accept:
            let ok = await acceptRole(taskID: taskID, roleID: roleID)
            return ok ? .success("Accepted role \(roleID) on task #\(taskID).")
                      : .failure(lastErrorMessage ?? "Could not accept role \(roleID).")
        case .reject(let reason):
            return .failure(reason)
        case .finishChatRole:
            return await finishRoleAndMaybeClose(taskID: taskID, roleID: roleID)
        }
    }

    /// Finishes an advisory role, then — for a chat-mode task with no other active work
    /// role — closes the task (chat tasks never reach `.done` on their own). Shared by the
    /// accept-route chat exit and the `finish_advisory` verb. Returns the manager-facing
    /// result directly, so no stale `lastErrorMessage` is ever echoed.
    private func finishRoleAndMaybeClose(taskID: Int, roleID: String) async -> AutovisorActionResult {
        guard await finishAdvisoryRoleAwaiting(taskID: taskID, roleID: roleID) else {
            return .failure("Could not finish role \(roleID) on task #\(taskID).")
        }
        // Re-read AFTER the finish — the close decision must derive from persisted state,
        // not a pre-mutation guess (`mutateTask == true` ≠ the closure ran).
        guard let task = loadedTask(taskID), task.isChatMode, let run = task.runs.last else {
            // Non-chat advisory finish: role is done, task stays open (the engine drives
            // it to completion without an acceptance flow).
            return .success("Finished advisory role \(roleID) on task #\(taskID).")
        }
        let active = run.activeWorkRoles(definitions: resolvedTeam(for: task).roles)
        guard active.isEmpty else {
            let names = active.map(\.roleName).joined(separator: ", ")
            return .success("Finished role \(roleID) on chat task #\(taskID). Still active: \(names). A chat task never finishes on its own — use control_task close when you want to end it.")
        }
        // No active work left → end the chat task. Recursive stop FIRST so in-flight
        // delegation children aren't orphaned (closeTask's own stopEngine is
        // non-recursive), matching the control_task .close arm. Both writes go through
        // mutateTask on @MainActor, so the race with the engine's own chat-done arm
        // (stopped just above) is benign.
        stopEngineForTask(taskID)
        let closed = await closeTask(taskID: taskID)
        return closed
            ? .success("Finished role \(roleID) and closed chat task #\(taskID) — no other roles were active.")
            : .failure("Finished role \(roleID) on chat task #\(taskID), but closing it failed: \(lastErrorMessage ?? "unknown"). Retry with control_task close.")
    }

    /// Outcome of classifying a `create_managed_task` team_id.
    private enum ManagedTeamResolution {
        case useActiveTeam            // omitted/empty → the folder's active team
        case team(NTMSID)             // an existing, non-hidden team
        case generated                // the `"generated"` sentinel
        case generationDisabled       // sentinel, but generation is off for this folder
        case activeTeamIsChat(String) // omitted, but the active team is chat → fail loudly
        case unknown(String)          // provided but unresolvable → must fail loudly
    }

    /// Classifies a team_id without side effects (testable). The `generated` case is
    /// materialized separately by `ensureGeneratedTeamID` so this stays pure.
    /// The `"generated"` sentinel resolves to `.generationDisabled` when the folder's
    /// `autovisorAllowTeamGeneration` is off — a runtime backstop for a model that
    /// emits the sentinel despite the schema (built via `buildSchema(allowGenerated:)`)
    /// no longer advertising it.
    private func classifyManagedTeamID(_ raw: String?) -> ManagedTeamResolution {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            // Omitted team_id → the folder's active team. But omission means "use the
            // default", not an intentional "I want an open-ended chat", and a chat active
            // team would spawn a task that never terminates on its own (occupying a
            // concurrency slot until a human closes it). Fail loudly so the manager picks
            // a pipeline team explicitly. (An explicit chat team_id IS allowed — it's a
            // marked, intentional choice, and the manager can `control_task close` it.)
            if let active = snapshot?.workFolder.activeTeam, active.isChatMode {
                return .activeTeamIsChat(active.name)
            }
            return .useActiveTeam
        }
        if raw == DelegationConstants.generatedTeamSentinel {
            let allowed = snapshot?.workFolder.settings.autovisorAllowTeamGeneration ?? true
            return allowed ? .generated : .generationDisabled
        }
        if let team = snapshot?.workFolder.teams.first(where: { $0.id == raw }), !team.isHiddenFromPickers {
            return .team(team.id)
        }
        return .unknown(raw)
    }

    /// Returns the id of the (lazily-created) generated placeholder team.
    private func ensureGeneratedTeamID() async -> NTMSID {
        if let existing = snapshot?.workFolder.teams.first(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
            return existing.id
        }
        let team = TeamTemplateFactory.generatedTeam()
        await mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
                proj.teams.append(team)
            }
        }
        return team.id
    }

    // MARK: - Private helpers

    /// True when the task's engine is in any active state (`startRun` would no-op).
    /// Mirrors the file-private `isTaskEngineActive` in `+Scheduling.swift`
    /// (Swift `private` is file-scoped, so it can't be shared across the extension).
    private func managerTaskEngineActive(_ taskID: Int) -> Bool {
        switch taskEngineStates[taskID] {
        case .running, .needsAcceptance, .needsSupervisorInput: return true
        default: return false
        }
    }

    /// The step for `roleID` in the task's latest run, or nil if no such role exists.
    private func resolveManagedRoleStep(taskID: Int, roleID: String) -> StepExecution? {
        loadedTask(taskID)?.runs.last?.steps.first { $0.effectiveRoleID == roleID }
    }

    /// Runs a `Void` orchestrator op and converts a freshly-surfaced error banner
    /// into a `.failure` for the manager. Used for the persistence/lifecycle verbs
    /// whose orchestrator methods report failure via `lastErrorMessage` (the
    /// silent-no-op cases that DON'T set an error — `start`, role validation,
    /// `correct`-not-paused — are pre-checked by the callers instead).
    private func reportingError(_ successMessage: String, _ op: () async -> Void) async -> AutovisorActionResult {
        let before = lastErrorMessage
        await op()
        if let err = lastErrorMessage, err != before { return .failure(err) }
        return .success(successMessage)
    }
}
