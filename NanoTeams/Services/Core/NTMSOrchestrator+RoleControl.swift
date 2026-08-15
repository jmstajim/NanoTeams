import Foundation

/// Role-level control: restart, finish advisory, accept, request revision.
extension NTMSOrchestrator {

    // MARK: - Role Control

    /// Restarts a role and cascades the reset to all downstream dependents.
    func restartRole(taskID: Int, roleID: String, comment: String?) async {
        // The synthetic `team_generation_*` step is not a role: it belongs to no roster and
        // the engine cannot execute it. Restarting it is not a no-op but destructive —
        // `StepExecution.reset()` erases the `create_team` error envelope (the only record
        // of WHY generation failed), writes a phantom `roleStatuses` entry for an id no
        // roster contains, clears the recovery latch, and this method's own post-mutation
        // verification PASSES on the result, so it reports success. Observed in production
        // 2026-08-07; the task then derived `.running` forever with a dead engine.
        //
        // The Autovisor layer routes `manage_role restart` on this prefix to
        // `retryTeamGenerationReportingResult` before it ever reaches here, and the UI
        // resolves `selectedRoleID` from roster ids — so this is the structural backstop
        // that makes the primitive total for callers that don't exist yet.
        guard !roleID.hasPrefix(StepExecution.teamGenerationIDPrefix) else {
            lastErrorMessage = "Team generation isn't a role — restart doesn't apply. "
                + "Use Retry in the team panel to re-run generation."
            return
        }

        await ensureTaskLoaded(taskID)

        // A restart with no active run can't reset anything. Surface it instead of
        // silently no-op'ing: the reset closure's `guard ... runs.indices.last` would
        // otherwise return quietly while `mutateTask` still reports success (CLAUDE.md §7),
        // and the woken engine would just transition to `.failed` with no banner.
        guard let task = loadedTask(taskID), task.runs.last != nil else {
            lastErrorMessage = "Couldn't restart the role — the task has no active run."
            return
        }
        let team = resolvedTeam(for: task)
        let roles = team.roles
        let roleName = roles.first(where: { $0.id == roleID })?.name ?? roleID

        let downstreamRoles = ArtifactDependencyResolver.getDownstreamRoles(
            of: roleID,
            roles: roles
        )
        var rolesToReset = Set([roleID])
        rolesToReset.formUnion(downstreamRoles)

        // Tear down the engine's stale per-role tasks for the roles we're resetting so the
        // run loop re-spawns them. A normally-returned Task is NOT `.isCancelled`, so a
        // lingering entry (a prior completion, or a `.working` role whose LLM we cancel
        // below) makes `startRoles`' skip-guard skip the role forever and the restart
        // silently does nothing. Done before the reset so the still-running loop (`.running`
        // state) can't waste an iteration on the stale entry.
        let engine = engineForTask(taskID)
        engine.cancelRoleTasks(for: rolesToReset)

        // Cancel LLM for steps being reset. `cancelRoleTasks` above only cancels the
        // engine's role-wrapper task (unblocking `waitForStepCompletion`); the in-flight
        // LLM stream and its execution state are torn down here — both are required, don't
        // collapse them. `clearStreamingPreview` is explicit (not relied on transitively
        // through `cancelStepExecution`) so a stale "Thinking…" bubble can't linger, matching
        // the advisory-finish path.
        if let run = loadedTask(taskID)?.runs.last {
            for step in run.steps where rolesToReset.contains(step.effectiveRoleID) {
                await llmExecutionService.cancelStepExecution(stepID: step.id, taskID: taskID)
                clearStreamingPreview(stepID: step.id, taskID: taskID)
            }
        }

        // Reset roles and steps
        await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            let now = MonotonicClock.shared.now()

            // Clear closedAt so derived status won't stay .done
            task.closedAt = nil
            // The reset leaves the restarted steps `.pending`, so a recovery latch left
            // armed by an earlier launch would render "Paused" over a role that is about
            // to work. Restarting is a transition back to live — drop the latch.
            task.clearRecoveryPauseLatch()

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

        // Verify the reset actually landed before waking the engine. `mutateTask`
        // returning true means "persisted", not "the closure mutated anything"
        // (CLAUDE.md §7) — a missing primary step or a concurrent state change would
        // otherwise leave the role un-reset and the restart silently ineffective.
        guard let resetRun = loadedTask(taskID)?.runs.last,
              resetRun.roleStatuses[roleID] == .idle,
              resetRun.steps.first(where: { $0.effectiveRoleID == roleID })?.status == .pending
        else {
            lastErrorMessage = "Couldn't restart '\(roleName)' — its task state changed during the reset. Please try again."
            return
        }

        // Wake the engine (its stale per-role tasks are now gone). The engine was created
        // above if missing (e.g. after app restart).
        if engine.state == .pending {
            engine.start()
        } else {
            engine.notifyExternalEvent()
        }
    }

    /// Strict-pipeline hold for an approved change-request revision (see the
    /// `LLMStateDelegate` declaration). Every transitive downstream role still
    /// RUNNING on the revised role's now-stale output is cancelled and queued for
    /// revision so it cannot keep working in parallel with the upstream; the
    /// existing `startableRevisionRoleIDs` gating serializes the re-runs after the
    /// upstream produces a fresh artifact.
    ///
    /// The requester (`requesterRoleID`) is special: it triggered the change from
    /// inside its own running tool loop and is `await`-blocked in
    /// `handleChangeRequest`. Task-cancelling it would tear down its own context and
    /// leave its step `.running` forever — breaking `resetStepForRevision`, which
    /// acts only on `.done`/`.failed`. So the requester is NOT cancelled: only
    /// flagged `.revisionRequested`. Its loop finishes naturally to `.done` (the
    /// `handleRoleCompleted` `.working` guard stops that completion from clobbering
    /// the flag), and it is gated behind the revised target so it re-runs last.
    ///
    /// `requesterRoleID` is a role id (== `StepExecution.id` == `effectiveRoleID`),
    /// the SAME namespace as `runningRoleIDs`, so the `roleID != requesterRoleID`
    /// comparison is sound. A `requesterRoleID` absent from `runningRoleIDs` (the
    /// requester wasn't a downstream consumer of the target — so it correctly should
    /// NOT re-run) just means every entry is treated as a peer.
    func holdDownstreamForRevision(taskID: Int, runningRoleIDs: [String], requesterRoleID: String) async {
        guard !runningRoleIDs.isEmpty else { return }
        let engine = engineForTask(taskID)
        let peers = runningRoleIDs.filter { $0 != requesterRoleID }

        // PEER running downstream roles: cancel the engine role-wrapper task +
        // in-flight LLM stream so the run loop re-spawns them after the upstream
        // revision. (Not the requester — see the doc comment.)
        if !peers.isEmpty {
            engine.cancelRoleTasks(for: Set(peers))
            if let run = loadedTask(taskID)?.runs.last {
                for step in run.steps where peers.contains(step.effectiveRoleID) {
                    await llmExecutionService.cancelStepExecution(stepID: step.id, taskID: taskID)
                    clearStreamingPreview(stepID: step.id, taskID: taskID)
                }
            }
        }

        await mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            let now = MonotonicClock.shared.now()
            for roleID in runningRoleIDs {
                guard let stepIndex = task.runs[runIndex].steps.firstIndex(
                    where: { $0.effectiveRoleID == roleID }
                ) else { continue }
                if roleID != requesterRoleID {
                    // Peer: force the step terminal so `resetStepForRevision` resets it
                    // (preserving conversation/artifacts — NOT a full `step.reset()`).
                    task.runs[runIndex].steps[stepIndex].status = .done
                    task.runs[runIndex].steps[stepIndex].completedAt = now
                }
                // Both peers and the requester get queued for revision. The requester's
                // step is left `.running`; it completes naturally (the `.working`
                // completion guard protects this flag) and is gated behind the target.
                task.runs[runIndex].roleStatuses[roleID] = .revisionRequested
                task.runs[runIndex].steps[stepIndex].updatedAt = now
            }
            task.runs[runIndex].updatedAt = now
        }

        // §7 (CLAUDE.md): `mutateTask == true` means "persisted", not "the closure
        // mutated". A peer that was cancelled above but (on a run-shape race) not
        // flipped would be stranded non-terminal with no signal — it would never
        // re-run and never error. Verify every cancelled peer that still has a step
        // reached `.revisionRequested`; surface any miss loudly. (Phantom peers with
        // no step are intentionally skipped above and are not strandings.)
        if let run = loadedTask(taskID)?.runs.last {
            let stranded = peers.filter { peer in
                run.steps.contains(where: { $0.effectiveRoleID == peer })
                    && run.roleStatuses[peer] != .revisionRequested
            }
            if !stranded.isEmpty {
                lastErrorMessage = "Revision hold incomplete — downstream role(s) \(stranded.joined(separator: ", ")) were cancelled but not queued for revision. Please restart the affected role(s)."
            }
        }

        if engine.state != .running && engine.state != .pending {
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
        // 1. Cancel running LLM task if step is active. Resolve by `effectiveRoleID` —
        // the same predicate stages 2/3 use — so cancel and mutate can't target
        // different steps when a role has (legacy) duplicate effectiveRoleIDs; the
        // `stepsByRoleBaseID()` dict kept the LAST such step while the mutation keeps
        // the FIRST.
        if let step = loadedTask(taskID)?.runs.last?.steps.first(where: { $0.effectiveRoleID == roleID }) {
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

        // 3. Wake engine to check completion / start dependents. Total (creates the engine after
        // a restart, starts a `.pending` one) — the raw `taskEngines[taskID]?` this replaced was
        // a silent no-op exactly when no engine existed, which is the post-restart shape this
        // method is reachable in from the graph node menu on a `.ready` advisory role.
        // `wakeEngine`'s `runs.last` guard is load-bearing HERE specifically: this method has no
        // run guard of its own (pinned by `FinishAdvisoryRoleTests.testFinishAdvisoryRole_noRuns_doesNotCrash`).
        wakeEngine(taskID: taskID)

        // Verify the step actually reached .done (mutateTask returning true means
        // "persisted", not "did something" — CLAUDE.md §7).
        return loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == roleID })?.status == .done
    }

    /// Supervisor accepts a role's work, advancing it to `.accepted`.
    /// Returns `true` if the role was accepted and persisted successfully.
    func acceptRole(taskID: Int, roleID: String) async -> Bool {
        guard let task = loadedTask(taskID), let run = task.runs.last else {
            lastErrorMessage = "Cannot accept role: task \(taskID) has no active run."
            return false
        }
        // Only a role genuinely awaiting acceptance (`.needsAcceptance`) can be accepted.
        // Pre-check (NOT inside the closure): `mutateTask == true` means "persisted", not
        // "mutated" (CLAUDE.md §7), so validating inside and skipping the write would still
        // return true. Both UI accept paths already gate on `.needsAcceptance`, so this only
        // makes the Autovisor's `manage_role accept` honest — accepting an already-`.done`
        // role no longer overwrites `.done` → `.accepted` and falsely reports success.
        if let reason = AcceptanceService.validateAcceptance(roleID: roleID, roleStatuses: run.roleStatuses) {
            lastErrorMessage = reason
            return false
        }
        let success = await mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            run.roleStatuses[roleID] = .accepted
            run.updatedAt = MonotonicClock.shared.now()
            task.runs[task.runs.count - 1] = run
        }
        guard success else { return false }
        // Total wake. Worse than the revision case if it no-ops: `.accepted` is
        // `isComplete: true`, so the role leaves every attention surface (the Watchtower banner
        // self-dismisses, the acceptance card vanishes) while the released mid-pipeline gate
        // lands in a dead engine — nothing left on screen says the pipeline stalled.
        wakeEngine(taskID: taskID)
        return true
    }

    /// Supervisor corrects an active role while the task is paused.
    /// Two branches distinguished by `step.needsSupervisorInput` (set before pause):
    /// - **Branch A** — step was waiting for Supervisor input when paused. Route through
    ///   `answerSupervisorQuestion` with a "Supervisor Feedback: …" prefix so the existing
    ///   supervisor-continuation path replays the step's `wireTranscript` and appends the
    ///   answer turn. `answerSupervisorQuestion` auto-resumes.
    /// - **Branch B** — step was mid-stream (`.running`) when paused. Cancellation did
    ///   not persist a terminal transcript arm, so
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

        // The synthetic `team_generation_*` step is not a role — same structural backstop
        // `restartRole` carries. It belongs to no roster, so flipping it `.revisionRequested`
        // writes a phantom `roleStatuses` entry the engine can never execute.
        guard !roleID.hasPrefix(StepExecution.teamGenerationIDPrefix) else {
            lastErrorMessage = "Team generation isn't a role — request changes doesn't apply. "
                + "Use Retry in the team panel to re-run generation."
            return
        }

        // A closed task is terminal here. `closeTask` finalizes every non-terminal role to
        // `.done` — which SATISFIES the step gate below — so without this the Autovisor's
        // `request_changes` (whose arm, unlike `accept` / `finish_advisory`, carries no
        // closed-task pre-check) would flip a role on a finished task. Reviving it is not the
        // remedy: close also finalized every DOWNSTREAM role `.done`, and `findReadyRoles`
        // excludes `.done`, so the revised artifact would have no consumer and nothing would
        // re-close the task. `restartRole` is the primitive that both reopens and cascades.
        guard loadedTask(taskID)?.closedAt == nil else {
            lastErrorMessage = "Task #\(taskID) is closed — use restart to reopen the task and "
                + "re-run the role (it also resets the roles downstream of it)."
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
        // Report a refused wake instead of trading an invisible stall for a different one: the
        // flag is on disk, so silence here is exactly the bug this method was fixed for. Must
        // stay the last statement with no `await` after it — the Autovisor's `reportingError`
        // reads `errorSurfaceCount` immediately on return.
        if !wakeEngine(taskID: taskID) {
            lastErrorMessage = "Changes were requested from '\(roleID)', but the run couldn't be "
                + "resumed right now — press Resume on the task."
        }
    }
}
