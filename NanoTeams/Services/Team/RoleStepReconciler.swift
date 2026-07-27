import Foundation

// MARK: - Role ↔ Step Reconciliation

/// The single rule for deriving a role's status from its step's status.
///
/// `RoleExecutionStatus` and `StepStatus` are two encodings of one fact, written by two
/// different subsystems in two separate `mutateTask` calls: `finalizeStepCompletion`
/// writes the step (`.done` / `.needsApproval` / `.failed`), and the engine writes the
/// role later, when `waitForStepCompletion`'s 250 ms poll or the run loop's reconcile pass
/// notices. Any interruption between the two — a quit inside the poll gap, a `pauseRun`
/// (which cancels the engine's `roleTasks` but never touches role statuses), a
/// `stopAllEngines()` on work-folder switch — persists a TORN pair to `task.json`.
///
/// Before this type existed the mapping lived in three places that all gated on
/// `roleStatus == .working` (the run loop's reconcile pass, `reconcileAfterPause`, and
/// `handleRoleCompleted`), while `StatusRecoveryService` moved the pair the OTHER way
/// (`.working` → `.idle`) at every launch. The demotion was therefore one-way: no
/// reconciler would look at the role again, `derivedStatusFromActiveRun` took its
/// "roles still working" arm forever, and every Supervisor review affordance vanished
/// (they all reduce to `NTMSTask.isReadyForFinalAcceptance`).
///
/// The gate is now on the ROLE's own status, not on `.working` alone, so a role parked at
/// `.idle` / `.ready` next to a terminal step is healed by whichever consumer sees it
/// first — including status recovery at launch, which is what makes an already-broken
/// `task.json` self-heal with no migration.
nonisolated enum RoleStepReconciler {

    /// What a consumer should do about one (role, step) pair.
    enum Outcome: Equatable {
        /// The step reached a terminal status and the role has not recorded it yet —
        /// write the carried status.
        case settle(RoleExecutionStatus)

        /// The step is genuinely mid-flight (`.running` / `.paused` / `.pending` /
        /// `.needsSupervisorInput`) or the role has no step at all. Consumers differ on
        /// what to do: the engine may restart the step, status recovery parks the role
        /// at `.idle`.
        case inFlight

        /// Never write: the pair already agrees, or the role holds a status this rule
        /// must not overwrite.
        case noAction
    }

    /// - Parameters:
    ///   - roleStatus: `nil` is read as `.idle`, matching `Run.activeWorkRoleIDs`'
    ///     `?? .idle` convention for a role with no entry yet.
    ///   - stepStatus: `nil` means the role has no step in this run.
    ///   - gate: whether a completed role needs a per-role Supervisor acceptance.
    static func outcome(
        roleStatus: RoleExecutionStatus?,
        stepStatus: StepStatus?,
        gate: AcceptanceService.Gate,
        roleID: String
    ) -> Outcome {
        switch roleStatus ?? .idle {
        case .needsAcceptance:
            // A LIVE Supervisor gate. Re-deriving it under `.finalOnly` would rewrite it
            // to `.done` — a silent acceptance on the Supervisor's behalf, and an
            // unrecoverable one: `AcceptanceService.validateAcceptance` then rejects the
            // role with "Role already completed", leaving only `restartRole` (which wipes
            // the step) as a way back.
            return .noAction

        case .revisionRequested:
            // `resetStepForRevision` writes `.pending`, so between the request and the
            // reset this role legitimately sits next to a still-`.done` step. Re-deriving
            // would erase the revision flag. Pinned by
            // `TeamEngineTests.testHandleRoleCompleted_skipsWhenRoleRevisionRequested`.
            return .noAction

        case .done, .accepted, .skipped:
            // Terminal. This arm is also what keeps `handleRoleCompleted` idempotent
            // between the run loop's reconcile pass and `waitForStepCompletion`.
            return .noAction

        case .failed:
            // A recorded failure is never healed into a success. `resumeRun`'s revival
            // branch owns the `.failed` → retry transition.
            return .noAction

        case .idle, .ready, .working:
            break
        }

        switch stepStatus {
        case .done:
            return .settle(gate.requestsAcceptance(roleID: roleID) ? .needsAcceptance : .done)
        case .needsApproval:
            // The step itself already says "a Supervisor must look at this" — no
            // acceptance-mode lookup needed.
            return .settle(.needsAcceptance)
        case .failed:
            return .settle(.failed)
        case .running, .paused, .pending, .needsSupervisorInput, nil:
            return .inFlight
        }
    }
}
