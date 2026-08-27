import SwiftUI

// MARK: - Chat Queue Management
//
// The Supervisor message queue's storage-agnostic control plane: enqueue,
// the two-path consumption (primary injection lives in `LLMExecutionService`;
// this owns the `.needsSupervisorInput` / terminal-state BACKSTOP), the
// resume/start wake mechanisms with their give-up maps, and the
// `MainLayoutView` onChange glue. See the property docs on the main type for
// the dedup/give-up invariants.

extension QuickCaptureController {

    /// Queues the currently-typed composer message for the active task's next
    /// supervisor-input prompt. Called from the Quick Capture overlay when the LLM
    /// is still streaming (`.taskWorking` mode with chat-mode team) and the user
    /// wants to line up their next message without waiting for a question.
    /// Silently no-ops when no task is active (guarded upstream by `canSubmit`);
    /// callers rely on `queueChatMessage` to accept/reject the payload.
    ///
    /// Targets the same role the QuickCapture title displays — i.e. the first
    /// running step's role. This keeps title and queue recipient in lockstep
    /// (multi-role chat teams like Quest Party show one role at a time and
    /// auto-switch as the engine progresses; submit-time lookup follows that
    /// switch). If no running step exists during a transient state transition,
    /// `targetRoleID` falls back to `nil` and the message is drained tier-2
    /// (untargeted) on the next backstop fire.
    func submitQueuedMessageFromForm() {
        guard let store else {
            return
        }
        guard let taskID = store.activeTaskID else {
            store.lastErrorMessage = "No active task — open or create a task first."
            return
        }
        let targetRoleID = store.loadedTask(taskID).flatMap(Self.firstRunningStepRoleID(in:))
        let queued = queueChatMessage(
            text: formState.answerText,
            attachments: formState.answerAttachments,
            clippedTexts: formState.answerClippedTexts.texts,
            taskID: taskID,
            targetRoleID: targetRoleID
        )
        guard queued else { return }
        formState.answerText = ""
        formState.answerAttachments = []
        formState.answerClippedTexts = []
        // The queued message now names files under `.nanoteams/staged/<draftID>/`, and it
        // outlives this composer. Rotate, exactly as `clearTaskDraft()` does on the task
        // path, so the batch owns that directory and the live composer starts a fresh one
        // — otherwise the next `cancelDraft` (or a task creation from the same panel)
        // deletes a directory whose files a pending delivery still depends on, and the
        // failure surfaces minutes later at finalize time with nothing linking the two.
        formState.draftID = UUID()
    }

    /// The role ID of the first running step in `task`'s latest run, if any.
    /// Single source of truth used by both `QuickCaptureModeCoordinator` (to
    /// build the `.taskWorking` title) and `submitQueuedMessageFromForm` (to
    /// target the queue at the same role). Without this shared call site, a
    /// future tweak to either site could silently desync title vs. queue target.
    static func firstRunningStepRoleID(in task: NTMSTask) -> String? {
        task.runs.last?.steps.first(where: { $0.status == .running })?.effectiveRoleID
    }

    /// Stores a message for `taskID`. There are **two** consumption paths and the
    /// queue is the shared storage for both:
    /// - Primary (`.running` roles): `LLMExecutionService.injectQueuedSupervisorMessage`
    ///   pops eligible messages at the top of each `runOneLLMToolIteration`, so
    ///   the LLM sees them on its next request without needing to call
    ///   `ask_supervisor` first.
    /// - Backstop (`.needsSupervisorInput`): `tryFlushQueuedMessages` below
    ///   delivers via `answerSupervisorQuestion` when the role has already paused
    ///   waiting for an answer. Either path pops from the same queue, so no
    ///   double-delivery.
    /// `targetRoleID` narrows delivery to a specific role (delivered only when
    /// THAT role's step iterates or asks for input); `nil` delivers on whichever
    /// role's step consumes first.
    /// Queued messages for a role that completes (`.done`) stay in the queue —
    /// restarting the role (`NTMSOrchestrator.restartRole`) resets the step's
    /// session, so iteration 1 of the restarted step satisfies the injection
    /// hook's guard and delivers them.
    /// Returns `true` if the message was queued AND survived the immediate flush;
    /// `false` if rejected (empty payload via `QueuedChatMessage.init?`) or
    /// synchronously discarded by the flush (non-chat completed task, closed
    /// task) — callers keep the draft and must not show a "queued" confirmation.
    @discardableResult
    func queueChatMessage(
        text: String,
        attachments: [StagedAttachment],
        clippedTexts: [String],
        taskID: Int,
        targetRoleID: String? = nil
    ) -> Bool {
        guard let message = QuickCaptureFormState.QueuedChatMessage(
            text: text,
            attachments: attachments,
            clippedTexts: clippedTexts,
            targetRoleID: targetRoleID
        ) else {
            return false
        }
        formState.appendQueuedMessage(message, for: taskID)
        // Delegation-interrupt path: when the message is targeted at a role
        // that's currently mid-`delegate_to_team`, the role's tool loop is
        // suspended on `awaitTaskTerminalState` — the normal queue
        // consumption paths (next-iteration injection, supervisor-input
        // backstop) can't fire because the role isn't iterating and its
        // engine isn't transitioning. Wake the handler instead so it can
        // pause the child engine and surface the message text inside a
        // `paused_by_supervisor` success envelope on the parent role's next
        // iteration. This is the "team is looping, stop it" feedback loop.
        //
        // The channel is a single `String` that reaches the role inside a JSON envelope,
        // and the entry is DESTROYED right after a successful wake — so whatever the
        // channel cannot carry is lost while the call still reports success. Clips are
        // text: they ride, composed through the same `AnswerTextBuilder` every other
        // submission path uses, so the role reads them in the shape its prompt describes.
        // Files cannot, and finalizing them here would open a second lifecycle over the
        // same staged files the queue's own drain finalizes — so a message carrying
        // attachments declines the fast path entirely and stays queued, delivered whole by
        // the ordinary path. Late, but complete.
        if let role = targetRoleID,
           let store,
           message.attachments.isEmpty,
           store.notifyDelegationInterrupt(
               parentTaskID: taskID,
               parentRoleID: role,
               text: AnswerTextBuilder.build(text: text, clips: clippedTexts).answer
           )
        {
            // The interrupt embedded `text` in the paused envelope returned
            // to the role. Drop the queue entry now — without this the
            // role's next iteration would hit `injectQueuedSupervisorMessage`
            // and consume the same message a second time, delivering the
            // Supervisor's guidance twice (once via the envelope, once as a
            // fresh user turn). Skip `tryFlushQueuedMessages` since the
            // role is mid-delegation, not in any state the flush paths
            // handle.
            formState.removeQueuedMessage(withID: message.id, for: taskID)
            return true
        }
        // Drive the wake-up immediately so a `.paused` engine doesn't leave the
        // message hanging until the next unrelated `engineState` onChange. Cheap
        // for `.running`/`.needsAcceptance` (default branch is no-op); for
        // `.needsSupervisorInput` and `.paused`/`.pending`/`.none` it triggers the
        // appropriate dispatch path.
        tryFlushQueuedMessages()
        // Honest return: the SYNCHRONOUS part of the flush can discard this very
        // message (non-chat `.done` arm; closed-task discard in
        // `wakeRunForQueuedMessages`). Callers use the Bool to clear their draft
        // and show a "queued" confirmation banner — returning `true` after a
        // discard would destroy the draft and overwrite the discard banner with a
        // lie. The async consumption paths (`.needsSupervisorInput` flush Task,
        // resume/start wakes) can't pop before this returns (no await between
        // their dispatch and here), so "still queued" is exactly "not discarded".
        return formState.queuedMessages(for: taskID).contains { $0.id == message.id }
    }

    /// Backstop for the queue — handles the `.needsSupervisorInput` case (primary
    /// consumption happens in `LLMExecutionService.injectQueuedSupervisorMessage`
    /// for `.running` roles). Drains every eligible queued message for the chosen
    /// waiting role into one combined `answerSupervisorQuestion` call (matches the
    /// primary path's drain-all-at-once batching). Called from
    /// `MainLayoutView.onChange(of: engineState.taskEngineStates)` — panel-visibility
    /// independent (queue must resolve even when the overlay is closed).
    ///
    /// `.done` splits by team kind. A non-chat pipeline that reached `.done` is
    /// genuinely finished — discard the queue with a banner (reopening is
    /// `restartRole`'s job). A CHAT task at `.done` is just an ended turn/pass:
    /// chat-mode advisory steps DO reach `.done` via `markChatModeAdvisoryStepDone`
    /// (`noteNonProductiveTurn` after `LLMConstants.maxNonProductiveTurns`
    /// no-tool turns; historically also the
    /// Autovisor's `wait_for_events`, which now parks instead) — so a queued
    /// message wakes the task with a FRESH `startRun` (`resumeRun` would re-enter
    /// the all-terminal run, execute no step, and bounce straight back to `.done`).
    /// The fresh run's step has `session == nil`, so the iteration-1 injection
    /// gate passes and the queue drains.
    ///
    /// Terminal-state discard surfaces `store.lastInfoMessage` with a count so users
    /// aren't silently stranded. `.failed` (any team) and `.done`-chat each apply an
    /// attempted-message-IDs give-up so an unconsumable queue can't wake-loop — via
    /// SEPARATE maps, because the two wake mechanisms are independent (see the
    /// `failedResumeAttemptedMessageIDs` doc).
    ///
    /// NOTE: This discards at the **task** level on engine-terminal states only —
    /// it does NOT fire on individual role completion. Queued messages for a
    /// `.done` role stay queued so `restartRole` can deliver them on iteration 1
    /// of the restarted step.
    func tryFlushQueuedMessages() {
        guard let store else { return }
        // Prune both give-up attempted-IDs maps to tasks that still have queued
        // messages, so entries for deleted/consumed tasks don't accumulate. Safe:
        // the `.failed` and `.done`-chat arms only read entries for tasks present
        // in `taskIDsWithQueuedMessages` (kept here).
        if !failedResumeAttemptedMessageIDs.isEmpty {
            failedResumeAttemptedMessageIDs = failedResumeAttemptedMessageIDs.filter {
                formState.hasQueuedMessage(for: $0.key)
            }
        }
        if !chatStartAttemptedMessageIDs.isEmpty {
            chatStartAttemptedMessageIDs = chatStartAttemptedMessageIDs.filter {
                formState.hasQueuedMessage(for: $0.key)
            }
        }
        // Every arm below can WAKE a run (`resumeRun` / `startRun`) keyed by a bare
        // per-folder task id, which is what made the folder-scope leak escalate from "a
        // message reaches the wrong task" to "opening a folder starts runs nobody asked
        // for". A second guard here — discard ids the current folder's index does not
        // contain — was written and then removed: `apply(_:)` already drops the queue on
        // the folder edge and `removeTask` already drops it on delete, so the guard's only
        // marginal input is one production callers cannot construct, while it made thirty
        // routing tests fail on their synthetic ids. The cause is fixed at the edge; a
        // weaker duplicate downstream is not defence, it is noise.
        for taskID in formState.taskIDsWithQueuedMessages {
            switch store.taskEngineStates[taskID] {
            case .needsSupervisorInput:
                // Retained in DEBUG ONLY so tests can join the drain rather than poll for a
                // side effect — see `_testPendingFlushTasks`. Every signal a poll could watch
                // is produced before the suspension the asserted value is written after.
                retainFlushTaskForTests(Task { @MainActor [weak self] in
                    await self?.flushQueuedChatMessage(taskID: taskID)
                })
            case .done:
                if Self.isChatModeTask(taskID, store: store) {
                    // Chat-mode `.done` is an ended turn, not a finished pipeline —
                    // a queued message continues the chat via a fresh run (drained
                    // on iteration 1). Same give-up shape as `.failed` (own map) so a
                    // run that completes WITHOUT consuming the queue (persistence
                    // failure re-prepends the batch) can't wake-loop LLM passes.
                    let queuedIDs = Set(formState.queuedMessages(for: taskID).map(\.id))
                    let attempted = (chatStartAttemptedMessageIDs[taskID] ?? []).intersection(queuedIDs)
                    let allAlreadyAttempted = !queuedIDs.isEmpty && queuedIDs.isSubset(of: attempted)
                    if allAlreadyAttempted, !pendingResumeForQueueFlush.contains(taskID) {
                        formState.clearQueuedMessages(for: taskID)
                        chatStartAttemptedMessageIDs[taskID] = nil
                        store.lastInfoMessage = "\(queuedIDs.count) queued message(s) discarded — the chat couldn't be restarted."
                    } else {
                        // Only the ids NOT already carrying an attempt are being spent by this
                        // dispatch; `performStartWake` needs to know which, because its
                        // load-failure arm has to give exactly them back and nothing else.
                        let newlyStamped = queuedIDs.subtracting(attempted)
                        chatStartAttemptedMessageIDs[taskID] = attempted.union(queuedIDs)
                        wakeRunForQueuedMessages(
                            taskID: taskID, store: store, mode: .start,
                            newlyStampedIDs: newlyStamped)
                    }
                } else {
                    // A completed non-chat task is reopened via `restartRole`, not by
                    // a stray message — discard the queue and surface the count so
                    // the user isn't silently stranded.
                    failedResumeAttemptedMessageIDs[taskID] = nil
                    chatStartAttemptedMessageIDs[taskID] = nil
                    let count = formState.queuedMessages(for: taskID).count
                    formState.clearQueuedMessages(for: taskID)
                    if count > 0 {
                        store.lastInfoMessage = "\(count) queued message(s) discarded — task completed."
                    }
                }
            case .failed:
                // First send → attempt a resume: `resumeRun` revives transiently-failed
                // steps (retry, conversation intact) and the queue drains on the revived
                // step's first iteration. But if every queued message has ALREADY had an
                // attempt that completed (not in-flight) and the engine is STILL `.failed`,
                // the run had no revivable step — resuming again would wake-loop
                // (resume→re-fail→onChange→resume…) and the messages would never be
                // consumed. Discard honestly instead (restores the pre-change "task failed"
                // feedback). Keyed by message ID so a brand-new message (any enqueue path)
                // always earns its own attempt, and the transient `.running` of a doomed
                // resume can't reset the guard. Prune to the live queue so consumed IDs drop.
                let queuedIDs = Set(formState.queuedMessages(for: taskID).map(\.id))
                let attempted = (failedResumeAttemptedMessageIDs[taskID] ?? []).intersection(queuedIDs)
                let allAlreadyAttempted = !queuedIDs.isEmpty && queuedIDs.isSubset(of: attempted)
                if allAlreadyAttempted, !pendingResumeForQueueFlush.contains(taskID) {
                    formState.clearQueuedMessages(for: taskID)
                    failedResumeAttemptedMessageIDs[taskID] = nil
                    if !queuedIDs.isEmpty {
                        store.lastInfoMessage = "\(queuedIDs.count) queued message(s) discarded — task failed and couldn't be retried."
                    }
                } else {
                    failedResumeAttemptedMessageIDs[taskID] = attempted.union(queuedIDs)
                    wakeRunForQueuedMessages(taskID: taskID, store: store)
                }
            case .paused, .pending, .none:
                // Wake the run so the primary path (`injectQueuedSupervisorMessage`)
                // can drain the queue on the next tool-loop iteration. Without this,
                // the queue silently waits for an unrelated `engineState` onChange
                // (the user-reported "messages just sit there after restart" bug).
                wakeRunForQueuedMessages(taskID: taskID, store: store)
            case .running, .needsAcceptance:
                continue
            }
        }
    }

    /// How a queue-driven wake revives the task.
    /// `.resume` — `resumeRun`: paused/pending/failed runs with a revivable step.
    /// `.start` — `startRun`: chat-mode tasks whose run ended `.done`. `resumeRun`
    /// is useless there — it re-enters the same all-terminal run, never executes a
    /// step, and flips straight back to `.done` (the engine's chat auto-complete
    /// arm), wake-looping via the onChange it triggers. A FRESH run's step has
    /// `session == nil`, so the iteration-1 injection gate passes and the queue
    /// drains — the proven `sendMessageToAutovisor` pattern.
    enum QueueWakeMode { case resume, start }

    /// Dispatches a wake (`resumeRun` or `startRun`, per `mode`) for an engine
    /// whose task has queued messages. Three guards — in priority order:
    ///
    /// 1. **Closed-task discard** — `closedAt != nil` means the task is finalized
    ///    (active-task close is normally caught by `handleActiveTaskClosedAtChanged`,
    ///    but: (a) there's a race when `stopEngine` removes the engine state before
    ///    the `closedAt` onChange fires, and (b) background-task close has no
    ///    closedAt onChange wired). Drop the queue and surface the discard message
    ///    so we don't resurrect a closed task by creating a fresh engine. The
    ///    `.start` path re-checks AFTER loading the task: `startRun` has NO closed
    ///    guard and `createNewRun` CLEARS `closedAt`, so waking an unloaded closed
    ///    background task (sync check nil-soft) would silently REOPEN it.
    /// 2. **In-flight dedupe** — a single wake per (taskID, in-flight cycle).
    ///    Multiple `tryFlush` ticks can fire before the first wake changes
    ///    engineState (see `pendingResumeForQueueFlush` doc).
    /// 3. **Test seam** — `resumeRunForTesting`/`startRunForTesting` short-circuit
    ///    the `Task` dispatch so unit tests can assert call sequencing synchronously.
    private func wakeRunForQueuedMessages(
        taskID: Int, store: NTMSOrchestrator, mode: QueueWakeMode = .resume,
        newlyStampedIDs: Set<UUID> = []
    ) {
        if store.loadedTask(taskID)?.closedAt != nil {
            discardQueueForClosedTask(taskID: taskID, store: store)
            return
        }
        guard !pendingResumeForQueueFlush.contains(taskID) else { return }
        pendingResumeForQueueFlush.insert(taskID)
        switch mode {
        case .resume:
            if let resume = resumeRunForTesting {
                // Test path: the in-flight flag is intentionally NOT cleared after
                // the closure — that mirrors production semantics where the flag
                // stays set while the dispatched `Task` is in flight. Tests that
                // need to simulate "Task finished, ready for next resume" call
                // `clearPendingResumeForQueueFlushForTesting(taskID:)` explicitly.
                resume(taskID)
                return
            }
            Task { @MainActor [weak self] in
                defer { self?.pendingResumeForQueueFlush.remove(taskID) }
                await self?.store?.resumeRun(taskID: taskID)
            }
        case .start:
            if let start = startRunForTesting {
                start(taskID)
                return
            }
            Task { @MainActor [weak self] in
                defer { self?.pendingResumeForQueueFlush.remove(taskID) }
                await self?.performStartWake(taskID: taskID, newlyStampedIDs: newlyStampedIDs)
            }
        }
    }

    /// Body of the `.start` wake's dispatched Task — extracted (mirrors
    /// `flushQueuedChatMessage`) so the async path is directly testable; the
    /// `startRunForTesting` seam bypasses it. Re-checks the task AFTER loading:
    /// `startRun` has NO closed guard and `createNewRun` CLEARS `closedAt`, so
    /// waking an unloaded closed background task (the sync pre-check is nil-soft)
    /// would silently REOPEN it. The load itself must be bound explicitly — a
    /// failed load (task deleted concurrently, unreadable task.json) would make
    /// `loadedTask(taskID)?.closedAt == nil` vacuously true and start a run
    /// against a phantom task; instead surface the error and keep the queue for
    /// a later tick.
    ///
    /// `newlyStampedIDs` is what the dispatching arm spent on THIS attempt. The load-failure arm
    /// gives back exactly those and nothing else: the stamp map is cumulative
    /// (`attempted.union(queuedIDs)`), so clearing the whole entry also refunded attempts that
    /// really did reach `startRun` on an earlier tick — and those attempts are the only thing
    /// stopping an unconsumable queue from waking a fresh LLM pass on every tick.
    ///
    /// No default: a caller that omitted it would silently pick one of the two wrong answers —
    /// refund everything (the bug) or refund nothing (a message that never got its one attempt
    /// is discarded as if it had). The set is cheap to state at every site.
    func performStartWake(taskID: Int, newlyStampedIDs: Set<UUID>) async {
        guard let store else { return }
        await store.ensureTaskLoaded(taskID)
        guard let task = store.loadedTask(taskID) else {
            // No startRun ran — this was NOT a real attempt, but the `.done`-chat
            // arm stamped `chatStartAttemptedMessageIDs` BEFORE dispatching us.
            // Un-stamp so the next tick genuinely retries; leaving the stamp
            // would discard the queue with a misattributed "chat couldn't be
            // restarted" banner right after promising "kept in queue".
            if let stamped = chatStartAttemptedMessageIDs[taskID] {
                let kept = stamped.subtracting(newlyStampedIDs)
                chatStartAttemptedMessageIDs[taskID] = kept.isEmpty ? nil : kept
            }
            store.lastErrorMessage =
                "Couldn't load task #\(taskID) to deliver queued message(s) — kept in queue."
            return
        }
        guard task.closedAt == nil else {
            discardQueueForClosedTask(taskID: taskID, store: store)
            return
        }
        await store.startRun(taskID: taskID)
    }

    /// Shared closed-task discard for the wake paths: drop the queue and surface
    /// the count so the user isn't silently stranded (and a closed task is never
    /// resurrected by a stray message).
    private func discardQueueForClosedTask(taskID: Int, store: NTMSOrchestrator) {
        let count = formState.queuedMessages(for: taskID).count
        formState.clearQueuedMessages(for: taskID)
        if count > 0 {
            store.lastInfoMessage = "\(count) queued message(s) discarded — task closed."
        }
    }

    /// Chat-mode lookup that works for unloaded background tasks: prefers the
    /// loaded task (authoritative — `generatedTeam.isChatMode` dominates), falls
    /// back to the tasks-index summary (`TaskSummary.isChatMode`). Defaults to
    /// `false` when neither source knows the task, preserving the non-chat
    /// discard behavior.
    static func isChatModeTask(_ taskID: Int, store: NTMSOrchestrator) -> Bool {
        if let task = store.loadedTask(taskID) { return task.isChatMode }
        return store.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode ?? false
    }

    #if DEBUG
    /// Test-only: clears the in-flight resume guard for a given task, simulating
    /// completion of the production `Task { resumeRun }`. Lets tests verify that
    /// a subsequent `tryFlush` after the prior resume "finishes" can dispatch
    /// another resume.
    func clearPendingResumeForQueueFlushForTesting(taskID: Int) {
        pendingResumeForQueueFlush.remove(taskID)
    }

    /// Test-only: whether the `.failed`-resume give-up map still holds an entry for
    /// `taskID`. Lets tests assert the map is pruned for tasks with no queued messages.
    func _testHasFailedResumeAttempted(taskID: Int) -> Bool {
        failedResumeAttemptedMessageIDs[taskID] != nil
    }

    /// Test-only sibling for the `.done`-chat give-up map.
    func _testHasChatStartAttempted(taskID: Int) -> Bool {
        chatStartAttemptedMessageIDs[taskID] != nil
    }
    #endif

    /// Discards all queued chat messages for the given task. Use on task delete/close
    /// to prevent a stale queue from re-applying to a reincarnated task ID.
    func discardQueuedChatMessage(taskID: Int) {
        formState.clearQueuedMessages(for: taskID)
        failedResumeAttemptedMessageIDs[taskID] = nil
        chatStartAttemptedMessageIDs[taskID] = nil
    }

    // MARK: - MainLayoutView onChange Handlers
    //
    // Extracted from `MainLayoutView.onChange` blocks so the wiring is unit-testable
    // without mounting a SwiftUI view. `MainLayoutView` still owns the `.onChange`
    // declarations but delegates the body to these methods.

    /// Called when `engineState.taskEngineStates` changes. Refreshes the panel (for
    /// live mode transitions) and drives the queue flush. Two concerns, one entry
    /// point so `MainLayoutView` only has to wire one observer.
    func handleEngineStateChanged() {
        refreshPanelIfVisible()
        tryFlushQueuedMessages()
    }

    /// Called when `store.activeTask?.closedAt` changes. When the task becomes closed
    /// (`closedAt` transitions from `nil` to non-nil), discards any queued messages.
    /// Redundant with terminal-state discard in `tryFlushQueuedMessages`, but covers
    /// the edge case where `closedAt` is set before the engine state transitions to
    /// `.done` — without it a just-closed task briefly retains its queue.
    func handleActiveTaskClosedAtChanged(newValue: Date?, taskID: Int?) {
        guard newValue != nil, let taskID else { return }
        discardQueuedChatMessage(taskID: taskID)
    }

    /// Drains every eligible queued message for the chosen waiting role into
    /// ONE combined `answerSupervisorQuestion` call. Mirrors the primary path's
    /// drain-all semantics in `NTMSOrchestrator.consumeQueuedSupervisorMessage`
    /// — eliminates the previous drip-pattern where messages dribbled out one
    /// per `engineState` transition (and could stall entirely when SwiftUI's
    /// `onChange` coalesced rapid `.needsSupervisorInput` re-entries or the
    /// `TeamEngine` same-state guard suppressed `onStateChanged`).
    ///
    /// Atomicity contract (matches primary path):
    /// 1. Pop every collected message id synchronously BEFORE any `await`. A
    ///    concurrent `flushQueuedChatMessage` invocation triggered by another
    ///    rapid state flip would otherwise see the same messages and double-deliver.
    /// 2. On `answerSupervisorQuestion` failure (attachment finalize, missing step,
    ///    etc.), re-insert popped messages at the queue **head** via
    ///    `prependQueuedMessages` — preserves FIFO under concurrent additions
    ///    (a message queued during the await would otherwise push the failed
    ///    batch behind it).
    private func flushQueuedChatMessage(taskID: Int) async {
        guard let store,
              let task = store.loadedTask(taskID),
              let run = task.runs.last
        else { return }

        let waitingSteps = run.steps.filter(\.canReceiveSupervisorAnswer)
        guard !waitingSteps.isEmpty else { return }

        let queue = formState.queuedMessages(for: taskID)
        guard let picked = Self.collectQueuedMessagesForFlush(
            queue: queue,
            waitingStepRoleIDs: waitingSteps.map(\.effectiveRoleID)
        ) else { return }
        guard let step = waitingSteps.first(where: { $0.effectiveRoleID == picked.stepRoleID })
        else { return }

        // ATOMIC RESERVE — pop every collected id synchronously before any await,
        // in one pass (the per-id loop was O(batch × queue)).
        let popped = formState.popQueuedMessages(withIDs: picked.messageIDs, for: taskID)
        guard !popped.isEmpty else { return }

        // Build each message's body and join with a single newline (matching the
        // primary path). No `Supervisor:` prefix here — the backstop delivers
        // through `answerSupervisorQuestion`, which routes via the `ask_supervisor`
        // tool-result path; LLM attribution is intrinsic.
        var bodies: [String] = []
        var combinedAttachments: [StagedAttachment] = []
        var failedFiles: [String] = []
        for msg in popped {
            let built = AnswerTextBuilder.build(
                text: msg.text,
                clips: msg.clippedTexts,
                attachments: msg.attachments,
                embedFiles: embedFilesInPrompt
            )
            bodies.append(built.answer)
            combinedAttachments.append(contentsOf: msg.attachments)
            failedFiles.append(contentsOf: built.failedFiles)
        }
        let combinedAnswer = bodies.joined(separator: "\n")

        // Attribution for the resolved-answer badge: auto only when EVERY drained
        // message was authored by an automated supervisor (the Autovisor's
        // `message_task`) — any human content in the batch makes it a human answer.
        let allAutomated = popped.allSatisfy(\.isFromAutomatedSupervisor)

        // answerSupervisorQuestion auto-resumes the run — do NOT call resumeRun separately.
        let errorsBefore = store.errorSurfaceCount
        let delivered = await store.answerSupervisorQuestion(
            stepID: step.id,
            taskID: taskID,
            answer: combinedAnswer,
            attachments: combinedAttachments,
            isAutoAnswer: allAutomated
        )
        if delivered, !failedFiles.isEmpty {
            // Same report the two sibling submit paths (`createTask`, `submitAnswer`) make from
            // the same builder result. Dropping it meant a file that could not be read as text
            // was simply absent from the delivered message: the role answers without it, and
            // nothing on screen says which file went missing — or that one did.
            //
            // Only on a delivered batch: a failed delivery re-queues the messages and owns the
            // single `lastErrorMessage` slot with the more actionable reason, and the embed
            // failure recurs on the retry anyway.
            store.lastErrorMessage = "Could not embed \(failedFiles.count) file(s) as text: "
                + "\(failedFiles.joined(separator: ", ")). They may be binary files."
        }
        if !delivered {
            // Re-insert at HEAD (not append) so FIFO holds even if new messages
            // were queued during the await.
            formState.prependQueuedMessages(popped, for: taskID)
            // The specific reason comes from THIS call or not at all. Reading the
            // `lastErrorMessage` slot took whatever an unrelated operation had parked
            // there and presented it — suffixed with our own "queued message(s) kept"
            // — as the reason delivery failed; and once a render had consumed the slot,
            // a real, specific failure degraded to the generic string.
            let reason = store.errorSurfaced(since: errorsBefore) ?? "Message delivery failed."
            store.lastErrorMessage = reason
                + " — \(popped.count) queued message(s) kept; retry after resolving the issue."
        }
    }

    // MARK: - Backstop Priority (pure, unit-testable)

    /// Collects every deliverable queued message for the `.needsSupervisorInput`
    /// backstop path in priority order. Mirrors the primary path's drain-all
    /// semantics in `NTMSOrchestrator.consumeQueuedSupervisorMessage` — one
    /// combined Supervisor turn per backstop fire instead of dripping one
    /// message per `engineState` transition.
    ///
    /// Tier priority (matches the primary path):
    /// - **Tier 1** — role-targeted messages whose target role is currently
    ///   waiting, FIFO within the tier. The first such message determines the
    ///   recipient role; subsequent tier-1 messages targeted at the *same* role
    ///   join the batch, while messages targeted at other waiting roles stay
    ///   queued for their own backstop fire.
    /// - **Tier 2** — untargeted (Team) messages join the same batch as the
    ///   tier-1 winner's role (FIFO). If no tier-1 messages match, the oldest
    ///   untargeted message picks the first waiting role and drains all
    ///   untargeted messages into that batch.
    ///
    /// Returns the chosen recipient `stepRoleID` and an ordered `[UUID]` to pop
    /// in sequence. Returns `nil` when nothing is deliverable to the current
    /// waiting set. Pure — no I/O, no main-actor dependency — so backstop
    /// priority is trivially unit-testable without an engine.
    static func collectQueuedMessagesForFlush(
        queue: [QuickCaptureFormState.QueuedChatMessage],
        waitingStepRoleIDs: [String]
    ) -> (stepRoleID: String, messageIDs: [UUID])? {
        guard !waitingStepRoleIDs.isEmpty else { return nil }
        let waiting = Set(waitingStepRoleIDs)

        // ONE pass. The first role-targeted message whose target is waiting picks
        // the recipient (targeted messages whose target is NOT waiting stay queued
        // for their own backstop fire); untargeted ids are buffered from the START
        // of the scan — a leading untargeted message must not be lost to a later
        // tier-1 winner — and targeted ids are bucketed per role so the winner's
        // batch is ready without a second scan.
        var pickedRoleID: String?
        var targetedByRole: [String: [UUID]] = [:]
        var untargeted: [UUID] = []
        for msg in queue {
            if let target = msg.targetRoleID {
                targetedByRole[target, default: []].append(msg.id)
                if pickedRoleID == nil, waiting.contains(target) { pickedRoleID = target }
            } else {
                untargeted.append(msg.id)
            }
        }
        // The fallback recipient comes from the ARRAY — "first waiting step" is
        // order-significant, and a Set would randomize it per process.
        let roleID = pickedRoleID ?? (untargeted.isEmpty ? nil : waitingStepRoleIDs.first)
        guard let roleID else { return nil }

        // Tier 1 first (role-targeted to roleID, FIFO), then tier 2 (untargeted, FIFO).
        let ids = targetedByRole[roleID, default: []] + untargeted
        guard !ids.isEmpty else { return nil }
        return (roleID, ids)
    }
}
