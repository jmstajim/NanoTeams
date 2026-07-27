import Foundation

/// Reconciles task state after an app restart.
///
/// When the app closes while a task is running, its steps and role statuses persist in
/// their "active" states with no engine backing them. This service brings them back to
/// honest values — which means BOTH parking genuinely-interrupted work AND settling work
/// that actually finished but whose role status never caught up.
///
/// The second half matters because role and step status are written by two different
/// subsystems in two separate `mutateTask` calls (`finalizeStepCompletion` writes the
/// step; the engine writes the role later, via `waitForStepCompletion`'s 250 ms poll).
/// Any interruption in between — a quit inside the poll gap, a `pauseRun` (which cancels
/// the engine's `roleTasks` and never touches role statuses), a `stopAllEngines()` on
/// work-folder switch — persists a TORN pair. Blindly demoting the role to `.idle` there
/// used to make the tear permanent: every engine reconciler gates on the role's own
/// status, `derivedStatusFromActiveRun` then took its "roles still working" arm forever,
/// and every Supervisor review affordance disappeared.
///
/// The role pass now routes through `RoleStepReconciler`, the single source of truth
/// shared with the engine, so a completed run survives a restart into a reviewable state
/// and any `task.json` already carrying a torn pair heals on the next launch.
nonisolated enum StatusRecoveryService {

    /// Transitions stale in-flight statuses to safe states and settles torn role↔step pairs.
    ///
    /// Call after loading a task from disk when no engine is running.
    /// - Steps in `.running` or `.needsSupervisorInput` → `.paused`
    /// - Roles whose step is terminal → the status `RoleStepReconciler` derives
    /// - Roles in `.working` whose step is genuinely mid-flight (or absent) → `.idle`
    ///
    /// - Parameter teamSettings: settings of the task's effective team, for the per-role
    ///   acceptance gate. Resolve via `TeamResolution.teamSettings(for:in:)`. Deliberately
    ///   has NO default value: a `= nil` default is exactly the "resolves outward
    ///   silently" trap of CLAUDE.md gotcha #49 — every call site must state where its
    ///   settings came from. See `AcceptanceService.Gate` for what `nil` means.
    /// - Returns: `true` if any changes were made.
    @discardableResult
    static func recoverStaleStatuses(
        in task: inout NTMSTask,
        teamSettings: TeamSettings?
    ) -> Bool {
        let gate = AcceptanceService.Gate(task: task, teamSettings: teamSettings)
        var changed = false
        // Tracked separately from `changed`: the `task.status = .paused` latch means
        // "a launch found work parked mid-flight". A pass that only settled a torn
        // TERMINAL pair interrupted nothing, so arming the latch there would be a lie —
        // and a durable one, since the latch permanently arms the guard in
        // `derivedStatusFromActiveRun`.
        var parked = false
        let activeRunIndex = task.runs.indices.last

        for runIndex in task.runs.indices {
            var runChanged = false

            // Recover stale step statuses. Runs FIRST so the role pass below reads the
            // rewritten values — a step just parked to `.paused` is non-terminal, which
            // is what keeps its `.working` role on the demote path.
            for stepIndex in task.runs[runIndex].steps.indices {
                let status = task.runs[runIndex].steps[stepIndex].status
                if status == .running || status == .needsSupervisorInput {
                    task.runs[runIndex].steps[stepIndex].status = .paused
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    runChanged = true
                    parked = true
                }
            }

            let stepMap = task.runs[runIndex].stepsByRoleBaseID()
            let isActiveRun = runIndex == activeRunIndex

            // Reconcile role statuses against their steps.
            for (roleID, roleStatus) in task.runs[runIndex].roleStatuses {
                switch RoleStepReconciler.outcome(
                    roleStatus: roleStatus,
                    stepStatus: stepMap[roleID]?.status,
                    gate: gate,
                    roleID: roleID
                ) {
                case .settle(let settled):
                    // Historical runs settle too — a `.done` step must not leave its role
                    // reading "Working" forever in the run-history graph, which is the
                    // same stale lie this service exists to remove. But NEVER to
                    // `.needsAcceptance`: `TeamBoardView` feeds `displayedRun` (which can
                    // be a historical run) into `ActivityFeedActionBar` un-gated on
                    // `isReadOnly`, while `acceptRole` writes to `runs.last` — an Accept
                    // card there would mutate a DIFFERENT run. A superseded run has no
                    // acceptance gate left to honour, so it collapses to `.done`.
                    let target: RoleExecutionStatus = isActiveRun || settled != .needsAcceptance
                        ? settled
                        : .done
                    guard target != roleStatus else { break }
                    task.runs[runIndex].roleStatuses[roleID] = target
                    runChanged = true

                case .inFlight:
                    guard roleStatus == .working else { break }
                    task.runs[runIndex].roleStatuses[roleID] = .idle
                    runChanged = true
                    parked = true

                case .noAction:
                    break
                }
            }

            if runChanged {
                task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
                changed = true
            }
        }

        if changed {
            task.updatedAt = MonotonicClock.shared.now()
        }
        if parked {
            task.status = .paused
        }

        return changed
    }
}
