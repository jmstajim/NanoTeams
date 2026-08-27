import Foundation

/// Run lifecycle: start, pause, resume.
extension NTMSOrchestrator {

    // MARK: - Run Lifecycle

    /// Starts a fresh run for a task: materializes the run, then launches it.
    ///
    /// The boundary between the two phases is load-bearing. After `materializeRun`
    /// the board is renderable — the run exists with its `roleStatuses` seeded, and
    /// the Supervisor's own message is a TASK-level feed item, so the chat shows what
    /// the user just typed without waiting for a step (steps are created on demand by
    /// the engine). Everything `launchRun` does is warm-up for the FIRST PROMPT
    /// (rescanning agent instructions and role skills) plus the engine start.
    /// The Quick Capture create path returns to the UI at that boundary and lets the
    /// launch finish behind the already-open chat; see `createPreparedTaskAndStart`.
    ///
    /// This entry point's own contract is unchanged — it returns once the engine has
    /// started (or team generation has been spawned) — so all its other callers
    /// (Play, Autovisor, recurrence, delegation, queue flush) are unaffected.
    func startRun(taskID: Int) async {
        guard let generation = claimRunStart(taskID: taskID) else { return }
        defer { releaseRunStart(taskID: taskID, generation: generation) }
        await materializeRun(taskID: taskID)
        await launchRun(taskID: taskID, generation: generation)
    }

    /// Takes the run-start claim and returns the generation this start owns, or `nil`
    /// if the start must not proceed.
    ///
    /// Every guard here is synchronous ON PURPOSE: the claim must be visible to a
    /// concurrent caller before the first suspension point, because the engine-state
    /// guard cannot see a run that is still being created. `wakeEngine` and
    /// `startAutovisorPass` both read `engineState.initializingRunTaskIDs` for exactly
    /// that reason.
    ///
    /// The returned generation is not a convenience: it is what lets `launchRun` tell
    /// "still the start I was spawned for" from "a start that was aborted and
    /// replaced" — see `runStartGeneration`.
    func claimRunStart(taskID: Int) -> Int? {
        if let state = taskEngineStates[taskID],
           state == .running || state == .needsAcceptance || state == .needsSupervisorInput {
            return nil
        }
        // Prevent Play / Cmd+R re-entry while generation for this task is in flight.
        // Without this, `createNewRun` would wipe the placeholder Supervisor step and
        // a second concurrent `runTeamGeneration` would be spawned.
        if isGeneratingTeam(taskID: taskID) { return nil }
        // Re-entrancy guard: both phases suspend (task load, run creation,
        // instructions rescan) BEFORE the engine-state guard above can see the new
        // run — a concurrent second call for the same task (Play + queue-flush
        // backstop / recurrence fire) would double-create runs. `beginRunStart` is
        // `insert().inserted`, so two callers on the same tick cannot both pass (same
        // idiom as `forcingRunTaskIDs` in `startAutovisorPass`).
        guard engineState.beginRunStart(taskID) else { return nil }
        let generation = (runStartGeneration[taskID] ?? 0) + 1
        runStartGeneration[taskID] = generation
        return generation
    }

    /// Releases the claim taken by `claimRunStart`. Paired by `startRun`'s `defer`
    /// for an inline start, and by the spawned task in `spawnBackgroundRunLaunch`
    /// when the launch phase runs behind an already-open chat.
    ///
    /// Generation-guarded, and that is load-bearing rather than tidy: an aborted
    /// launch keeps unwinding after `abortRunStart` returns, and the Supervisor can
    /// start the task again in the meantime. Without the check, the OLD launch's
    /// `defer` would drop the NEW start's claim — re-opening the double-start window
    /// the claim exists to close, and switching every Initializing surface off while a
    /// run really is starting.
    func releaseRunStart(taskID: Int, generation: Int) {
        guard runStartGeneration[taskID] == generation else { return }
        engineState.endRunStart(taskID)
    }

    /// Abandons an in-flight run start and reports whether there was one.
    ///
    /// Three acts, none of which alone is enough. Bumping the generation is the
    /// REFUSAL: every `runLaunchIsStillWanted` past this point fails, on the inline
    /// path as well as the background one. Cancelling the registered `Task` only makes
    /// the background launch unwind sooner — the detached scans it is parked in do not
    /// inherit cancellation (see `drainRunStartLaunches`), so the abort takes effect at
    /// the launch's next re-check, which is still BEFORE anything is written. Dropping
    /// the claim is what the user sees: all four Initializing surfaces go dark on this
    /// tick rather than when the scan finally returns.
    ///
    /// The Bool is the caller's verdict, not decoration — `pauseRun` reports it as a
    /// successful pause, because an aborted start produces no engine and so cannot be
    /// judged by the engine mirror (CLAUDE.md #130).
    @discardableResult
    func abortRunStart(taskID: Int) -> Bool {
        guard engineState.isInitializingRun(taskID) else { return false }
        runStartGeneration[taskID] = (runStartGeneration[taskID] ?? 0) + 1
        cancelRunStartLaunch(taskID: taskID)
        engineState.endRunStart(taskID)
        return true
    }

    /// Phase 1 — everything the board needs before it can render this run.
    ///
    /// Deliberately does NOT rescan agent instructions or skills: those feed the
    /// first prompt, not the first frame, and awaiting them here is what used to
    /// keep the chat closed for seconds after Send.
    func materializeRun(taskID: Int) async {
        await ensureTaskLoaded(taskID)
        await createNewRun(taskID: taskID)
        #if DEBUG
        SubmitLatencyProbe.mark("run")
        #endif
    }

    /// Whether the background launch for `taskID` may still proceed.
    ///
    /// Three conditions, and no one of them implies another — which is exactly why this
    /// is one predicate called from every point in `launchRun` rather than a guard
    /// written out where it happened to be needed (CLAUDE.md #51).
    ///
    /// `Task.isCancelled` is what `stopEngine(for:)` and `stopAllEngines()` set: task
    /// deletion, work-folder switch, shutdown. It is NOT redundant with the loaded-task
    /// check, and the folder switch is the case that proves it: `NTMSTask.id` is a
    /// sequential `Int` scoped to ONE work folder, so folder B almost certainly has its
    /// own task 1. A launch for folder A's task 1, suspended in the skills scan while the
    /// user switches, would find folder B's task 1 loaded and start an engine on a task
    /// nobody asked to run — a key outliving the data it identifies (CLAUDE.md #74).
    ///
    /// The loaded-task half covers the mirror case: a task evicted without either stop
    /// verb running. `engineForTask` is a WRITE, so it must not be reached for a task
    /// that is no longer in memory.
    ///
    /// The generation half is the Supervisor's own "stop this". `Task.isCancelled`
    /// cannot express it on the INLINE start path (Play, Autovisor, recurrence), where
    /// the launch runs in the caller's context and `backgroundRunLaunches` holds
    /// nothing to cancel — so without it Pause would defend one of the two paths, which
    /// is a coincidence rather than a defence (CLAUDE.md #51).
    private func runLaunchIsStillWanted(taskID: Int, generation: Int) -> Bool {
        !Task.isCancelled
            && loadedTask(taskID) != nil
            && runStartGeneration[taskID] == generation
    }

    /// Phase 2 — prompt warm-up, then team generation or the engine itself.
    func launchRun(taskID: Int, generation: Int) async {
        #if DEBUG
        // Deterministic seam for `RunStartOrderingTests`: holds the launch phase open
        // so a test can assert what is true at the navigation boundary. A wall-clock
        // race cannot express that question — the phase is normally shorter than the
        // suspension the assertion itself would take.
        if let gate = Self._testRunLaunchGate { await gate() }
        #endif

        guard runLaunchIsStillWanted(taskID: taskID, generation: generation) else { return }

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
            #if DEBUG
            SubmitLatencyProbe.mark("instructions")
            #endif
            await refreshAgentSkills()
            #if DEBUG
            SubmitLatencyProbe.mark("skills")
            #endif
        }

        // Asked AGAIN, because both scans suspend and either one is long enough for the
        // Supervisor to delete the task, switch folders, or press Pause (CLAUDE.md #54 —
        // re-check a stop condition after every suspension point, not only on entry).
        // Everything below this line WRITES: `spawnTeamGeneration` and `engineForTask`
        // both create state that would then outlive what it belongs to.
        guard runLaunchIsStillWanted(taskID: taskID, generation: generation) else { return }

        // For "Generated Team" template: run team generation in a detached Task so
        // this phase returns as soon as the placeholder Supervisor step is on disk.
        // The engine is started from inside the detached Task after generation
        // succeeds — preserving the invariant that the engine never starts before
        // `task.generatedTeam` is set.
        if needsTeamGeneration(taskID: taskID) {
            // `clearingPriorSteps: false` — `materializeRun` just replaced the run,
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
        #if DEBUG
        // Holds the line open: `engine.start()` only SPAWNS the run loop, so the submit's
        // remaining silence — up to the first `beginStreaming` — is still ahead of us.
        SubmitLatencyProbe.markAwaitingStream("engine")
        #endif
    }

    /// Spawns `launchRun` in the background, holding the run-start claim until it
    /// completes, and registers the handle so tests and headless runs can join it.
    ///
    /// The registry write lands before the spawned task can run — we are on
    /// `@MainActor` and it cannot start until this synchronous stretch yields — so
    /// `runStartTask(for:)` never observes a hole between spawn and registration.
    func spawnBackgroundRunLaunch(taskID: Int, generation: Int) {
        let launch = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.backgroundRunLaunches.removeValue(forKey: taskID)
                self.releaseRunStart(taskID: taskID, generation: generation)
                #if DEBUG
                // Attempted HERE and not at the end of `launchRun`: this is the one
                // launch a submit owns, so another task's concurrent run start
                // cannot close the submit's measurement early and mis-attribute it.
                // A no-op once the engine started — `markAwaitingStream` holds the line
                // open for the first stream frame — so what this actually closes is the
                // launches that ended WITHOUT one: refused, aborted, team generation.
                SubmitLatencyProbe.end()
                #endif
            }
            await self.launchRun(taskID: taskID, generation: generation)
        }
        backgroundRunLaunches[taskID] = launch
    }

    /// The in-flight background run launch for a task, if there is one.
    ///
    /// `nil` for an inline `startRun` — there the caller's own `await` IS the join —
    /// and `nil` once the launch has finished. Tests and headless runs drain it so
    /// they don't race the engine start that the create path deliberately backgrounds.
    func runStartTask(for taskID: Int) -> Task<Void, Never>? {
        backgroundRunLaunches[taskID]
    }

    /// Cancels the background launch for one task, if there is one.
    ///
    /// Cancel only — the registry entry and the run-start claim are owned by the launch's
    /// own `defer`. Removing the entry here as well would race a launch spawned for the
    /// same id in between and drop the NEW handle, leaving it unjoinable.
    ///
    /// Cancellation is cooperative, so this is only half the mechanism: `launchRun`
    /// re-asks `runLaunchIsStillWanted` after each suspension. A cancel with no check, or
    /// a check with no cancel, defends nothing.
    func cancelRunStartLaunch(taskID: Int) {
        backgroundRunLaunches[taskID]?.cancel()
    }

    /// Cancels every in-flight background launch. Paired with `stopAllEngines()`, whose
    /// contract is that nothing keeps running across a work-folder boundary.
    func cancelAllRunStartLaunches() {
        for (_, launch) in backgroundRunLaunches { launch.cancel() }
    }

    /// Cancels every in-flight launch and waits for them to unwind.
    ///
    /// Called from test teardown, and deliberately from NOWHERE in production — including the
    /// work-folder switch, which cancels but does not wait. That is a decision rather than an
    /// omission: the launch is suspended inside a `Task.detached` scan, and a detached task
    /// does NOT inherit its parent's cancellation, so draining at the switch would block it
    /// for the remainder of the very scan this split moved off the submit path. Cancel-and-
    /// re-check (`runLaunchIsStillWanted`) already makes the switch SAFE; the drain only adds
    /// DETERMINISM — which a teardown needs and a user waiting on a folder does not.
    ///
    /// Re-reads the registry each pass instead of snapshotting it: a launch that is
    /// spawned while an earlier one is being awaited would not be in the snapshot, and
    /// draining is precisely the promise that none is left.
    func drainRunStartLaunches() async {
        while let (_, launch) = backgroundRunLaunches.first {
            launch.cancel()
            await launch.value
        }
    }

    /// Pauses a task and reports whether it is ACTUALLY stopped afterwards.
    ///
    /// The Bool exists because every caller had to assume the pause took. `pauseRun` used to
    /// return `Void` with its last act an optional chain (`taskEngines[taskID]?.pause()`), so on
    /// an engineless task the Autovisor's `control_task pause` reported success, the engine
    /// mirror stayed non-`.paused`, and `manage_role correct` then refused with "use
    /// control_task pause" — two plausible instructions pointing at each other, re-run every
    /// manager pass.
    ///
    /// The verdict is about the PARENT only; the children's verdicts in the cascade are
    /// discarded, because a caller asked about this task.
    @discardableResult
    func pauseRun(taskID: Int) async -> Bool {
        // Captured BEFORE the cascade, because the cascade is what clears it: an
        // aborted start leaves no engine behind, so asking the engine mirror
        // afterwards would report a successful Pause as a failure. A predicate that
        // judges an operation by state the operation legitimately does not produce is
        // wrong in one direction only, and this is that direction (CLAUDE.md #130):
        // pre-fix, Pause pressed during `Initializing…` really did stop the run and
        // still told the Autovisor's `control_task pause` — and the UI — that it had not.
        let abortedAnInitialization = engineState.isInitializingRun(taskID)
        await pauseRun(taskID: taskID, visited: [])
        return taskEngineStates[taskID] == .paused || abortedAnInitialization
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

        // ...and any in-flight run START, for the same reason at the phase before it:
        // a launch parked in the agent-instruction / skill rescan would wake up and
        // call `engine.start()` after this verb has returned. Same address as the line
        // above because it answers the same question one step earlier — "nothing this
        // task had in flight survives a Pause".
        abortRunStart(taskID: taskID)

        // Cascade pause to delegated child tasks recursively. Children pause
        // BEFORE the parent so when this method returns the entire delegation
        // subtree is in a consistent paused state.
        for childID in childTaskIDs(of: taskID) {
            await pauseRun(taskID: childID, visited: nextVisited)
        }

        // Cancel LLM execution per-step, NOT bulk-by-task: a step with a SUSPENDED
        // `delegate_to_team` handler must not be cancelled — the handler is parked
        // non-cancellably inside `TaskCompletionAwaiter.register`, and cancelling
        // its runningTask would orphan that continuation.
        //
        // The predicate is `hasWaiters`, NOT the marker, and that distinction is the
        // whole fix (2026-08-25). `activeChildID` answers "which child is this step
        // bound to" — a DURABLE question whose lifetime is the disk's. Pause asks a
        // PROCESS-lifetime question: "is a handler suspended right now". They come
        // apart in two reachable ways. After a restart the marker survives and the
        // handler does not (recovery now clears it, but the predicate must not depend
        // on that). And `awaitDelegationCompletion`'s `.parentMessageQueued` arm
        // RETURNS while deliberately leaving the marker set, so during pause-and-decide
        // the step is `.running` with a live tool loop — no crash involved. Skipping it
        // there meant Pause silently stopped nothing while a bash- and file-editing
        // agent kept calling the LLM.
        //
        // `notifyDelegationInterrupt` already asked the right question
        // (`marker != nil && hasWaiters`), which is what makes this CLAUDE.md #51/#52:
        // the guard existed at one of several sites, and the unguarded ones were the
        // common path.
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
                if let childID = step.activeDelegationChildID,
                   completionAwaiter.hasWaiters(for: childID) { continue }
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

        // Re-derive the engine mirror from what is now on the task. Without this the two homes
        // of "is this task running" disagree on an engineless task: `pauseStep` above parks the
        // steps so the DERIVED status becomes `.paused`, while `taskEngineStates[taskID]` — what
        // `manage_role correct` and the board's Play button read — stays nil (#91).
        //
        // No new rule: `syncEngineStateFromRun` already owns "derive the mirror from durable
        // state", and its own guard makes this a no-op whenever an engine exists, since there
        // the engine owns the mirror.
        if let task = loadedTask(taskID) {
            syncEngineStateFromRun(taskID: taskID, task: task)
        }
    }

    /// True iff the task's latest run has a step whose `delegate_to_team` handler is
    /// suspended RIGHT NOW awaiting a child task.
    ///
    /// Renamed from `stepHasActiveDelegation` (2026-08-25). The old name is what made a
    /// durable marker read as an answer to a liveness question: it claimed "live handler"
    /// in its doc comment while testing a field that outlives the process (#79 — a name
    /// or comment that misdescribes the mechanism is what hides it). `hasWaiters` is the
    /// process-lifetime fact, and it is the one `resumeRun`'s short-circuit needs: the
    /// short-circuit exists so a second `runStep` does not land on top of a suspended one.
    private func stepHasSuspendedDelegationHandler(taskID: Int) -> Bool {
        guard let task = loadedTask(taskID),
              let run = task.runs.last
        else { return false }
        return run.steps.contains {
            guard let childID = $0.activeDelegationChildID else { return false }
            return completionAwaiter.hasWaiters(for: childID)
        }
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
        //
        // Filtered on `hasWaiters`, and the ASYMMETRY with pauseRun's cascade (which is
        // unconditional) is deliberate: pausing is never wrong, resuming can be. Three
        // cases the filter gets right and an unconditional resume would not — an orphan
        // child left by a restart (nothing awaits it, so reviving it burns LLM cycles for
        // no one), a child paused by `.parentMessageQueued` while the deciding role has not
        // yet released it (restarting it goes behind that role's back), and a child whose
        // parent handler IS suspended, which is the case this cascade exists for.
        // Do not "tidy" the two cascades into symmetry.
        for childID in childTaskIDs(of: taskID) where completionAwaiter.hasWaiters(for: childID) {
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
                // The failure this banner reported is being retried — a stored
                // dismissal must not survive into the retry's outcome.
                retireRoleBannerDismissals(taskID: taskID, roleIDs: [roleID])
                await runStep(stepID: stepID, taskID: taskID)
            }
        }

        // Mid-delegation: parent's runStep Task was NOT cancelled on pause. The
        // handler's `awaitTaskTerminalState` continuation is still suspended; the
        // child engine resume above will wake it. We must not run the normal
        // `runStep` restart loop here — that would spawn a SECOND runStep for
        // the same step on top of the already-suspended one.
        if stepHasSuspendedDelegationHandler(taskID: taskID) {
            // Same total shape as the tail of this method, NOT `wakeEngine` — that would be
            // correct about the engine and wrong about the step, and this branch exists
            // precisely to keep a second `runStep` off an already-suspended one.
            //
            // The raw `taskEngines[taskID]?.resume()` this replaced was the worst member of the
            // silent-wake class because it has a BUTTON: the branch is taken while `taskEngines`
            // can be empty, so Resume on the parent did nothing at all and the early `return`
            // skipped the total `engineForTask` at the end of this method.
            //
            // Reachable as: a PAUSE of a live delegation. `pauseRun` deliberately leaves such a
            // step uncancelled, so its handler is still suspended and the engine is gone — the
            // shape this branch is for. It is NOT the restart path any more: after a restart no
            // handler exists, `hasWaiters` is false, and `StatusRecoveryService` has cleared the
            // marker and closed the tool call, so the step takes the ordinary restart route
            // below. That is deliberate — a restarted step must be restarted, not treated as
            // though something were still awaiting it.
            let engine = engineForTask(taskID)
            if engine.state == .pending { engine.start() } else { engine.resume() }
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
