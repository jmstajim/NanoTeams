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
    func setTaskRunTimeout(taskID: Int, seconds: TimeInterval?) async {
        await ensureTaskLoaded(taskID)
        guard loadedTask(taskID) != nil else { return }
        await mutateTask(taskID: taskID) { $0.runTimeoutSeconds = seconds }
    }

    // MARK: - Lifecycle

    /// Runs the skip-missed reconcile once, then starts the once-a-minute poll
    /// loop. Idempotent — cancels any prior loop first. Called from `openWorkFolder`.
    func startAutomationScheduler() async {
        stopAutomationScheduler()
        await reconcileMissedRecurrences()
        // Captured OUTSIDE the loop task: the tick delay must not require `self`
        // (which the loop only holds weakly, and only after the sleep).
        let tickInterval = automationTickInterval
        automationPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Sleep until the next minute boundary so wakes are aligned to
                // the wall clock (the trigger fires on the boundary regardless of
                // when scheduling started), not drifting from the start time.
                // An injected `automationTickInterval` replaces the boundary
                // cadence wholesale — see its doc on `NTMSOrchestrator`.
                try? await Task.sleep(for: .seconds(
                    tickInterval ?? NTMSOrchestrator.secondsUntilNextMinuteBoundary()))
                // Honor cancellation that fired while we slept (work-folder
                // switch / close) before touching any state.
                guard !Task.isCancelled, let self else { return }
                // Auto-off FIRST: an expired manager must neither fire one final
                // recurrence pass (below) nor get woken once more by the backstop.
                await self.evaluateAutovisorAutoDisable()
                await self.evaluateDueRecurrences()
                await self.evaluateRunTimeouts()
                // Level-triggered backstop: wake the Autovisor for any matching
                // task (catches event-wakes the observer debounced; a mid-review
                // manager gets the event injected into its LIVE conversation
                // instead of a fresh pass). `includeStuck: true` runs the
                // loop/hang detector here (poll path only — never on the hot observer).
                await self.wakeAutovisorForEvents(includeStuck: true)
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
    func reconcileMissedRecurrences(now: Date = Date()) async {
        guard let folderURL = workFolderURL else { return }
        for taskID in recurringTaskIDsDue(now: now) {
            // Folder-switch guard: scheduler cancellation is cooperative, so an
            // in-flight pass can resume after `openWorkFolder` swapped folders.
            // Task IDs are per-folder sequential ints — bail before a stale ID
            // resolves against (and persists into) the new folder.
            guard workFolderURL == folderURL else { return }
            await ensureTaskLoaded(taskID)
            guard loadedTask(taskID) != nil else { continue }
            guard workFolderURL == folderURL else { return }
            await mutateTask(taskID: taskID) { $0.recurrence?.reschedule(after: now) }
            evictIfReclaimable(taskID)
        }
    }

    /// Steady-state pass: fire every recurrence whose slot has arrived.
    func evaluateDueRecurrences(now: Date = Date()) async {
        for taskID in recurringTaskIDsDue(now: now) {
            await fireRecurrence(taskID: taskID, now: now)
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

    private func fireRecurrence(taskID: Int, now: Date) async {
        // Folder identity captured at entry; re-checked after every suspension
        // before the next persist-capable call. Scheduler cancellation is
        // cooperative — a fire suspended in `ensureTaskLoaded`/`startRun`/
        // `mutateTask` resumes after a folder switch, where the same numeric
        // taskID resolves against the NEW folder's tasks (IDs are per-folder
        // sequential ints). Without these guards a resumed fire could start a
        // spurious run on an unrelated task in the new folder.
        guard let folderURL = workFolderURL else { return }
        await ensureTaskLoaded(taskID)
        guard workFolderURL == folderURL else { return }
        // Zombie guard: the manager's recurrence must never fire while the feature
        // is off. Normally `setAutovisorEnabled(false)` disables the recurrence
        // alongside the flag, but those are TWO writes (settings.json, then the
        // manager's task.json) — a failed second write leaves "recurrence enabled +
        // feature off" on disk, and after a relaunch nothing else reconciles it
        // (`ensureAutovisorTask` early-returns when disabled). Without this gate
        // an OFF Autovisor would keep running scheduled review passes forever.
        // Self-heal durably instead of firing.
        if taskID == autovisorTaskID,
           snapshot?.workFolder.settings.autovisorEnabled != true {
            await mutateTask(taskID: taskID) { $0.recurrence?.isEnabled = false }
            evictIfReclaimable(taskID)
            return
        }
        // Re-read + re-check against the loaded task: the recurrence may have
        // been disabled between the index scan and now (fire-vs-disable race).
        guard let recurrence = loadedTask(taskID)?.recurrence, recurrence.isDue(now: now) else {
            evictIfReclaimable(taskID)
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
            evictIfReclaimable(taskID)
            return
        }

        guard workFolderURL == folderURL else { return }

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
                quickCaptureFormState?.clearQueuedMessages(for: taskID)
            }
            stopEngineForTask(taskID)
        }

        // Fire: re-run the SAME task. `startRun` appends a fresh Run (clearing
        // closedAt) and starts the engine in the background.
        let runsBefore = loadedTask(taskID)?.runs.count ?? 0
        await startRun(taskID: taskID)
        guard workFolderURL == folderURL else { return }

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
        guard didStart else {
            lastErrorMessage = "Recurring task '\(loadedTask(taskID)?.title ?? "#\(taskID)")' could not start its scheduled run."
            evictIfReclaimable(taskID)
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
    func evaluateRunTimeouts(now: Date = MonotonicClock.shared.now()) async {
        // Folder identity captured at entry and re-checked after every suspension, for the
        // same reason `fireRecurrence` and `reconcileMissedRecurrences` do it: scheduler
        // cancellation is cooperative, so a pass suspended in `mutateTask` / `pauseRun`
        // resumes after a work-folder switch. `activeIDs` was sampled from the OLD folder's
        // engines and task ids are per-folder sequential ints, so from the second iteration
        // on, `loadedTask(taskID)` resolves against the NEW folder — and any task there
        // with a timeout configured and a run older than it (an ordinary steady state for
        // anything finished yesterday) would be stamped `timedOutAt` and paused. That mark
        // is durable: it shows as "(timed out)" in the run-history picker forever and is
        // reported to the Autovisor as fact.
        guard let folderURL = workFolderURL else { return }
        let activeIDs = taskEngineStates
            .filter { $0.value == .running || $0.value == .needsSupervisorInput }
            .map(\.key)
        var timedOutTitles: [String] = []
        for taskID in activeIDs {
            guard workFolderURL == folderURL else { return }
            guard let task = loadedTask(taskID),
                  let timeout = task.runTimeoutSeconds,
                  let run = task.runs.last,
                  run.timedOutAt == nil,
                  now.timeIntervalSince(run.createdAt) > timeout
            else { continue }

            await mutateTask(taskID: taskID) { task in
                guard let i = task.runs.indices.last else { return }
                task.runs[i].timedOutAt = now
                task.runs[i].updatedAt = MonotonicClock.shared.now()
            }
            guard workFolderURL == folderURL else { return }
            await pauseRun(taskID: taskID)
            timedOutTitles.append(task.title)
        }
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
    @discardableResult
    func evictIfReclaimable(_ taskID: Int) -> Task<Void, Never>? {
        guard taskID != activeTaskID else { return nil }
        if isTaskEngineActive(taskID) { return nil }
        if isGeneratingTeam(taskID: taskID) { return nil }
        if let activeID = activeTaskID,
           snapshot?.tasksIndex.descendantIDs(of: activeID).contains(taskID) == true {
            return nil
        }
        // Only sweep if this call ACTUALLY evicted something. `evictLoadedTask`
        // is an unconditional `removeValue`, so a call for a task not in
        // `loadedTasks` (already evicted, or never loaded — the startup status
        // sweep hits both) would otherwise spawn a full reconcile for a no-op,
        // making the documented "nil when nothing was evicted" contract false.
        guard snapshot?.loadedTasks[taskID] != nil else { return nil }
        evictLoadedTask(taskID)
        return Task { [weak self] in
            guard let self else { return }
            // Silent (scheduler housekeeping) — see
            // `sweepResidencyAfterEngineTransition`.
            await self.reconcileChatModelResidency()
        }
    }
}
