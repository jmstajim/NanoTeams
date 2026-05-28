import Foundation

/// Service for task CRUD operations and task summaries.
@MainActor
final class TaskService {
    private let repository: any NTMSRepositoryProtocol

    init(repository: any NTMSRepositoryProtocol) {
        self.repository = repository
    }

    func createTask(
        at url: URL,
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID? = nil,
        parentTaskID: Int? = nil,
        parentRoleID: String? = nil,
        delegationDepth: Int = 0
    ) throws -> (snapshot: WorkFolderContext, taskID: Int) {
        try repository.createTask(
            at: url,
            title: title,
            supervisorTask: supervisorTask,
            preferredTeamID: preferredTeamID,
            parentTaskID: parentTaskID,
            parentRoleID: parentRoleID,
            delegationDepth: delegationDepth
        )
    }

    func switchTask(at url: URL, to taskID: Int?) throws -> WorkFolderContext {
        try repository.setActiveTask(at: url, taskID: taskID)
    }

    func removeTask(at url: URL, taskID: Int) throws -> WorkFolderContext {
        try repository.deleteTask(at: url, taskID: taskID)
    }

    /// Returns the visible task summaries for sidebar/watchtower lists.
    ///
    /// Child tasks created via `delegate_to_team` (`parentTaskID != nil`) are filtered
    /// out unconditionally — they exist only as internal state of the parent's tool call
    /// and are auto-accepted by the parent role, so they should not appear in any
    /// supervisor-facing list.
    func taskSummaries(from snapshot: WorkFolderContext?, filter: TaskFilter) -> [TaskSummary] {
        guard let tasks = snapshot?.tasksIndex.tasks else { return [] }
        let topLevelOnly = tasks.filter { $0.parentTaskID == nil }

        let filtered: [TaskSummary]
        switch filter {
        case .running:
            filtered = topLevelOnly.filter { $0.status != .done }
        case .done:
            filtered = topLevelOnly.filter { $0.status == .done }
        case .all:
            filtered = topLevelOnly
        }

        return filtered.sorted(by: { $0.updatedAt > $1.updatedAt })
    }
    nonisolated deinit {}
}
