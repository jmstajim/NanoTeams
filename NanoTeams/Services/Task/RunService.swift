import Foundation

/// Service for run creation and management.
nonisolated enum RunService {
    /// Computes initial role execution statuses for a set of roles.
    /// Supervisor → `.done`, no dependencies → `.ready`, otherwise → `.idle`.
    static func initialRoleStatuses(for roles: [TeamRoleDefinition]) -> [String: RoleExecutionStatus] {
        var statuses: [String: RoleExecutionStatus] = [:]
        for role in roles {
            if role.isSupervisor {
                statuses[role.id] = .done
            } else if role.dependencies.requiredArtifacts.isEmpty {
                statuses[role.id] = .ready
            } else {
                statuses[role.id] = .idle
            }
        }
        return statuses
    }

    /// Creates a fresh run for a task based on team roles.
    /// Steps are created on-demand by TeamEngine as roles become ready.
    static func createTeamRun(
        task: inout NTMSTask,
        team: Team
    ) -> Run {
        let roleStatuses = initialRoleStatuses(for: team.roles)

        let run = Run(
            id: task.runs.count,
            steps: [],  // Steps created on-demand by TeamEngine
            roleStatuses: roleStatuses,
            teamID: team.id
        )

        task.runs.append(run) // run-id:allow-runs-mutation THE appender — id == count is the invariant
        task.updatedAt = MonotonicClock.shared.now()

        return run
    }

    static func activeRunID(from task: NTMSTask?) -> Int? {
        task?.runs.last?.id
    }

    /// O(1) by-id lookup. Rests on the invariant THIS file establishes: `createTeamRun` is
    /// the sole appender (`id: task.runs.count` + `task.runs.append(run)` above), nothing
    /// removes, reorders or writes a whole element of `runs` (pinned tree-wide by
    /// `Ratchet/RunIDIsPositionPinTests`; edits go through `mutateActiveRun` below), and
    /// `Run.id` is `let`. The `runs[runID].id == runID` compare is redundant under the
    /// invariant; on a malformed or legacy array it degrades to "absent" — the arm every
    /// caller already has for an unknown id — and can never answer "present" for a run that
    /// is not there (`RunServiceTests.testRunIndex_malformedArray_neverAnswersPresentForAMissingRun`).
    static func runIndex(in task: NTMSTask, runID: Int) -> Int? {
        guard task.runs.indices.contains(runID), task.runs[runID].id == runID else { return nil }
        return runID
    }

    /// Edits the newest run IN PLACE; `false` (body not run) when the task has no runs.
    ///
    /// The orchestrator sites that edit the active run (`acceptRole`, `finishAdvisoryRoleAwaiting`,
    /// `closeTask`, `switchTeam`) used to copy it out (`guard var run = task.runs.last`), mutate
    /// the copy and store it back with `task.runs[task.runs.count - 1] = run`. That whole-element
    /// write is the one shape `Run.id` being `let` does not police: a run read from another slot,
    /// or built elsewhere, lands with the wrong id and `id == position` breaks silently. Through
    /// `inout` there is no copy to write back, so the array's ids cannot change here BY
    /// CONSTRUCTION rather than by a check — which is what lets the source pin forbid the
    /// `runs[i] = run` shape tree-wide instead of asserting at every site.
    @discardableResult
    static func mutateActiveRun(in task: inout NTMSTask, _ body: (inout Run) -> Void) -> Bool {
        guard let i = task.runs.indices.last else { return false }
        body(&task.runs[i])
        return true
    }

    static func selectedRunSnapshot(from task: NTMSTask?, selectedRunID: Int?) -> Run? {
        guard let task else { return nil }
        if let selectedRunID, let i = runIndex(in: task, runID: selectedRunID) {
            return task.runs[i]
        }
        return task.runs.last
    }

    static func isSelectedRunActive(task: NTMSTask?, selectedRunID: Int?) -> Bool {
        guard let selectedRun = selectedRunSnapshot(from: task, selectedRunID: selectedRunID) else {
            return false
        }
        return selectedRun.id == activeRunID(from: task)
    }

}
