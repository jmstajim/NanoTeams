import SwiftUI

// MARK: - Chat Queue Management
//
// Thin forwarding facade on `QuickCaptureController` delegating queue control-plane
// operations to `SupervisorMessageQueueService` (owned by `NTMSOrchestrator.messageQueue`,
// with `fallbackQueue` for controller tests that omit `store` or use an instance with its
// own `formState`). See `SupervisorMessageQueueService.swift` for the queue's two-path
// consumption contract, wake mechanisms, and dedup/give-up invariants.

extension QuickCaptureController {

    /// Queues the currently-typed composer message for the active task's next
    /// supervisor-input prompt. Called from the Quick Capture overlay when the LLM
    /// is still streaming (`.taskWorking` mode with chat-mode team) and the user
    /// wants to line up their next message without waiting for a question.
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
        formState.clearAnswerFields()
        formState.draftID = UUID()
    }

    /// The role ID of the first running step in `task`'s latest run, if any.
    static func firstRunningStepRoleID(in task: NTMSTask) -> String? {
        SupervisorMessageQueueService.firstRunningStepRoleID(in: task)
    }

    /// Stores a message for `taskID` via the orchestrator's `SupervisorMessageQueueService`
    /// using this controller's `formState` and `embedFilesInPrompt` preference.
    @discardableResult
    func queueChatMessage(
        text: String,
        attachments: [StagedAttachment],
        clippedTexts: [String],
        taskID: Int,
        targetRoleID: String? = nil
    ) -> Bool {
        queueService.queueChatMessage(
            text: text,
            attachments: attachments,
            clippedTexts: clippedTexts,
            taskID: taskID,
            targetRoleID: targetRoleID,
            formState: formState
        )
    }

    /// Backstop for the queue — delegates to `SupervisorMessageQueueService` using
    /// this controller's `formState`.
    func tryFlushQueuedMessages() {
        queueService.tryFlushQueuedMessages(formState: formState)
    }

    /// Body of the `.start` wake's dispatched Task — forwards to `queueService`.
    func performStartWake(taskID: Int, newlyStampedIDs: Set<UUID>) async {
        await queueService.performStartWake(
            taskID: taskID,
            newlyStampedIDs: newlyStampedIDs,
            formState: formState
        )
    }

    /// Chat-mode lookup that works for unloaded background tasks.
    static func isChatModeTask(_ taskID: Int, store: NTMSOrchestrator) -> Bool {
        SupervisorMessageQueueService.isChatModeTask(taskID, store: store)
    }

    #if DEBUG
    func clearPendingResumeForQueueFlushForTesting(taskID: Int) {
        queueService.clearPendingResumeForQueueFlushForTesting(taskID: taskID)
    }

    func _testHasFailedResumeAttempted(taskID: Int) -> Bool {
        queueService._testHasFailedResumeAttempted(taskID: taskID)
    }

    func _testHasChatStartAttempted(taskID: Int) -> Bool {
        queueService._testHasChatStartAttempted(taskID: taskID)
    }
    #endif

    /// Discards all queued chat messages for the given task.
    func discardQueuedChatMessage(taskID: Int) {
        queueService.discardQueuedChatMessage(taskID: taskID, formState: formState)
    }

    // MARK: - MainLayoutView onChange Handlers

    /// Called when `engineState.taskEngineStates` changes. Refreshes the panel (for
    /// live mode transitions) and drives the queue flush.
    func handleEngineStateChanged() {
        refreshPanelIfVisible()
        tryFlushQueuedMessages()
    }

    /// Called when `store.activeTask?.closedAt` changes. When the task becomes closed
    /// (`closedAt` transitions from `nil` to non-nil), discards any queued messages.
    func handleActiveTaskClosedAtChanged(newValue: Date?, taskID: Int?) {
        guard newValue != nil, let taskID else { return }
        discardQueuedChatMessage(taskID: taskID)
    }

    // MARK: - Backstop Priority (pure, unit-testable)

    static func collectQueuedMessagesForFlush(
        queue: [QuickCaptureFormState.QueuedChatMessage],
        waitingStepRoleIDs: [String]
    ) -> (stepRoleID: String, messageIDs: [UUID])? {
        SupervisorMessageQueueService.collectQueuedMessagesForFlush(
            queue: queue,
            waitingStepRoleIDs: waitingStepRoleIDs
        )
    }
}
