import Foundation

/// Service for step execution mutations (status changes, reset, Supervisor comment injection).
enum StepExecutionService {

    /// Prepares a step for execution by injecting Supervisor comments.
    static func prepareStepForExecution(
        stepID: String,
        in task: inout NTMSTask
    ) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }

        injectSupervisorCommentIfNeeded(task: &task, location: location)
    }

    /// Approves a step by injecting Supervisor comments and setting status to pending.
    static func approveStep(stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }

        injectSupervisorCommentIfNeeded(task: &task, location: location)

        if task.runs[location.runIndex].steps[location.stepIndex].status == .needsApproval {
            task.runs[location.runIndex].steps[location.stepIndex].status = .pending
        }
    }

    /// Sets a step's status to running if it's pending or paused.
    static func markStepRunning(stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }

        let status = task.runs[location.runIndex].steps[location.stepIndex].status
        if status == .pending || status == .paused {
            task.runs[location.runIndex].steps[location.stepIndex].status = .running
        }
    }

    /// Pauses a running step.
    static func pauseStep(stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let status = task.runs[location.runIndex].steps[location.stepIndex].status
        if status == .running || status == .needsSupervisorInput {
            task.runs[location.runIndex].steps[location.stepIndex].status = .paused
        }
    }

    /// Resets a step and all subsequent steps in the run.
    static func redoStep(stepID: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        for idx in location.stepIndex..<task.runs[location.runIndex].steps.count {
            resetStep(&task.runs[location.runIndex].steps[idx])
        }
    }

    /// Gets the status of a step.
    static func stepStatus(stepID: String, from task: NTMSTask?) -> StepStatus? {
        guard let run = task?.runs.last else { return nil }
        return run.steps.first(where: { $0.id == stepID })?.status
    }

    // MARK: - Private Helpers

    private static func injectSupervisorCommentIfNeeded(task: inout NTMSTask, location: StepLocation) {
        guard location.stepIndex > 0 else { return }

        let previous = task.runs[location.runIndex].steps[location.stepIndex - 1]
        guard let comment = previous.supervisorCommentForNext?.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else { return }

        let expectedPrefix = "Supervisor Comment: "
        let expectedContent = expectedPrefix + comment

        let alreadyInjected = task.runs[location.runIndex].steps[location.stepIndex].messages.contains {
            $0.role == .supervisor && $0.content == expectedContent
        }

        if !alreadyInjected {
            task.runs[location.runIndex].steps[location.stepIndex].messages.append(
                StepMessage(role: .supervisor, content: expectedContent)
            )
            task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    private static func resetStep(_ step: inout StepExecution) {
        step.reset()
    }
}
