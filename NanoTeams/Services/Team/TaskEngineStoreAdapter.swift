import Foundation

/// Adapts NTMSOrchestrator to `TeamEngineStore` scoped to a specific task.
/// Each running task gets its own adapter so that the TeamEngine only sees
/// the task it is responsible for.
@MainActor
final class TaskEngineStoreAdapter: TeamEngineStore {
    private weak var orchestrator: NTMSOrchestrator?
    let taskID: Int

    init(orchestrator: NTMSOrchestrator, taskID: Int) {
        self.orchestrator = orchestrator
        self.taskID = taskID
    }

    // MARK: - TeamEngineStore

    var activeTask: NTMSTask? {
        orchestrator?.loadedTask(taskID)
    }

    var teamSettings: TeamSettings {
        resolvedTeam?.settings ?? .default
    }

    var activeTeam: Team? {
        resolvedTeam
    }

    func stepStatus(stepID: String) -> StepStatus? {
        guard let task = activeTask, let run = task.runs.last else { return nil }
        // Build a temporary O(1) lookup; steps array is typically 5-7 elements.
        // This avoids the O(n) linear scan in the hot 250ms polling path.
        for step in run.steps where step.id == stepID {
            return step.status
        }
        return nil
    }

    func producedArtifactNames() -> Set<String> {
        guard let task = activeTask, let run = task.runs.last else { return [] }
        return Self.computeProducedArtifactNames(task: task, run: run)
    }

    /// Computes produced artifact names, excluding artifacts from roles awaiting acceptance.
    nonisolated static func computeProducedArtifactNames(task: NTMSTask, run: Run) -> Set<String> {
        var names = Set<String>()

        if task.hasInitialInput {
            names.insert(SystemTemplates.supervisorTaskArtifactName)
        }

        // Roles awaiting acceptance — their artifacts are not yet available downstream
        let pendingRoles = Set(run.roleStatuses.compactMap { roleID, status in
            status == .needsAcceptance ? roleID : nil
        })

        for step in run.steps where step.status == .done {
            if pendingRoles.contains(step.effectiveRoleID) { continue }
            for artifact in step.artifacts {
                names.insert(artifact.name)
            }
        }

        return names
    }

    func updateRoleStatus(roleID: String, status: RoleExecutionStatus) async {
        await orchestrator?.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            task.runs[runIndex].roleStatuses[roleID] = status
            task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    func prepareStepForExecution(stepID: String) async {
        await orchestrator?.mutateTask(taskID: taskID) { task in
            StepExecutionService.prepareStepForExecution(
                stepID: stepID,
                in: &task
            )
        }
    }

    func runStep(stepID: String) async {
        await orchestrator?.runStep(stepID: stepID, taskID: taskID)
    }

    func findOrCreateStep(roleID: String) async -> String? {
        await orchestrator?.findOrCreateStep(taskID: taskID, roleID: roleID)
    }

    /// Resets a completed step for revision (stateful continuation).
    /// Preserves all state (messages, artifacts, llmConversation, llmSessionID, scratchpad, toolCalls,
    /// amendments) so the LLM continues the conversation with full context.
    /// Sets `revisionComment` from the last supervisor message to enable stateful session continuation
    /// and prevent premature artifact completeness auto-completion.
    func resetStepForRevision(stepID: String) async {
        await orchestrator?.mutateTask(taskID: taskID) { task in
            guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
            let step = task.runs[location.runIndex].steps[location.stepIndex]
            let status = step.status
            if status == .done || status == .failed {
                let feedback = step.messages.last(where: { $0.role == .supervisor })?.content
                    ?? "Please revise your work based on the requested changes."
                task.runs[location.runIndex].steps[location.stepIndex].status = .pending
                task.runs[location.runIndex].steps[location.stepIndex].completedAt = nil
                task.runs[location.runIndex].steps[location.stepIndex].revisionComment = feedback
                task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
                // llmSessionID kept for stateful continuation via previous_response_id
            }
        }
    }

    func setLastErrorMessageForUI(_ message: String) async {
        await orchestrator?.setLastErrorMessageForUI(message)
    }

    // MARK: - Private

    /// Resolve the team for this task: prefer task's preferredTeamID, then project's activeTeam.
    private var resolvedTeam: Team? {
        let task = activeTask
        if let preferredTeamID = task?.preferredTeamID,
           let team = orchestrator?.workFolder?.team(withID: preferredTeamID) {
            return team
        }
        return orchestrator?.workFolder?.activeTeam
    }
}
