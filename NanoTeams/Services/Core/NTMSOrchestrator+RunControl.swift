import Foundation

/// Run lifecycle: start, pause, resume.
extension NTMSOrchestrator {

    // MARK: - Run Lifecycle

    func startRun(taskID: Int) async {
        if let state = taskEngineStates[taskID],
           state == .running || state == .needsAcceptance || state == .needsSupervisorInput {
            return
        }
        await ensureTaskLoaded(taskID)
        await createNewRun(taskID: taskID)
        let engine = engineForTask(taskID)
        engine.start()
    }

    func pauseRun(taskID: Int) async {
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
