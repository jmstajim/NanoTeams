import Foundation

/// Service for managing step messaging operations (Supervisor comments, answers).
enum StepMessagingService {
    static func setSupervisorCommentForNext(stepID: String, comment: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        task.runs[location.runIndex].steps[location.stepIndex].supervisorCommentForNext = clean.isEmpty ? nil : clean
    }

    /// Returns `true` when the answer was applied to a real pending step. Returns
    /// `false` when no step matches `stepID` — caller must surface this to the
    /// Supervisor instead of silently writing a no-op (CLAUDE.md §7: `mutateTask`
    /// returning `true` means "persisted", not "the mutation did something"; without
    /// this signal, an answer typed against a step that was restarted between chip
    /// render and submit would evaporate without any banner).
    @discardableResult
    static func answerSupervisorQuestion(
        stepID: String,
        answer: String,
        attachmentPaths: [String] = [],
        in task: inout NTMSTask
    ) -> Bool {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return false }

        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswer = clean.isEmpty ? nil : clean
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerAttachmentPaths = attachmentPaths
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = false

        if task.runs[location.runIndex].steps[location.stepIndex].status == .needsSupervisorInput {
            task.runs[location.runIndex].steps[location.stepIndex].status = .pending
        }
        return true
    }
}
