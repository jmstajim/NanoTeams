import Foundation

/// Autovisor lifecycle: lazily ensures the hidden singleton manager task
/// exists when enabled, and toggles the feature on/off. The manager runs as a
/// normal (but sidebar-hidden) chat-mode task on the built-in "Autovisor"
/// team; everything downstream reuses the existing engine, scheduler, and feed.
extension NTMSOrchestrator {

    /// Ensures the Autovisor team exists in `teams.json` regardless of whether the
    /// feature is enabled, so it's always a (protected) entry in the Settings → Teams
    /// list, AND reconciles its template invariants (Manager icon + mandatory tools +
    /// Auto coordinator) on EVERY open — including when the feature is disabled and the
    /// team already exists. No-op only when there is no real work folder. The diff-based
    /// `mutateWorkFolder` write is skipped when the sync changes nothing.
    func ensureAutovisorTeam() async {
        guard hasRealWorkFolder, snapshot != nil else { return }
        await mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.templateID == AutovisorConstants.teamTemplateID }) {
                proj.teams.append(TeamTemplateFactory.autovisor())
            }
            // Keep the hidden team's template invariants in sync (Manager icon +
            // mandatory tools + Auto meeting coordinator) — also normalizes a team a
            // prior build seeded. Returns false on a no-op, so nothing is persisted then.
            _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &proj.teams)
        }
    }

    /// Ensures the Autovisor task exists (creating the team + task lazily on
    /// first enable) and starts an open-time review pass. Idempotent. No-op when
    /// the feature is disabled or there is no real work folder (default storage
    /// has nothing to manage). Safe to call repeatedly from `openWorkFolder` and
    /// from `setAutovisorEnabled(true)`.
    func ensureAutovisorTask() async {
        guard hasRealWorkFolder,
              let snap = snapshot,
              snap.workFolder.settings.autovisorEnabled
        else { return }

        let managerID: Int
        if let existing = snap.workFolder.state.autovisorTaskID,
           snap.tasksIndex.tasks.contains(where: { $0.id == existing }) {
            managerID = existing
            await ensureTaskLoaded(managerID)
            // Re-enable the review recurrence: a prior `setAutovisorEnabled(false)`
            // set `isEnabled = false`, and the existing-task branch otherwise never
            // restores it — so a disable→enable cycle would run only the open-time
            // pass and then never recur. Preserve the user's rule/interval; seed a
            // default if somehow missing.
            await mutateTask(taskID: managerID) { task in
                if task.recurrence == nil {
                    task.recurrence = TaskRecurrence(
                        rule: .interval(seconds: AutovisorConstants.defaultScheduleIntervalSeconds),
                        isEnabled: true
                    )
                } else {
                    task.recurrence?.isEnabled = true
                }
                task.recurrence?.reschedule(after: Date())
            }
        } else if let created = await createAutovisorTask() {
            managerID = created
        } else {
            return
        }

        // Keep the hidden Manager role's icon in sync with its template so an existing
        // (persisted) Autovisor team picks up a template icon rename. Pure logic
        // lives in TeamManagementService (unit-tested); the diff-based persist no-ops
        // when nothing changed.
        await mutateWorkFolder { proj in
            _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &proj.teams)
        }

        await seedAutovisorDefaultsAndSyncBrief(managerID: managerID)

        // Seed the "seen" set so tasks that already exist at open aren't treated
        // as newly-created by the `onTaskCreated` trigger (the open-time pass below
        // reviews them anyway). Without this every existing task would look new.
        autovisorSeenTaskIDs = Set(autovisorWatchableTasks(excluding: managerID).map(\.id))

        // Mandatory open-time review pass (dive-deeper finding 11): tasks left
        // waiting on the manager after restart would otherwise hang. `startRun`
        // does NOT change `activeTaskID`, so this never steals the user's focus.
        // Supersedes a parked (`wait_for_events`) engine — relevant when this runs
        // from `setAutovisorEnabled(true)` mid-session, not just at folder open.
        await startAutovisorPass(taskID: managerID)
    }

    /// Starts a fresh manager review pass, superseding a parked (`wait_for_events`)
    /// run if present — `startRun`'s re-entry guard bails on `.needsSupervisorInput`,
    /// so the parked engine must be stopped first. The parked conversation is
    /// abandoned by design (events and schedules get a clean pass; only human
    /// messages continue the parked chat). Queued chat messages survive the
    /// supersede — the fresh run drains them on iteration 1.
    func startAutovisorPass(taskID: Int) async {
        if taskEngineStates[taskID] == .needsSupervisorInput {
            stopEngineForTask(taskID)
        }
        await startRun(taskID: taskID)
    }

    /// Seeds the default goal/memory when empty so both fields start populated and
    /// editable (Settings + Watchtower) and the manager's first prompt has the
    /// "explore & wait for a goal" directive. "When empty" == "by default" — a real
    /// goal/memory the user or the manager set is never clobbered. Then syncs the
    /// manager's brief (the "Supervisor Task" artifact, rendered as "## Supervisor
    /// Goal") to the current goal — they are the same thing for the manager — which
    /// also migrates an existing manager whose brief still holds the old hardcoded
    /// "Oversee this work folder…" text. Extracted from `ensureAutovisorTask` so
    /// it's unit-testable without starting the engine. `managerID` must already be loaded.
    func seedAutovisorDefaultsAndSyncBrief(managerID: Int) async {
        await mutateWorkFolder { proj in
            if proj.settings.autovisorGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proj.settings.autovisorGoal = AutovisorConstants.defaultGoal
            }
            if proj.settings.autovisorMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proj.settings.autovisorMemory = AutovisorConstants.defaultMemory
            }
        }
        let currentGoal = snapshot?.workFolder.settings.autovisorGoal ?? AutovisorConstants.defaultGoal
        await mutateTask(taskID: managerID) { task in
            if task.supervisorTask != currentGoal { task.supervisorTask = currentGoal }
        }
    }

    /// Toggles the Autovisor. Enabling lazily creates the manager task;
    /// disabling stops its engine and disables its recurrence so the scheduler
    /// stops firing it.
    func setAutovisorEnabled(_ enabled: Bool) async {
        await mutateWorkFolder { $0.settings.autovisorEnabled = enabled }
        if enabled {
            await ensureAutovisorTask()
        } else if let id = snapshot?.workFolder.state.autovisorTaskID {
            stopEngineForTask(id)
            await mutateTask(taskID: id) { $0.recurrence?.isEnabled = false }
        }
        rearmAutovisorAutoDisable()  // arms the sleep timer on enable, clears it on disable
    }

    // MARK: - Auto-off sleep timer

    /// Re-arms (or clears) the in-memory auto-off deadline from `now`, per the
    /// sleep-timer contract: deadline = now + duration whenever the feature is ON
    /// and the timer is configured; nil otherwise. Total over current state —
    /// derives arm-vs-clear from settings, so callers don't branch on which
    /// transition occurred. Each call RESTARTS the countdown from `now`, so
    /// persist paths receiving the whole struct must gate on an effective-duration
    /// change (see `updateAutovisorActivation`). "Run now" and recurrence fires
    /// deliberately never call this — the countdown runs from enable, not activity.
    func rearmAutovisorAutoDisable(now: Date = Date()) {
        guard hasRealWorkFolder,
              let settings = snapshot?.workFolder.settings,
              settings.autovisorEnabled,
              let duration = settings.autovisorActivation.effectiveAutoDisableAfterSeconds
        else {
            clearAutovisorAutoDisable()
            return
        }
        autovisorAutoDisableAt = now.addingTimeInterval(duration)
    }

    /// Unconditionally drops the in-memory auto-off deadline. The named funnel for
    /// every nil-write (`rearmAutovisorAutoDisable`'s guard, the stale-deadline
    /// self-heal, `openWorkFolder`'s pre-loop clear) so "who writes the deadline"
    /// stays answerable by grepping two method names.
    func clearAutovisorAutoDisable() {
        autovisorAutoDisableAt = nil
    }

    /// Minute-tick check. Must run BEFORE `evaluateDueRecurrences` and
    /// `wakeAutovisorForEvents` in the scheduler tick, so an expired manager
    /// neither fires a final recurrence nor gets woken once more. Past the
    /// deadline → turn the Autovisor off exactly like the manual power toggle,
    /// and announce via the neutral info banner. Up to ~60 s of lag between
    /// deadline and actual off is inherent to the tick (UI copy says
    /// "around HH:mm"); a deadline that passed during macOS sleep fires on the
    /// first tick after wake — correct sleep-timer behavior.
    func evaluateAutovisorAutoDisable(now: Date = Date()) async {
        guard let deadline = autovisorAutoDisableAt, now >= deadline else { return }
        guard snapshot?.workFolder.settings.autovisorEnabled == true else {
            clearAutovisorAutoDisable()   // stale deadline (direct settings write) — self-heal silently
            return
        }
        let errorBaseline = lastErrorMessage
        await setAutovisorEnabled(false)
        // Verify semantic success before announcing (CLAUDE.md §7 — persisted ≠
        // intended; same honest-error pattern as `deleteAutovisor`). The disable
        // makes TWO writes, and announcing over either failure would DISPLACE the
        // error in the single banner slot:
        // • settings flag failed → feature still enabled (the flag check), and the
        //   disable path's rearm re-armed a fresh countdown — an automatic retry
        //   in one full duration;
        // • recurrence persist failed → flag is off but `lastErrorMessage` moved
        //   off the baseline (the on-disk orphan is self-healed by
        //   `fireRecurrence`'s zombie guard).
        guard snapshot?.workFolder.settings.autovisorEnabled == false,
              lastErrorMessage == errorBaseline else { return }
        lastInfoMessage = "Autovisor turned off — its auto-off timer ended."
    }

    /// Fully removes the Autovisor from this folder (sidebar context-menu
    /// "Delete"): deletes its task (disk + index), clears the pinned id, and turns
    /// the feature off. Re-enabling later via `setAutovisorEnabled(true)`
    /// recreates it (the hidden team is reused). `removeTask` runs FIRST — while
    /// `autovisorTaskID` is still set — so the active-task fallback keeps
    /// excluding the manager when picking the next active task.
    func deleteAutovisor() async {
        guard let id = autovisorTaskID else { return }
        await removeTask(id)
        // Only clear the pin once the task is actually gone. `removeTask` swallows a
        // disk failure into `lastErrorMessage` and leaves the task in the index; if we
        // nil the pin anyway, the still-present manager task (hidden only while the pin
        // matches its id, per `TaskService.taskSummaries`) would orphan into the regular
        // sidebar list. On failure we keep the pin so the manager stays hidden and the
        // surfaced error is honest ("delete failed").
        guard snapshot?.tasksIndex.tasks.contains(where: { $0.id == id }) != true else { return }
        await mutateWorkFolder {
            $0.state.autovisorTaskID = nil
            $0.settings.autovisorEnabled = false
        }
        rearmAutovisorAutoDisable()  // feature is now off → clears the sleep-timer deadline
    }

    /// The current Autovisor task ID, if one has been created for this folder.
    var autovisorTaskID: Int? {
        snapshot?.workFolder.state.autovisorTaskID
    }

    /// The Manager role definition (the single non-Supervisor role of the Folder
    /// Manager team), if the team exists. Used by the Settings Model card.
    var autovisorRole: TeamRoleDefinition? {
        snapshot?.workFolder.teams
            .first(where: { $0.templateID == AutovisorConstants.teamTemplateID })?
            .roles.first(where: { !$0.isSupervisor })
    }

    /// Queues a human message (optionally with staged attachments) to the Autovisor
    /// and wakes it if idle so it processes promptly. The human is the manager's
    /// Supervisor; this is the standard queued-supervisor flow — the consume path
    /// finalizes the attachments and injects their paths. Two wake shapes:
    /// • parked at `.needsSupervisorInput` (`wait_for_events`) — flush the queue into
    ///   the parked step via the `.needsSupervisorInput` backstop, continuing the
    ///   SAME conversation by stateful continuation (`startRun` is gated on that
    ///   state, and there's no engine transition to trigger the backstop otherwise);
    /// • any other non-running state — `startRun` (a fresh run drains the queue on
    ///   iteration 1).
    /// Returns `false` (without queueing) when there's no manager task, the queue
    /// isn't wired (`quickCaptureFormState` nil — queueing would silently drop the
    /// message), or the payload is entirely empty, so the caller can keep the
    /// draft intact.
    @discardableResult
    func sendMessageToAutovisor(_ text: String, attachments: [StagedAttachment] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = autovisorTaskID,
              let formState = quickCaptureFormState,
              let message = QuickCaptureFormState.QueuedChatMessage(
                  text: trimmed, attachments: attachments, clippedTexts: [], targetRoleID: autovisorRole?.id
              ) else { return false }
        formState.appendQueuedMessage(message, for: id)
        switch Self.autovisorMessageWake(for: taskEngineStates[id]) {
        case .nextIteration:
            break // Drained by `injectQueuedSupervisorMessage` on the next iteration.
        case .flushParked:
            // Reaches the process-wide singleton (the orchestrator has no DI handle
            // for the controller — see `notifyQueuedMessageBackstop`). The wiring
            // (`QuickCaptureController.shared.setup` + `store.quickCaptureFormState`)
            // happens in `NanoTeamsApp` before any UI path can get here. If the
            // singleton isn't wired (unit tests; hypothetical headless callers),
            // the flush no-ops and the message STAYS QUEUED — delivered by the
            // next supersede-driven fresh pass instead of the same-conversation
            // continuation. Degraded, never lost.
            QuickCaptureController.shared.tryFlushQueuedMessages()
        case .startRun:
            Task { await startRun(taskID: id) }
        }
        return true
    }

    /// How `sendMessageToAutovisor` wakes the manager for a queued message — pure
    /// mapping from the engine state, unit-testable without the controller singleton:
    /// • `.running` → nothing (next-iteration injection drains the queue);
    /// • `.needsSupervisorInput` (parked on `wait_for_events`, or an escalation park)
    ///   → flush the queue into the parked step so the SAME conversation continues
    ///   (`startRun` is gated on that state, and queueing alone causes no engine
    ///   transition to trigger the backstop);
    /// • anything else (idle/paused/done/failed/none) → `startRun` (fresh run drains
    ///   the queue on iteration 1).
    nonisolated static func autovisorMessageWake(for state: TeamEngineState?) -> AutovisorMessageWake {
        switch state {
        case .running: .nextIteration
        case .needsSupervisorInput: .flushParked
        default: .startRun
        }
    }

    /// See `autovisorMessageWake(for:)`.
    nonisolated enum AutovisorMessageWake {
        case nextIteration, flushParked, startRun
    }

    /// True when the manager's parked step is the deliberate `wait_for_events` idle
    /// park (no human attention needed) — vs. a genuine escalation question, which
    /// shares the same `.needsSupervisorInput` engine state. The durable marker is
    /// the parked step's `supervisorQuestion` matching `idleParkQuestion` by exact
    /// equality (the runtime `parkForEventsRequested` flag is consumed before the
    /// park lands — see the constant's doc for the trim-stability/copy-edit caveat).
    /// Latest run only — an idle park in an earlier run is history, not state.
    /// Checks the persistent `needsSupervisorInput` FLAG, not `status`: a
    /// restart-recovered park (`StatusRecoveryService` flips status to `.paused`,
    /// keeps the flag) still matches, so callers must gate on live engine state the
    /// way `autovisorIsIdleParked` does. `contains` semantics: the manager team is
    /// single-role (one step per run); with hypothetical mixed steps, idle-park
    /// suppression would win over a sibling's real question.
    nonisolated static func taskHasIdleParkStep(_ task: NTMSTask?) -> Bool {
        guard let run = task?.runs.last else { return false }
        return run.steps.contains {
            $0.needsSupervisorInput && $0.supervisorQuestion == AutovisorConstants.idleParkQuestion
        }
    }

    /// True when the manager's latest-run step already carries an unprocessed HUMAN
    /// answer — text and/or attachments. Uses `effectiveSupervisorAnswer` (the same
    /// signal `resumeRun` consumes) so an attachment-only answer (empty text, files
    /// attached → `supervisorAnswer == nil` but `effectiveSupervisorAnswer != nil`)
    /// is still covered; keying on raw `supervisorAnswer` would leave that case
    /// unprotected (CLAUDE.md: always read `effectiveSupervisorAnswer`). The idle
    /// park clears the answer (`setNeedsSupervisorInput`), so a non-nil, non-auto
    /// answer is unambiguous "answered, awaiting resume" — an event/recurrence
    /// supersede in that window would `createNewRun` and orphan it on the old run
    /// (data loss). Pure/static for unit testing. Latest run only.
    nonisolated static func taskHasPendingHumanAnswer(_ task: NTMSTask?) -> Bool {
        task?.runs.last?.steps.contains {
            $0.effectiveSupervisorAnswer != nil && !$0.supervisorAnswerWasAuto
        } ?? false
    }

    /// Whether the manager has any pending HUMAN continuation — either a queued human
    /// message not yet flushed, OR an answer already written to the parked step. The
    /// supersede paths defer to the human-driven resume instead, which continues the
    /// SAME run. Why BOTH arms: a supersede while an answer is already written would
    /// `createNewRun` and orphan it on the old run (DATA LOSS); a still-queued message
    /// would itself survive a supersede (it re-drains on the fresh run — see
    /// `fireRecurrence`'s queue-preservation), but deferring keeps session continuity
    /// and avoids a needless reset. Checking both also closes the race fully:
    /// `flushQueuedChatMessage` pops synchronously and flows synchronously into
    /// `answerSupervisorQuestion` → `mutateTask`, whose in-memory answer write runs in
    /// `mutateTask`'s prologue BEFORE its first actor-yielding suspension (the detached
    /// disk write). So between "popped" and "written" there is no main-actor yield —
    /// the guard always observes the queued message (before pop) or the written answer
    /// (after), never the gap. (A future edit that inserts a yielding `await` before
    /// that write would reopen the window.) Automated queue entries (event notices, the
    /// Autovisor's own `message_task`) are excluded — they must NOT block a supersede.
    func autovisorHasPendingHumanContinuation(_ managerID: Int) -> Bool {
        if Self.taskHasPendingHumanAnswer(loadedTask(managerID)) { return true }
        return (quickCaptureFormState?.queuedMessages(for: managerID) ?? [])
            .contains { !$0.isFromAutomatedSupervisor }
    }

    /// UI affordance gate: skip attention treatments (sidebar icon pulse) while the
    /// manager is idle-parked. Falls back to `false` (= keep the attention treatment)
    /// when the task isn't loaded. No flicker race with the engine state — the
    /// guarantee is structural, not temporal: the engine's ONLY transition to
    /// `.needsSupervisorInput` (TeamEngine run loop) is derived from the persisted
    /// step status, which `setNeedsSupervisorInput` writes atomically with the
    /// question in one `mutateTask` closure — the state can never be observed
    /// before the question is on the step.
    var autovisorIsIdleParked: Bool {
        guard let id = autovisorTaskID,
              taskEngineStates[id] == .needsSupervisorInput else { return false }
        return Self.taskHasIdleParkStep(loadedTask(id))
    }

    /// Sets (or clears) the Manager role's per-role LLM override. Bumps the team's
    /// `updatedAt` (via `updateRole`) so `@Observable` UI refreshes; persistence is
    /// JSON-diff'd by `mutateWorkFolder` regardless.
    func setAutovisorLLMOverride(baseURL: String?, model: String?) async {
        let b = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = LLMOverride(
            baseURLString: (b?.isEmpty == false) ? b : nil,
            modelName: (m?.isEmpty == false) ? m : nil
        )
        await mutateWorkFolder { proj in
            guard let ti = proj.teams.firstIndex(where: { $0.templateID == AutovisorConstants.teamTemplateID }),
                  var role = proj.teams[ti].roles.first(where: { !$0.isSupervisor }) else { return }
            role.llmOverride = override.isEmpty ? nil : override
            proj.teams[ti].updateRole(role)
        }
    }

    /// Wakes the manager when a folder task needs it, per the activation triggers.
    /// Called both as an immediate event-wake (engine-state observer) and as a
    /// level-triggered backstop from the poll loop — the latter catches event-wakes
    /// the observer debounced. Two delivery shapes:
    /// • manager `.running` (mid-review) — the event is injected into the LIVE
    ///   conversation as a queued supervisor message (drained next tool-loop
    ///   iteration), deduped per (task, trigger) via `autovisorNotifiedAttentionKeys`
    ///   and exempt from the wake debounce;
    /// • any other state — a FRESH review pass, debounced by `minSecondsBetweenRuns`
    ///   (a parked `wait_for_events` engine is superseded, not continued).
    ///
    /// `includeStuck` enables the `onTaskStuck` evaluation — passed `true` ONLY by
    /// the per-minute poll backstop. The hot engine-state observer leaves it `false`
    /// so the per-running-task loop/LCS detector never runs on that high-frequency
    /// path; a hung role runs forever anyway, so ≤~60 s latency is immaterial.
    func wakeAutovisorForEvents(now: Date = Date(), includeStuck: Bool = false) async {
        guard hasRealWorkFolder,
              let settings = snapshot?.workFolder.settings,
              settings.autovisorEnabled,
              let managerID = autovisorTaskID else { return }

        let act = settings.autovisorActivation
        let watchable = autovisorWatchableTasks(excluding: managerID)
        let stuckEvaluated = includeStuck && act.onTaskStuck
        let stuck = stuckEvaluated ? computeStuckTaskIDs(watchable: watchable, now: now) : []
        let items = Self.autovisorAttentionItems(
            watchable: watchable, engineStates: taskEngineStates, activation: act,
            seen: autovisorSeenTaskIDs, stuck: stuck
        )
        // Prune the mid-review dedup set to still-matching conditions so one that
        // went quiet re-notifies if it later re-fires. `.stuck` is the one trigger
        // that can go unevaluated between wakes (the hot observer path never
        // computes it), so only its keys are exempt while unevaluated — there,
        // "absent from items" means "not looked at", not "cleared"; evicting them
        // would make every poll tick re-inject the same still-hung condition.
        // Known bounded corner: a `.stuck` condition that clears AND re-fires
        // entirely while `onTaskStuck` is disabled keeps its stale key, so the
        // re-fire stays suppressed for the rest of the CURRENT pass — the next
        // pass start reseeds (erasing the key) and the condition delivers then.
        let stillMatchingKeys = Set(items.map(\.key))
        autovisorNotifiedAttentionKeys = autovisorNotifiedAttentionKeys.filter {
            stillMatchingKeys.contains($0) || ($0.trigger == .stuck && !stuckEvaluated)
        }
        guard !items.isEmpty else { return }

        // Already reviewing → deliver the event into the LIVE conversation (queued
        // supervisor message, drained on the next tool-loop iteration) instead of
        // waiting for the pass to end. Deduped per (task, trigger); the wake
        // debounce deliberately does NOT apply — each distinct condition notifies
        // once while it persists. No `autovisorLastWakeAt` stamp, so a condition
        // the manager fails to address mid-pass still gets the normal fresh-pass
        // wake once the pass ends. This branch is fully synchronous (no `await`),
        // so a concurrent observer/poll call can't double-inject.
        if taskEngineStates[managerID] == .running {
            let fresh = items.filter { !autovisorNotifiedAttentionKeys.contains($0.key) }
            // The form-state guard must precede ALL bookkeeping: when it isn't
            // wired (headless), marking notified/seen without delivery would
            // permanently silence `created` (seen IS its level-clear) and mute the
            // others for the whole pass. Skipping everything keeps the levels live
            // so the fresh-pass wake delivers after the pass ends — degraded,
            // never lost. A pass that parks/finishes before the next iteration is
            // also safe: the queue backstops flush into the parked conversation or
            // a fresh run's iteration 1.
            guard !fresh.isEmpty,
                  let formState = quickCaptureFormState,
                  let message = QuickCaptureFormState.QueuedChatMessage(
                      text: Self.composeAutovisorEventNotice(fresh),
                      attachments: [], clippedTexts: [],
                      targetRoleID: autovisorRole?.id,
                      isFromAutomatedSupervisor: true
                  ) else { return }
            formState.appendQueuedMessage(message, for: managerID)
            autovisorNotifiedAttentionKeys.formUnion(fresh.map(\.key))
            // `created` has no state transition that clears its level — mark the
            // notified tasks seen so the condition goes quiet once delivered.
            autovisorSeenTaskIDs.formUnion(fresh.filter { $0.trigger == .created }.map(\.taskID))
            return
        }

        // A human message/answer is pending to the parked step (queued or already
        // written; resume is imminent). Superseding now would `createNewRun` and
        // orphan it on the old run (data loss). Defer to the resume — it continues
        // the SAME run; the event stays live (level-triggered) and injects once the
        // manager hits `.running` (the observer re-fires on that transition). No
        // debounce stamp / no seen update here so the event remains deliverable.
        if taskEngineStates[managerID] == .needsSupervisorInput,
           autovisorHasPendingHumanContinuation(managerID) {
            return
        }

        if let last = autovisorLastWakeAt, now.timeIntervalSince(last) < act.minSecondsBetweenRuns { return }
        // Mark every current top-level task as seen so `onTaskCreated` doesn't
        // re-trigger for the same ones next tick (the other triggers are
        // level-based and re-evaluate correctly under the debounce).
        autovisorSeenTaskIDs = Set(watchable.map(\.id))
        autovisorLastWakeAt = now
        // Event wakes get a FRESH review pass — a parked (`wait_for_events`)
        // engine is superseded, not continued (only human messages continue
        // the parked conversation).
        await startAutovisorPass(taskID: managerID)
    }

    /// Seeds the mid-review dedup set with every condition matching RIGHT NOW —
    /// called from `startRun`'s manager hook at every pass start (event-wake,
    /// recurrence, Run-now, open-time, queue-driven chat wake). A pass observes
    /// everything matching at its start via `list_tasks`, so only conditions that
    /// NEWLY arise mid-pass should inject a live notice. Without this, the
    /// manager's own `.running` transition re-fires the engine-state observer and
    /// the injection branch would duplicate the very condition the pass was
    /// started for. `stuck: []` — a stuck condition present at pass start injects
    /// once on the next poll tick, which is desirable since `list_tasks` doesn't
    /// surface "stuck". The `flushParked` resume path (a human continuing a parked
    /// conversation via `answerSupervisorQuestion` → `resumeRun`) deliberately does
    /// NOT re-seed — the continued conversation never observed mid-park arrivals,
    /// so injecting them there is correct.
    func seedAutovisorNotifiedKeysForPassStart() {
        guard let settings = snapshot?.workFolder.settings, settings.autovisorEnabled,
              let managerID = autovisorTaskID else { return }
        autovisorNotifiedAttentionKeys = Set(Self.autovisorAttentionItems(
            watchable: autovisorWatchableTasks(excluding: managerID), engineStates: taskEngineStates,
            activation: settings.autovisorActivation, seen: autovisorSeenTaskIDs, stuck: []
        ).map(\.key))
    }

    /// Top-level, non-manager tasks the Autovisor watches. Single source of truth —
    /// the pass-start seed MUST see the same set as the wake (the seed absorbs the
    /// condition that triggered the pass only if both compute identical watchables),
    /// and the open-time seen-seed keys `onTaskCreated` off the same population.
    private func autovisorWatchableTasks(excluding managerID: Int) -> [TaskSummary] {
        (snapshot?.tasksIndex.tasks ?? []).filter { $0.parentTaskID == nil && $0.id != managerID }
    }

    /// Whether any watchable top-level task currently matches an enabled activation trigger.
    /// Pure read over the supplied snapshots — no engine, no side effects — so it is unit-testable
    /// with hand-built `TaskSummary` values.
    ///
    /// All four triggers are LEVEL-triggered: a task that stays in a matching state keeps the
    /// manager wake-eligible every tick. The caller's `minSecondsBetweenRuns` debounce bounds how
    /// often that actually spawns a run, and the per-minute poll backstop catches event-wakes the
    /// observer debounced. The manager resolves each by acting — answering, closing, or restarting —
    /// after which the trigger goes quiet.
    ///
    /// `onTaskCompleted` keys on the DERIVED `.needsSupervisorAcceptance` ("Review") status, NOT
    /// `.done`: a finished task derives to Review until the manager closes it, and `.done` only
    /// appears AFTER close. Matching `.done` (the old behavior) both missed the actual review AND
    /// looped forever on every already-closed task (closed tasks persist in `tasksIndex`).
    /// `onTaskNeedsSupervisor` reads the live engine state (the signal the immediate event-wake
    /// observes); the status-based triggers read the derived summary so a closed task stops matching.
    ///
    /// `stuck` carries the ids the poll backstop found looping/hung (empty on the
    /// observer path); `onTaskStuck` matches against it. Defaulted to `[]` so the
    /// predicate's existing call sites and tests are unaffected.
    nonisolated static func autovisorNeedsAttention(
        watchable: [TaskSummary],
        engineStates: [Int: TeamEngineState],
        activation act: AutovisorActivation,
        seen: Set<Int>,
        stuck: Set<Int> = []
    ) -> Bool {
        !autovisorAttentionItems(
            watchable: watchable, engineStates: engineStates, activation: act,
            seen: seen, stuck: stuck
        ).isEmpty
    }

    /// The activation trigger a watchable task matched. One item is emitted PER
    /// matching trigger (a task can match several), so mid-review dedup keys are
    /// per-condition, not per-task. No raw value on purpose — the cases are never
    /// persisted or wire-facing, and a `String` raw value would falsely signal a
    /// stability contract (the `FeatureTipID` / `LoopSignal.scope` convention).
    nonisolated enum AutovisorAttentionTrigger {
        case needsSupervisor, failed, completed, created, stuck
    }

    /// Dedup identity of one attention condition — the task and the trigger,
    /// deliberately WITHOUT the title (a rename must not re-notify).
    nonisolated struct AutovisorAttentionKey: Hashable {
        let taskID: Int
        let trigger: AutovisorAttentionTrigger
    }

    /// One matched attention condition, carrying the title for notice text.
    /// Deliberately NOT Hashable — the only hashable currency is `key`, so
    /// title-inclusive dedup (a `Set<AutovisorAttentionItem>`) won't compile.
    nonisolated struct AutovisorAttentionItem {
        let taskID: Int
        let title: String
        let trigger: AutovisorAttentionTrigger
        var key: AutovisorAttentionKey { .init(taskID: taskID, trigger: trigger) }
    }

    /// Itemized form of `autovisorNeedsAttention` — same five trigger rules, but
    /// returns WHAT matched so the mid-review injection path can compose a notice
    /// and dedup per condition. Order: watchable order, triggers in the fixed
    /// sequence below (deterministic for tests and notice text).
    nonisolated static func autovisorAttentionItems(
        watchable: [TaskSummary],
        engineStates: [Int: TeamEngineState],
        activation act: AutovisorActivation,
        seen: Set<Int>,
        stuck: Set<Int> = []
    ) -> [AutovisorAttentionItem] {
        watchable.flatMap { summary -> [AutovisorAttentionItem] in
            var triggers: [AutovisorAttentionTrigger] = []
            if act.onTaskNeedsSupervisor, engineStates[summary.id] == .needsSupervisorInput { triggers.append(.needsSupervisor) }
            if act.onTaskFailed, summary.status == .failed { triggers.append(.failed) }
            if act.onTaskCompleted, summary.status == .needsSupervisorAcceptance { triggers.append(.completed) }
            if act.onTaskCreated, !seen.contains(summary.id) { triggers.append(.created) }
            if act.onTaskStuck, stuck.contains(summary.id) { triggers.append(.stuck) }
            return triggers.map { AutovisorAttentionItem(taskID: summary.id, title: summary.title, trigger: $0) }
        }
    }

    /// Renders the mid-review event notice delivered into the manager's live
    /// conversation — one bullet per condition with the actionable tool hint.
    nonisolated static func composeAutovisorEventNotice(_ items: [AutovisorAttentionItem]) -> String {
        let bullets = items.map { item -> String in
            let task = "Task #\(item.taskID) \"\(item.title)\""
            switch item.trigger {
            case .needsSupervisor:
                return "- \(task) is waiting for a supervisor answer (answer_task_question)."
            case .failed:
                return "- \(task) failed (task_status to triage)."
            case .completed:
                return "- \(task) finished and awaits review (review it, then control_task close)."
            case .created:
                return "- New task: \(task) was created."
            case .stuck:
                return "- \(task) looks stuck or looping (task_status / manage_role)."
            }
        }
        return (["Event update while you are reviewing — new since this pass started:"] + bullets)
            .joined(separator: "\n")
    }

    /// Top-level, currently-`.running` tasks whose latest run has a looping or hung
    /// role. Mirrors `evaluateRunTimeouts`' access pattern (running engine ⇒ task is
    /// loaded). The live token-activity timestamp comes from `streamingPreviewManager`
    /// (the per-step keying matches `DelegationLoopWatcher`/`executionStates`). Called
    /// only from the per-minute poll path, so the per-task detector cost stays off the
    /// hot observer path.
    func computeStuckTaskIDs(watchable: [TaskSummary], now: Date) -> Set<Int> {
        // User-tunable stuck-detection thresholds (Settings → Autovisor → Stuck
        // detection), defaulting to the constants when no snapshot is loaded.
        let tuning = snapshot?.workFolder.settings.autovisorTuning ?? .default
        var stuck: Set<Int> = []
        for summary in watchable where taskEngineStates[summary.id] == .running {
            guard let task = loadedTask(summary.id) else { continue }
            let verdict = AutovisorStuckEvaluator.evaluate(
                task: task, now: now,
                lastStreamActivityAt: { self.streamingPreviewManager.lastStreamActivity(stepID: $0, taskID: summary.id) },
                liveStreamText: { self.streamLiveText(stepID: $0, taskID: summary.id) },
                hangSeconds: tuning.stuckHangSeconds,
                loopRecencySeconds: tuning.stuckLoopRecencySeconds
            )
            if verdict.isStuck { stuck.insert(summary.id) }
        }
        return stuck
    }

    // MARK: - Action hook (LLMStateDelegate)

    /// Applies one Autovisor write-action by dispatching to the matching
    /// orchestrator operation. Enforces the self-guard up front. See
    /// `AutovisorAction`.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func performAutovisorAction(_ action: AutovisorAction) async -> AutovisorActionResult {
        // Self-guard: the manager must never act on its own task (would deadlock /
        // self-destruct). Folder-level actions (createManagedTask, setWorkFolderContext)
        // have no target and pass through. A task-targeted action against a task that
        // doesn't exist fails loudly here instead of silently no-op'ing downstream.
        if let target = action.targetTaskID {
            if target == autovisorTaskID {
                return .failure("Refused: the manager cannot act on its own task (#\(target)).")
            }
            await ensureTaskLoaded(target)
            guard loadedTask(target) != nil else {
                return .failure("Task #\(target) not found — call list_tasks for current task ids.")
            }
        }

        switch action {
        case .createManagedTask(let title, let brief, let teamID):
            // User-tunable caps (Settings → Autovisor → Limits); fall back to the
            // constant defaults when no snapshot is loaded.
            let tuning = snapshot?.workFolder.settings.autovisorTuning ?? .default
            // Runaway guard (dive-deeper finding 7): bound concurrent in-flight work.
            let runningNonManager = taskEngineStates.filter {
                $0.value == .running && $0.key != autovisorTaskID
            }.count
            if runningNonManager >= tuning.maxConcurrentManagedTasks {
                return .failure("Too many tasks already running (\(runningNonManager)). Wait for some to finish before creating more.")
            }
            // Per-review cap: bound how many NEW tasks one review pass may spawn
            // (reset on each manager run start in `startRun`). The concurrent cap
            // alone wouldn't stop a burst of immediately-idle creations.
            if autovisorCreationsThisReview >= tuning.maxManagedTasksPerReview {
                return .failure("Per-review task-creation limit (\(tuning.maxManagedTasksPerReview)) reached this pass — review or finish existing tasks before creating more.")
            }
            // Resolve the team BEFORE creating anything: a provided-but-unresolvable
            // team_id must fail loudly, not silently fall back to the active team.
            let resolvedTeamID: NTMSID?
            switch classifyManagedTeamID(teamID) {
            case .useActiveTeam:
                resolvedTeamID = nil
            case .team(let id):
                resolvedTeamID = id
            case .generated:
                resolvedTeamID = await ensureGeneratedTeamID()
            case .unknown(let raw):
                return .failure("Unknown team_id '\(raw)'. Pick one from the catalog in create_managed_task's description, omit it for the active team, or use 'generated'.")
            }
            guard let id = await createTask(
                title: title, supervisorTask: brief, preferredTeamID: resolvedTeamID, makeActive: false
            ) else {
                return .failure(lastErrorMessage ?? "Failed to create task.")
            }
            autovisorCreationsThisReview += 1
            // Pre-mark the new task as seen so the manager's OWN creation can't trip the
            // `onTaskCreated` self-wake before the next event-wake overwrites the seen-set.
            autovisorSeenTaskIDs.insert(id)
            await ensureTaskLoaded(id)
            await startRun(taskID: id)
            return .success("Created and started task #\(id): \(title)", createdTaskID: id)

        case .controlTask(let taskID, let verb):
            return await applyControlTask(taskID: taskID, verb: verb)

        case .manageRole(let taskID, let roleID, let verb):
            return await applyManageRole(taskID: taskID, roleID: roleID, verb: verb)

        case .answerTaskQuestion(let taskID, let answer):
            guard let stepID = loadedTask(taskID)?.runs.last?.steps
                .first(where: { $0.needsSupervisorInput })?.id else {
                return .failure("Task #\(taskID) is not waiting for supervisor input.")
            }
            // On failure, `answerSupervisorQuestion` already set a specific
            // `lastErrorMessage` (race / attachment-finalize) — surface it to the
            // manager rather than a generic string so it learns WHY delivery failed.
            // `isAutoAnswer: true` — the Autovisor (an LLM) is the one answering.
            let before = lastErrorMessage
            let ok = await answerSupervisorQuestion(
                stepID: stepID, taskID: taskID, answer: answer, isAutoAnswer: true)
            if ok { return .success("Answered task #\(taskID).") }
            let detail = (lastErrorMessage != before ? lastErrorMessage : nil)
                ?? "Failed to deliver answer to task #\(taskID)."
            return .failure(detail)

        case .messageTask(let taskID, let text, let roleID):
            guard let formState = quickCaptureFormState,
                  let message = QuickCaptureFormState.QueuedChatMessage(
                      text: text, attachments: [], clippedTexts: [], targetRoleID: roleID,
                      // The Autovisor (an LLM) authored this — if the backstop
                      // delivers it as a question ANSWER, the feed must show the
                      // "Auto-answered" badge, not the human checkmark.
                      isFromAutomatedSupervisor: true
                  ) else {
                return .failure("Could not queue message for task #\(taskID).")
            }
            formState.appendQueuedMessage(message, for: taskID)
            // Wake an idle task so it consumes the message promptly (a fresh run
            // drains the queue on iteration 1); a running task picks it up next iteration.
            if taskEngineStates[taskID] != .running {
                await startRun(taskID: taskID)
            }
            return .success("Queued message for task #\(taskID).")

        case .scheduleTask(let taskID, let intervalMinutes):
            if intervalMinutes <= 0 {
                await setTaskRecurrence(taskID: taskID, recurrence: nil)
                return .success("Cleared schedule for task #\(taskID).")
            }
            let seconds = TimeInterval(max(1, intervalMinutes) * 60)
            let recurrence = TaskRecurrence(rule: .interval(seconds: seconds), isEnabled: true)
            await setTaskRecurrence(taskID: taskID, recurrence: recurrence)
            return .success("Task #\(taskID) will now run every \(intervalMinutes) min.")

        case .setWorkFolderContext(let content):
            return await reportingError("Updated the Work Folder Context.") {
                await self.updateWorkFolderContext(content)
            }
        }
    }

    /// Write-through of the manager's standing memory (from `update_scratchpad`).
    /// Returns `false` if the underlying `settings.json` write failed, so the
    /// caller can surface a persistence failure to the manager (its memory is its
    /// only cross-run state — a silent failure means it silently forgets).
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func persistAutovisorMemory(_ text: String) async -> Bool {
        let before = lastErrorMessage
        await updateAutovisorMemory(text)
        return lastErrorMessage == before
    }

    /// Loads a task (background tasks aren't always in `loadedTasks`) for `task_status`.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func autovisorLoadTask(_ taskID: Int) async -> NTMSTask? {
        await ensureTaskLoaded(taskID)
        return loadedTask(taskID)
    }

    /// Live token-activity timestamp for a step, sourced from the streaming
    /// preview manager. Feeds the Autovisor stuck-detector's hang check.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func streamLastActivityAt(stepID: String, taskID: Int) -> Date? {
        streamingPreviewManager.lastStreamActivity(stepID: stepID, taskID: taskID)
    }

    /// The step's current (uncommitted) streaming thinking+content buffer, combined
    /// the same way `DelegationLoopWatcher` combines them. Feeds the stuck-detector's
    /// within-message (thinking-loop) check. Returns nil when nothing is buffered.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func streamLiveText(stepID: String, taskID: Int) -> String? {
        let thinking = streamingPreviewManager.streamingThinking(stepID: stepID, taskID: taskID) ?? ""
        let content = streamingPreviewManager.streamingContent(stepID: stepID, taskID: taskID) ?? ""
        guard !thinking.isEmpty || !content.isEmpty else { return nil }
        return thinking + "\n" + content
    }

    // MARK: - Private

    private func applyControlTask(taskID: Int, verb: ControlVerb) async -> AutovisorActionResult {
        switch verb {
        case .start:
            // `startRun` silently returns when the engine is already active /
            // generating, so report that as a failure instead of a false success.
            if managerTaskEngineActive(taskID) || isGeneratingTeam(taskID: taskID) {
                return .failure("Task #\(taskID) is already running.")
            }
            let runsBefore = loadedTask(taskID)?.runs.count ?? 0
            await startRun(taskID: taskID)
            let started = (loadedTask(taskID)?.runs.count ?? 0) > runsBefore
                || managerTaskEngineActive(taskID) || isGeneratingTeam(taskID: taskID)
            return started ? .success("Started task #\(taskID).")
                           : .failure(lastErrorMessage ?? "Task #\(taskID) could not start.")
        case .pause:
            return await reportingError("Paused task #\(taskID).") { await self.pauseRun(taskID: taskID) }
        case .resume:
            return await reportingError("Resumed task #\(taskID).") { await self.resumeRun(taskID: taskID) }
        case .stop:
            stopEngineForTask(taskID)
            return .success("Stopped task #\(taskID).")
        case .close:
            // Recursive stop FIRST so in-flight delegation children aren't orphaned
            // (dive-deeper finding 12b — closeTask's own stopEngine is non-recursive).
            stopEngineForTask(taskID)
            let ok = await closeTask(taskID: taskID)
            return ok ? .success("Closed task #\(taskID).")
                      : .failure(lastErrorMessage ?? "Failed to close task #\(taskID).")
        case .delete:
            return await reportingError("Deleted task #\(taskID).") { await self.removeTask(taskID) }
        case .rename(let title):
            return await reportingError("Renamed task #\(taskID) to \"\(title)\".") {
                await self.updateTaskTitle(id: taskID, title: title)
            }
        case .setTimeout(let seconds):
            let msg = seconds == nil ? "Cleared run timeout for task #\(taskID)." : "Set run timeout for task #\(taskID)."
            return await reportingError(msg) { await self.setTaskRunTimeout(taskID: taskID, seconds: seconds) }
        }
    }

    private func applyManageRole(taskID: Int, roleID: String, verb: RoleVerb) async -> AutovisorActionResult {
        // Every role verb needs a real role in the task's latest run. A hallucinated
        // role_id would otherwise set a status for a nonexistent role (a §7 no-op)
        // and report success. `accept`'s own Bool already covers this AND rejects a role
        // that isn't `.needsAcceptance` (via `acceptRole`'s status guard), but validating
        // existence up front gives a clearer message for all verbs.
        guard resolveManagedRoleStep(taskID: taskID, roleID: roleID) != nil else {
            return .failure("Task #\(taskID) has no role '\(roleID)' — call task_status for valid role_ids.")
        }
        switch verb {
        case .restart(let comment):
            return await reportingError("Restarted role \(roleID) on task #\(taskID).") {
                await self.restartRole(taskID: taskID, roleID: roleID, comment: comment)
            }
        case .accept:
            let ok = await acceptRole(taskID: taskID, roleID: roleID)
            return ok ? .success("Accepted role \(roleID) on task #\(taskID).")
                      : .failure(lastErrorMessage ?? "Could not accept role \(roleID).")
        case .requestChanges(let comment):
            return await reportingError("Requested changes from role \(roleID) on task #\(taskID).") {
                await self.requestRevision(taskID: taskID, roleID: roleID, comment: comment)
            }
        case .correct(let comment):
            // `correctRole` hard-requires the task to be paused; pre-check so the
            // manager gets an actionable message instead of a false success.
            guard taskEngineStates[taskID] == .paused else {
                return .failure("correct requires task #\(taskID) to be paused first (use control_task pause).")
            }
            return await reportingError("Sent correction to role \(roleID) on task #\(taskID).") {
                await self.correctRole(taskID: taskID, roleID: roleID, comment: comment)
            }
        case .finishAdvisory:
            let ok = await finishAdvisoryRoleAwaiting(taskID: taskID, roleID: roleID)
            return ok ? .success("Finished advisory role \(roleID) on task #\(taskID).")
                      : .failure(lastErrorMessage ?? "Could not finish advisory role \(roleID).")
        }
    }

    /// Outcome of classifying a `create_managed_task` team_id.
    private enum ManagedTeamResolution {
        case useActiveTeam            // omitted/empty → the folder's active team
        case team(NTMSID)             // an existing, non-hidden team
        case generated                // the `"generated"` sentinel
        case unknown(String)          // provided but unresolvable → must fail loudly
    }

    /// Classifies a team_id without side effects (testable). The `generated` case is
    /// materialized separately by `ensureGeneratedTeamID` so this stays pure.
    private func classifyManagedTeamID(_ raw: String?) -> ManagedTeamResolution {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .useActiveTeam
        }
        if raw == DelegationConstants.generatedTeamSentinel { return .generated }
        if let team = snapshot?.workFolder.teams.first(where: { $0.id == raw }), !team.isHiddenFromPickers {
            return .team(team.id)
        }
        return .unknown(raw)
    }

    /// Returns the id of the (lazily-created) generated placeholder team.
    private func ensureGeneratedTeamID() async -> NTMSID {
        if let existing = snapshot?.workFolder.teams.first(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
            return existing.id
        }
        let team = TeamTemplateFactory.generatedTeam()
        await mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
                proj.teams.append(team)
            }
        }
        return team.id
    }

    // MARK: - Private helpers

    /// True when the task's engine is in any active state (`startRun` would no-op).
    /// Mirrors the file-private `isTaskEngineActive` in `+Scheduling.swift`
    /// (Swift `private` is file-scoped, so it can't be shared across the extension).
    private func managerTaskEngineActive(_ taskID: Int) -> Bool {
        switch taskEngineStates[taskID] {
        case .running, .needsAcceptance, .needsSupervisorInput: return true
        default: return false
        }
    }

    /// The step for `roleID` in the task's latest run, or nil if no such role exists.
    private func resolveManagedRoleStep(taskID: Int, roleID: String) -> StepExecution? {
        loadedTask(taskID)?.runs.last?.steps.first { $0.effectiveRoleID == roleID }
    }

    /// Runs a `Void` orchestrator op and converts a freshly-surfaced error banner
    /// into a `.failure` for the manager. Used for the persistence/lifecycle verbs
    /// whose orchestrator methods report failure via `lastErrorMessage` (the
    /// silent-no-op cases that DON'T set an error — `start`, role validation,
    /// `correct`-not-paused — are pre-checked by the callers instead).
    private func reportingError(_ successMessage: String, _ op: () async -> Void) async -> AutovisorActionResult {
        let before = lastErrorMessage
        await op()
        if let err = lastErrorMessage, err != before { return .failure(err) }
        return .success(successMessage)
    }

    /// Creates the team (if missing) + the hidden manager task, pins its ID, and
    /// seeds its review recurrence. Returns the new task ID, or nil on failure.
    private func createAutovisorTask() async -> Int? {
        // 1. Ensure the Autovisor team exists in teams.json (team must exist
        //    before createTask resolves `preferredTeamID` off disk).
        await ensureAutovisorTeam()
        guard let teamID = snapshot?.workFolder.teams
            .first(where: { $0.templateID == AutovisorConstants.teamTemplateID })?.id
        else {
            // ensureAutovisorTeam should always leave the team present; if it didn't
            // (persist failure / work-folder closed mid-flight) don't fail silently —
            // surface it unless mutateWorkFolder already set a more specific message.
            if lastErrorMessage == nil {
                lastErrorMessage = "Autovisor could not start — its team is missing. Try reopening the work folder."
            }
            return nil
        }

        // 2. Create the hidden manager task (makeActive: false — never steals focus).
        //    The brief IS the goal (rendered as "## Supervisor Goal"); it's kept in
        //    lock-step with `settings.autovisorGoal` by `ensureAutovisorTask`
        //    and `updateAutovisorGoal`. Must be non-empty so `hasInitialInput`
        //    marks the "Supervisor Task" artifact produced and the manager is ready.
        guard let taskID = await createTask(
            title: "Autovisor",
            supervisorTask: AutovisorConstants.defaultGoal,
            preferredTeamID: teamID,
            makeActive: false
        ) else {
            // Loud failure (mirrors the missing-team branch above): the folder
            // would otherwise sit `autovisorEnabled == true` with no manager
            // task — auto-answer stays suppressed for every top-level task
            // while `wakeAutovisorForEvents` bails on the nil `autovisorTaskID`
            // guard, so questions pile up that "Autovisor should have answered"
            // with zero signal about why.
            if lastErrorMessage == nil {
                lastErrorMessage = "Autovisor could not start — its task could not be created. Try toggling Autovisor off and on, or reopening the work folder."
            }
            return nil
        }
        await ensureTaskLoaded(taskID)

        // 3. Pin the ID (single source of truth for sidebar/fallback exclusions).
        //    Goal/memory defaults are seeded by the caller `ensureAutovisorTask`
        //    (one place, covers both fresh creations and existing empty managers).
        await mutateWorkFolder { $0.state.autovisorTaskID = taskID }

        // 4. Seed the review recurrence (enabled). The scheduler picks it up because
        //    the manager is top-level (parentTaskID == nil).
        let rule = RecurrenceRule.interval(seconds: AutovisorConstants.defaultScheduleIntervalSeconds)
        await setTaskRecurrence(taskID: taskID, recurrence: TaskRecurrence(rule: rule, isEnabled: true))

        return taskID
    }
}
