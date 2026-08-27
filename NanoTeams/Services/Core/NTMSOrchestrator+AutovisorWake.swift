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
    func sendMessageToAutovisor(
        _ text: String,
        attachments: [StagedAttachment] = [],
        clippedTexts: [String] = []
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = autovisorTaskID,
              let formState = quickCaptureFormState,
              let message = QuickCaptureFormState.QueuedChatMessage(
                  text: trimmed, attachments: attachments, clippedTexts: clippedTexts, targetRoleID: autovisorRole?.id
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

    /// The other kind of park: `LoopRecoveryPolicy` gave up after
    /// `maxThinkingLoopBreaks` and parked the manager carrying the loop diagnostic.
    ///
    /// Sibling of `taskHasIdleParkStep`, and deliberately NOT the same predicate: an
    /// idle park means "I finished the pass and have nothing left to do", a loop park
    /// means "the pass died mid-thought". Matched by `contains` on
    /// `LoopRecoveryPolicy.stuckQuestionMarker` rather than by equality, because the
    /// question interpolates the role name and the diagnostic.
    nonisolated static func taskHasLoopParkStep(_ task: NTMSTask?) -> Bool {
        guard let run = task?.runs.last else { return false }
        return run.steps.contains {
            $0.needsSupervisorInput
                && ($0.supervisorQuestion?.contains(LoopRecoveryPolicy.stuckQuestionMarker) ?? false)
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
    func setAutovisorLLMOverride(baseURL: String?, model: String?, provider: LLMProvider?) async {
        let b = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = LLMOverride(
            baseURLString: (b?.isEmpty == false) ? b : nil,
            modelName: (m?.isEmpty == false) ? m : nil,
            provider: provider
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
    /// level-triggered backstop from the poll loop. No throttle — two delivery shapes:
    /// • manager `.running` (mid-review) — the event is injected into the LIVE
    ///   conversation as a queued supervisor message (drained next tool-loop
    ///   iteration), deduped per (task, trigger) via `autovisorNotifiedAttentionKeys`;
    /// • any other state — an immediate FRESH review pass for a not-yet-seen condition
    ///   (a parked `wait_for_events` engine is superseded, not continued). A condition
    ///   already in `autovisorLastPassAttentionKeys` is not re-delivered FOR AS LONG AS IT
    ///   KEEPS MATCHING (deliver-once). A `.needsSupervisor` condition that goes quiet is
    ///   retired from that baseline — by `noteSupervisorQuestionResolved` when an answer
    ///   resolves it, or by this method's own prune otherwise — so the NEXT question on the
    ///   same task is a new condition and wakes.
    ///
    /// `includeStuck` enables the `onTaskStuck` evaluation — passed `true` ONLY by
    /// the per-minute poll backstop. The hot engine-state observer leaves it `false`
    /// so the per-running-task loop/LCS detector never runs on that high-frequency
    /// path; a hung role runs forever anyway, so ≤~60 s latency is immaterial.
    func wakeAutovisorForEvents(now: Date = MonotonicClock.shared.now(), includeStuck: Bool = false) async {
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
        // Retire spent `.needsSupervisor` keys from the deliver-once baseline too, so
        // "delivered once" means once per QUESTION rather than once per task for the life
        // of the process. `answerSupervisorQuestion` retires a key the moment it resolves
        // one (`noteSupervisorQuestionResolved`); this covers the clearing paths that carry
        // no answer — `manage_role restart`, `control_task stop`, a superseded run.
        //
        // ABOVE the `items.isEmpty` return on purpose: the wake that observes a question go
        // quiet is usually the one carrying NO items at all (the manager answered the task
        // and it resumed to `.running`), and that is the only moment this can be learned.
        //
        // ONLY `.needsSupervisor`. The other triggers keep their level semantics because
        // there a "flicker" is noise, not news: the manager's remedy for `.failed` is a
        // restart, so pruning that key would make a deterministically-failing role wake a
        // fresh pass every failure latency until auto-off — one `createNewRun` each, each
        // resetting `autovisorCreationsThisReview`. A question is different in kind: the
        // remedy CONSUMES it, and the next one is a thing the manager has never seen. The
        // recurrence sweep remains the re-review for everything still standing.
        //
        // Cannot weaken the concurrent-wake serialization below, and the argument is per
        // key: `hasFreshCondition` only ever tests keys that ARE in `items`, and any such
        // key is in `stillMatchingKeys`, so it survives. A key this drops is one the
        // freshness gate would not have looked at.
        autovisorLastPassAttentionKeys = autovisorLastPassAttentionKeys.filter {
            $0.trigger != .needsSupervisor || stillMatchingKeys.contains($0)
        }
        guard !items.isEmpty else { return }

        // Already reviewing → deliver the event into the LIVE conversation (queued
        // supervisor message, drained on the next tool-loop iteration) instead of
        // waiting for the pass to end. Deduped per (task, trigger) — each distinct
        // condition notifies once while it persists; a condition the manager fails to
        // address mid-pass still gets the normal fresh-pass wake once the pass ends.
        // This branch is fully synchronous (no `await`), so a concurrent observer/poll
        // call can't double-inject.
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
                      // Both axes, and they are not the same fact: `isFromAutomatedSupervisor`
                      // says WHO (it feeds the auto-answer badge and the pending-human guard),
                      // `kind` says WHAT — the drain reads it to persist `.autovisorEvent` and
                      // to ship the turn unmarked. `message_task` is automated speech and takes
                      // only the first.
                      isFromAutomatedSupervisor: true,
                      kind: .autovisorEventNotice
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
        // freshness-snapshot / seen update here so the event remains deliverable.
        if taskEngineStates[managerID] == .needsSupervisorInput,
           autovisorHasPendingHumanContinuation(managerID) {
            return
        }

        // NO THROTTLE: a "fresh" condition — one NOT present at the manager's last pass
        // start (`autovisorLastPassAttentionKeys`) — wakes the manager immediately. A
        // condition it has ALREADY seen AND THAT IS STILL STANDING is not re-delivered
        // (deliver-once — the prune above retires a question that went quiet); the periodic
        // recurrence sweep re-reviews any it didn't resolve, so a standing unresolved
        // condition can't tight-loop. The baseline is recomputed at pass start INCLUDING
        // stuck (`seedAutovisorNotifiedKeysForPassStart`) — one of the baseline's THREE
        // maintainers, beside this method's prune+record and the single-key retirement in
        // `noteSupervisorQuestionResolved` — so a stuck task is delivered
        // ONCE (not every poll tick) and a no-longer-stuck one is dropped (a fresh stuck
        // episode re-wakes). Fixes the wedge where a task the manager CREATED mid-pass
        // produced its artifact / called ask_supervisor AFTER it parked: never in the
        // snapshot → wakes promptly. (A burst is naturally bounded: the first event flips
        // the manager to `.running`, so the rest take the mid-review injection branch
        // above instead of new passes.)
        let hasFreshCondition = items.contains { !autovisorLastPassAttentionKeys.contains($0.key) }
        guard hasFreshCondition else { return }
        // Record what THIS pass reviews as the new deliver-once baseline — SYNCHRONOUSLY,
        // before the `await startAutovisorPass` below — so a concurrent observer/poll wake
        // for the same conditions sees them as not-fresh and bails. This synchronous record
        // is now the SOLE serialization between the two callers (the debounce that used to
        // provide it was removed); without it both would `createNewRun`. The pass-start
        // seed re-sets it once the run is live.
        autovisorLastPassAttentionKeys = Set(items.map(\.key))
        // Mark every current top-level task as seen so `onTaskCreated` doesn't
        // re-trigger for the same ones next tick (the other triggers are
        // level-based and re-evaluate correctly).
        autovisorSeenTaskIDs = Set(watchable.map(\.id))
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
        let watchable = autovisorWatchableTasks(excluding: managerID)
        let act = settings.autovisorActivation
        // Injection dedup set: `stuck: []` (its existing contract — list_tasks doesn't
        // surface stuck, so a stuck condition injects once mid-pass).
        autovisorNotifiedAttentionKeys = Set(Self.autovisorAttentionItems(
            watchable: watchable, engineStates: taskEngineStates,
            activation: act, seen: autovisorSeenTaskIDs, stuck: []
        ).map(\.key))
        // Deliver-once freshness baseline for the NEXT event wake — ASSIGNED here (the other
        // two maintainers are `wakeAutovisorForEvents`' prune+record and
        // `noteSupervisorQuestionResolved`). Covers passes that
        // DON'T go through `wakeAutovisorForEvents` (recurrence, open-time, Run-now); the
        // event-wake path also sets it synchronously for the race guard. RECOMPUTES stuck
        // (once per pass — cheap next to the LLM call) so a stuck task the manager just
        // reviewed isn't re-delivered every poll, while a no-longer-stuck one is dropped
        // (a fresh stuck episode re-wakes).
        let stuck = act.onTaskStuck ? computeStuckTaskIDs(watchable: watchable, now: MonotonicClock.shared.now()) : []
        autovisorLastPassAttentionKeys = Set(Self.autovisorAttentionItems(
            watchable: watchable, engineStates: taskEngineStates,
            activation: act, seen: autovisorSeenTaskIDs, stuck: stuck
        ).map(\.key))
    }

    /// Retires the deliver-once bookkeeping for a Supervisor question that has just been
    /// ANSWERED, so the next question on the same task counts as a new condition.
    ///
    /// `AutovisorAttentionKey` is `(taskID, trigger)` — it names the CONDITION, not the
    /// occurrence — so without this the key from a task's first question outlived the
    /// question itself and `hasFreshCondition` read false for every later one (CLAUDE.md
    /// #74). In a chat-mode task every turn is an `ask_supervisor`, so that swallowed every
    /// follow-up until the 10-minute recurrence; the per-minute poll could not help, since
    /// it evaluates the same gate.
    ///
    /// Called from `answerSupervisorQuestion` — the single seam every answer flows through
    /// (the manager's own `answer_task_question`, a human's Quick Capture flush, the
    /// delegated side exchange). Positive evidence at the moment of resolution (CLAUDE.md
    /// #92), so it needs no wake to sample the gap; `wakeAutovisorForEvents`' own prune is
    /// the level-triggered net for clears that carry no answer.
    ///
    /// The loop-park ledger is retired with it: its entry bounds re-delivery for ONE
    /// episode, and keeping a spent one would deny the next, genuinely distinct question
    /// its one free rollback.
    func noteSupervisorQuestionResolved(taskID: Int) {
        let key = AutovisorAttentionKey(taskID: taskID, trigger: .needsSupervisor)
        autovisorLastPassAttentionKeys.remove(key)
        autovisorLoopParkRedelivered.remove(key)
    }

    /// Roll back the attention baseline a pass never earned, once.
    ///
    /// `autovisorLastPassAttentionKeys` means "the manager has reviewed these", and it
    /// is written at pass START. A pass that ends in a `LoopRecoveryPolicy` park died
    /// mid-thought without reviewing anything, so leaving its baseline in place tells
    /// every later wake that a still-unhandled condition is old news — the failed
    /// worker keeps its `.failed` level forever, the poll's `hasFreshCondition` guard
    /// stays false, and recovery falls through to the 10-minute recurrence (or to the
    /// auto-off deadline, after which nothing wakes the folder at all).
    ///
    /// Subtracting only keys NOT already in `autovisorLoopParkRedelivered` is the bound:
    /// one extra pass per key per EPISODE — `noteSupervisorQuestionResolved` retires a
    /// question's entry when it is answered, so a spent rollback cannot deny the next,
    /// genuinely distinct question its own. A manager that loops again immediately finds
    /// its keys already spent, rolls back nothing, and stays parked — so this cannot
    /// become the tight wake loop the deliver-once design prevents.
    ///
    /// Called from `engineForTask`'s state observer (a headless-safe seam) rather than
    /// from a SwiftUI observer, so it also fires with no window mounted.
    func noteAutovisorLoopPark(_ taskID: Int) {
        guard taskID == autovisorTaskID,
              Self.taskHasLoopParkStep(loadedTask(taskID)) else { return }
        let rollback = autovisorLastPassAttentionKeys.subtracting(autovisorLoopParkRedelivered)
        guard !rollback.isEmpty else { return }
        autovisorLastPassAttentionKeys.subtract(rollback)
        autovisorLoopParkRedelivered.formUnion(rollback)
    }

    /// A healthy terminal means the manager actually completed a pass, so the one free
    /// re-delivery is re-armed for any future loop-park episode.
    func clearAutovisorLoopParkLedger(_ taskID: Int) {
        guard taskID == autovisorTaskID else { return }
        autovisorLoopParkRedelivered.removeAll()
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
    /// All five triggers are LEVEL-triggered: a task that stays in a matching state keeps the
    /// manager wake-eligible every tick. The caller's deliver-once freshness baseline
    /// (`autovisorLastPassAttentionKeys`) bounds how often that actually spawns a run (a condition
    /// already reviewed isn't re-delivered), and the per-minute poll backstop is the level-triggered
    /// safety net. The manager resolves each by acting — answering, closing, or restarting —
    /// after which the trigger goes quiet.
    ///
    /// `onTaskCompleted` keys on the DERIVED `.needsSupervisorAcceptance` ("Review") status, NOT
    /// `.done`: a finished task derives to Review until the manager closes it, and `.done` only
    /// appears AFTER close. Matching `.done` (the old behavior) both missed the actual review AND
    /// looped forever on every already-closed task (closed tasks persist in `tasksIndex`).
    /// `onTaskNeedsSupervisor` reads the DURABLE wait-fact (or the live engine state — see
    /// `summaryAwaitsSupervisor`), so a question that survived a relaunch still matches even
    /// though recovery demoted its status; the status-based triggers read the derived summary
    /// so a closed task stops matching.
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

    /// The `onTaskNeedsSupervisor` level: this task is owed a Supervisor answer that can
    /// actually be delivered right now.
    ///
    /// Reads the DURABLE fact (`TaskSummary.isWaitingForSupervisor`), not the engine mirror
    /// alone. `taskEngineStates` is derived from step STATUS, and `StatusRecoveryService`
    /// rewrites every waiting step to `.paused` at launch while leaving the flag AND the
    /// question intact — so `mapDerivedStatusToEngineState` seeds `.paused` for a task that
    /// is still waiting, and a task that was never loaded has no mirror entry at all.
    /// Keying on the mirror is how a question that survived a relaunch reached the manager
    /// only via the 10-minute recurrence. This is the seventh consumer of the durable fact
    /// (CLAUDE.md #91); the other six moved on 2026-08-20 and this one did not.
    ///
    /// The mirror is OR'd in, never replaced: it is the only answer a LEGACY index row can
    /// give (`hasPendingSupervisorInput == nil`, written before the field existed, reads
    /// `false` through `isWaitingForSupervisor` by design), so dropping it would silently
    /// narrow the trigger for exactly those rows. It needs no liveness qualifier of its own
    /// — the engine reaches `.needsSupervisorInput` only while a step SITS at that status.
    ///
    /// `status == .running` vetoes the DURABLE arm, and only that arm.
    /// `hasActiveSupervisorInput` is `needsSupervisorInput || activeAskCall != nil`, so the
    /// durable fact flips true when the `ask_supervisor` CALL lands in `step.toolCalls` —
    /// sub-second before `setNeedsSupervisorInput` writes the park — and it stays true on a
    /// chat-mode step auto-finished carrying an unanswered trailing ask (which derives
    /// `.running` through the chat-mode override). `answer_task_question` matches the STORED
    /// flag, so waking for either shape buys a pass that cannot answer anything. The veto
    /// costs no real wake: every ANSWERABLE shape derives something else — a parked step
    /// derives `.needsSupervisorInput` and a restart-recovered one `.paused`, both
    /// outranking `hasRunning` in `Run.derivedTaskStatus()`. Status is read only to VETO,
    /// never to establish the wait, so this is not the substitution
    /// `isWaitingForSupervisor`'s own doc forbids.
    ///
    /// Accepted consequence: `StepExecutionService.pauseStep` leaves the flag set, so a
    /// DELIBERATELY paused task with a pending question is an item here too, and answering
    /// it resumes the task. It is indistinguishable from a restart-recovered park at every
    /// level (both derive `.paused`; `acceptsSupervisorAnswer` includes `.paused` by
    /// design), so the manager is told instead of guessed for: `list_tasks` reports
    /// `status: "paused"` and `waiting_for_supervisor: true` side by side.
    nonisolated static func summaryAwaitsSupervisor(
        _ summary: TaskSummary, engineState: TeamEngineState?
    ) -> Bool {
        if summary.isWaitingForSupervisor, summary.status != .running { return true }
        return engineState == .needsSupervisorInput
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
            if act.onTaskNeedsSupervisor,
               Self.summaryAwaitsSupervisor(summary, engineState: engineStates[summary.id]) {
                triggers.append(.needsSupervisor)
            }
            if act.onTaskFailed, summary.status == .failed { triggers.append(.failed) }
            if act.onTaskCompleted, summary.status == .needsSupervisorAcceptance { triggers.append(.completed) }
            if act.onTaskCreated, !seen.contains(summary.id) { triggers.append(.created) }
            if act.onTaskStuck, stuck.contains(summary.id) { triggers.append(.stuck) }
            return triggers.map { AutovisorAttentionItem(taskID: summary.id, title: summary.title, trigger: $0) }
        }
    }

    /// Renders the mid-review event notice delivered into the manager's live
    /// conversation — one bullet per condition with the actionable tool hint.
    ///
    /// The opening line comes from `MessageSourceContext.autovisorEventNoticeHeader` rather
    /// than a literal here, because two other places depend on its exact text: the notice
    /// ships UNMARKED (no `Supervisor:` badge, like every other system notice), so that line
    /// is what identifies it on a wire both providers flatten — and the feed's collapsed row
    /// skips it when building its one-line preview, so the glance shows a bullet instead of
    /// the banner its `system: event` label already states.
    ///
    /// Because the notice is unmarked, `PlanningPhasePolicy.discardedSupervisorMessages` —
    /// which finds re-queueable turns by the `Supervisor:` prefix — does not carry it across
    /// a planning boundary. Structurally unreachable rather than merely unlikely:
    /// `PlanningPhasePolicy.isEligible` carries `!isAutovisor`, so the manager never has a
    /// planning phase to cross. A still-standing condition re-notifies on the fresh-pass wake
    /// regardless (`testFailedDeliveredMidPass_unaddressed_freshWakeFiresAfterPassEnds`).
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
        return ([MessageSourceContext.autovisorEventNoticeHeader] + bullets)
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
                processingStatus: { self.streamProcessingStatus(stepID: $0, taskID: summary.id) },
                hangSeconds: tuning.stuckHangSeconds,
                prefillHangSeconds: tuning.stuckPrefillHangSeconds,
                loopRecencySeconds: tuning.stuckLoopRecencySeconds
            )
            if verdict.isStuck { stuck.insert(summary.id) }
        }
        return stuck
    }
}
