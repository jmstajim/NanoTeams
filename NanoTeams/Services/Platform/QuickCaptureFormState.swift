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

    // MARK: - Answer Mode Transitions

    /// Enters answer mode: saves current `supervisorTask`, clears it for answer input, stores the payload.
    /// Re-entry is non-destructive — if already in answer mode, only the payload is updated so
    /// the original `savedSupervisorTask` (the user's task draft) is preserved.
    func enterAnswerMode(payload: SupervisorAnswerPayload) {
        guard !isInAnswerMode else {
            pendingAnswer = payload
            return
        }
        savedSupervisorTask = supervisorTask
        supervisorTask = ""
        pendingAnswer = payload
        isInAnswerMode = true
    }

    /// Exits answer mode: restores the saved `supervisorTask`, clears answer-mode attachments and clips.
    func exitAnswerMode() {
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

    /// Clears answer-mode clips/attachments without restoring the saved supervisor task.
    /// Used on panel dismiss so stale clips don't pollute a future session, while
    /// task-mode state is preserved across open/close cycles.
    func clearAnswerSession() {
        answerAttachments = []
        answerClippedTexts = []
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

    // MARK: - Test Helpers

    #if DEBUG
    var _testSavedSupervisorTask: String? { savedSupervisorTask }
    #endif
}
