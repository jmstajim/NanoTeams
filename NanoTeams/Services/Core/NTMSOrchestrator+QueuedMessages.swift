import Foundation

/// `LLMStateDelegate.consumeQueuedSupervisorMessage` implementation.
///
/// Bridges the `QuickCaptureFormState` queue (owned by `QuickCaptureController`
/// in the UI layer) into the LLM execution pipeline. When a role's
/// `runOneLLMToolIteration` asks for queued input, this method **drains** every
/// eligible entry for that role (role-targeted FIFO, then untargeted FIFO),
/// finalizes attachments, and persists the batch into `step.llmConversation`.
///
/// The batch is grouped into runs of CONSECUTIVE same-`kind` entries, in queue order, and
/// each run is composed by its own rules — because the queue carries two different things
/// (`QueuedChatMessage.Kind`): a Supervisor speaking, and the app reporting that folder
/// state moved. A batch of one kind, which is every human path, produces exactly what it
/// always did.
///
/// Batching shape (what the LLM sees in the request input — ONE `.user` turn, since
/// `injectQueuedSupervisorMessage` appends the returned string as a single `ChatMessage`):
/// ```
/// Supervisor:
/// <speech 1 body>
/// <speech 2 body>
///
/// Event update while you are reviewing — new since this pass started:
/// - Task #35 "…" is waiting for a supervisor answer (answer_task_question).
/// ```
/// The `Supervisor:` line is the attribution marker for the LLM — a `role: .user` turn is
/// otherwise indistinguishable from tool results and memory blocks mixed into the same
/// `input` string. The activity feed strips it at render time via `LLMMessage.displayContent`.
///
/// The event run carries NO such marker, matching every other system notice (`retryNudge`,
/// `toolAcknowledgement`, `runtimeWarning` all ship as bare `.user` turns): the app is not
/// the Supervisor, and wearing that badge is what made the feed draw a crowned bubble the
/// human never typed. What separates it on a wire both providers flatten is the blank line
/// between runs plus its own opening header
/// (`MessageSourceContext.autovisorEventNoticeHeader`).
///
/// Feed side, one `LLMMessage` per run: `.supervisorMessage`/`sourceRole: .supervisor` for
/// speech, `.autovisorEvent`/`sourceRole: nil` for the notice — nil because every other
/// system notice is written unattributed, which is what makes the feed file the collapsed
/// row under the WORKING role instead of under a Supervisor who did not speak.
///
/// Separation-of-concerns: finalization + persistence belong here (not inline
/// in `LLMExecutionService`) so the service stays free of repository and
/// UI-singleton references and goes through the delegate only.
///
/// Atomicity contract — **read this before editing**:
/// 1. Peek + pop is synchronous and completes BEFORE any `await`. Main-actor
///    reentrancy means a concurrent parallel-role call could otherwise peek
///    the queue during our awaits and double-deliver the same entry.
/// 2. On attachment-finalize failure OR persistence failure, every popped
///    message is re-appended so the user's input is never silently lost.
///    `lastErrorMessage` surfaces the condition.
extension NTMSOrchestrator {

    func consumeQueuedSupervisorMessage(
        taskID: Int,
        roleID: String,
        stepID: String
    ) async -> String? {
        guard let formState = quickCaptureFormState else { return nil }

        // Collect ids in priority order. Tier 1: role-targeted (FIFO within tier).
        // Tier 2: untargeted (Team) — FIFO within tier. Both tiers drain into a
        // single combined LLM turn.
        let queue = formState.queuedMessages(for: taskID)
        let ids = queue.compactMap { msg -> UUID? in
            msg.targetRoleID == roleID ? msg.id : nil
        } + queue.compactMap { msg -> UUID? in
            msg.targetRoleID == nil ? msg.id : nil
        }
        guard !ids.isEmpty else { return nil }

        // ATOMIC RESERVE — pop every eligible entry synchronously before any
        // `await`, in one pass; the returned batch carries the collected id
        // sequence's tier order. (The per-id loop this replaces was
        // O(batch × queue) — and this path runs on every tool-loop iteration.)
        let popped = formState.popQueuedMessages(withIDs: ids, for: taskID)
        guard !popped.isEmpty else { return nil }

        // Finalize attachments for every popped message. On ANY failure: re-queue
        // ALL messages (preserving order) and surface the error so the user can
        // retry. A partial success would leak files / split the batch.
        var finalPathsByMessage: [[String]] = Array(repeating: [], count: popped.count)
        if let workFolderRoot = workFolderURL {
            for (i, msg) in popped.enumerated() where !msg.attachments.isEmpty {
                do {
                    finalPathsByMessage[i] = try repository.finalizeAttachments(
                        at: workFolderRoot,
                        taskID: taskID,
                        stagedEntries: msg.attachments.map {
                            (path: $0.stagedRelativePath, isProjectReference: $0.isProjectReference)
                        }
                    )
                } catch {
                    requeueAll(popped, formState: formState, taskID: taskID)
                    lastErrorMessage = "Failed to finalize queued attachments: \(error.localizedDescription). \(popped.count) message(s) kept in queue — retry after resolving."
                    return nil
                }
            }
        }

        // Build each message's body (text + clips + optional inline embed +
        // finalized attachment paths), then join with a blank line between.
        var bodies: [String] = []
        var allFailedFiles: [String] = []
        for (i, msg) in popped.enumerated() {
            // Trim ONLY trailing whitespace from the raw user text. Leading
            // whitespace may be intentional (e.g. indented code paste).
            var trimmedText = msg.text
            while let last = trimmedText.last, last.isWhitespace {
                trimmedText.removeLast()
            }
            let built = AnswerTextBuilder.build(
                text: trimmedText,
                clips: msg.clippedTexts,
                attachments: msg.attachments,
                embedFiles: configuration.embedFilesInPrompt
            )
            allFailedFiles.append(contentsOf: built.failedFiles)

            var body = built.answer
            let nonEmbeddedPaths = zip(msg.attachments, finalPathsByMessage[i]).compactMap {
                (staged, finalPath) -> String? in
                built.embeddedAttachmentIDs.contains(staged.id) ? nil : finalPath
            }
            if !nonEmbeddedPaths.isEmpty {
                let pathList = nonEmbeddedPaths.map { "- \($0)" }.joined(separator: "\n")
                let section = "## Attached Files\n\(pathList)"
                body = body.isEmpty ? section : body + "\n\n" + section
            }
            bodies.append(body)
        }

        // Group into consecutive same-kind runs and compose each by its own rules. The
        // redelivery split lives inside: the FEED shows only what the user has not already
        // seen. A redelivery is a message that was delivered once, rendered once, and came
        // back only because the wire it rode was discarded (the planning-phase boundary keeps
        // just the task statement and the scratchpad). It still has to reach the model — the
        // implementation phase never saw it — but persisting a second bubble would show the
        // user their own message twice for something they typed once.
        //
        // Resolved per message rather than per batch: a redelivery can be drained together
        // with a genuinely new message, and the new one must still appear.
        let delivery = Self.composeQueuedDelivery(
            zip(popped, bodies).map { message, body in
                QueuedDeliveryEntry(
                    kind: message.kind, body: body, isRedelivery: message.isRedelivery
                )
            }
        )

        guard !delivery.displayTurns.isEmpty else {
            // Nothing new to show. Delivery is the return value below; there is no persistence to
            // guard, and no data to lose — the user has seen this text and the model already acted
            // on it once.
            return delivery.wirePrompt
        }

        // Persist one LLMMessage per run, in queue order, inside ONE mutation — the batch is
        // a single arrival and a partially-applied one would leave the feed inconsistent with
        // the turn the model just got. `LLMMessage.createdAt` defaults to
        // `MonotonicClock.shared.now()`, evaluated per construction, so the array is already
        // strictly increasing and the feed's sort keeps queue order.
        //
        // Use a captured flag (not `mutateTask`'s return value) — the closure may
        // short-circuit via its own `locateStepInLatestRun` guard while `mutateTask` still
        // returns `true` for a no-op (CLAUDE.md §7). On closure-guard failure, re-queue the
        // whole batch so no data is silently lost.
        //
        // `step.messages` is intentionally left alone — it has no UI consumer
        // and mid-iteration writes don't affect this run's `fullConversation`.
        let messages = delivery.displayTurns.map { turn in
            LLMMessage(
                role: .user,
                content: turn.content,
                sourceRole: turn.sourceRole,
                sourceContext: turn.sourceContext
            )
        }
        var didPersist = false
        await mutateTask(taskID: taskID) { task in
            guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
            task.runs[location.runIndex].steps[location.stepIndex].llmConversation
                .append(contentsOf: messages)
            task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
            didPersist = true
        }
        guard didPersist else {
            // Persist failure: the partial-embed degradation (if any) is moot
            // because nothing was actually delivered. Report ONLY the persistence
            // error — surfacing the info message first would get immediately
            // overwritten by the error banner anyway, and combining them would
            // confuse the user about what went wrong.
            requeueAll(popped, formState: formState, taskID: taskID)
            lastErrorMessage = "Queued message(s) could not be persisted — step \(stepID) is no longer in the latest run. \(popped.count) message(s) kept in queue."
            return nil
        }

        // Success path: surface partial-embed degradation (if any) as info. This
        // runs AFTER persistence so a subsequent error can't race and overwrite
        // it — the info is only accurate when the delivery actually happened.
        if !allFailedFiles.isEmpty {
            lastInfoMessage = "\(allFailedFiles.count) file(s) couldn't be embedded inline — attached as paths: \(allFailedFiles.joined(separator: ", "))."
        }

        return delivery.wirePrompt
    }

    // MARK: - Composition

    /// One popped entry reduced to what composition needs.
    nonisolated struct QueuedDeliveryEntry: Equatable {
        let kind: QuickCaptureFormState.QueuedChatMessage.Kind
        /// The body AFTER attachment finalization, clip inlining and embedding.
        let body: String
        let isRedelivery: Bool
    }

    /// One turn to persist: a run of consecutive same-kind entries that has something the
    /// user has not already seen.
    nonisolated struct QueuedDeliveryTurn: Equatable {
        let content: String
        let sourceContext: MessageSourceContext
        let sourceRole: Role?
    }

    nonisolated struct QueuedDelivery: Equatable {
        /// What the model gets — one string, because `injectQueuedSupervisorMessage` appends
        /// it as a single `ChatMessage`. Carries redeliveries too: the model may never have
        /// seen them.
        let wirePrompt: String
        /// What the feed gets — one per run with fresh content, in queue order. Empty when
        /// the whole batch is redelivery, which is the caller's signal to skip persistence.
        let displayTurns: [QueuedDeliveryTurn]
    }

    /// Splits a drained batch into consecutive same-kind runs and composes each.
    ///
    /// Consecutive rather than partitioned-by-kind on purpose: FIFO is the contract the
    /// whole queue is built on, and reordering a Supervisor's two sentences around an event
    /// notice that arrived between them would rewrite what the human said. A single-kind
    /// batch — every human path, and the Autovisor notice on its own — collapses to exactly
    /// one run, which is why the existing drain tests are the regression pin for this.
    ///
    /// Pure and `nonisolated`, same shape as `composeAutovisorEventNotice`: the interesting
    /// part is string composition, and it should be testable without standing up an
    /// orchestrator.
    nonisolated static func composeQueuedDelivery(
        _ entries: [QueuedDeliveryEntry]
    ) -> QueuedDelivery {
        var wireSections: [String] = []
        var displayTurns: [QueuedDeliveryTurn] = []

        var runStart = entries.startIndex
        while runStart < entries.endIndex {
            let kind = entries[runStart].kind
            var runEnd = runStart
            while runEnd < entries.endIndex, entries[runEnd].kind == kind { runEnd += 1 }
            let run = entries[runStart..<runEnd]
            runStart = runEnd

            // ONE pass over the run rather than map + filter + contains. The three-pass
            // form was linear overall too (the slices partition `entries`), but it reads as
            // a scan inside a loop — which is the shape the complexity gate ranks and the
            // shape a later edit turns quadratic by accident.
            var allParts: [String] = []
            var freshParts: [String] = []
            var hasFresh = false
            for entry in run {
                allParts.append(entry.body)
                guard !entry.isRedelivery else { continue }
                freshParts.append(entry.body)
                // Tracked separately from `freshParts.isEmpty`: an entry carrying only an
                // attachment can compose an empty body, and it is still something the user
                // has not seen.
                hasFresh = true
            }
            let allBodies = allParts.joined(separator: "\n")
            let freshBodies = freshParts.joined(separator: "\n")

            switch kind {
            case .supervisorSpeech:
                let prefix = MessageSourceContext.supervisorMessagePrefix
                wireSections.append(prefix + allBodies)
                if hasFresh {
                    displayTurns.append(QueuedDeliveryTurn(
                        content: prefix + freshBodies,
                        sourceContext: .supervisorMessage,
                        sourceRole: .supervisor
                    ))
                }
            case .autovisorEventNotice:
                // No attribution marker: the app is not the Supervisor, and every other
                // system notice ships bare. `sourceRole: nil` for the same reason — the feed
                // then files the collapsed row under the working role.
                wireSections.append(allBodies)
                if hasFresh {
                    displayTurns.append(QueuedDeliveryTurn(
                        content: freshBodies,
                        sourceContext: .autovisorEvent,
                        sourceRole: nil
                    ))
                }
            }
        }

        // A blank line between runs — the only separation a mixed batch gets, since the
        // notice carries no delimiters. Within a run the join stays "\n", byte-identical to
        // what a single-kind batch has always produced.
        return QueuedDelivery(
            wirePrompt: wireSections.joined(separator: "\n\n"),
            displayTurns: displayTurns
        )
    }

    /// Re-inserts a batch of popped messages at the **head** of the queue,
    /// preserving their internal FIFO order. Using insert-at-head (not append)
    /// matters under concurrent arrivals: if the user queues another message
    /// while this consumption is `await`-ing finalization or persistence, and
    /// the operation then fails, appending would push the original messages
    /// BEHIND the newcomer — inverting FIFO. Prepending restores the exact
    /// head-of-queue position the batch held before the pop.
    private func requeueAll(
        _ messages: [QuickCaptureFormState.QueuedChatMessage],
        formState: QuickCaptureFormState,
        taskID: Int
    ) {
        formState.prependQueuedMessages(messages, for: taskID)
    }

    /// `LLMStateDelegate.notifyQueuedMessageBackstop` witness — bridges the
    /// step-mutation side of the LLM pipeline to the queued-message backstop
    /// owned by `QuickCaptureController`. The orchestrator has no DI handle for
    /// the controller (the controller holds a weak `store` reference back; the
    /// reverse direction would create the cycle), so the witness reaches the
    /// process-wide singleton directly.
    ///
    /// `taskID` is unused for now — `tryFlushQueuedMessages` iterates every
    /// task with a non-empty queue regardless of the trigger source. The
    /// parameter is kept on the protocol for symmetry with other taskID-keyed
    /// hooks and to keep future per-task scoping low-friction. If
    /// `tryFlushQueuedMessages` ever gains a scoped overload, this witness must
    /// be updated to forward the taskID, or the parameter dropped from the
    /// protocol — leaving it silently unused at the bridge point would mask the
    /// intended scope.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func notifyQueuedMessageBackstop(taskID _: Int) {
        QuickCaptureController.shared.tryFlushQueuedMessages()
    }

    /// `LLMStateDelegate.requeueSupervisorMessageAtHead` witness — the planning-phase boundary's
    /// undo for a message it is about to discard.
    ///
    /// Rebuilt rather than restored: the pipeline hands the LLM a composed prompt (attachments
    /// finalized, clips inlined) and does not keep the original `QueuedChatMessage`, so what comes
    /// back is the text. Attachments were finalized on first delivery and their paths are already
    /// inside that text, so nothing is lost by re-queueing without them — and re-staging them
    /// would duplicate files on disk.
    ///
    /// `targetRoleID` is set so the redelivery goes to the same role rather than to whichever role
    /// asks first: this message was already routed once, and re-routing it on the way back would
    /// silently change who the human was talking to.
    ///
    /// `kind` takes its `.supervisorSpeech` default, and cannot be anything else: the caller
    /// finds re-queueable turns with `PlanningPhasePolicy.discardedSupervisorMessages`, which
    /// matches on the `Supervisor:` prefix — so an `.autovisorEvent` run, which ships unmarked,
    /// is never handed back here. That is a boundary the Autovisor structurally cannot reach
    /// anyway (`PlanningPhasePolicy.isEligible` carries `!isAutovisor`), and a still-standing
    /// condition re-notifies on the next fresh-pass wake regardless.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func requeueSupervisorMessageAtHead(taskID: Int, roleID: String, text: String) {
        guard let formState = quickCaptureFormState,
              let message = QuickCaptureFormState.QueuedChatMessage(
                  text: text, attachments: [], clippedTexts: [], targetRoleID: roleID,
                  isRedelivery: true)
        else { return }
        formState.prependQueuedMessages([message], for: taskID)
    }
}
