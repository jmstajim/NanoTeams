import Foundation

/// Role-level control: restart, finish advisory, accept, request revision.
extension NTMSOrchestrator {

    // MARK: - Role Control

    /// Restarts a role and cascades the reset to all downstream dependents.
    func restartRole(taskID: Int, roleID: String, comment: String?) async {
        await ensureTaskLoaded(taskID)

        let task = loadedTask(taskID)
        let team = resolvedTeam(for: task)
        let roles = team.roles

        let downstreamRoles = ArtifactDependencyResolver.getDownstreamRoles(
            of: roleID,
            roles: roles
        )
        var rolesToReset = Set([roleID])
        rolesToReset.formUnion(downstreamRoles)

        // Cancel LLM for steps being reset
        if let task = loadedTask(taskID), let run = task.runs.last {
            for step in run.steps where rolesToReset.contains(step.effectiveRoleID) {
                await llmExecutionService.cancelStepExecution(stepID: step.id, taskID: taskID)
            }
        }

        // Reset roles and steps
        await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            let now = MonotonicClock.shared.now()

            // Clear closedAt so derived status won't stay .done
            task.closedAt = nil

            for resetRoleID in rolesToReset {
                if let stepIndex = task.runs[runIndex].steps.firstIndex(
                    where: { $0.effectiveRoleID == resetRoleID }
                ) {
                    // Primary role gets the Supervisor comment; downstream roles reset clean
                    let supervisorComment: String? =
                        (resetRoleID == roleID && !(comment ?? "").isEmpty)
                        ? "Supervisor: \(comment!)"
                        : nil
                    task.runs[runIndex].steps[stepIndex].reset(supervisorComment: supervisorComment)
                }

                task.runs[runIndex].roleStatuses[resetRoleID] = .idle
            }
            task.runs[runIndex].updatedAt = now
        }

        // Ensure engine exists and is running — creates if missing (e.g. after app restart)
        let engine = engineForTask(taskID)
        if engine.state == .pending {
            engine.start()
        } else {
            engine.notifyExternalEvent()
        }
    }

    /// Finishes an advisory role immediately — sets step and role to `.done`.
    /// Can be called at any point once the role is ready or working. Fire-and-forget
    /// wrapper around `finishAdvisoryRoleAwaiting` for UI call sites (button actions).
    func finishAdvisoryRole(taskID: Int, roleID: String) {
        Task { _ = await self.finishAdvisoryRoleAwaiting(taskID: taskID, roleID: roleID) }
    }

    /// Awaitable core of advisory finish. Returns `true` iff a matching step was
    /// found and set to `.done` — so callers that need a real outcome (the Folder
    /// Manager's `finish_advisory`) can report success/failure instead of assuming
    /// the fire-and-forget `Task` succeeded.
    @discardableResult
    func finishAdvisoryRoleAwaiting(taskID: Int, roleID: String) async -> Bool {
        // 1. Cancel running LLM task if step is active
        if let step = loadedTask(taskID)?.runs.last?.stepsByRoleBaseID()[roleID] {
            await llmExecutionService.cancelStepExecution(stepID: step.id, taskID: taskID)
            clearStreamingPreview(stepID: step.id, taskID: taskID)
        }

        // 2. Mutate: step → .done, role → .done
        await mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            if let s = run.steps.firstIndex(where: { $0.effectiveRoleID == roleID }) {
                run.steps[s].status = .done
                run.steps[s].completedAt = MonotonicClock.shared.now()
            }
            run.roleStatuses[roleID] = .done
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[task.runs.count - 1] = run
        }

        // 3. Wake engine to check completion / start dependents
        taskEngines[taskID]?.notifyExternalEvent()

        // Verify the step actually reached .done (mutateTask returning true means
        // "persisted", not "did something" — CLAUDE.md §7).
        return loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == roleID })?.status == .done
    }

    /// Supervisor accepts a role's work, advancing it to `.accepted`.
    /// Returns `true` if the role was accepted and persisted successfully.
    func acceptRole(taskID: Int, roleID: String) async -> Bool {
        guard let task = loadedTask(taskID), task.runs.last != nil else {
            lastErrorMessage = "Cannot accept role: task \(taskID) has no active run."
            return false
        }
        let success = await mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            run.roleStatuses[roleID] = .accepted
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[task.runs.count - 1] = run
        }
        guard success else { return false }
        notifyEngineExternalEvent(taskID: taskID)
        return true
    }

    /// Supervisor corrects an active role while the task is paused.
    /// Two branches distinguished by `step.needsSupervisorInput` (set before pause):
    /// - **Branch A** — step was waiting for Supervisor input when paused. `llmSessionID`
    ///   was persisted by `setNeedsSupervisorInput`. Route through `answerSupervisorQuestion`
    ///   with a "Supervisor Feedback: …" prefix so the existing stateful supervisor-
    ///   continuation path sends the answer via `previous_response_id`. `answerSupervisorQuestion`
    ///   auto-resumes.
    /// - **Branch B** — step was mid-stream (`.running`) when paused. Cancellation did
    ///   not persist the session (`StepLifecycle` only persists on completion paths), so
    ///   `runStep` will rebuild `fullConversation` from `step.messages` on resume. Append
    ///   the feedback there and set `revisionComment` as the artifact-completion gate.
    ///
    /// In both branches the step's current `status` is `.paused` (set by `pauseStep`).
    /// The needsSupervisorInput flag disambiguates what it was doing pre-pause.
    func correctRole(taskID: Int, roleID: String, comment: String) async {
        guard let state = taskEngineStates[taskID], state == .paused else {
            lastErrorMessage = "Correct Role requires the task to be paused."
            return
        }
        // Normalize to raw — same trim + caller-supplied-prefix strip as requestRevision.
        let trimmed = MessageSourceContext.rawFeedback(comment)
        guard !trimmed.isEmpty else {
            lastErrorMessage = "Correction text cannot be empty."
            return
        }

        guard let task = loadedTask(taskID),
              let run = task.runs.last,
              let step = run.steps.first(where: {
                  $0.effectiveRoleID == roleID && $0.status == .paused
              })
        else {
            lastErrorMessage = "Could not apply correction — role is no longer paused or step is missing."
            return
        }

        // Branch A: was waiting for Supervisor input. answerSupervisorQuestion handles
        // the stateful supervisor-continuation path and auto-resumes the run.
        // We pass no attachments here (the CorrectRoleSheet is text-only), and
        // `answerSupervisorQuestion` only returns `false` on attachment-finalize
        // failure — so delivery is effectively infallible on this path. If the
        // sheet ever grows attachment support, the `@discardableResult` return is
        // already surfaced via `lastErrorMessage` by `answerSupervisorQuestion`
        // itself — don't clobber that specific error with a generic message here.
        if step.needsSupervisorInput {
            _ = await answerSupervisorQuestion(
                stepID: step.id, taskID: taskID,
                answer: MessageSourceContext.supervisorFeedbackPrefix + trimmed
            )
            return
        }

        // Branch B: mid-stream before pause. Append feedback message + set revisionComment gate.
        // Re-verify status inside the closure — mutateTask runs async and the step could
        // have transitioned out of `.paused` between the outer guard and this mutation
        // (e.g. if resumeRun fired concurrently). `mutateTask` returning true means
        // "persisted" — NOT "mutation did something" — so we pre-check and fail loudly.
        let stepIDToMutate = step.id
        let applied = await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(
                      where: { $0.id == stepIDToMutate && $0.status == .paused }
                  )
            else { return }
            task.runs[runIndex].steps[stepIndex].messages.append(StepMessage(
                role: .supervisor,
                content: MessageSourceContext.supervisorFeedbackPrefix + trimmed
            ))
            task.runs[runIndex].steps[stepIndex].revisionComment = trimmed
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
        }
        // Verify the mutation actually landed — re-read and look for the appended message.
        if applied,
           let updated = loadedTask(taskID)?.runs.last?.steps.first(where: { $0.id == stepIDToMutate }),
           updated.revisionComment == trimmed {
            await resumeRun(taskID: taskID)
        } else {
            lastErrorMessage = "Correction could not be applied — step state changed."
        }
    }

    /// Supervisor requests changes for a role, appending feedback and transitioning to `.revisionRequested`.
    ///
    /// Requires the role's step to be `.done` or `.failed` — the only states
    /// `resetStepForRevision` can act on. Any other status fails loudly via
    /// `lastErrorMessage`: without the gate, flipping a live step to
    /// `.revisionRequested` makes the engine's revision branch call `runStep` on a
    /// step that never reset, spawning a second concurrent LLM execution into the
    /// same step. The Autovisor `manage_role(request_changes)` wrapper converts the
    /// surfaced error into a failure envelope (honest-results contract).
    func requestRevision(taskID: Int, roleID: String, comment: String) async {
        // Normalize to raw: trims, and strips a caller-supplied prefix (the Autovisor's
        // LLM sees prefixed feedback in history and can echo it inside `comment`).
        let raw = MessageSourceContext.rawFeedback(comment)
        guard !raw.isEmpty else {
            lastErrorMessage = "Revision comment cannot be empty."
            return
        }

        guard let step = loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == roleID }),
            step.status == .done || step.status == .failed
        else {
            lastErrorMessage =
                "Cannot request changes from '\(roleID)' — the role has no completed work to revise."
            return
        }

        let stepID = step.id
        let persisted = await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: {
                      // Re-verify status inside the closure — the step could transition
                      // between the outer guard and this mutation (engine runs async).
                      $0.id == stepID && ($0.status == .done || $0.status == .failed)
                  })
            else { return }
            // roleStatuses flips together with the step mutation — a partial write
            // (.revisionRequested with no recorded feedback) would make the engine
            // re-run the role blind on the generic default comment.
            task.runs[runIndex].roleStatuses[roleID] = .revisionRequested
            task.runs[runIndex].steps[stepIndex].messages.append(StepMessage(
                role: .supervisor,
                content: MessageSourceContext.supervisorFeedbackPrefix + raw
            ))
            // Raw comment — see MessageSourceContext.supervisorFeedbackPrefix for the
            // single-application contract (prefix attached once where it reaches the LLM).
            task.runs[runIndex].steps[stepIndex].revisionComment = raw
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
        }
        // `mutateTask` returning true means "persisted", not "the closure did something"
        // (CLAUDE.md §7) — re-read to confirm the revision actually landed.
        guard persisted,
              loadedTask(taskID)?.runs.last?.steps
                  .first(where: { $0.id == stepID })?.revisionComment == raw
        else {
            lastErrorMessage =
                "Could not request changes from '\(roleID)' — step state changed."
            return
        }
        notifyEngineExternalEvent(taskID: taskID)
    }
}
