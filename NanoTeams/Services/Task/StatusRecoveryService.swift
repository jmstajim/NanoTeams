import Foundation

/// Recovers stale task statuses after app restart.
///
/// When the app closes while tasks are running, steps and role statuses
/// persist in their "active" states (`.running`, `.working`) with no engine
/// backing them. This service transitions those statuses to safe states.
enum StatusRecoveryService {

    /// Transitions stale in-flight statuses to safe states.
    ///
    /// Call after loading a task from disk when no engine is running.
    /// - Steps in `.running` or `.needsSupervisorInput` → `.paused`
    /// - Roles in `.working` → `.idle`
    /// - Returns `true` if any changes were made.
    @discardableResult
    static func recoverStaleStatuses(in task: inout NTMSTask) -> Bool {
        var changed = false

        for runIndex in task.runs.indices {
            var runChanged = false

            // Recover stale step statuses
            for stepIndex in task.runs[runIndex].steps.indices {
                let status = task.runs[runIndex].steps[stepIndex].status
                if status == .running || status == .needsSupervisorInput {
                    task.runs[runIndex].steps[stepIndex].status = .paused
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    runChanged = true
                }
            }

            // Recover stale role statuses
            for (roleID, roleStatus) in task.runs[runIndex].roleStatuses {
                if roleStatus == .working {
                    task.runs[runIndex].roleStatuses[roleID] = .idle
                    runChanged = true
                }
            }

            if runChanged {
                task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
                changed = true
            }
        }

        if changed {
            task.updatedAt = MonotonicClock.shared.now()
            task.status = .paused
        }

        return changed
    }
}
