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
        // Cancel any in-flight generated-team creation first. The detached Task's
        // `defer` releases the reserve flag as it unwinds, and the cancellation
        // check inside the Task prevents `engine.start()` from firing after pause.
        cancelTeamGeneration(taskID: taskID)

        // Cancel LLM streaming BEFORE mutating step statuses to prevent
        // race conditions where LLM completes and transitions steps after pause.
        llmExecutionService.cancelExecutions(forTaskID: taskID)

        if let task = loadedTask(taskID), let run = task.runs.last {
            for step in run.steps where step.status == .running || step.status == .needsSupervisorInput {
                await pauseStep(stepID: step.id, taskID: taskID)
            }
        }
        taskEngines[taskID]?.pause()
    }

    func resumeRun(taskID: Int) async {
        await ensureTaskLoaded(taskID)

        guard let task = loadedTask(taskID), let run = task.runs.last else { return }

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
