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
    }

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
    func appendStreamingThinking(stepID: String, content: String) {
        streamingPreviewManager.appendThinking(stepID: stepID, content: content)
    }

    // periphery:ignore - protocol conformance (LLMStreamingDelegate)
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
