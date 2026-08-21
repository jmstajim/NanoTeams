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
            let allTeams = snapshot?.workFolder.teams ?? []
            let activeTeam = snapshot?.workFolder.activeTeam
            let teamPolicy = snapshot.map { AutovisorTeamPolicy(settings: $0.workFolder.settings) }
                ?? .unrestricted
            let resolution = teamPolicy.classify(
                teamID: teamID, allTeams: allTeams, activeTeam: activeTeam)
            // Same predicate the omit branch of `classify` uses — computing viability with a
            // different question here would let the remedy contradict the refusal.
            let omitPathIsViable = activeTeam.map {
                !$0.isChatMode && !$0.isHiddenFromPickers && !teamPolicy.blocks(id: $0.id)
            } ?? false
            if let message = teamPolicy.failureMessage(
                for: resolution, allTeams: allTeams, omitPathIsViable: omitPathIsViable) {
                return .failure(message)
            }
            let resolvedTeamID: NTMSID?
            switch resolution {
            case .generated:
                resolvedTeamID = await ensureGeneratedTeamID()
            case .team(let id):
                resolvedTeamID = id
            default:
                // `.useActiveTeam` — every other case produced a message above and returned.
                resolvedTeamID = nil
            }
            // Keyed on `errorSurfaceCount`, NOT on the `lastErrorMessage` slot — see
            // `reportingError` below for the full argument. Reading the slot directly
            // attributed an UNRELATED banner to this creation: `createTask`'s
            // no-work-folder exit returns nil WITHOUT setting anything, so whatever an
            // earlier failure had left in the slot was reported as the reason creation
            // failed. The mirror case is just as wrong — a banner consumed by a render
            // during the `await` reads back nil and buries a real, specific error under
            // the generic string. Only an error surfaced BY this call may be reported.
            let creationErrorsBefore = errorSurfaceCount
            guard let id = await createTask(
                title: title, supervisorTask: brief, preferredTeamID: resolvedTeamID, makeActive: false
            ) else {
                return .failure(
                    errorSurfaced(since: creationErrorsBefore) ?? "Failed to create task.")
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
            // Keyed on `errorSurfaceCount`, NOT on a snapshot of the `lastErrorMessage`
            // slot, for the reason `reportingError` below documents: that snapshot fails
            // in BOTH directions and each failure silently discards the very detail this
            // arm exists to deliver. A REPEATED identical failure — the manager retrying
            // the same dead question, the commonest case here — never differs from the
            // snapshot, and a banner consumed by a render across the `await` reads back
            // nil. Both degrade to the generic string.
            // `isAutoAnswer: true` — the Autovisor (an LLM) is the one answering.
            let before = errorSurfaceCount
            let ok = await answerSupervisorQuestion(
                stepID: stepID, taskID: taskID, answer: answer, isAutoAnswer: true)
            if ok { return .success("Answered task #\(taskID).") }
            let detail = errorSurfaced(since: before)
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
    ///
    /// Keyed on `errorSurfaceCount`, not on a snapshot of the `lastErrorMessage` slot:
    /// that snapshot claimed success for a genuine failure in two ways. A REPEATED
    /// identical error — the manager re-writing its memory each pass against a disk that
    /// is still full, the commonest shape here — never differs from the snapshot; and a
    /// banner consumed by a render across the `await` reads back as the `nil` it started
    /// from. Both told the manager its memory landed when it had not, which is the one
    /// thing this return value exists to prevent.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func persistAutovisorMemory(_ text: String) async -> Bool {
        let before = errorSurfaceCount
        await updateAutovisorMemory(text)
        return errorSurfaced(since: before) == nil
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
            let errorsBefore = errorSurfaceCount
            await startRun(taskID: taskID)
            let started = (loadedTask(taskID)?.runs.count ?? 0) > runsBefore
                || managerTaskEngineActive(taskID) || isGeneratingTeam(taskID: taskID)
            return started ? .success("Started task #\(taskID).")
                : .failure(errorSurfaced(since: errorsBefore)
                    ?? "Task #\(taskID) could not start.")
        case .pause:
            return await reportingError("Paused task #\(taskID).") { await self.pauseRun(taskID: taskID) }
        case .resume:
            // A task still waiting on team generation resumes BY REGENERATING (see
            // `resumeRun`). Route it to the reporting wrapper rather than through
            // `reportingError`: that wrapper reports `ok:true` whenever no *error*
            // surfaces, and both of the retry path's silent exits set `lastInfoMessage`.
            // It also checks the precondition BEFORE the cleanup deletes the `create_team`
            // record — the same reason `manage_role restart` on a generation step is
            // routed here instead of running as a role verb.
            if needsTeamGeneration(taskID: taskID) {
                return await retryTeamGenerationReportingResult(taskID: taskID)
            }
            return await reportingError("Resumed task #\(taskID).") { await self.resumeRun(taskID: taskID) }
        case .stop:
            stopEngineForTask(taskID)
            return .success("Stopped task #\(taskID).")
        case .close:
            // Recursive stop FIRST so in-flight delegation children aren't orphaned
            // (dive-deeper finding 12b — closeTask's own stopEngine is non-recursive).
            stopEngineForTask(taskID)
            // `closeTask` has a SILENT `false` (its `loadedTask == nil` bail), so the
            // slot routinely holds a foreign message at this point — reading it directly
            // reported an unrelated failure as the reason the close failed, and the
            // manager acts on that diagnosis.
            let errorsBefore = errorSurfaceCount
            let ok = await closeTask(taskID: taskID)
            return ok ? .success("Closed task #\(taskID).")
                : .failure(errorSurfaced(since: errorsBefore)
                    ?? "Failed to close task #\(taskID).")
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
        // `resolveManagedRoleStep` checks that a STEP exists, not that it belongs to the
        // team's roster — and `runTeamGeneration` injects a synthetic
        // `team_generation_<UUID>` step that belongs to no roster and that the engine
        // cannot execute at all. Letting a role verb through on it is not a no-op, it is
        // destructive: `restartRole` → `StepExecution.reset()` erased the create_team
        // error envelope (the only record of WHY generation failed) and then woke an
        // engine that has no way to re-run generation, leaving the task `running` forever
        // with zero activity. Observed 2026-08-07; under the manager's own
        // "ONE TASK IN FLIGHT" rule that deadlocks every milestone behind it.
        //
        // `restart` is routed to the operation the manager actually wanted;
        // `retryTeamGeneration` already owns this prefix as a namespace and clears the
        // stale step itself, so it recovers even from the wedged state.
        if roleID.hasPrefix(StepExecution.teamGenerationIDPrefix) {
            guard case .restart = verb else {
                return .failure(
                    "'\(roleID)' is team generation, not a role — \(verb.autovisorVerbName) does not apply. "
                        + "Use manage_role restart to re-run generation, or control_task delete to drop the task.")
            }
            return await retryTeamGenerationReportingResult(taskID: taskID)
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
            //
            // The `.paused` precondition is deliberate and stays: restart IS the remedy
            // for a stuck RUNNING role, and it must still proceed after `control_task
            // stop` (both pinned by `AutovisorOrchestratorTests`). Widening this to every
            // state was considered after the 2026-08-07 wedge — a step that failed before
            // any engine existed has no engine state, so the guard could not see it — and
            // rejected: that case is the SYNTHETIC generation step, which is now refused
            // by roster-shape at the top of this method and never reaches here.
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
            // `acceptRole` returns false from several guards that surface nothing
            // (status not `.needsAcceptance`, no active run), so a foreign banner would
            // otherwise be handed back as the reason.
            let errorsBefore = errorSurfaceCount
            let ok = await acceptRole(taskID: taskID, roleID: roleID)
            return ok ? .success("Accepted role \(roleID) on task #\(taskID).")
                : .failure(errorSurfaced(since: errorsBefore)
                    ?? "Could not accept role \(roleID).")
        case .reject(let reason):
            // APPEND the manager-facing remedy, never replace: the table string is the
            // pinned fact ("Role already completed"), the suffix is the way out — the
            // manager has no other recovery channel (no guidance turn, no `next` hint
            // on the Autovisor error envelope). `routeAccept` is pure and nothing
            // suspends between the task load above and here, so the predicates are
            // consistent with the statuses it just rejected on.
            // `isReadyForFinalAcceptance`, NOT a bare derived-status test: a task with
            // a sibling at a live `.needsAcceptance` gate ALSO derives Review, and
            // close advice there would sweep the gated output past the Supervisor —
            // the same reason `handleTaskStatus` gates its close hint on this exact
            // predicate (the two surfaces must agree in every state).
            if let advice = AutovisorStatus.acceptRejectionAdvice(
                roleStatus: run.roleStatuses[roleID],
                isChatModeTask: isChatModeTask,
                taskReadyToClose: task.isReadyForFinalAcceptance
            ) {
                return .failure(reason + " — " + advice)
            }
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
        let errorsBefore = errorSurfaceCount
        let closed = await closeTask(taskID: taskID)
        let reason = errorSurfaced(since: errorsBefore) ?? "unknown"
        return closed
            ? .success("Finished role \(roleID) and closed chat task #\(taskID) — no other roles were active.")
            : .failure("Finished role \(roleID) on chat task #\(taskID), but closing it failed: \(reason). Retry with control_task close.")
    }

    // `ManagedTeamResolution` + `classify` moved onto `AutovisorTeamPolicy` (Domain): the
    // block list made the decision policy-shaped, and the failure strings are model-read, so
    // both belong on a pure `nonisolated` type that unit tests and the prompt-convention
    // sweep can reach without standing up an orchestrator.

    /// Returns the id of the (lazily-created) generated placeholder team.
    private func ensureGeneratedTeamID() async -> NTMSID {
        if let existing = snapshot?.workFolder.teams.first(where: { $0.isGeneratedPlaceholder }) {
            return existing.id
        }
        let team = TeamTemplateFactory.generatedTeam()
        await mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.isGeneratedPlaceholder }) {
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
    ///
    /// Keys on `errorSurfaceCount`, NOT on the `lastErrorMessage` slot, which the error
    /// banner writes back to nil on any render. Snapshot-and-compare over that slot fails
    /// in both directions across the `await`: a failed `control_task delete` sets the error,
    /// `removeTask` then suspends again in `reconcileChatModelResidency`, SwiftUI renders,
    /// the banner consumes the slot, and the manager is told `ok:true` for a task still on
    /// disk — which keeps occupying its "ONE TASK IN FLIGHT" slot and keeps firing its
    /// recurrence. A REPEATED identical error was swallowed too, since it never differed
    /// from the snapshot. Same class as the one `retryTeamGenerationReportingResult`
    /// documents; that one reads durable task state instead, which is stronger where it
    /// exists, but these verbs have no comparable durable signal.
    private func reportingError(_ successMessage: String, _ op: () async -> Void) async -> AutovisorActionResult {
        let before = errorSurfaceCount
        await op()
        if let err = errorSurfaced(since: before) { return .failure(err) }
        return .success(successMessage)
    }

    #if DEBUG
    /// Test seam. Both failure modes this guards against need an op that fails on demand,
    /// and every verb routed through it (`pause` / `resume` / `delete` / `rename` /
    /// `setTimeout`) fails only on real disk or engine conditions a test cannot stage.
    func _testReportingError(
        _ successMessage: String, _ op: () async -> Void
    ) async -> AutovisorActionResult {
        await reportingError(successMessage, op)
    }
    #endif
}
