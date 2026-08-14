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

            // Phantom role entries for the synthetic generation step. `restartRole` writes
            // `roleStatuses["team_generation_<uuid>"]` for an id that no roster contains,
            // so removing them is unconditionally correct — and REQUIRED before the role
            // pass below, which would otherwise reconcile the phantom against the step and
            // settle it, after which `resumeRun`'s failed-step revival would call
            // `runStep` on a step belonging to no team.
            let phantomRoleIDs = task.runs[runIndex].roleStatuses.keys.filter {
                $0.hasPrefix(StepExecution.teamGenerationIDPrefix)
            }
            for roleID in phantomRoleIDs {
                task.runs[runIndex].roleStatuses.removeValue(forKey: roleID)
                runChanged = true
            }

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
                    continue
                }
                // A DESTROYED team-generation record. `runTeamGeneration` drives its
                // synthetic step `.running` → `.done` / `.failed` / `.paused`, and
                // `retryTeamGeneration` deletes rather than resets — so `.pending` there
                // has exactly one writer, `StepExecution.reset()` via `restartRole`. It
                // means the record was destroyed and nothing will ever advance it, while
                // `Run.derivedTaskStatus()` reads it as work still to come and pins the
                // task at `.running` forever: invisible to the Autovisor's triage, which
                // has no `running` bullet.
                //
                // Park it like any other interrupted work rather than failing it.
                // `resumeRun` re-enters generation for a task that still needs one, so
                // `.paused` is TRUE here and both remedies the manager is told about
                // (`control_task resume`, the pane's Retry) do the same thing. `.failed`
                // would instead hide the toolbar control entirely
                // (`TeamBoardRunControl.select` returns nil for it), split this shape from
                // the cancelled/parked one that is already `.paused`, and steer the
                // manager to a bullet that offers `control_task delete`. A retry that
                // fails again writes `.failed` on its own.
                //
                // With a team already adopted there is nothing left to generate, so the
                // record settles `.done` — otherwise `allDone` can never be true and the
                // task never reaches Review.
                if status == .pending, task.runs[runIndex].steps[stepIndex].isTeamGenerationStep {
                    task.runs[runIndex].steps[stepIndex].status =
                        task.generatedTeam == nil ? .paused : .done
                    task.runs[runIndex].steps[stepIndex].completedAt = MonotonicClock.shared.now()
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    runChanged = true
                    // Deliberately NOT `parked`: the latch means "a launch found work
                    // mid-flight", and nothing was interrupted here. The step's own
                    // `.paused` already drives the derived status.
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
