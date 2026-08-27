import Foundation

/// One owner for the question "is this role actually on the team's roster", and for the orphan
/// statuses left behind when it stops being.
///
/// ## The defect this closes (D-13, 2026-08-25)
///
/// `requestRevision` wrote `roleStatuses[roleID] = .revisionRequested` for any role id it was
/// handed, and `restartRole` `reset()` a step for any role that HAD one. Neither checked the
/// roster. The reachable trigger is deleting a role in the Team Editor while a non-closed task
/// is still pinned to that team — `switchTeam` is clean, because it already deletes non-roster
/// steps and re-seeds `roleStatuses`.
///
/// The orphan status does not merely go unread; it makes two completion readers DISAGREE.
/// `TeamEngine.allRolesComplete` goes through `Run.activeWorkRoleIDs`, which iterates
/// `definitions`, so the orphan is invisible and the run retires `.done`. But
/// `NTMSTask.derivedStatusFromActiveRun`'s `.done` arm reads `run.roleStatuses.values` RAW, and
/// the orphan is not complete, so the task reads "Working" forever behind a finished engine
/// with nothing running. One fact, two homes (#91), and the Supervisor and the Autovisor were
/// both told `ok: true`.
///
/// `restartRole`'s missing guard is the destructive one: it finds the step, `reset()`s it —
/// destroying the conversation, tool calls and artifacts — then reports success for a role the
/// engine can never start again.
///
/// Foundation-only and `nonisolated`, so `StatusRecoveryService` can use it.
nonisolated enum RoleRosterGuard {

    /// `nil` when the role is on the roster; otherwise the refusal to report to whoever asked.
    ///
    /// Resolution goes through `Team.findRole(byIdentifier:)` so this agrees with
    /// `findOrCreateStep` about what counts as the same role — a stricter check here would
    /// refuse the snake_case identifiers the LLM legitimately produces.
    static func refusal(roleID: String, team: Team) -> String? {
        guard team.findRole(byIdentifier: roleID) == nil else { return nil }
        return "Role “\(roleID)” is not on team “\(team.name)”. It may have been removed from "
            + "the team while this task was running. Call task_status to see the current roster."
    }

    /// Role-status keys whose role is no longer on the roster.
    ///
    /// Returns `[]` for a `nil` roster, and that is the whole third state (#97): "the team could
    /// not be resolved" is not "the team has no roles". Treating them alike would strip every
    /// role status from every task pinned to a deleted team, which reads as Done.
    ///
    /// The Supervisor is excluded because it is the user, never a roster entry.
    static func orphanRoleIDs(
        roleStatuses: [String: RoleExecutionStatus],
        team: Team?
    ) -> [String] {
        guard let team else { return [] }
        return roleStatuses.keys
            .filter { $0 != Role.supervisor.id }
            .filter { team.findRole(byIdentifier: $0) == nil }
            .sorted()
    }
}
