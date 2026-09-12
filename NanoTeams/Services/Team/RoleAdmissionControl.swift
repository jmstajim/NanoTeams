import Foundation

// MARK: - Role Admission Control

/// Decides which of the roles the engine *could* dispatch this pass it *may* dispatch,
/// given the user's `RoleConcurrencyMode`.
///
/// A rule, not a mechanism — a sibling of `RoleStepReconciler` for the same reason: the
/// decision is a pure function of durable state, so it can be tested without an engine,
/// and there is exactly one place to read when asking "why did that role wait?".
///
/// ## What counts as holding a slot
///
/// **Not `.working`.** That looks like the obvious measure and is wrong in four separate
/// ways, each reachable today:
///
///  - The role that had `request_changes` approved is flagged `.revisionRequested` while
///    its own step deliberately keeps running (`holdDownstreamForRevision`). By `.working`
///    it is invisible, and a cap of one would hand out a second stream beside it.
///  - A role deleted from the roster mid-run keeps its `.working` entry — `StatusRecoveryService`
///    preserves it on purpose — and would eat the only slot forever. Hence the walk is over
///    the ROSTER, exactly like `Run.activeWorkRoleIDs`, never over the status dictionary.
///  - A role parked on `ask_supervisor`, or paused, is `.working` and holds nothing.
///  - A role suspended in `delegate_to_team` is `.working` with a `.running` step for as
///    long as the child task takes (up to 30 minutes) and is not touching the server —
///    counting it would deadlock the very template that delegates by design (Coding Agent).
///
/// So the measure is the STEP: a role holds a slot while its step is `.running` without an
/// `activeDelegationChildID`, plus the one window where the step does not exist yet (the
/// role is already `.working` between `updateRoleStatus` and `findOrCreateStep`).
///
/// A `.pending` step is deliberately NOT counted: it is a step that is not executing, and
/// the moment between creating one and running it is covered by the engine's own live-task
/// set, which it unions into `occupied` before calling `admit`.
///
/// A role waiting on a `bash` / computer-use approval card DOES hold its slot — its step is
/// `.running`. That is a decision, not an oversight (a human answers one question at a time
/// anyway), and `RoleAdmissionControlTests` pins it so the next reader does not "fix" it blind.
nonisolated enum RoleAdmissionControl {

    /// The roles of `roles` that currently hold an execution slot in `run`.
    static func occupiedRoleIDs(run: Run, roles: [TeamRoleDefinition]) -> Set<String> {
        let stepMap = run.stepsByRoleBaseID()
        var occupied: Set<String> = []

        for role in roles where !role.isSupervisor && !role.isObserver {
            guard let step = stepMap[role.id] else {
                // No step yet: only the freshly-flagged `.working` role is on its way to one.
                if run.roleStatuses[role.id] == .working { occupied.insert(role.id) }
                continue
            }
            guard step.activeDelegationChildID == nil else { continue }
            if step.status == .running { occupied.insert(role.id) }
        }

        return occupied
    }

    /// The candidates that may start, given who already holds a slot.
    ///
    /// - Parameters:
    ///   - candidates: roles the engine would dispatch this pass, in priority order
    ///     (roster order, so the same run makes the same choice twice).
    ///   - occupied: roles already holding a slot — `occupiedRoleIDs` unioned with whatever
    ///     in-flight bookkeeping the caller owns.
    ///   - limit: `nil` = the app imposes no limit and every candidate is admitted.
    /// - Returns: the admitted candidates, order preserved.
    ///
    /// A candidate that is ALREADY in `occupied` is admitted without spending a slot, because
    /// it is not asking for a new one — the commonest shape is a `.revisionRequested` role
    /// whose step is still `.running` after an app restart, which has to be re-entered on
    /// exactly the slot it already counts against. That is a capacity question; "is somebody
    /// already executing this role" is a different one, answered by the engine's own
    /// `hasLiveRoleTask` at each dispatch site, and conflating the two here would refuse to
    /// restart the very roles a restart exists for.
    static func admit(candidates: [String], occupied: Set<String>, limit: Int?) -> [String] {
        guard let limit else { return candidates }
        // `<= 0` is read as 1 rather than as "none": a cap of zero would admit nothing
        // forever, and the run loop would be left waiting for a slot that can never open.
        var free = max(0, max(1, limit) - occupied.count)
        var admitted: [String] = []
        for candidate in candidates {
            if occupied.contains(candidate) {
                admitted.append(candidate)
            } else if free > 0 {
                admitted.append(candidate)
                free -= 1
            }
        }
        return admitted
    }
}
