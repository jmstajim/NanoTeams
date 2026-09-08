import Foundation

/// Box for the result of an out-of-loop compaction, which has to run inside a
/// `Task<Void, Never>` (the type `StepExecutionState.runningTask` holds, and holding it there
/// is what makes every existing re-entry door cancel the epoch for free).
@MainActor
private final class CompactionResultBox {
    var succeeded = false
}

/// Context compaction: the triggers, the epoch, and the two places an epoch can run.
///
/// An epoch replaces the step's wire with `CompactionPolicy.compactedWire` — pinned head,
/// one seed turn, optionally a retained park. It runs in two shapes:
///
/// - **In the tool loop**, consumed at the top of an iteration right after the planning
///   phase has had its say. Never mid-batch: a compaction between a tool call and its
///   results would leave the model an answer to a question it can no longer see.
/// - **Out of the loop**, on a step that is parked, paused or failed. There is no iteration
///   to hang it off, so it borrows the step's own `runningTask` slot and writes through a
///   compare-and-swap (`persistCompactedWire`) — the summary takes seconds, and the
///   Supervisor may answer during them.
///
/// What never happens here is a fixed schedule. Every entry point is a MEASUREMENT (the
/// server's own prompt count, its truncation signal, its refusal) or a human's click
/// (playbook R3.9.6).
extension LLMExecutionService {

    // MARK: - Public entry points

    /// Marks a RUNNING step to compact at the top of its next tool iteration.
    ///
    /// Returns `false` when the step is not running — the caller then routes to
    /// `compactSuspendedStep`, which is a different mechanism, not a retry of this one.
    @discardableResult
    func requestCompaction(stepID: String, taskID: Int) -> Bool {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard executionStates[key]?.runningTask != nil else { return false }
        executionStates[key]?.compactRequested = .manual
        return true
    }

    /// Whether an epoch is in flight for this step. Drives the indicator's disabled state,
    /// so a second click cannot start a second summary against the same wire.
    func isCompacting(stepID: String, taskID: Int) -> Bool {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.compactionEpochToken != nil
    }

    /// What the runtime already tried, for the overflow failure text.
    func compactionOutcomeForFailure(
        stepID: String, taskID: Int
    ) -> ContextBudgetPolicy.CompactionOutcome {
        guard delegate?.autoCompactEnabled ?? false else { return .disabled }
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        return (executionStates[key]?.compactionsThisEntry ?? 0) > 0 ? .attempted : .nothingToSeed
    }

    /// Re-derives compaction state when a step (re-)enters its loop.
    ///
    /// The fill is DERIVED from what was persisted rather than carried in memory, on the same
    /// principle as the planning phase's wire-derived state: `StepExecutionState` is rebuilt
    /// on every entry, so anything stored there would disagree with the transcript after a
    /// pause or a Supervisor round-trip.
    ///
    /// An ESTIMATE never arms the trigger, only seeds the indicator — the estimator's spread
    /// across languages makes it unusable as a threshold, and re-entry is exactly where a
    /// wrong "compact now" costs a whole conversation.
    func seedCompactionStateOnEntry(stepID: String, taskID: Int, step: StepExecution) {
        guard let fill = step.contextFill else { return }
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[key]?.lastContextFill = fill
        guard delegate?.autoCompactEnabled ?? false, !fill.isEstimate,
              let budget = fill.budget, fill.promptTokens >= budget
        else { return }
        executionStates[key]?.compactRequested = .budgetExceeded
    }

    // MARK: - Triggers

    /// Reads the response's server-side prompt count, publishes the step's fill, and arms an
    /// automatic epoch when the count has crossed the budget.
    ///
    /// The window is re-probed at most ONCE per epoch, and only here — after a response.
    /// Before the first request Ollama's `/api/ps` is silent about a model it has not loaded
    /// and LM Studio answers with the model's nominal `max_context_length` rather than the
    /// `loaded_context_length` that actually bounds the request, so a pre-send probe often
    /// leaves the budget unknowable. After a response both servers answer.
    func evaluateCompactionTrigger(
        stepID: String,
        taskID: Int,
        client: any LLMClient,
        config: LLMConfig,
        serverPromptTokens: Int?
    ) async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard executionStates[key] != nil else { return }

        let window = await resolveWindowForFill(
            stepKey: key, client: client, config: config)
        let percent = delegate?.autoCompactBudgetPercent ?? AppDefaults.autoCompactBudgetPercent
        let budget = ContextBudgetPolicy.stepBudget(window: window, percent: percent)

        // The fill is published for ANY count we have — including an estimate — because the
        // indicator's job is to show the slope. The TRIGGER below reads the server count
        // alone: the estimator spans 0.45×–2.58× against real tokenizers, so compacting on
        // one would discard a Cyrillic conversation at 45% of its true occupancy.
        if let serverPromptTokens, serverPromptTokens > 0 {
            publishContextFill(
                stepID: stepID, taskID: taskID,
                fill: ContextFill(
                    promptTokens: serverPromptTokens,
                    window: window,
                    budget: budget,
                    isEstimate: false,
                    compactions: executionStates[key]?.compactionsThisEntry ?? 0))
        }

        guard delegate?.autoCompactEnabled ?? false,
              executionStates[key]?.autoCompactExhausted == false,
              executionStates[key]?.compactRequested == nil
        else { return }

        guard case .budgetExceeded(let count, _) = ContextBudgetPolicy.compactionVerdict(
            serverPromptTokens: serverPromptTokens, window: window, percent: percent)
        else { return }

        // Did the previous epoch buy anything? Two ways to answer no, and both latch:
        // the count is still past the budget having just been compacted, or it moved by
        // less than the smallest difference the prefix detector calls material. Either
        // means the head alone is the problem, and no further epoch can fix it.
        if let previous = executionStates[key]?.lastCompactionServerPromptTokens {
            let saved = previous - count
            guard saved >= PrefixCachePolicy.materialTokenThreshold else {
                executionStates[key]?.autoCompactExhausted = true
                delegate?.setLastErrorMessageForUI(
                    "\(config.modelName): compacting the conversation did not free enough room "
                        + "— the pinned system prompt and task brief are already near the "
                        + "budget. Raise the compaction budget in Settings → LLM, or load the "
                        + "model with a larger context window.")
                return
            }
        }
        executionStates[key]?.compactRequested = .budgetExceeded
    }

    /// Arms an epoch after the server reported it is TRUNCATING — the silent case, where the
    /// window probe never answered and the prompt is already being cut from the head.
    func noteServerTruncationForCompaction(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard delegate?.autoCompactEnabled ?? false,
              executionStates[key]?.autoCompactExhausted == false,
              executionStates[key]?.compactRequested == nil
        else { return }
        executionStates[key]?.compactRequested = .serverTruncation
    }

    /// The refusal arm: the server rejected the request as an overflow.
    ///
    /// Compacts WITHOUT asking the model for a summary — that request carries the same
    /// conversation and would be refused for the same reason. The seed is built from what
    /// the app already holds: the role's own recorded notes and the Supervisor record.
    ///
    /// Bounded to one attempt per response. A second refusal means the pinned head does not
    /// fit on its own, which no epoch can change, so the caller takes the ordinary
    /// permanent-failure path.
    ///
    /// - Returns: `true` when the wire was compacted and the iteration should be retried.
    func compactAfterServerRefusal(
        stepID: String,
        taskID: Int,
        step: StepExecution,
        conversationMessages: inout [ChatMessage]
    ) async -> Bool {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard delegate?.autoCompactEnabled ?? false,
              executionStates[key]?.overflowCompactionsSinceLastResponse == 0
        else { return false }
        executionStates[key]?.overflowCompactionsSinceLastResponse += 1
        return await applyEpoch(
            stepID: stepID, taskID: taskID, reason: .serverRefusedOverflow,
            notes: step.scratchpad, summary: nil,
            conversationMessages: &conversationMessages)
    }

    // MARK: - In-loop epoch

    /// Runs the epoch a trigger armed, at the top of a tool iteration.
    ///
    /// - Returns: `true` when the wire was replaced.
    @discardableResult
    func compactConversationInLoop(
        stepID: String,
        taskID: Int,
        reason: CompactionPolicy.CompactionReason,
        step: StepExecution,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?,
        roleForMessage: Role,
        conversationMessages: inout [ChatMessage]
    ) async -> Bool {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[key]?.compactRequested = nil

        // Nothing beyond the head: the conversation IS its pinned prefix, and folding it
        // would replace the system prompt with a summary of itself.
        guard CompactionPolicy.plan(for: conversationMessages, retainTail: false) != nil else {
            executionStates[key]?.autoCompactExhausted = true
            return false
        }

        let epoch = UUID()
        executionStates[key]?.compactionEpochToken = epoch
        delegate?.setContextCompacting(stepID: stepID, taskID: taskID, true)
        defer {
            if executionStates[key]?.compactionEpochToken == epoch {
                executionStates[key]?.compactionEpochToken = nil
            }
            delegate?.setContextCompacting(stepID: stepID, taskID: taskID, false)
        }

        let outcome = await summarizeWithLiveBubble(
            stepID: stepID, taskID: taskID, epoch: epoch, wire: conversationMessages,
            client: client, config: config, networkLogger: networkLogger,
            role: roleForMessage)
        // A Pause is not a failure, and neither is a re-entry: leave the conversation
        // exactly as it was found and say nothing.
        guard !outcome.wasCancelled else { return false }

        return await applyEpoch(
            stepID: stepID, taskID: taskID, reason: reason,
            notes: step.scratchpad, summary: outcome.summary,
            conversationMessages: &conversationMessages)
    }

    // MARK: - Out-of-loop epoch

    /// Compacts a step that is parked, paused or failed.
    ///
    /// Borrows the step's own `runningTask` slot so the epoch is cancelled by every door
    /// that re-enters the step (`startStepExecution` cancels then replaces the entry), and
    /// writes through `persistCompactedWire`'s compare-and-swap so an answer that arrives
    /// mid-summary wins over a wire that was built before it existed.
    ///
    /// - Returns: `true` when the stored transcript was replaced.
    @discardableResult
    func compactSuspendedStep(stepID: String, taskID: Int) async -> Bool {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard executionStates[key]?.runningTask == nil,
              executionStates[key]?.compactionEpochToken == nil,
              let delegate,
              let workFolderRoot = delegate.workFolderURL,
              let task = delegate.loadedTask(taskID),
              let runIndex = task.runs.indices.last,
              let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
        else { return false }

        let step = task.runs[runIndex].steps[stepIndex]
        guard Self.compactableSuspendedStatuses.contains(step.status),
              !step.supervisorAnswerPendingDelivery,
              !step.wireTranscript.isEmpty
        else { return false }

        let runtime = resolveStepRuntime(
            step: step, task: task, runID: task.runs[runIndex].id,
            workFolderRoot: workFolderRoot, delegate: delegate)

        // A parked step keeps its entry (with a nil `runningTask`); a failed one may not
        // have one at all. Creating it is what makes `appendLLMMessage` and the fill
        // publisher — both gated on `isExecutionLive` — reach this step at all.
        let entryPreexisted = executionStates[key] != nil
        if !entryPreexisted { executionStates[key] = StepExecutionState() }

        let epoch = UUID()
        executionStates[key]?.compactionEpochToken = epoch
        // Pins the model for residency reconciliation exactly as a running step does: the
        // summary is a real request, and unloading the model under it costs a reload.
        recordActiveModel(stepID: stepID, taskID: taskID, config: runtime.effectiveConfig)
        delegate.setContextCompacting(stepID: stepID, taskID: taskID, true)

        let box = CompactionResultBox()
        let handle = Task { [weak self] in
            guard let self else { return }
            box.succeeded = await self.performSuspendedEpoch(
                stepID: stepID, taskID: taskID, epoch: epoch, step: step,
                runtime: runtime)
        }
        executionStates[key]?.runningTask = handle
        await handle.value

        delegate.setContextCompacting(stepID: stepID, taskID: taskID, false)
        // Only if this epoch still owns the slot: a re-entry replaces the whole entry, and
        // clearing then would cancel the execution that superseded us.
        if executionStates[key]?.compactionEpochToken == epoch {
            executionStates[key]?.compactionEpochToken = nil
            executionStates[key]?.runningTask = nil
            if !entryPreexisted { executionStates[key] = nil }
        }
        return box.succeeded
    }

    private func performSuspendedEpoch(
        stepID: String,
        taskID: Int,
        epoch: UUID,
        step: StepExecution,
        runtime: StepRuntime
    ) async -> Bool {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let expected = step.wireTranscript

        // The park is retained STRUCTURALLY: re-entry resolves an answered
        // `ask_supervisor` by finding its pending result and replacing it in place, so
        // folding the call away would leave the answer with nothing to attach to. Refused
        // when that tail alone already fills half the budget — an epoch that cannot make
        // the conversation smaller than its own remainder is not worth an LLM call.
        let percent = delegate?.autoCompactBudgetPercent ?? AppDefaults.autoCompactBudgetPercent
        let budget = ContextBudgetPolicy.stepBudget(
            window: step.contextFill?.window, percent: percent)
        guard let plan = CompactionPolicy.plan(
            for: expected, retainTail: true, maxTailTokens: budget.map { $0 / 2 })
        else {
            delegate?.setLastInfoMessageForUI(
                "Nothing to compact: this conversation is its own pinned prefix.")
            return false
        }

        let outcome = await summarizeWithLiveBubble(
            stepID: stepID, taskID: taskID, epoch: epoch, wire: expected,
            client: runtime.client, config: runtime.effectiveConfig,
            networkLogger: runtime.networkLogger, role: runtime.roleForMessage)

        guard !outcome.wasCancelled, !Task.isCancelled,
              executionStates[key]?.compactionEpochToken == epoch
        else { return false }

        let discarded = plan.discardedRange(in: expected)
        let record = CompactionPolicy.supervisorRecord(in: expected, discarded: discarded)
        guard CompactionPolicy.hasSeedMaterial(
            summary: outcome.summary, notes: step.scratchpad, record: record)
        else {
            delegate?.setLastInfoMessageForUI(
                "Nothing to compact: the model produced no summary and this step has no "
                    + "recorded notes.")
            return false
        }

        let seed = CompactionPolicy.seedTurn(
            summary: outcome.summary, notes: step.scratchpad, record: record)
        let compacted = CompactionPolicy.compactedWire(
            from: expected, plan: plan, seedTurn: seed)
        let fill = ContextFill(
            promptTokens: ContextBudgetPolicy.estimateTokens(messages: compacted),
            window: step.contextFill?.window,
            budget: budget,
            isEstimate: true,
            compactions: (step.contextFill?.compactions ?? 0) + 1)

        guard await persistCompactedWire(
            stepID: stepID, taskID: taskID,
            expected: expected, compacted: compacted, fill: fill)
        else {
            delegate?.setLastInfoMessageForUI(
                "Compaction skipped: this conversation moved while the summary was being "
                    + "written.")
            return false
        }

        // The next request must read as this owner's FIRST, not as a rewrite of a chain
        // that described the conversation just replaced.
        await prefixLedger.forgetOwner(.step(taskID: taskID, stepID: stepID))
        publishContextFill(stepID: stepID, taskID: taskID, fill: fill)
        await appendCompactionNotice(
            stepID: stepID, taskID: taskID, reason: .manual,
            beforeTokens: step.contextFill?.promptTokens,
            afterTokens: fill.promptTokens,
            foldedTurns: discarded.count, seedTurn: seed)
        return true
    }

    // MARK: - Shared epoch application

    /// Replaces the in-memory wire and resets everything that described the old one.
    ///
    /// The checklist is the planning boundary's, for the same reasons stated there: assign,
    /// clear the conversation-scoped latches and baselines, re-seed the message-loop ring
    /// from the array that now exists, and flag the deliberate prefix reset so the cache
    /// detector does not report the epoch as a defect.
    private func applyEpoch(
        stepID: String,
        taskID: Int,
        reason: CompactionPolicy.CompactionReason,
        notes: String?,
        summary: String?,
        conversationMessages: inout [ChatMessage]
    ) async -> Bool {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard let plan = CompactionPolicy.plan(for: conversationMessages, retainTail: false)
        else {
            executionStates[key]?.autoCompactExhausted = true
            return false
        }
        let discarded = plan.discardedRange(in: conversationMessages)
        let record = CompactionPolicy.supervisorRecord(
            in: conversationMessages, discarded: discarded)
        guard CompactionPolicy.hasSeedMaterial(summary: summary, notes: notes, record: record)
        else {
            executionStates[key]?.autoCompactExhausted = true
            return false
        }

        let seed = CompactionPolicy.seedTurn(summary: summary, notes: notes, record: record)
        let before = executionStates[key]?.lastServerPromptTokens
            ?? executionStates[key]?.lastContextFill?.promptTokens
        let foldedTurns = discarded.count

        conversationMessages = CompactionPolicy.compactedWire(
            from: conversationMessages, plan: plan, seedTurn: seed)
        // Every latch and delta baseline below described the array that no longer exists —
        // the same argument the planning boundary makes one file over.
        executionStates[key]?.resetConversationScopedState()
        reseedMessageLoopRing(stepKey: key, from: conversationMessages)
        executionStates[key]?.expectedPrefixResetPending = true
        executionStates[key]?.compactionsThisEntry += 1
        executionStates[key]?.lastCompactionServerPromptTokens = before

        let after = ContextBudgetPolicy.estimateTokens(messages: conversationMessages)
        await appendCompactionNotice(
            stepID: stepID, taskID: taskID, reason: reason,
            beforeTokens: before, afterTokens: after,
            foldedTurns: foldedTurns, seedTurn: seed)
        return true
    }

    // MARK: - Summary call

    /// The label this epoch's one extra request carries in the prefix ledger.
    static let compactionCallLabel = "context compaction"

    /// Runs the summary request with a LIVE bubble in the feed.
    ///
    /// The bubble exists because an epoch discards the conversation, and a silent pause of
    /// several seconds while that happens is indistinguishable from a hang. It must not look
    /// like the model taking a step, and the epoch writes NOTHING into the bubble's prose to
    /// make sure it cannot: both channels go to `appendStreamingThinking`, the buffer the
    /// collapsed row opens. So the bubble's content is empty for its whole life, and what the
    /// feed shows is one row — "Compacting…" (`markStreamingCompaction`, raised by
    /// `beginStreaming` so no tick can catch it reading "Waiting…"), first as the status row
    /// and then, once anything lands, as the disclosure's own animated row.
    ///
    /// Prose here would be a turn the model never took, standing in the feed beside the turns
    /// it did. The bubble is DISCARDED on every path, success included; its durable
    /// counterparts are the seed on the wire (which the model reads) and the collapsed
    /// `system: compaction` row (which the human opens).
    private func summarizeWithLiveBubble(
        stepID: String,
        taskID: Int,
        epoch: UUID,
        wire: [ChatMessage],
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?,
        role: Role
    ) async -> ContextCompactionSummaryService.Outcome {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let messageID = UUID()
        // Raised WITH the stream rather than after it: `beginStreaming` plants the feed's
        // message before its own suspension (multi-task invariant #6) and resets the mark on
        // the way through, so a separate raise afterwards leaves a tick in which the epoch's
        // only row reads "Waiting…".
        await delegate?.beginStreaming(
            stepID: stepID, taskID: taskID, messageID: messageID, role: role,
            isCompacting: true)

        let outcome = await ContextCompactionSummaryService.summarize(
            wire: wire,
            client: client,
            config: config,
            logger: networkLogger,
            stepID: stepID,
            roleName: role.displayName.isEmpty ? nil : role.displayName,
            onDelta: { [weak self] delta in
                // The gate is the epoch token rather than `isExecutionLive`, which
                // `performStreamingCall` uses: a parked step's entry is live by that test
                // whether or not this epoch still owns it, so the token is the only thing
                // that answers "am I still the compaction that opened this bubble". It is now
                // the ONLY thing between a superseded epoch and the live disclosure.
                guard let self,
                      self.executionStates[key]?.compactionEpochToken == epoch
                else { return }
                // ONE buffer, and `appendStreamingPreview` is deliberately absent from this
                // file — see the doc comment above.
                self.delegate?.appendStreamingThinking(
                    stepID: stepID, taskID: taskID, content: delta)
            })

        await noteInterleavingCall(label: Self.compactionCallLabel, config: config)
        await delegate?.discardStreaming(
            stepID: stepID, messageID: messageID, taskID: taskID)
        delegate?.markStreamingCompaction(stepID: stepID, taskID: taskID, false)
        return outcome
    }

    // MARK: - Feed notice

    private func appendCompactionNotice(
        stepID: String,
        taskID: Int,
        reason: CompactionPolicy.CompactionReason,
        beforeTokens: Int?,
        afterTokens: Int?,
        foldedTurns: Int,
        seedTurn: String
    ) async {
        await appendLLMMessage(
            stepID: stepID, taskID: taskID, role: .user,
            content: CompactionPolicy.noticeText(
                reason: reason, beforeTokens: beforeTokens, afterTokens: afterTokens,
                foldedTurns: foldedTurns, seedTurn: seedTurn),
            sourceContext: .compaction)
    }

    // MARK: - Fill publication

    /// Mirrors a fill into the execution state (so `persistTokenUsage` writes it) and into
    /// the projection the composer's indicator observes.
    func publishContextFill(stepID: String, taskID: Int, fill: ContextFill) {
        executionStates[TaskStepKey(taskID: taskID, stepID: stepID)]?.lastContextFill = fill
        delegate?.updateContextFill(stepID: stepID, taskID: taskID, fill: fill)
    }

    /// The step's window, re-probing at most once per epoch after a response.
    private func resolveWindowForFill(
        stepKey: TaskStepKey,
        client: any LLMClient,
        config: LLMConfig
    ) async -> Int? {
        let cacheKey = "\(config.baseURLString.normalizedBaseURL)|\(config.modelName)"
        if let cached = probedContextLengths[cacheKey], let value = cached { return value }
        guard executionStates[stepKey]?.windowReprobeSpent == false else { return nil }
        executionStates[stepKey]?.windowReprobeSpent = true
        let probed = await client.modelContextLength(config: config)
        if probed != nil { probedContextLengths[cacheKey] = probed }
        return probed
    }
}
