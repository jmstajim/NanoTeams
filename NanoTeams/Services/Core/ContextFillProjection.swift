import Foundation
import Observation

/// How full each step's context window is, and which steps are compacting right now.
///
/// A projection of its own rather than two more fields on `NTMSOrchestrator`, for the reason
/// `TaskFactsProjection` exists: a view that reads the orchestrator's `snapshot` is a
/// PER-EVENT root — `applyTaskUpdate` rewrites it on every `mutateTask`, i.e. on every LLM
/// delta and every tool result — and the composer's chip row would then re-evaluate at that
/// rate to render a number that changes once per REQUEST. Observation tracks per property, so
/// reading `store.contextFill.fillByStep` registers this object and nothing else.
///
/// Keyed by `TaskStepKey` alone (multi-task invariant #5): `StepExecution.id` equals the team
/// role ID, so two concurrent tasks on the same team share step ids and a stepID-keyed map
/// would have them overwrite each other's fills.
@Observable
@MainActor
final class ContextFillProjection {

    /// The last measured fill per step. Absent until a step's first response — the indicator
    /// hides rather than inventing a number.
    private(set) var fillByStep: [TaskStepKey: ContextFill] = [:]

    /// Steps with a compaction epoch in flight. The indicator SHOWS it (a flat grey at the last
    /// measured length); what refuses a second click is the service —
    /// `compactRoleContext` reads `LLMExecutionService.isCompacting`, not this projection,
    /// because a mirror can only be equal to the fact or behind it.
    private(set) var compactingKeys: Set<TaskStepKey> = []

    /// Records a fill, skipping the write when nothing changed — an identical assignment
    /// still notifies every observer of this property.
    func update(stepID: String, taskID: Int, fill: ContextFill) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard fillByStep[key] != fill else { return }
        fillByStep[key] = fill
    }

    func setCompacting(stepID: String, taskID: Int, _ isCompacting: Bool) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if isCompacting {
            guard !compactingKeys.contains(key) else { return }
            compactingKeys.insert(key)
        } else {
            guard compactingKeys.contains(key) else { return }
            compactingKeys.remove(key)
        }
    }

    func fill(stepID: String, taskID: Int) -> ContextFill? {
        fillByStep[TaskStepKey(taskID: taskID, stepID: stepID)]
    }

    func isCompacting(stepID: String, taskID: Int) -> Bool {
        compactingKeys.contains(TaskStepKey(taskID: taskID, stepID: stepID))
    }

    /// Seeds from what a task persisted, so a step that is merely LOADED — not running —
    /// still shows its last known fill. Only the latest run: earlier runs' steps are history,
    /// and their fills describe conversations that no longer drive anything.
    func seed(from task: NTMSTask) {
        guard let run = task.runs.last else { return }
        for step in run.steps {
            guard let fill = step.contextFill else { continue }
            let key = TaskStepKey(taskID: task.id, stepID: step.id)
            if fillByStep[key] != fill { fillByStep[key] = fill }
        }
    }

    /// Drops everything for one task — a new run, a role restart, or a task that left memory.
    /// The fills described conversations that were just discarded.
    func removeTask(_ taskID: Int) {
        let doomed = fillByStep.keys.filter { $0.taskID == taskID }
        for key in doomed { fillByStep[key] = nil }
        let doomedCompacting = compactingKeys.filter { $0.taskID == taskID }
        for key in doomedCompacting { compactingKeys.remove(key) }
    }

    /// Drops one step's fill — `restartRole` resets the step, so the number it showed
    /// describes a conversation that no longer exists.
    func removeStep(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        fillByStep[key] = nil
        compactingKeys.remove(key)
    }

    func clear() {
        guard !fillByStep.isEmpty || !compactingKeys.isEmpty else { return }
        fillByStep = [:]
        compactingKeys = []
    }
}
