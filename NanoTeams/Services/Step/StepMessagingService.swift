import Foundation

/// Service for managing step messaging operations (Supervisor comments, answers, work notes).
enum StepMessagingService {
    static func setSupervisorCommentForNext(stepID: String, comment: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        task.runs[location.runIndex].steps[location.stepIndex].supervisorCommentForNext = clean.isEmpty ? nil : clean
    }

    static func answerSupervisorQuestion(
        stepID: String,
        answer: String,
        attachmentPaths: [String] = [],
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }

        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswer = clean.isEmpty ? nil : clean
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerAttachmentPaths = attachmentPaths
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = false

        if task.runs[location.runIndex].steps[location.stepIndex].status == .needsSupervisorInput {
            task.runs[location.runIndex].steps[location.stepIndex].status = .pending
        }
    }
}
