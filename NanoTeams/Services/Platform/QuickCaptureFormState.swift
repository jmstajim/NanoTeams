import Foundation

// MARK: - Quick Capture Form State

/// Owns all user-editable form state for Quick Capture (overlay + sheet).
///
/// Separated from `QuickCaptureController` (panel lifecycle, hotkeys, mode routing)
/// and from `TaskManagementState` (sidebar selection, delete/rename state). This is
/// the Information Expert for the form itself: title, supervisorTask, team, attachments, and
/// the answer-mode sub-state that tracks a transient Supervisor question.
@Observable @MainActor
final class QuickCaptureFormState {
    // MARK: - Task Creation Fields

    var title: String = ""
    var supervisorTask: String = ""
    var selectedTeamID: NTMSID?
    var draftID: UUID = UUID()
    var attachments: [StagedAttachment] = []
    var clippedTexts: [String] = []

    // MARK: - Answer Mode Sub-State

    private(set) var pendingAnswer: SupervisorAnswerPayload?
    var answerAttachments: [StagedAttachment] = []
    var answerClippedTexts: [String] = []

    @ObservationIgnored private(set) var isInAnswerMode: Bool = false
    @ObservationIgnored private var savedSupervisorTask: String?

    /// Per-task answer draft storage. Keyed by taskID.
    /// Preserves attachments, clips, and typed text across task switches and panel close/open.
    @ObservationIgnored private var answerDrafts: [Int: AnswerDraft] = [:]

    // MARK: - Answer Draft

    struct AnswerDraft {
        var text: String
        var attachments: [StagedAttachment]
        var clippedTexts: [String]
    }

    // MARK: - Answer Mode Transitions

    /// Enters answer mode: saves current `supervisorTask`, clears it for answer input, stores the payload.
    /// Re-entry is non-destructive — if already in answer mode, only the payload is updated so
    /// the original `savedSupervisorTask` (the user's task draft) is preserved.
    func enterAnswerMode(payload: SupervisorAnswerPayload) {
        guard !isInAnswerMode else {
            // Task changed while already in answer mode — switch drafts
            if let oldTaskID = pendingAnswer?.taskID, oldTaskID != payload.taskID {
                switchAnswerTask(from: oldTaskID, to: payload)
            } else {
                pendingAnswer = payload
            }
            return
        }
        savedSupervisorTask = supervisorTask
        supervisorTask = ""
        pendingAnswer = payload
        isInAnswerMode = true
        // Restore saved draft for this task if available
        if let draft = answerDrafts[payload.taskID] {
            supervisorTask = draft.text
            answerAttachments = draft.attachments
            answerClippedTexts = draft.clippedTexts
        }
    }

    /// Exits answer mode: saves current answer draft per-task, restores `supervisorTask`.
    func exitAnswerMode() {
        // Save current answer state as draft before exiting
        if let payload = pendingAnswer {
            saveCurrentAnswerDraft(taskID: payload.taskID)
        }
        supervisorTask = savedSupervisorTask ?? ""
        savedSupervisorTask = nil
        answerAttachments = []
        answerClippedTexts = []
        pendingAnswer = nil
        isInAnswerMode = false
    }

    /// Updates the pending answer payload without toggling the mode flag. Used when the
    /// active task changes while the panel is already in answer mode.
    func updateAnswerPayload(_ payload: SupervisorAnswerPayload) {
        pendingAnswer = payload
    }

    /// Saves the current answer-mode fields as a draft for the given task,
    /// then clears them so the next task starts clean.
    func switchAnswerTask(from oldTaskID: Int, to newPayload: SupervisorAnswerPayload) {
        saveCurrentAnswerDraft(taskID: oldTaskID)
        // Load draft for the new task (or start fresh)
        if let draft = answerDrafts[newPayload.taskID] {
            supervisorTask = draft.text
            answerAttachments = draft.attachments
            answerClippedTexts = draft.clippedTexts
        } else {
            supervisorTask = ""
            answerAttachments = []
            answerClippedTexts = []
        }
        pendingAnswer = newPayload
    }

    /// Clears answer-mode clips/attachments without restoring the saved supervisor task.
    /// Used on panel dismiss — saves draft first so it persists across open/close.
    func clearAnswerSession() {
        if let payload = pendingAnswer {
            saveCurrentAnswerDraft(taskID: payload.taskID)
        }
        answerAttachments = []
        answerClippedTexts = []
    }

    /// Discards the answer draft for a specific task. Called on successful submit or explicit cancel.
    func discardAnswerDraft(taskID: Int) {
        answerDrafts.removeValue(forKey: taskID)
    }

    // MARK: - Task Creation State Reset

    /// Clears task-creation fields and generates a new `draftID` for the next task.
    func clearTaskDraft() {
        title = ""
        supervisorTask = ""
        selectedTeamID = nil
        draftID = UUID()
        attachments = []
        clippedTexts = []
    }

    // MARK: - Submission Guards

    /// Can the form be submitted given its current mode?
    func canSubmit(mode: QuickCaptureMode) -> Bool {
        let hasText = !supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if case .supervisorAnswer = mode {
            return hasText || !answerAttachments.isEmpty || !answerClippedTexts.isEmpty
        }
        return hasText
    }

    /// True when any task-draft content is present. Used to decide whether to show a
    /// "discard draft?" confirmation on cancel.
    var hasTaskDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clippedTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !attachments.isEmpty
    }

    // MARK: - Private

    private func saveCurrentAnswerDraft(taskID: Int) {
        let text = supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && answerAttachments.isEmpty && answerClippedTexts.isEmpty {
            answerDrafts.removeValue(forKey: taskID)
        } else {
            answerDrafts[taskID] = AnswerDraft(
                text: supervisorTask,
                attachments: answerAttachments,
                clippedTexts: answerClippedTexts
            )
        }
    }

    // MARK: - Test Helpers

    #if DEBUG
    var _testSavedSupervisorTask: String? { savedSupervisorTask }
    var _testAnswerDrafts: [Int: AnswerDraft] { answerDrafts }
    func _testClearAnswerDrafts() { answerDrafts.removeAll() }
    #endif
    nonisolated deinit {}
}
