import Foundation

/// Background automation owned by the orchestrator: recurring-task scheduling
/// (re-run the same task on a schedule) + per-run timeout enforcement.
///
/// One poll loop drives both. It scans the **in-memory** `snapshot.tasksIndex`
/// (authoritative — every `mutateTask` path refreshes it synchronously on
/// `@MainActor`) for due recurrences, and `engineState.taskEngineStates` for
/// over-budget runs. Cadence is a fixed once-a-minute tick, matching the
/// 1-minute minimum schedule granularity.
///
/// **Two comparisons, two clocks, and the difference is which operand the value
/// is compared AGAINST.** Recurrence uses real wall-clock `Date()`: its other
/// operand is `TaskRecurrence.nextFireAt`, computed by `RecurrenceRule` from a
/// wall-clock date, so both sides are wall time. The run-timeout watchdog does
/// NOT: its other operand is `Run.createdAt`, a `MonotonicClock` model stamp, so
/// it measures on the stamping clock — see `evaluateRunTimeouts`. Taking the
/// single-sentence rule ("scheduling uses `Date()`") on both halves is what put
/// this file on the wrong side of CLAUDE.md's 2026-07-18 clock-mixing class.
/// The evaluation entry points take an injectable `now:` so tests stay deterministic.
extension NTMSOrchestrator {

    /// Seconds from `reference` until the next wall-clock minute boundary (`:00`).
    /// The poll loop sleeps this long so its wakes are ALIGNED to minute
    /// boundaries — the trigger fires on the boundary independent of when the
    /// app/scheduler started. This is phase-alignment, NOT a finer tick: the
    /// cadence stays once a minute, it's just pinned to the wall clock.
    static func secondsUntilNextMinuteBoundary(from reference: Date = Date()) -> TimeInterval {
        let rem = reference.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        return rem == 0 ? 60 : 60 - rem
    }

    // MARK: - Public API (UI)

    /// Sets (or clears, when `nil`) the task's recurrence and recomputes its
    /// next fire time. Called from the task-detail automation sheet.
    func setTaskRecurrence(taskID: Int, recurrence: TaskRecurrence?) async {
        await ensureTaskLoaded(taskID)
        guard loadedTask(taskID) != nil else { return }
        await mutateTask(taskID: taskID) { task in
            var updated = recurrence
            updated?.reschedule(after: Date())
            task.recurrence = updated
        }
    }

    /// Sets (or clears, when `nil`) the task's per-run timeout in seconds.
    /// Preserves `Run.timedOutAt` as a durable historical timestamp (§5.1, C2).
    /// When timeout increases past `timedOutAtLimit`, the watchdog re-arms automatically.
    ///
    /// A run that timed out before F4 recorded `timedOutAtLimit` carries the stamp alone, and the
    /// watchdog's `isArmed` never re-armed it — a raised limit and a resume ran it with no limit
    /// at all (F6 C11). The limit it crossed is recorded here, before the new value replaces it:
    /// the task's previous limit, or, when that was cleared since, how long the run had gone when
    /// the watchdog fired — the limit was at most that.
    func setTaskRunTimeout(taskID: Int, seconds: TimeInterval?) async {
        await ensureTaskLoaded(taskID)
        guard loadedTask(taskID) != nil else { return }
        let now = MonotonicClock.shared.now()
        await mutateTask(taskID: taskID) { task in
            if let lastIdx = task.runs.indices.last {
                let run = task.runs[lastIdx]
                if let timedOutAt = run.timedOutAt, run.timedOutAtLimit == nil {
                    task.runs[lastIdx].timedOutAtLimit = task.runTimeoutSeconds
                        ?? timedOutAt.timeIntervalSince(run.createdAt).rounded(.down)
                }
                task.runs[lastIdx].updatedAt = now
            }
            task.runTimeoutSeconds = seconds
        }
    }

    // MARK: - Lifecycle

    /// Runs the skip-missed reconcile once, then starts the once-a-minute poll
    /// loop. Idempotent — cancels any prior loop first. Called from `openWorkFolder`, with the
    /// open's own lifecycle; a caller outside an open captures its own
    /// (`currentFolderLifecycle`) at its entry.
    ///
    /// The reconcile suspends (its writes), so the lifecycle is asked again after it, before the
    /// loop starts: a superseded open starts no loop for the folder it left. And the assignment
    /// below cancels whatever loop it replaces, so no path can leave a loop running that nothing
    /// holds a handle to. The loop then BELONGS to that lifecycle: each tick runs in it, so a tick
    /// that was suspended inside an evaluator when the next open began does no further work in
    /// either folder, and the loop ends.
    func startAutomationScheduler(lifecycle: WorkFolderLifecycle) async {
        stopAutomationScheduler()
        await reconcileMissedRecurrences(lifecycle: lifecycle)
        guard await folderLifecycleStillCurrent(lifecycle, into: .automationLoop) else { return }
        // Captured OUTSIDE the loop task: the tick delay must not require `self`
        // (which the loop only holds weakly, and only after the sleep).
        let tickInterval = automationTickInterval
        automationPollTask?.cancel()
        #if DEBUG
        _testLiveAutomationLoops += 1
        #endif
        automationPollTask = Task { @MainActor [weak self] in
            #if DEBUG
            defer { self?._testLiveAutomationLoops -= 1 }
            #endif
            while !Task.isCancelled {
                // Sleep until the next minute boundary so wakes are aligned to
                // the wall clock (the trigger fires on the boundary regardless of
                // when scheduling started), not drifting from the start time.
                // An injected `automationTickInterval` replaces the boundary
                // cadence wholesale — see its doc on `NTMSOrchestrator`.
                try? await Task.sleep(for: .seconds(
                    tickInterval ?? NTMSOrchestrator.secondsUntilNextMinuteBoundary()))
                // One tick, in the lifecycle of the open that started the loop. Each of its four
                // evaluators suspends — a write, a fire's launch, the watchdog's pause — and the
                // next folder transition can begin inside any of them, ending this lifecycle and
                // cancelling this task: so the tick asks both before EACH evaluator, and hands
                // the lifecycle to each to ask after its own suspensions. A tick that only checked
                // cancellation when it woke ran its remaining evaluators against the folder that
                // had opened since: B's missed slot fired from A's loop (a run appended,
                // `lastFiredAt` stamped), A's auto-off announced in B. Written in the loop body
                // rather than as a helper so the scans its evaluators run stay in loop context
                // for `coverage/tools/algorithmic_complexity.py`, which follows two call hops.
                guard let self, !Task.isCancelled, self.isCurrentFolderLifecycle(lifecycle) else { return }
                // Auto-off FIRST: an expired manager must neither fire one final
                // recurrence pass (below) nor get woken once more by the backstop.
                await self.evaluateAutovisorAutoDisable(within: lifecycle)
                guard !Task.isCancelled, self.isCurrentFolderLifecycle(lifecycle) else { return }
                await self.evaluateDueRecurrences(within: lifecycle)
                guard !Task.isCancelled, self.isCurrentFolderLifecycle(lifecycle) else { return }
                await self.evaluateRunTimeouts(within: lifecycle)
                guard !Task.isCancelled, self.isCurrentFolderLifecycle(lifecycle) else { return }
                // Level-triggered backstop: wake the Autovisor for any matching
                // task (catches event-wakes the observer debounced; a mid-review
                // manager gets the event injected into its LIVE conversation
                // instead of a fresh pass). `includeStuck: true` runs the
                // loop/hang detector here (poll path only — never on the hot observer).
                await self.wakeAutovisorForEvents(includeStuck: true, within: lifecycle)
            }
        }
    }

    func stopAutomationScheduler() {
        automationPollTask?.cancel()
        automationPollTask = nil
    }

    // MARK: - Recurrence evaluation

    /// Skip-missed pass on folder open: a recurrence whose slot already passed
    /// while the app was closed is advanced to the next future slot WITHOUT
    /// firing. Runs before the loop ticks, so anything due at open is treated as
    /// "missed" (skip), and only slots that arrive while the app is live fire.
    ///
    /// `lifecycle` is the open's (`startAutomationScheduler`), asked after every suspension
    /// before the next step: task ids are per-folder sequential ints, so an id sampled from this
    /// folder must not resolve against — or be written, loaded or evicted in — another. The
    /// lifecycle, not the folder's URL: the next open ends it at its first line, and moves the
    /// URL only after its read, so a URL check let a pass superseded while the next folder was
    /// read go on writing into the folder being left. The evict asks it itself
    /// (`evictIfReclaimable(_:within:)`), and the next iteration's first check ends the pass.
    func reconcileMissedRecurrences(now: Date = Date(), lifecycle: WorkFolderLifecycle) async {
        guard workFolderURL != nil else { return }
        for taskID in recurringTaskIDsDue(now: now) {
            guard isCurrentFolderLifecycle(lifecycle) else { return }
            await ensureTaskLoaded(taskID)
            guard loadedTask(taskID) != nil else { continue }
            guard isCurrentFolderLifecycle(lifecycle) else { return }
            await mutateTask(taskID: taskID) { $0.recurrence?.reschedule(after: now) }
            evictIfReclaimable(taskID, within: lifecycle)
        }
    }

    /// Steady-state pass: fire every recurrence whose slot has arrived — all of them in the
    /// folder whose lifecycle the pass runs in (the poll loop's), and none once a folder
    /// transition has begun since.
    func evaluateDueRecurrences(now: Date = Date(), within lifecycle: WorkFolderLifecycle) async {
        for taskID in recurringTaskIDsDue(now: now) {
            guard isCurrentFolderLifecycle(lifecycle) else { return }
            await fireRecurrence(taskID: taskID, now: now, lifecycle: lifecycle)
        }
    }

    /// Top-level task IDs whose enabled recurrence is due at `now`, read from the
    /// authoritative in-memory index. Child/delegated tasks never recur.
    private func recurringTaskIDsDue(now: Date) -> [Int] {
        guard let summaries = snapshot?.tasksIndex.tasks else { return [] }
        return summaries
            .filter { $0.parentTaskID == nil }
            .filter { summary in summary.nextRecurrenceFireAt.map { $0 <= now } ?? false }
            .map(\.id)
    }

    private func fireRecurrence(taskID: Int, now: Date, lifecycle: WorkFolderLifecycle) async {
        // The pass's lifecycle, re-asked after every suspension before the next
        // persist-capable call. Scheduler cancellation is cooperative — a fire suspended in
        // `ensureTaskLoaded`/`startRun`/`mutateTask` resumes after a folder switch, where the
        // same numeric taskID resolves against the NEW folder's tasks (IDs are per-folder
        // sequential ints). Without these guards a resumed fire could start a spurious run on an
        // unrelated task in the new folder. The lifecycle, not the URL: a fire whose start the
        // next open abandoned while that open still read (`abortRunStart`) went on past a URL
        // check — the URL was still this folder's — and reported "could not start its scheduled
        // run" into the session being opened.
        guard workFolderURL != nil else { return }
        await ensureTaskLoaded(taskID)
        guard isCurrentFolderLifecycle(lifecycle) else { return }
        // Zombie guard: the manager's recurrence must never fire while the feature
        // is off. Normally `setAutovisorEnabled(false)` disables the recurrence
        // alongside the flag, but those are TWO writes (settings.json, then the
        // manager's task.json) — a failed second write leaves "recurrence enabled +
        // feature off" on disk, and after a relaunch nothing else reconciles it
        // (`ensureAutovisorTask` early-returns when disabled). Without this gate
        // an OFF Autovisor would keep running scheduled review passes forever.
        // Self-heal durably instead of firing.
        if taskID == autovisorTaskID,
           (snapshot?.workFolder.settings.autovisorEnabled != true
            || snapshot?.workFolder.settings.autovisorDriver == .externalAgent) {
            await mutateTask(taskID: taskID) { $0.recurrence?.isEnabled = false }
            evictIfReclaimable(taskID, within: lifecycle)
            return
        }
        // Re-read + re-check against the loaded task: the recurrence may have
        // been disabled between the index scan and now (fire-vs-disable race).
        guard let recurrence = loadedTask(taskID)?.recurrence, recurrence.isDue(now: now) else {
            evictIfReclaimable(taskID, within: lifecycle)
            return
        }

        let state = taskEngineStates[taskID]
        // The ONLY thing that blocks the next occurrence is the previous one still
        // ACTIVELY executing (`.running`, or a team still being generated).
        // Everything else — parked awaiting acceptance / a supervisor answer,
        // paused, done, failed — is superseded by the schedule: restart a fresh
        // run. (Per product decision: "restart on the timer without restrictions,
        // unless it's still running.")
        //
        // EXCEPTION for the Autovisor: defer (don't supersede) when its parked step
        // has a pending HUMAN continuation — superseding would `createNewRun` and
        // orphan the human's answer on the old run (data loss). The resume the human
        // path triggers continues the SAME conversation; this slot just waits one
        // interval. Defense-in-depth alongside the event-wake guard (this race window
        // is sub-second on a minute boundary). The queue itself already survives a
        // supersede (preserved below + drained on the fresh run), so this is purely to
        // protect an already-written answer and to keep session continuity.
        if state == .running || isGeneratingTeam(taskID: taskID)
            || (taskID == autovisorTaskID && state == .needsSupervisorInput
                && autovisorHasPendingHumanContinuation(taskID)) {
            await mutateTask(taskID: taskID) { $0.recurrence?.reschedule(after: now) }
            evictIfReclaimable(taskID, within: lifecycle)
            return
        }

        guard isCurrentFolderLifecycle(lifecycle) else { return }

        // Tear down the previous occurrence so the fresh run starts clean and
        // `startRun`'s own re-entry guard (which bails on .needsAcceptance /
        // .needsSupervisorInput) doesn't skip. The prior run stays in history.
        //
        // Use the RECURSIVE `stopEngineForTask` (stops descendants first, then
        // `stopEngine` + `cancelExecutions` per node) so an in-flight delegation's
        // child engines aren't orphaned. Also drop the prior occurrence's queued
        // Supervisor messages — otherwise they re-inject into the new run as
        // phantom answers (matches `removeTask`'s cleanup).
        if state != nil {
            // Dive-deeper finding A: do NOT clear the Autovisor's queue on a
            // recurrence fire — its queued messages are legitimate standing human
            // steering (sent from the manager chat), not stale supervisor answers.
            // A fresh run drains them on iteration 1 (session == nil), so they never
            // accumulate. Clearing here would silently drop the human's message if a
            // minute-boundary tick beat its delivery.
            if taskID != autovisorTaskID {
                messageQueue.discardQueuedChatMessage(taskID: taskID)
            }
            stopEngineForTask(taskID)
        }

        // Fire: re-run the SAME task. `startRun` appends a fresh Run (clearing
        // closedAt) and starts the engine in the background.
        let runsBefore = loadedTask(taskID)?.runs.count ?? 0
        await startRun(taskID: taskID)
        guard isCurrentFolderLifecycle(lifecycle) else { return }

        // Stamp `lastFiredAt` ONLY if a run actually started. `startRun` is
        // fire-and-forget with several silent early-returns (no work folder,
        // generation reserve failed, a residual engine guard); recording a fire
        // that produced no run would advance the schedule AND surface "last run:
        // now" while nothing happened — the classic "looks healthy, did nothing"
        // trap. The slot is rescheduled either way so we don't re-fire next tick.
        let didStart = (loadedTask(taskID)?.runs.count ?? 0) > runsBefore
            || taskEngineStates[taskID] == .running
            || isGeneratingTeam(taskID: taskID)
        await mutateTask(taskID: taskID) { task in
            if didStart { task.recurrence?.lastFiredAt = now }
            task.recurrence?.reschedule(after: now)
        }
        guard isCurrentFolderLifecycle(lifecycle) else { return }
        guard didStart else {
            lastErrorMessage = "Recurring task '\(loadedTask(taskID)?.title ?? "#\(taskID)")' could not start its scheduled run."
            evictIfReclaimable(taskID, within: lifecycle)
            return
        }
        // Now running — keep it loaded (no evict).
    }

    // MARK: - Run timeout watchdog

    /// Pauses any active run that has exceeded its task's `runTimeoutSeconds`,
    /// measured from `run.createdAt` (all waits/pauses counted).
    /// Fires once per run via `Run.timedOutAt`, then notifies the Supervisor.
    ///
    /// **`now` MUST be a `MonotonicClock` stamp**, unlike the recurrence evaluators in
    /// this file. The budget is measured against `Run.createdAt`, which
    /// `RunService.createTeamRun` stamps with `MonotonicClock.shared.now()`; that clock is
    /// `max(Date(), last + 1ms)` and therefore only ever runs AHEAD of the wall clock. A
    /// wall-clock `now` understates the run's age by exactly the drift accumulated when it
    /// was stamped, so the budget fires late — or never, once the drift exceeds it — and
    /// `timedOutAt` records a moment that can precede the `createdAt` it is measured from.
    /// Defaulted so callers cannot get it wrong, exactly as
    /// `AutovisorStatus.idleSeconds` / `.roleElapsedSeconds` / `.taskElapsedSeconds` are;
    /// pinned by `RunTimeoutClockCoverageTests`.
    func evaluateRunTimeouts(now: Date = MonotonicClock.shared.now(), within lifecycle: WorkFolderLifecycle) async {
        // The pass's lifecycle — the poll loop's — asked before every id and after every
        // suspension, for the same reason `fireRecurrence` and `reconcileMissedRecurrences` ask
        // theirs: a pass suspended in `mutateTask` / `pauseRun` resumes after a folder transition
        // began. `activeIDs` is sampled from THIS folder's engine mirror and task ids are
        // per-folder sequential ints, so once the next open has committed, `loadedTask(taskID)`
        // resolves against the next folder — and any task there with a timeout configured and a
        // run older than it (an ordinary steady state for anything finished yesterday) would be
        // stamped `timedOutAt` and paused. That mark is durable: it shows as "(timed out)" in the
        // run-history picker forever and is reported to the Autovisor as fact. While the next
        // folder is still read, the ids resolve against the folder being left, which nothing may
        // stamp or pause any longer. The lifecycle rather than the folder's URL: the next open
        // ends it at its first line and moves the URL only at its commit.
        guard workFolderURL != nil else { return }
        let activeIDs = taskEngineStates
            .filter { $0.value == .running || $0.value == .needsSupervisorInput }
            .map(\.key)
        var timedOutTitles: [String] = []
        for taskID in activeIDs {
            guard isCurrentFolderLifecycle(lifecycle) else { return }
            guard let task = loadedTask(taskID),
                  let timeout = task.runTimeoutSeconds,
                  let run = task.runs.last
            else { continue }

            let isArmed = run.timedOutAt == nil || (run.timedOutAtLimit.map { timeout > $0 } ?? false)
            let elapsed = now.timeIntervalSince(run.createdAt)
            guard isArmed && elapsed > timeout else { continue }

            await mutateTask(taskID: taskID) { task in
                guard let i = task.runs.indices.last else { return }
                task.runs[i].timedOutAt = now
                task.runs[i].timedOutAtLimit = timeout
                task.runs[i].updatedAt = MonotonicClock.shared.now()
            }
            guard isCurrentFolderLifecycle(lifecycle) else { return }
            let didPause = await pauseRun(taskID: taskID, cause: .runTimedOut)
            if didPause {
                completionAwaiter.deliver(
                    taskID: taskID,
                    outcome: .paused(.runTimedOut(seconds: Int(timeout)))
                )
            }
            timedOutTitles.append(task.title)
        }
        // The banner is this folder's, and the last pause suspended.
        guard isCurrentFolderLifecycle(lifecycle) else { return }
        // One combined banner. Multiple parallel runs can exceed budget in the
        // same tick (CLAUDE.md #45) and `lastInfoMessage` is a single slot — a
        // per-task assignment would clobber all but the last, so only one timeout
        // would be announced. The durable per-run Watchtower `.timedOut`
        // notification still surfaces each one individually.
        switch timedOutTitles.count {
        case 0: break
        case 1: lastInfoMessage = "Task '\(timedOutTitles[0])' paused — it exceeded its run timeout."
        default: lastInfoMessage = "\(timedOutTitles.count) tasks paused — they exceeded their run timeouts."
        }
    }

    // MARK: - Helpers

    private func isTaskEngineActive(_ taskID: Int) -> Bool {
        switch taskEngineStates[taskID] {
        case .running, .needsAcceptance, .needsSupervisorInput: return true
        default: return false
        }
    }

    /// Drops a background, non-running task from `loadedTasks` after the
    /// scheduler touched it, so reconcile/skip passes don't accumulate unviewed
    /// task blobs in memory. Never evicts the active task, a running/awaiting
    /// task, a generating task, or a delegation descendant of the active task
    /// (the active task's activity feed + graph need those loaded).
    ///
    /// An actual eviction returns a background residency sweep (`nil` when
    /// nothing was evicted): dropping the task de-references its
    /// generated-team per-role override models, and no other trigger observes
    /// scheduler evictions. Returned so tests can await it; production call
    /// sites discard it.
    ///
    /// Internal (not `private`) — also called by the startup status sweep
    /// (`recoverStaleStatusesAcrossIndex`).
    ///
    /// `lifecycle` is the caller's, asked here at the one seam an id sampled before a suspension
    /// drops a task from memory: every caller evicts after a write, and a folder transition that
    /// committed inside that write leaves the id naming the next folder's task of the same number
    /// — which each caller used to refuse with a check of its own, and one forgotten check was an
    /// evicted task of the next folder.
    @discardableResult
    func evictIfReclaimable(
        _ taskID: Int, protectedDescendants: Set<Int>? = nil, within lifecycle: WorkFolderLifecycle
    ) -> Task<Void, Never>? {
        guard isCurrentFolderLifecycle(lifecycle) else { return nil }
        guard taskID != activeTaskID else { return nil }
        // Only sweep if this call ACTUALLY evicted something. `evictLoadedTask`
        // is an unconditional `removeValue`, so a call for a task not in
        // `loadedTasks` (already evicted, or never loaded — the startup status
        // sweep hits both) would otherwise spawn a full reconcile for a no-op,
        // making the documented "nil when nothing was evicted" contract false.
        // Checked FIRST: it is a dictionary probe, while the descendant walk
        // below is O(index) — the startup sweep calls this once per stale row,
        // mostly for never-loaded tasks the walk would be pure waste on.
        guard snapshot?.loadedTasks[taskID] != nil else { return nil }
        if isTaskEngineActive(taskID) { return nil }
        if isGeneratingTeam(taskID: taskID) { return nil }
        // The active task's delegation subtree must stay resident. Per-call the
        // walk is one childLinks build; loops (the startup sweep) precompute the
        // set once and pass it in.
        if let activeID = activeTaskID {
            let protected: Set<Int> = protectedDescendants
                ?? Set(snapshot?.tasksIndex.descendantIDs(of: activeID) ?? [])
            if protected.contains(taskID) { return nil }
        }
        evictLoadedTask(taskID)
        return Task { [weak self] in
            guard let self else { return }
            // Silent (scheduler housekeeping) — see
            // `sweepResidencyAfterEngineTransition`.
            await self.reconcileChatModelResidency()
        }
    }
}

#if DEBUG
extension NTMSOrchestrator {
    /// Test seams: an evaluation begun NOW, in the folder the process describes — what a suite
    /// that stages a pass by hand means by calling an evaluator. Production runs each one only
    /// inside the poll loop, in the lifecycle of the open that started the loop
    /// (`startAutomationScheduler`).
    func evaluateAutovisorAutoDisable(now: Date = Date()) async {
        let lifecycle = currentFolderLifecycle
        await evaluateAutovisorAutoDisable(now: now, within: lifecycle)
    }

    func evaluateDueRecurrences(now: Date = Date()) async {
        let lifecycle = currentFolderLifecycle
        await evaluateDueRecurrences(now: now, within: lifecycle)
    }

    func evaluateRunTimeouts(now: Date = MonotonicClock.shared.now()) async {
        let lifecycle = currentFolderLifecycle
        await evaluateRunTimeouts(now: now, within: lifecycle)
    }
}
#endif
