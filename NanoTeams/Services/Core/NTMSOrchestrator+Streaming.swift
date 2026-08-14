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
    func beginStreaming(stepID: String, taskID: Int, messageID: UUID, role: Role) async {
        streamingPreviewManager.beginStreaming(stepID: stepID, taskID: taskID, messageID: messageID, role: role)

        // Pre-create empty LLMMessage in step.llmConversation so timeline picks it up
        let msg = LLMMessage(id: messageID, role: .assistant, content: "")
        await mutateTask(taskID: taskID) { task in
            TaskMutationService.appendLLMMessage(msg, to: stepID, in: &task)
        }
    }

    func appendStreamingPreview(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        streamingPreviewManager.append(stepID: stepID, taskID: taskID, messageID: messageID, role: role, content: content)
        streamingPreviewManager.markStreamActivity(stepID: stepID, taskID: taskID)
    }

    func replaceStreamingPreview(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        streamingPreviewManager.replaceContent(stepID: stepID, taskID: taskID, messageID: messageID, role: role, content: content)
        streamingPreviewManager.markStreamActivity(stepID: stepID, taskID: taskID)
    }

    func appendStreamingThinking(stepID: String, taskID: Int, content: String) {
        streamingPreviewManager.appendThinking(stepID: stepID, taskID: taskID, content: content)
        streamingPreviewManager.markStreamActivity(stepID: stepID, taskID: taskID)
    }

    func markStreamActivity(stepID: String, taskID: Int) {
        streamingPreviewManager.markStreamActivity(stepID: stepID, taskID: taskID)
    }

    func markStreamingToolCall(stepID: String, taskID: Int) {
        streamingPreviewManager.markStreamingToolCall(stepID: stepID, taskID: taskID)
    }

    /// Reactive in-stream streaming-loop signal for a CHILD task — forwards to
    /// `DelegationLoopWatcher.noteStreamLoop` (cooldown + parent interrupt).
    /// Detection itself runs inside `performStreamingCall`; this is the
    /// `LLMStreamingDelegate` bridge. Returns whether the in-stream scanner
    /// should advance its throttle baseline (see `noteStreamLoop` for the I4 rule).
    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    @discardableResult
    func noteStreamLoop(taskID: Int, stepID: String, signal: LoopSignal) -> Bool {
        delegationLoopWatcher.noteStreamLoop(taskID: taskID, stepID: stepID, signal: signal)
    }

    /// Discards a TOP-LEVEL looping generation: clears the streaming preview and
    /// best-effort removes the pre-created empty assistant `LLMMessage` (planted by
    /// `beginStreaming`). Used by `performStreamingCall` instead of `commitStreaming`
    /// when a thinking loop breaks the stream. The removal is best-effort: on a
    /// teardown race where the step has already left the latest run, `mutateTask`'s
    /// closure no-ops and the empty turn is left — but it carries `content: ""` and
    /// renders as nothing (empty bubbles are suppressed downstream), so it's inert.
    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func discardStreaming(stepID: String, messageID: UUID, taskID: Int) async {
        streamingPreviewManager.clear(stepID: stepID, taskID: taskID)
        await mutateTask(taskID: taskID) { task in
            TaskMutationService.removeLLMMessage(id: messageID, from: stepID, in: &task)
        }
    }

    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async {
        // Get the role from the preview before committing
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let role = streamingPreviewManager.previews[key]?.role ?? .softwareEngineer
        let messageID = streamingPreviewManager.streamingMessageIDs[key] ?? UUID()

        // Clear streaming state
        streamingPreviewManager.commit(stepID: stepID, taskID: taskID)

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

        // Post-commit loop detection (child tasks only): ONE consolidated scan of
        // the finalized conversation + tool-call history via
        // `DelegationLoopWatcher.considerCommitted` → `LoopScanner.scanCommitted`
        // (tool-call sequence → within-message → across-messages, first wins).
        // Reads the just-committed assistant turn back from `step.llmConversation`
        // (commitStreamingContent updated it above). `thinking + content` is joined
        // per message inside the scanner so tool-only turns (empty `content` after
        // Harmony markers stripped) still contribute their reasoning text to the LCS.
        // NB: `commitStreaming` runs BEFORE the current iteration's `appendToolCalls`,
        // so `step.toolCalls` here is missing the just-finalized call — the
        // `repetitionMinIdenticalToolCalls = 3` threshold accounts for this (fire on
        // the 4th emitted identical call). The +5 suffix buffer keeps the scanner's
        // `createdAt > cutoff` filter from stranding the suffix below `minRepeats`.
        if let task = loadedTask(taskID),
           let run = task.runs.last,
           let step = run.steps.first(where: { $0.id == stepID })
        {
            let recentAssistant = step.llmConversation
                .filter { $0.role == .assistant }
                .suffix(5)
                .map { (thinking: $0.thinking, content: $0.content, createdAt: $0.createdAt) }
            let recentCalls = step.toolCalls
                .suffix(DelegationConstants.repetitionMinIdenticalToolCalls + 5)
                .map { (name: $0.name, argsJSON: $0.argumentsJSON, createdAt: $0.createdAt) }
            // Read off the UNFILTERED conversation: the boundary is a `.user` turn, so
            // the `.assistant` slice above cannot see it, and the watcher only ever
            // receives tuples. Bounds the tool-call scan so a child that was handed
            // guidance mid-delegation (`forward_to_team`) isn't reported as looping for
            // acting on it.
            delegationLoopWatcher.considerCommitted(
                taskID: taskID,
                recentAssistant: Array(recentAssistant),
                toolCalls: Array(recentCalls),
                informationBoundary: ConversationInformationBoundary.lastArrival(in: step.llmConversation)
            )
        }

        // Re-render the displayed-side audit log for this turn (best-effort, gated on `loggingEnabled`).
        renderConversationLog(taskID: taskID)
    }

    func clearStreamingPreview(stepID: String, taskID: Int) {
        streamingPreviewManager.clear(stepID: stepID, taskID: taskID)
    }

    // MARK: - Processing Progress

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func updateStreamingProcessingProgress(stepID: String, taskID: Int, progress: Double) {
        streamingPreviewManager.updateProcessingProgress(stepID: stepID, taskID: taskID, progress: progress)
    }

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func clearStreamingProcessingProgress(stepID: String, taskID: Int) {
        streamingPreviewManager.clearProcessingProgress(stepID: stepID, taskID: taskID)
    }
}
