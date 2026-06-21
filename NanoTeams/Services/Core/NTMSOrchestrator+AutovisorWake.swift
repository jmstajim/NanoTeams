import Foundation

// Autovisor messaging + event-wake control plane: human messaging, the
// activation-trigger itemizer, mid-review injection vs fresh-pass wake,
// idle-park detection, the LLM override, and stuck detection.
extension NTMSOrchestrator {

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
    func autovisorWatchableTasks(excluding managerID: Int) -> [TaskSummary] {
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
}
