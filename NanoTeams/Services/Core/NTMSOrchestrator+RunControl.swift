import Foundation

/// Run lifecycle: start, pause, resume.
extension NTMSOrchestrator {

    // MARK: - Run Lifecycle

    func startRun(taskID: Int) async {
        if let state = taskEngineStates[taskID],
           state == .running || state == .needsAcceptance || state == .needsSupervisorInput {
            return
        }
        // Prevent Play / Cmd+R re-entry while generation for this task is in flight.
        // Without this, `createNewRun` below would wipe the placeholder Supervisor
        // step and a second concurrent `runTeamGeneration` would be spawned.
        if isGeneratingTeam(taskID: taskID) { return }
        // Re-entrancy guard: everything below suspends (instructions rescan,
        // task load, run creation) BEFORE the engine-state guard above can see
        // the new run — a concurrent second call for the same task (Play +
        // queue-flush backstop / recurrence fire) would double-create runs.
        guard !startingRunTaskIDs.contains(taskID) else { return }
        startingRunTaskIDs.insert(taskID)
        defer { startingRunTaskIDs.remove(taskID) }

        // Refresh agent instruction files and role-attached skills so this run's
        // first prompt reflects the current disk state (a CLAUDE.md or a
        // SKILL.md edited since open is picked up).
        // Delegation children skip both refreshes: `startRunForTask` routes here
        // too, and rescanning mid-parent-run would swap the shared snapshots'
        // bytes under the parent's already-running steps.
        let isChildTask =
            snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.parentTaskID != nil
        if !isChildTask {
            await refreshAgentInstructions()
            await refreshAgentSkills()
        }

        await ensureTaskLoaded(taskID)
        await createNewRun(taskID: taskID)

        // For "Generated Team" template: run team generation in a detached Task so
        // `startRun` (and the QuickCapture submit chain awaiting it) returns as soon
        // as the placeholder Supervisor step is on disk. The engine is started from
        // inside the detached Task after generation succeeds — preserving the
        // invariant that the engine never starts before `task.generatedTeam` is set.
        if needsTeamGeneration(taskID: taskID) {
            // `clearingPriorSteps: false` — `createNewRun` above just replaced the run,
            // so there is nothing left over to clean up.
            spawnTeamGeneration(taskID: taskID, clearingPriorSteps: false)
            return
        }

        // Autovisor run start (any path: event-wake, recurrence, Run-now,
        // open-time pass). Stamp the "last reviewed" diagnostic timestamp, reset the
        // per-review creation counter, and seed the mid-review notice dedup set + the
        // deliver-once freshness baseline with everything matching right now — the pass
        // observes those via list_tasks, so only conditions that NEWLY arise mid-pass
        // inject a live notice (otherwise the manager's own `.running` transition
        // re-fires the observer and duplicates the triggering condition).
        if taskID == autovisorTaskID {
            autovisorLastWakeAt = Date()
            autovisorCreationsThisReview = 0
            seedAutovisorNotifiedKeysForPassStart()
        }

        let engine = engineForTask(taskID)
        engine.start()
    }

    func pauseRun(taskID: Int) async {
        await pauseRun(taskID: taskID, visited: [])
    }

    /// Internal recursive variant with a visited-set cycle guard. A
    /// corrupted `tasks_index.json` could in principle express a self-cycle
    /// (`childTaskIDs(parent) ⊇ parent`); without the guard the recursion
    /// would stack-overflow. `descendantIDs` already caps via
    /// `treeTraversalSafetyCap`, but `childTaskIDs` is a flat one-level
    /// lookup that the recursion drives — we cap here independently.
    private func pauseRun(taskID: Int, visited: Set<Int>) async {
        if visited.contains(taskID) { return }
        var nextVisited = visited
        nextVisited.insert(taskID)

        // Cancel any in-flight generated-team creation first. The detached Task's
        // `defer` releases the reserve flag as it unwinds, and the cancellation
        // check inside the Task prevents `engine.start()` from firing after pause.
        cancelTeamGeneration(taskID: taskID)

        // Cascade pause to delegated child tasks recursively. Children pause
        // BEFORE the parent so when this method returns the entire delegation
        // subtree is in a consistent paused state.
        for childID in childTaskIDs(of: taskID) {
            await pauseRun(taskID: childID, visited: nextVisited)
        }

        // Cancel LLM execution per-step, NOT bulk-by-task: a step whose
        // `activeDelegationChildID != nil` has a `delegate_to_team` handler
        // suspended on `awaitTaskTerminalState` — cancelling its runningTask
        // would orphan the awaiter (the model chain has an unresolved
        // `delegate_to_team` tool_call with no clean restart path on resume).
        // Every OTHER step (parallel ready roles per CLAUDE.md #45 — engine
        // can have multiple `.running` steps simultaneously) MUST be cancelled,
        // otherwise their LLM retry loops keep firing while the engine is
        // "paused", which is the bug the user observed: child team's
        // Software Engineer kept retrying LLM calls after the parent paused
        // because the child also had a delegating sibling step (depth-2 chain).
        // Pre-fix, the all-or-nothing `isMidDelegation` flag treated the whole
        // task as untouchable when ANY step was mid-delegation.
        if let runTask = loadedTask(taskID), let run = runTask.runs.last {
            for step in run.steps {
                if step.activeDelegationChildID != nil { continue }
                await llmExecutionService.cancelStepExecution(stepID: step.id, taskID: taskID)
                if step.status == .running || step.status == .needsSupervisorInput {
                    await pauseStep(stepID: step.id, taskID: taskID)
                }
            }
        } else {
            // Defensive: task not in memory (shouldn't happen for an active
            // engine, but pause may race with task lifecycle). Bulk-cancel any
            // executions tagged with this taskID — there can be no
            // mid-delegation step to preserve since we don't know about them.
            llmExecutionService.cancelExecutions(forTaskID: taskID)
        }
        taskEngines[taskID]?.pause()
    }

    /// True iff the task's latest run has at least one step with a live
    /// `delegate_to_team` handler awaiting a child task. Used by `pauseRun` and
    /// `resumeRun` to special-case the resume path so children continue from
    /// the same place after the user un-pauses.
    private func stepHasActiveDelegation(taskID: Int) -> Bool {
        guard let task = loadedTask(taskID),
              let run = task.runs.last
        else { return false }
        return run.steps.contains { $0.activeDelegationChildID != nil }
    }

    func resumeRun(taskID: Int) async {
        await resumeRun(taskID: taskID, visited: [])
    }

    /// Internal recursive variant with a visited-set cycle guard, mirroring
    /// `pauseRun(taskID:visited:)`.
    private func resumeRun(taskID: Int, visited: Set<Int>) async {
        if visited.contains(taskID) { return }
        var nextVisited = visited
        nextVisited.insert(taskID)

        await ensureTaskLoaded(taskID)

        guard let task = loadedTask(taskID), let run = task.runs.last else { return }

        // A closed task is terminal — never revive/restart it. Defends against the race
        // where `closeTask`/`removeTask` lands AFTER `wakeRunForQueuedMessages` dispatched
        // its `Task { resumeRun }` (that path's `closedAt` check is pre-dispatch only). All
        // legitimate resumers (Play→startRun, answerSupervisorQuestion, correctRole) target
        // open tasks; restartRole clears `closedAt` before re-running, so it's unaffected.
        guard task.closedAt == nil else { return }

        // Resuming is a transition back to live, so drop the recovery pause latch —
        // otherwise every all-`.pending` moment of the resumed run renders "Paused".
        // Pre-checked rather than called unconditionally: `mutateTask` returning true
        // means "persisted", not "mutated" (CLAUDE.md §7), so an unguarded call would
        // burn a disk write on every `answerSupervisorQuestion → resumeRun`.
        if task.status == .paused {
            await mutateTask(taskID: taskID) { $0.clearRecoveryPauseLatch() }
        }

        // Cascade resume to delegated children FIRST so when this method returns
        // the parent's `delegate_to_team` handler — if its runStep was preserved
        // through the pause — sees its child engine actively making progress.
        // (See pauseRun for the symmetric case.)
        for childID in childTaskIDs(of: taskID) {
            await resumeRun(taskID: childID, visited: nextVisited)
        }

        // Team generation never completed, so this run is still pinned to the "Generated
        // Team" placeholder (roleIDs: []). Everything below would eventually hand its
        // synthetic `team_generation_*` step — which belongs to no roster — to `runStep`,
        // and `engine.start()` at the bottom would find `Run.activeWorkRoleIDs` trivially
        // empty and retire the run `.done` with no team ever generated and no toolbar
        // control left. Re-enter generation instead: the same operation the graph pane's
        // Retry performs, so `[ resume ]` and Retry now mean the same thing.
        //
        // Spawned rather than awaited: `answerSupervisorQuestion` and `correctRole` await
        // `resumeRun` and would freeze the composer mid-submit for the length of an LLM
        // call. `spawnTeamGeneration` reserves synchronously, so a second resume in the
        // same tick is refused; on refusal we still return, because the generation already
        // in flight owns the engine start.
        if needsTeamGeneration(taskID: taskID) {
            spawnTeamGeneration(taskID: taskID, clearingPriorSteps: true)
            return
        }

        // Revive failed steps (transient LLM/stall failure) so sending a message RETRIES
        // the task instead of leaving it dead. Runs BEFORE the mid-delegation short-circuit
        // below so a clean failed *sibling* is revived even when another step is
        // mid-`delegate_to_team` — otherwise the short-circuit would skip it and the run
        // loop would re-fail immediately on the lingering `.failed` role. Skips any failed
        // step that still carries `activeDelegationChildID`: its transcript has an
        // unresolved `delegate_to_team` tool call, so a blind re-run would replay a
        // question nothing answers (that step needs `cancel_delegation`, not a retry).
        // Flip step .failed→.paused AND role .failed→.working in ONE closure, preserving
        // llmConversation/artifacts/toolCalls/wireTranscript — a retry, NOT a reset();
        // markStepRunning then promotes the
        // .paused step to .running on runStep. Disjoint from branches 1/1.5/3 (which handle
        // .paused/.pending steps): branches 1/1.5 read the pre-revival `run` snapshot, where
        // a revived step is still `.failed` and so matches neither their `.paused` nor
        // `.pending` filter; branch 3 re-reads after revival and sees the step as `.running`,
        // which also doesn't match its `.paused` filter. No double-processing either way.
        if let failedRun = loadedTask(taskID)?.runs.last {
            for step in failedRun.steps
            where step.status == .failed && step.activeDelegationChildID == nil {
                let roleID = step.effectiveRoleID
                let stepID = step.id
                // Only revive a genuinely in-play role: a .failed step's role is normally
                // .failed (reconciled) or transiently .working (pre-reconcile). Never flip a
                // settled role (.done/.accepted/.skipped/…) to .working — that would
                // resurrect finished work and corrupt the role↔step contract (mirrors the
                // defensive role guard in branch 1.5).
                let roleStatus = failedRun.roleStatuses[roleID]
                guard roleStatus == .failed || roleStatus == .working else { continue }
                await mutateTask(taskID: taskID) { task in
                    guard let ri = task.runs.indices.last,
                          let si = task.runs[ri].steps.firstIndex(
                              where: { $0.id == stepID && $0.status == .failed }
                          )
                    else { return }
                    task.runs[ri].steps[si].status = .paused
                    task.runs[ri].steps[si].completedAt = nil
                    task.runs[ri].roleStatuses[roleID] = .working
                    task.runs[ri].updatedAt = MonotonicClock.shared.now()
                }
                // mutateTask returning true means "persisted", not "did something"
                // (CLAUDE.md §7) — verify the flip landed before restarting, else a
                // still-.failed role would trip the run loop's immediate re-fail guard.
                let post = loadedTask(taskID)?.runs.last
                guard post?.steps.first(where: { $0.id == stepID })?.status == .paused,
                      post?.roleStatuses[roleID] == .working
                else {
                    lastErrorMessage = "Couldn't revive failed step after retry: task state changed concurrently"
                    continue
                }
                await runStep(stepID: stepID, taskID: taskID)
            }
        }

        // Mid-delegation: parent's runStep Task was NOT cancelled on pause. The
        // handler's `awaitTaskTerminalState` continuation is still suspended; the
        // child engine resume above will wake it. We must not run the normal
        // `runStep` restart loop here — that would spawn a SECOND runStep for
        // the same step on top of the already-suspended one.
        if stepHasActiveDelegation(taskID: taskID) {
            taskEngines[taskID]?.resume()
            return
        }

        // 1. Restore Supervisor questions: .paused + needsSupervisorInput=true + no answer → .needsSupervisorInput
        for step in run.steps where step.status == .paused {
            if step.needsSupervisorInput && step.effectiveSupervisorAnswer == nil {
                let roleID = step.effectiveRoleID
                await mutateTask(taskID: taskID) { task in
                    guard let loc = task.locateStepInLatestRun(stepID: step.id) else { return }
                    task.runs[loc.runIndex].steps[loc.stepIndex].status = .needsSupervisorInput
                    task.runs[loc.runIndex].steps[loc.stepIndex].updatedAt = MonotonicClock.shared.now()
                }
                if run.roleStatuses[roleID] != .working {
                    await mutateTask(taskID: taskID) { task in
                        guard let ri = task.runs.indices.last else { return }
                        task.runs[ri].roleStatuses[roleID] = .working
                    }
                }
            }
        }

        // 1.5 Supervisor answered while the step was suspended (an ask_supervisor
        // question, the Autovisor idle park, or any pause that landed on one).
        // `engine.start()` after restart skips `reconcileAfterPause()`, and branch 3
        // below depends on `step.messages`/`llmConversation` being non-empty — both
        // gaps cause the answered chat to never resume. Restart explicitly whenever
        // an answer is present; `startStepExecution` then replays the step's
        // `wireTranscript` and appends the answer turn.
        for step in run.steps where step.status == .paused || step.status == .pending {
            guard step.effectiveSupervisorAnswer != nil else { continue }
            let roleID = step.effectiveRoleID
            let roleStatus = run.roleStatuses[roleID]
            // Guard: only restart for live role states. Done / failed / skipped /
            // needsAcceptance / accepted / revisionRequested have their own flows.
            guard roleStatus == .idle || roleStatus == .working || roleStatus == .ready else { continue }
            if roleStatus != .working {
                await mutateTask(taskID: taskID) { task in
                    guard let ri = task.runs.indices.last else { return }
                    task.runs[ri].roleStatuses[roleID] = .working
                    task.runs[ri].updatedAt = MonotonicClock.shared.now()
                }
                // The closure can short-circuit (no runs in `task` due to a
                // concurrent mutation), and `mutateTask` returning true means
                // "persisted" not "did something" (CLAUDE.md §7). Re-read the
                // post-mutate state and skip `runStep` if the flip didn't land
                // — otherwise the engine starts a step with the role in a state
                // that violates its "step runs only when role is .working" invariant.
                let postStatus = loadedTask(taskID)?.runs.last?.roleStatuses[roleID]
                guard postStatus == .working else {
                    lastErrorMessage = "Couldn't restart role after restart: task state changed concurrently"
                    continue
                }
            }
            await runStep(stepID: step.id, taskID: taskID)
        }

        // 2. Re-read task after mutations
        guard let updatedTask = loadedTask(taskID), let updatedRun = updatedTask.runs.last else { return }

        // 3. Restart interrupted steps (idle role + paused step with messages = was running before pause/restart)
        //
        // `AutovisorStatus.isResumable` mirrors this branch to tell the Autovisor
        // whether a resume will land — keep the two in lock-step, or `task_status`
        // advertises a `resumable: true` this loop then silently skips.
        for step in updatedRun.steps where step.status == .paused {
            let roleID = step.effectiveRoleID
            let roleStatus = updatedRun.roleStatuses[roleID]

            if roleStatus == .working {
                // Normal pause: role still working, restart step
                await runStep(stepID: step.id, taskID: taskID)
            } else if roleStatus == .idle && (!step.messages.isEmpty || !step.llmConversation.isEmpty) {
                // Recovery: role was reset to idle (app restart), but step was interrupted
                await mutateTask(taskID: taskID) { task in
                    guard let ri = task.runs.indices.last else { return }
                    task.runs[ri].roleStatuses[roleID] = .working
                    task.runs[ri].updatedAt = MonotonicClock.shared.now()
                }
                await runStep(stepID: step.id, taskID: taskID)
            }
        }

        // 4. Create engine if needed (after app restart, engine doesn't exist)
        let engine = engineForTask(taskID)
        if engine.state == .pending {
            // Engine was just created (after app restart) — start instead of resume
            engine.start()
        } else {
            engine.resume()
        }
    }

}
