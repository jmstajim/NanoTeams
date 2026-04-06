import Foundation

/// Service for run creation and management.
enum RunService {
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

        task.runs.append(run)
        task.updatedAt = MonotonicClock.shared.now()

        return run
    }

    static func activeRunID(from task: NTMSTask?) -> Int? {
        task?.runs.last?.id
    }

    static func selectedRunSnapshot(from task: NTMSTask?, selectedRunID: Int?) -> Run? {
        guard let task else { return nil }
        if let selectedRunID, let run = task.runs.first(where: { $0.id == selectedRunID }) {
            return run
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
