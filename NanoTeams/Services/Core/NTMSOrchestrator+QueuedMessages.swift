import Foundation

/// `LLMStateDelegate.consumeQueuedSupervisorMessage` implementation.
///
/// Bridges the `QuickCaptureFormState` queue (owned by `QuickCaptureController`
/// in the UI layer) into the LLM execution pipeline. When a role's
/// `runOneLLMToolIteration` asks for queued input, this method **drains** every
/// eligible entry for that role (role-targeted FIFO, then untargeted FIFO),
/// finalizes attachments, and persists a single combined user turn into
/// `step.llmConversation` so the activity feed renders one Supervisor bubble.
///
/// Batching shape (what the LLM sees in the request input):
/// ```
/// Supervisor:
/// <message 1 body>
/// <message 2 body>
/// <message 3 body>
/// ```
/// The `Supervisor:` header line is the attribution marker for the LLM — a
/// `role: .user` turn is otherwise indistinguishable from tool results and
/// memory blocks mixed into the same `input` string. The activity feed strips
/// the header at render time via `LLMMessage.displayContent`.
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
        // `await`. Preserves tier order by popping in the collected id sequence.
        var popped: [QuickCaptureFormState.QueuedChatMessage] = []
        for id in ids {
            if let msg = formState.popFirstQueuedMessage(for: taskID, matching: { $0.id == id }) {
                popped.append(msg)
            }
        }
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
                let section = "--- Attached Files ---\n\(pathList)"
                body = body.isEmpty ? section : body + "\n\n" + section
            }
            bodies.append(body)
        }

        let prompt = MessageSourceContext.supervisorMessagePrefix + bodies.joined(separator: "\n")

        // Persist one LLMMessage carrying the combined batch. Use a captured
        // flag (not `mutateTask`'s return value) — the closure may short-circuit
        // via its own `locateStepInLatestRun` guard while `mutateTask` still
        // returns `true` for a no-op (CLAUDE.md §7). On closure-guard failure,
        // re-queue the whole batch so no data is silently lost.
        //
        // `step.messages` is intentionally left alone — it has no UI consumer
        // and mid-iteration writes don't affect this run's `fullConversation`.
        let message = LLMMessage(
            role: .user,
            content: prompt,
            sourceRole: .supervisor,
            sourceContext: .supervisorMessage
        )
        var didPersist = false
        await mutateTask(taskID: taskID) { task in
            guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
            task.runs[location.runIndex].steps[location.stepIndex].llmConversation.append(message)
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

        return prompt
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
}
