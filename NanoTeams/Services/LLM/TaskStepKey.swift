import Foundation

/// Uniquely identifies one step execution across concurrently running tasks.
///
/// `StepExecution.id` alone is NOT globally unique — it equals the team role ID
/// (`TeamRoleDefinition.id`), so two tasks running the same team carry identical
/// stepID strings. Any runtime registry keyed by the bare stepID lets one task's
/// flow address (and destroy) another task's state: pausing/restarting task B
/// cancelled task A's live LLM execution, and streaming previews overwrote each
/// other. Every per-step runtime dictionary (`LLMExecutionService.executionStates`,
/// `StreamingPreviewManager` state) must key by this composite instead.
///
/// No `runID` component by design: runs are serial within a task (a fresh `Run`
/// supersedes the previous one and a task has one `TeamEngine`), so at most one
/// live execution exists per (task, step) at any moment. If overlapping runs ever
/// become possible, this key needs a `runID` or the collision class returns.
nonisolated struct TaskStepKey: Hashable, Sendable {
    let taskID: Int
    let stepID: String
}
