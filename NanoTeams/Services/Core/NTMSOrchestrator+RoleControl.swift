import Foundation

/// Role-level control: restart, finish advisory, accept, request revision, correct, skip waiting.
///
/// Every verb here writes and then follows up by task id — a wake, a resume, a re-read, a
/// dismissal retired. Each one belongs to the folder described when it began: it takes that
/// lifecycle at entry and asks it after every suspension (a step's cancellation, the write),
/// and once a folder transition has ended it, nothing follows — `NTMSTask.id` is per folder,
/// so the id would name the next folder's task of the same number. A write begun before the
/// transition lands in the folder the verb was asked in, as it would have.
extension NTMSOrchestrator {

    // MARK: - Role Control

    /// Restarts a role and cascades the reset to all downstream dependents.
    ///
    /// `actor` is who asks: `nil` for the person, else the Autovisor. It is recorded on the
    /// comment's step message, which is all that is left of it after the reset (`task_log`
    /// lists it from there — DEBTS D-M15).
    func restartRole(taskID: Int, roleID: String, comment: String?, by actor: AutovisorActor? = nil) async {
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
        let lifecycle = currentFolderLifecycle
        guard isCurrentFolderLifecycle(lifecycle) else {
            lastErrorMessage = "Cannot restart role while switching work folders."
            return
        }
        guard !isDormantAutovisorManagerTask(taskID) else { return }

        await ensureTaskLoaded(taskID)
        guard !isDormantAutovisorManagerTask(taskID) else { return }

        // A restart with no active run can't reset anything. Surface it instead of
        // silently no-op'ing: the reset closure's `guard ... runs.indices.last` would
        // otherwise return quietly while `mutateTask` still reports success (CLAUDE.md §7),
        // and the woken engine would just transition to `.failed` with no banner.
        guard let task = loadedTask(taskID), task.runs.last != nil else {
            lastErrorMessage = "Couldn't restart the role — the task has no active run."
            return
        }
        let team = resolvedTeam(for: task)
        // Read before the reset: resetting the role whose step the Pause parked can leave no
        // step paused, and the run would then not read as the person's Pause any more.
        let waitsForThePersonsResume = decisionWaitsForThePersonsResume(taskID: taskID, by: actor)

        // Roster membership, checked BEFORE anything is reset. This is the destructive half of
        // D-13: `reset()` below destroys the step's conversation, tool calls and artifacts, and
        // without this guard it did so for a role deleted from the roster — then reported
        // success for a role the engine can never start again. The post-mutation verification
        // further down catches a HALLUCINATED id, but a role that still has a STEP sails past
        // it, and a Team Editor deletion against a live task produces exactly that shape.
        //
        // Resolved STRICTLY, not through `resolvedTeam(for:)`. That one coalesces to
        // `activeTeam ?? Team.default` for display, so on a task whose pinned team was deleted
        // it hands back a completely unrelated roster — and a refusal built on it would reject
        // EVERY role of that task. `TeamResolution.team(for:in:)` returns nil there instead, and
        // nil means "could not determine", which is not "not on the roster" (#97).
        if let snapshot,
           let strictTeam = TeamResolution.team(for: task, in: snapshot.projection),
           let refusal = RoleRosterGuard.refusal(roleID: roleID, team: strictTeam) {
            lastErrorMessage = refusal
            return
        }

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
                // `reset()` destroys the transcript the fill was measured against, so the
                // indicator must not keep showing that conversation's occupancy.
                contextFill.removeStep(stepID: step.id, taskID: taskID)
            }
        }
        // Each cancellation awaited its step's handler.
        guard isCurrentFolderLifecycle(lifecycle) else { return }

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
                            ? MessageSourceContext.supervisorMessagePrefix + comment!
                            : nil
                    task.runs[runIndex].steps[stepIndex].reset(
                        supervisorComment: supervisorComment,
                        commentAuthorLabel: actor?.agentLabel,
                        commentIsFromAutomatedSupervisor: actor != nil)
                }

                task.runs[runIndex].roleStatuses[resetRoleID] = .idle
            }
            task.runs[runIndex].round += 1
            task.runs[runIndex].roundStartedAt = now
            task.runs[runIndex].updatedAt = now
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return }
        // A restart births fresh instances of whatever banners these steps produce
        // next — stored dismissals from the previous failure/acceptance round must
        // not pre-dismiss them.
        retireRoleBannerDismissals(taskID: taskID, roleIDs: rolesToReset)

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

        // The end of the round the restart closed, then the start of the one it opened — one
        // sequence, so they land in this order, waited for at most the budget (N2, N5).
        await captureTaskSnapshots(
            Self.roundBoundarySnapshots(newRound: resetRun.round, ending: .restart),
            taskID: taskID, runID: resetRun.id, within: lifecycle,
            waitBudget: taskSnapshotWaitBudget)
        guard isCurrentFolderLifecycle(lifecycle) else { return }

        // Wake the engine (its stale per-role tasks are now gone). The engine was created
        // above if missing (e.g. after app restart). Not on a task the person paused: the reset
        // stands, and their Resume starts the role afresh.
        guard !waitsForThePersonsResume else { return }
        if engine.state == .pending {
            engine.start()
        } else {
            engine.notifyExternalEvent()
        }
    }

    /// The snapshots of a round boundary a restart or a revision makes: the end of the round it
    /// closed (none before round 1), then the start of `newRound`.
    nonisolated static func roundBoundarySnapshots(newRound: Int, ending phase: TaskSnapshotPhase) -> [TaskSnapshotRequest] {
        var requests: [TaskSnapshotRequest] = []
        if newRound > 1 {
            requests.append(TaskSnapshotRequest(round: newRound - 1, phase: phase))
        }
        requests.append(TaskSnapshotRequest(round: newRound, phase: .start))
        return requests
    }

    /// Whether a role decision by `actor` leaves the run asleep: the Autovisor's acceptance,
    /// request for changes, restart or finish on a task the person paused in the app is recorded
    /// and waits for their Resume (`isPausedInTheApp`). Each of those verbs woke the engine, and
    /// waking a paused engine resumes it — so until 2026-11-09 any of them lifted the person's
    /// Pause as a side effect, which a message or an answer no longer did. The person's own
    /// decision (`actor == nil`) wakes the run as it always did.
    func decisionWaitsForThePersonsResume(taskID: Int, by actor: AutovisorActor?) -> Bool {
        actor != nil && isPausedInTheApp(taskID: taskID)
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
    func holdDownstreamForRevision(
        taskID: Int,
        runningRoleIDs: [String],
        requesterRoleID: String,
        within lifecycle: WorkFolderLifecycle
    ) async {
        guard !runningRoleIDs.isEmpty,
              isCurrentFolderLifecycle(lifecycle),
              !isDormantAutovisorManagerTask(taskID)
        else { return }
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
        guard isCurrentFolderLifecycle(lifecycle) else { return }

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
        guard isCurrentFolderLifecycle(lifecycle) else { return }

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

        // Queuing a role for revision consumes its acceptance state — the next
        // acceptance round is a fresh banner instance.
        retireRoleBannerDismissals(taskID: taskID, roleIDs: runningRoleIDs)

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
    ///
    /// Once a folder transition has ended the lifecycle the finish began in, the verdict is the
    /// write's own — whether the closure found the step — since the task id would read the next
    /// folder's task, and the wake does not happen.
    @discardableResult
    func finishAdvisoryRoleAwaiting(taskID: Int, roleID: String, by actor: AutovisorActor? = nil) async -> Bool {
        let lifecycle = currentFolderLifecycle
        // Read before the finish: finishing the step the Pause parked can leave none paused.
        let waitsForThePersonsResume = decisionWaitsForThePersonsResume(taskID: taskID, by: actor)
        // 1. Cancel running LLM task if step is active. Resolve by `effectiveRoleID` —
        // the same predicate stages 2/3 use — so cancel and mutate can't target
        // different steps when a role has (legacy) duplicate effectiveRoleIDs; the
        // `stepsByRoleBaseID()` dict kept the LAST such step while the mutation keeps
        // the FIRST.
        if let step = loadedTask(taskID)?.runs.last?.steps.first(where: { $0.effectiveRoleID == roleID }) {
            await llmExecutionService.cancelStepExecution(stepID: step.id, taskID: taskID)
            clearStreamingPreview(stepID: step.id, taskID: taskID)
            guard isCurrentFolderLifecycle(lifecycle) else { return false }
        }

        // 2. Mutate: step → .done, role → .done
        var finishedTheStep = false
        await mutateTask(taskID: taskID) { task in
            RunService.mutateActiveRun(in: &task) { run in
                if let s = run.steps.firstIndex(where: { $0.effectiveRoleID == roleID }) {
                    run.steps[s].status = .done
                    run.steps[s].completedAt = MonotonicClock.shared.now()
                    finishedTheStep = true
                }
                run.roleStatuses[roleID] = .done
                run.updatedAt = MonotonicClock.shared.now()
            }
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return finishedTheStep }

        // 3. Wake engine to check completion / start dependents. Total (creates the engine after
        // a restart, starts a `.pending` one) — the raw `taskEngines[taskID]?` this replaced was
        // a silent no-op exactly when no engine existed, which is the post-restart shape this
        // method is reachable in from the graph node menu on a `.ready` advisory role.
        // `wakeEngine`'s `runs.last` guard is load-bearing HERE specifically: this method has no
        // run guard of its own (pinned by `FinishAdvisoryRoleTests.testFinishAdvisoryRole_noRuns_doesNotCrash`).
        // Not on a task the person paused: the finish stands, and their Resume runs on from it.
        if !waitsForThePersonsResume { wakeEngine(taskID: taskID) }

        // Verify the step actually reached .done (mutateTask returning true means
        // "persisted", not "did something" — CLAUDE.md §7).
        return loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == roleID })?.status == .done
    }

    /// Supervisor accepts a role's work, advancing it to `.accepted`.
    /// Returns `true` if the role was accepted and persisted successfully.
    func acceptRole(taskID: Int, roleID: String) async -> Bool {
        await acceptRole(taskID: taskID, roleID: roleID, by: nil)
    }

    /// `actor` is who accepts: `nil` for the person, else the Autovisor — whose acceptance names
    /// it on the timeline and, on a task the person paused in the app, waits for their Resume
    /// (`decisionWaitsForThePersonsResume`).
    func acceptRole(taskID: Int, roleID: String, by actor: AutovisorActor?) async -> Bool {
        let lifecycle = currentFolderLifecycle
        let waitsForThePersonsResume = decisionWaitsForThePersonsResume(taskID: taskID, by: actor)
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
        let trimmedAuthor = actor?.agentLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let success = await mutateTask(taskID: taskID) { task in
            RunService.mutateActiveRun(in: &task) { run in
                let now = MonotonicClock.shared.now()
                run.roleStatuses[roleID] = .accepted
                if let trimmedAuthor, !trimmedAuthor.isEmpty {
                    run.supervisorEvents.append(SupervisorTimelineEvent(
                        createdAt: now,
                        kind: .roleAccepted,
                        authorLabel: trimmedAuthor,
                        roleID: roleID
                    ))
                }
                run.updatedAt = now
            }
        }
        guard success else { return false }
        // The acceptance stands in the folder it was given in; what follows is that folder's.
        guard isCurrentFolderLifecycle(lifecycle) else { return true }
        retireRoleBannerDismissals(taskID: taskID, roleIDs: [roleID])
        // Total wake. Worse than the revision case if it no-ops: `.accepted` is
        // `isComplete: true`, so the role leaves every attention surface (the Watchtower banner
        // self-dismisses, the acceptance card vanishes) while the released mid-pipeline gate
        // lands in a dead engine — nothing left on screen says the pipeline stalled.
        // Not on a task the person paused: the acceptance stands, and their Resume runs it.
        if !waitsForThePersonsResume { wakeEngine(taskID: taskID) }
        return true
    }

    /// Supervisor corrects an active role while the task is paused.
    /// Two branches distinguished by `step.needsSupervisorInput` (set before pause):
    /// - **Branch A** — step was waiting for Supervisor input when paused. Route through
    ///   `answerSupervisorQuestion` with a "Supervisor Feedback: …" prefix so the existing
    ///   supervisor-continuation path replays the step's `wireTranscript` and appends the
    ///   answer turn, then resume the run if the answer left it paused.
    ///
    /// Either branch RESUMES, whoever paused the task: a correction is an explicit verb — it needs
    /// a paused task and exists to continue it — like `control_task resume`, and unlike an
    /// automated message or answer, which leaves a person's Pause standing. Until 2026-11-09
    /// branch A answered without naming the corrector: the Autovisor's correction of a person's
    /// Pause reported "corrected" and left the task paused, and an external agent's own was told
    /// back to it as somebody else's Resume.
    /// - **Branch B** — step was mid-stream (`.running`) when paused. Append the feedback
    ///   to `step.messages` and set `revisionComment` as the artifact-completion gate.
    ///   On resume `runStep` normally replays a transcript: the cancellation arm DOES
    ///   persist one (`LLMExecutionService+StepLifecycle`'s `catch is CancellationError`),
    ///   so `ConversationReplay.resume` returns it and the revision-continuation branch
    ///   appends the feedback turn and its `.supervisorFeedback` bubble. Only a step
    ///   paused before it ever completed a request has neither a transcript nor an
    ///   `llmConversation`; there `PromptBuilder` relays the `StepMessage` appended here
    ///   as the wire copy and the send site records the bubble separately.
    ///   (This paragraph claimed the opposite — "cancellation did not persist a terminal
    ///   transcript arm, so `runStep` will rebuild from `step.messages`" — from before
    ///   `wireTranscript` existed. CLAUDE.md #79.)
    ///
    /// In both branches the step's current `status` is `.paused` (set by `pauseStep`).
    /// The needsSupervisorInput flag disambiguates what it was doing pre-pause.
    func correctRole(taskID: Int, roleID: String, comment: String) async {
        await correctRole(taskID: taskID, roleID: roleID, comment: comment, by: nil)
    }

    /// `actor` is who corrects: `nil` for the person, else the Autovisor — recorded on the
    /// correction, whichever branch carries it (DEBTS D-M15). Until 2026-11-07 only an external
    /// agent's label was, so the built-in manager's correction of a parked step was filed as
    /// the person's answer.
    func correctRole(taskID: Int, roleID: String, comment: String, by actor: AutovisorActor?) async {
        let lifecycle = currentFolderLifecycle
        guard isCurrentFolderLifecycle(lifecycle) else {
            lastErrorMessage = "Cannot correct role while switching work folders."
            return
        }
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
        let trimmedAuthor = actor?.agentLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAuthor = (trimmedAuthor?.isEmpty == false) ? trimmedAuthor : nil
        if step.needsSupervisorInput {
            // Minted whenever the step is parked on a questionnaire, and with an EMPTY answer:
            // the Correct Role sheet is text-only, so nobody chose anything here. Its presence
            // is what says a person authored the text — without it
            // `SupervisorInquiryReply.compose` falls to `parse`, the grammar written for a
            // model's `Q2: 1, 3` reply, and a correction opening "1. Use Release instead" is
            // read as CHOOSING option 1 of question 1 — a decision the person never made.
            // (Until 2026-09-12 it cost the rest of the form too: every other question filled
            // from `options[0]` marked assumed. Nothing fills now, and the submission is still
            // load-bearing for the one reason above — it routes `compose` away from `parse`.)
            let submission = step.supervisorInquiry.map { _ in
                SupervisorInquirySubmission(answer: SupervisorInquiryAnswer(), note: trimmed)
            }
            let corrector = actor?.controlActor ?? .person
            let answered = await answerSupervisorQuestion(
                stepID: step.id, taskID: taskID,
                answer: MessageSourceContext.supervisorFeedbackPrefix + trimmed,
                origin: actor != nil ? .automated : .supervisor,
                submission: submission,
                author: effectiveAuthor,
                by: corrector,
                within: lifecycle
            )
            guard answered, isCurrentFolderLifecycle(lifecycle), taskEngineStates[taskID] == .paused else { return }
            await resumeRun(taskID: taskID, by: corrector)
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
                content: MessageSourceContext.supervisorFeedbackPrefix + trimmed,
                authorLabel: effectiveAuthor,
                isFromAutomatedSupervisor: actor != nil
            ))
            task.runs[runIndex].steps[stepIndex].revisionComment = trimmed
            task.runs[runIndex].steps[stepIndex].revisionCommentAuthor = effectiveAuthor
            task.runs[runIndex].steps[stepIndex].revisionCommentIsFromAutomatedSupervisor = actor != nil
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return }
        // Verify the mutation actually landed — re-read and look for the appended message.
        if applied,
           let updated = loadedTask(taskID)?.runs.last?.steps.first(where: { $0.id == stepIDToMutate }),
           updated.revisionComment == trimmed {
            await resumeRun(taskID: taskID, by: actor?.controlActor ?? .person)
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
        await requestRevision(taskID: taskID, roleID: roleID, comment: comment, by: nil)
    }

    /// `actor` is who asks: `nil` for the person, else the Autovisor — recorded on the feedback
    /// and carried to the turn the step re-enters with (DEBTS D-M15).
    func requestRevision(taskID: Int, roleID: String, comment: String, by actor: AutovisorActor?) async {
        let lifecycle = currentFolderLifecycle
        let waitsForThePersonsResume = decisionWaitsForThePersonsResume(taskID: taskID, by: actor)
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

        // Roster membership. Placed here deliberately — AFTER the two guards above and BEFORE
        // the step lookup. A role deleted from the roster can still HAVE a step, so the step
        // guard below would pass it through; and its message ("no completed work to revise") is
        // right for a hallucinated id and wrong for a deleted role. Ordering the two this way
        // means each refusal says the true thing (CLAUDE.md #58 — list what precedes a guard, or
        // it never executes for the case you wrote it for).
        //
        // Without this, `roleStatuses[roleID] = .revisionRequested` was written for a role no
        // roster contains, and the two completion readers then DISAGREED: the engine retired the
        // run (`activeWorkRoleIDs` iterates definitions, so the orphan is invisible) while the
        // task read "Working" forever (`derivedStatusFromActiveRun`'s `.done` arm reads
        // `roleStatuses` raw). Supervisor and Autovisor were both told `ok: true`.
        // Resolved STRICTLY — see `restartRole`'s sibling guard for why `resolvedTeam(for:)`
        // (which coalesces to the active team for display) cannot be the basis of a refusal.
        if let task = loadedTask(taskID), let snapshot,
           let strictTeam = TeamResolution.team(for: task, in: snapshot.projection),
           let refusal = RoleRosterGuard.refusal(roleID: roleID, team: strictTeam) {
            lastErrorMessage = refusal
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
        let trimmedAuthor = actor?.agentLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAuthor = (trimmedAuthor?.isEmpty == false) ? trimmedAuthor : nil
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
                content: MessageSourceContext.supervisorFeedbackPrefix + raw,
                authorLabel: effectiveAuthor,
                isFromAutomatedSupervisor: actor != nil
            ))
            // Raw comment — see MessageSourceContext.supervisorFeedbackPrefix for the
            // single-application contract (prefix attached once where it reaches the LLM).
            task.runs[runIndex].steps[stepIndex].revisionComment = raw
            task.runs[runIndex].steps[stepIndex].revisionCommentAuthor = effectiveAuthor
            task.runs[runIndex].steps[stepIndex].revisionCommentIsFromAutomatedSupervisor = actor != nil
            task.runs[runIndex].round += 1
            task.runs[runIndex].roundStartedAt = MonotonicClock.shared.now()
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
            task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return }
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
        retireRoleBannerDismissals(taskID: taskID, roleIDs: [roleID])
        if let currentRun = loadedTask(taskID)?.runs.last {
            await captureTaskSnapshots(
                Self.roundBoundarySnapshots(newRound: currentRun.round, ending: .revision),
                taskID: taskID, runID: currentRun.id, within: lifecycle,
                waitBudget: taskSnapshotWaitBudget)
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return }
        // On a task the person paused the request stands, and their Resume re-runs the role: a
        // wake withheld on purpose is no stall to report.
        guard !waitsForThePersonsResume else { return }
        // Report a refused wake instead of trading an invisible stall for a different one: the
        // flag is on disk, so silence here is exactly the bug this method was fixed for. Must
        // stay the last statement with no `await` after it — the Autovisor's `reportingError`
        // reads the action's error scope immediately on return.
        if !wakeEngine(taskID: taskID) {
            lastErrorMessage = "Changes were requested from '\(roleID)', but the run couldn't be "
                + "resumed right now — press Resume on the task."
        }
    }
    // MARK: - Watchtower dismissal retirement

    /// Event-driven half of the dismissal lifecycle: the moment the state that
    /// produced a banner is CONSUMED (acceptance granted, revision requested, role
    /// restarted, failed run revived), any stored dismissal for that step's banners
    /// has done its job and must not outlive it. The sampling GC
    /// (`WatchtowerInboxBuilder.staleDismissals`) cannot express this rule: it only
    /// expires a key whose banner is ABSENT while the task is loaded (or whose task is
    /// gone from the index), so a dismissal
    /// surviving into the NEXT instance of the same banner — the same step failing
    /// again after a restart, a second acceptance round after a revision — would
    /// suppress a banner nobody has read. Retiring both families together is
    /// deliberate: absent keys are a no-op, and the transitions that consume one
    /// state routinely produce the other.
    func retireRoleBannerDismissals(taskID: Int, roleIDs: some Sequence<String>) {
        guard let workFolderID = snapshot?.projection.id else { return }
        let steps = loadedTask(taskID)?.runs.last?.steps ?? []
        var keys: Set<WatchtowerDismissKey> = []
        for roleID in roleIDs {
            let stepID = steps.first(where: { $0.effectiveRoleID == roleID })?.id ?? roleID
            keys.insert(.acceptance(taskID: taskID, stepID: stepID))
            keys.insert(.failed(taskID: taskID, stepID: stepID))
        }
        configuration.undismissNotifications(workFolderID: workFolderID, keys: keys)
    }

    /// The question family's half of the same rule: the answer is the event that
    /// CONSUMES a `.supervisorInput` banner, so the dismissal of exactly that banner
    /// retires with it. The sampling GC (`WatchtowerInboxBuilder.staleDismissals`)
    /// reclaims a key only on positive evidence — its task LOADED and the banner ABSENT
    /// at a refresh, or the task gone from the index — and it samples from ONE place,
    /// `WatchtowerView.refreshNotifications`, which exists only while the Watchtower is
    /// the selected detail view. That rule has two gaps this closes. A flag-only
    /// escalation is keyed on its TEXT, so a key that outlives its answer is
    /// born-dismissing the next same-text escalation, which makes the key ACTIVE again
    /// before any refresh can see it absent. And a chat session lived in the TeamBoard
    /// never mounts the Watchtower: `MainLayoutView` read-dismisses each UUID-keyed
    /// question that arrives while the Supervisor is viewing that chat, every answer
    /// strands that key, and nothing reclaims them until the Watchtower is next shown
    /// with the task still resident — evicted or relaunched first, they wait until it
    /// is. `key` is the identity captured BEFORE the answer landed
    /// (`SupervisorQuestionInbox.dismissKey(forStep:taskID:)`) — afterwards the step no longer
    /// knows which banner it showed. It already carries the task scope. Absent key ⇒
    /// no write (`StoreConfiguration` guards on `contains`).
    func retireSupervisorInputDismissal(key: WatchtowerDismissKey, workFolderID: UUID?) {
        guard let workFolderID else { return }
        configuration.undismissNotification(workFolderID: workFolderID, key: key)
    }

    #if DEBUG
    func holdDownstreamForRevision(taskID: Int, runningRoleIDs: [String], requesterRoleID: String) async {
        let lifecycle = currentFolderLifecycle
        await holdDownstreamForRevision(
            taskID: taskID, runningRoleIDs: runningRoleIDs, requesterRoleID: requesterRoleID,
            within: lifecycle)
    }
    #endif

}
