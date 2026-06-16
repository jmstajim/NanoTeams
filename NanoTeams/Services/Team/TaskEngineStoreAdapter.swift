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
    /// Ensures `revisionComment` is set — preferring the raw comment stored by the
    /// requesting flow, falling back to the last supervisor message — to enable stateful
    /// session continuation and prevent premature artifact completeness auto-completion.
    /// No-ops for any status other than `.done`/`.failed` (benign: a `.pending` step was
    /// already reset by a prior pass).
    func resetStepForRevision(stepID: String) async {
        // Clear any stale streaming state ONLY when the step is actually being reset
        // (i.e. it is `.done`/`.failed` — the same gate the mutation below uses). The
        // reset returns the step to `.pending`; a leftover `activeMessageIDs` entry
        // would otherwise keep the activity-feed bubble animating "Thinking…" for a
        // step that is no longer running (the symptom on revised/held roles). Gating
        // the clear on terminal status means a `.pending`/`.running` no-op reset can't
        // wipe a genuinely live indicator.
        let currentStatus = orchestrator?.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.id == stepID })?.status
        if currentStatus == .done || currentStatus == .failed {
            orchestrator?.clearStreamingPreview(stepID: stepID, taskID: taskID)
        }
        await orchestrator?.mutateTask(taskID: taskID) { task in
            guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
            let step = task.runs[location.runIndex].steps[location.stepIndex]
            let status = step.status
            if status == .done || status == .failed {
                // Prefer the raw comment stored at the trigger site — `requestRevision`,
                // `executeAmendment`, and `propagateAmendmentDownstream` all set it.
                // The message fallback is defense-in-depth for steps persisted by older
                // builds and future `.revisionRequested` writers; the send site strips a
                // legacy "Supervisor Feedback: " prefix before re-applying, so even
                // pre-fix data can't double the attribution. A whitespace-only stored
                // comment is "no usable feedback" — fall through, like nil.
                let storedComment = step.revisionComment.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                }
                let feedback = storedComment
                    ?? step.messages.last(where: { $0.role == .supervisor })?.content
                    ?? "Please revise your work based on the requested changes."
                task.runs[location.runIndex].steps[location.stepIndex].status = .pending
                task.runs[location.runIndex].steps[location.stepIndex].completedAt = nil
                task.runs[location.runIndex].steps[location.stepIndex].revisionComment = feedback
                task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
                // llmSessionID kept for stateful continuation via previous_response_id
            }
        }
    }

    func setLastErrorMessageForUI(_ message: String) {
        orchestrator?.setLastErrorMessageForUI(message)
    }

    // MARK: - Private

    /// Resolve the team for this task — see `TeamResolution.resolve` for the full
    /// order. The critical property for the engine: a STARTED run is pinned to
    /// its `Run.teamID`, so a team deleted mid-run produces a loud `nil` (→
    /// engine `.failed`) rather than silently swapping in `activeTeam` and
    /// commingling a second roster into the live run. Child tasks still fail-fast
    /// (no parent `activeTeam` inheritance — spec #91 Coding Agent self-recursion).
    private var resolvedTeam: Team? {
        guard let task = activeTask else { return nil }
        switch TeamResolution.resolve(
            task: task,
            teamProvider: { orchestrator?.workFolder?.team(withID: $0) },
            activeTeam: orchestrator?.workFolder?.activeTeam
        ) {
        case .resolved(let team):
            return team
        case .failed(let reason):
            // Engine path: surface the diagnostic loudly; nil → engine `.failed`.
            orchestrator?.lastErrorMessage = reason
            return nil
        case .noTeam:
            return nil
        }
    }
    nonisolated deinit {}
}
