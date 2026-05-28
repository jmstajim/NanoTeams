import Foundation

extension NTMSOrchestrator {

    // MARK: - In-Memory Mutations

    func mutateTaskInMemory(
        taskID: Int, _ mutate: (inout NTMSTask) -> Void, updateIndex: Bool = false
    ) {
        if taskID == activeTaskID {
            guard var task = activeTask else { return }
            mutate(&task)
            activeTask = task

            guard var snap = snapshot else { return }
            snap.activeTask = task
            snap.activeTaskID = task.id

            if updateIndex {
                var tasksIndex = snap.tasksIndex
                let summary = task.toSummary()
                if let idx = tasksIndex.tasks.firstIndex(where: { $0.id == summary.id }) {
                    tasksIndex.tasks[idx] = summary
                } else {
                    tasksIndex.tasks.append(summary)
                }
                tasksIndex.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
                snap.tasksIndex = tasksIndex
            }

            snapshot = snap
        } else {
            guard var task = snapshot?.loadedTasks[taskID] else { return }
            mutate(&task)
            snapshot?.loadedTasks[taskID] = task
        }
    }

    // MARK: - Streaming (Inline Architecture)

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func beginStreaming(stepID: String, messageID: UUID, role: Role, taskID: Int) async {
        streamingPreviewManager.beginStreaming(stepID: stepID, messageID: messageID, role: role)

        // Pre-create empty LLMMessage in step.llmConversation so timeline picks it up
        let msg = LLMMessage(id: messageID, role: .assistant, content: "")
        await mutateTask(taskID: taskID) { task in
            TaskMutationService.appendLLMMessage(msg, to: stepID, in: &task)
        }
    }

    func appendStreamingPreview(stepID: String, messageID: UUID, role: Role, content: String) {
        streamingPreviewManager.append(stepID: stepID, messageID: messageID, role: role, content: content)
        streamingPreviewManager.markStreamActivity(stepID: stepID)
        considerStreamingForLoopDetection(stepID: stepID)
    }

    func replaceStreamingPreview(stepID: String, messageID: UUID, role: Role, content: String) {
        streamingPreviewManager.replaceContent(stepID: stepID, messageID: messageID, role: role, content: content)
        streamingPreviewManager.markStreamActivity(stepID: stepID)
        considerStreamingForLoopDetection(stepID: stepID)
    }

    func appendStreamingThinking(stepID: String, content: String) {
        streamingPreviewManager.appendThinking(stepID: stepID, content: content)
        streamingPreviewManager.markStreamActivity(stepID: stepID)
        considerStreamingForLoopDetection(stepID: stepID)
    }

    func markStreamActivity(stepID: String) {
        streamingPreviewManager.markStreamActivity(stepID: stepID)
    }

    /// Throttled hook for the loop watcher. The watcher itself rate-limits
    /// (only scans once every `repetitionStreamingThrottleSeconds` per step
    /// AND stays in cooldown after firing) — this method is a cheap
    /// dispatcher that the streaming pipeline calls on every token append
    /// without measurable overhead. We resolve the taskID for `stepID`
    /// once and short-circuit if the step isn't actually attached to a
    /// child task.
    private func considerStreamingForLoopDetection(stepID: String) {
        guard let taskID = llmExecutionService.taskIDForStep(stepID) else { return }
        let content = streamingPreviewManager.streamingContent(for: stepID) ?? ""
        let thinking = streamingPreviewManager.streamingThinking(for: stepID) ?? ""
        delegationLoopWatcher.considerStreamingBuffer(
            taskID: taskID,
            stepID: stepID,
            content: content,
            thinking: thinking
        )
    }

    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async {
        // Get the role from the preview before committing
        let role = streamingPreviewManager.previews[stepID]?.role ?? .softwareEngineer
        let messageID = streamingPreviewManager.streamingMessageIDs[stepID] ?? UUID()

        // Clear streaming state
        streamingPreviewManager.commit(stepID: stepID)

        // Update both LLMMessage and StepMessage atomically
        mutateTaskInMemory(
            taskID: taskID,
            { task in
                TaskMutationService.commitStreamingContent(
                    stepID: stepID,
                    messageID: messageID,
                    content: content,
                    thinking: thinking,
                    role: role,
                    in: &task
                )
            }, updateIndex: false)

        // Post-commit loop detection: cheap single-pass scan on the
        // finalized message + across-messages overlap on the role's
        // recent outputs. Both checks no-op for non-child tasks, in
        // cooldown, or below threshold — see `DelegationLoopWatcher`.
        delegationLoopWatcher.considerCommittedMessage(
            taskID: taskID,
            stepID: stepID,
            content: content,
            thinking: thinking
        )
        if let task = loadedTask(taskID),
           let run = task.runs.last,
           let step = run.steps.first(where: { $0.id == stepID })
        {
            // Across-messages: feed `thinking + content` per message so
            // tool-only assistant turns (empty `content` because Harmony
            // tool-call markers were stripped) still contribute their
            // reasoning text to the LCS comparison. Without the thinking
            // prefix every entry collapses to "" and `detectAcrossMessages`
            // bails on its `minMessageChars` floor — silent no-op on every
            // tool-only loop.
            let recentRoleMessages = step.llmConversation
                .filter { $0.role == .assistant }
                .suffix(4)
                .map { ($0.thinking ?? "") + "\n" + $0.content }
            delegationLoopWatcher.considerConversation(
                taskID: taskID,
                recentRoleMessages: Array(recentRoleMessages)
            )
            // Tool-call sequence: the model can keep emitting one identical
            // tool call per turn with empty `content` — invisible to the
            // text-based modes above. Read from `step.toolCalls` (which
            // includes cached/short-circuited calls — they're persisted via
            // `appendToolCalls` regardless of cache hit). NB: `commitStreaming`
            // runs BEFORE the current iteration's `appendToolCalls`
            // (LLMExecutionService+Streaming.swift), so `step.toolCalls`
            // here is missing the just-finalized call. The threshold
            // `repetitionMinIdenticalToolCalls = 3` accounts for this — fire
            // happens on the 4th actually-emitted identical call. We grab a
            // wider suffix (+5 buffer) because the watcher's `considerToolCallSequence`
            // filters by `createdAt > lastTrigger` to avoid false-positives on
            // revision-retained history; without the buffer that filter could
            // strand the suffix below `minRepeats`.
            let recentCalls = step.toolCalls
                .suffix(DelegationConstants.repetitionMinIdenticalToolCalls + 5)
                .map { (name: $0.name, argsJSON: $0.argumentsJSON, createdAt: $0.createdAt) }
            delegationLoopWatcher.considerToolCallSequence(
                taskID: taskID,
                recentCalls: Array(recentCalls)
            )
        }
    }

    func clearStreamingPreview(stepID: String) {
        streamingPreviewManager.clear(stepID: stepID)
    }

    // MARK: - Processing Progress

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func updateStreamingProcessingProgress(stepID: String, progress: Double) {
        streamingPreviewManager.updateProcessingProgress(stepID: stepID, progress: progress)
    }

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func clearStreamingProcessingProgress(stepID: String) {
        streamingPreviewManager.clearProcessingProgress(stepID: stepID)
    }
}
