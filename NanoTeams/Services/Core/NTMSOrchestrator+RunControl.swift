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

        await ensureTaskLoaded(taskID)
        await createNewRun(taskID: taskID)

        // For "Generated Team" template: run team generation in a detached Task so
        // `startRun` (and the QuickCapture submit chain awaiting it) returns as soon
        // as the placeholder Supervisor step is on disk. The engine is started from
        // inside the detached Task after generation succeeds — preserving the
        // invariant that the engine never starts before `task.generatedTeam` is set.
        if needsTeamGeneration(taskID: taskID) {
            guard beginTeamGeneration(taskID: taskID) else { return }
            let genTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.endTeamGeneration(taskID: taskID) }
                let generated = await self.runTeamGeneration(taskID: taskID)
                // Skip engine start if pauseRun cancelled us mid-generation.
                guard !Task.isCancelled else { return }
                guard generated else { return } // failure envelope + lastErrorMessage already set
                self.engineForTask(taskID).start()
            }
            registerTeamGenerationTask(taskID: taskID, task: genTask)
            return
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
                await llmExecutionService.cancelStepExecution(stepID: step.id)
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

        // Cascade resume to delegated children FIRST so when this method returns
        // the parent's `delegate_to_team` handler — if its runStep was preserved
        // through the pause — sees its child engine actively making progress.
        // (See pauseRun for the symmetric case.)
        for childID in childTaskIDs(of: taskID) {
            await resumeRun(taskID: childID, visited: nextVisited)
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

        // 1.5 Supervisor answered after restart (or any pause that left a saved session).
        // `engine.start()` after restart skips `reconcileAfterPause()`, and branch 3
        // below depends on `step.messages`/`llmConversation` being non-empty — both
        // gaps cause the answered chat to never resume. Restart explicitly when the
        // step has a saved session ID + an answer; `startStepExecution` then takes
        // the stateful continuation path and sends only the answer via
        // `previous_response_id` (no full history rebuild).
        for step in run.steps where step.status == .paused || step.status == .pending {
            guard step.effectiveSupervisorAnswer != nil, step.llmSessionID != nil else { continue }
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
