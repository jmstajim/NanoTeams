import Foundation

/// Service for task CRUD operations and task summaries.
@MainActor
final class TaskService {
    private let repository: any NTMSRepositoryProtocol

    init(repository: any NTMSRepositoryProtocol) {
        self.repository = repository
    }

    func createTask(at url: URL, title: String, supervisorTask: String, preferredTeamID: NTMSID? = nil) throws -> WorkFolderContext {
        try repository.createTask(at: url, title: title, supervisorTask: supervisorTask, preferredTeamID: preferredTeamID)
    }

    func switchTask(at url: URL, to taskID: Int?) throws -> WorkFolderContext {
        try repository.setActiveTask(at: url, taskID: taskID)
    }

    func removeTask(at url: URL, taskID: Int) throws -> WorkFolderContext {
        try repository.deleteTask(at: url, taskID: taskID)
    }

    func taskSummaries(from snapshot: WorkFolderContext?, filter: TaskFilter) -> [TaskSummary] {
        guard let tasks = snapshot?.tasksIndex.tasks else { return [] }

        let filtered: [TaskSummary]
        switch filter {
        case .running:
            filtered = tasks.filter { $0.status != .done }
        case .done:
            filtered = tasks.filter { $0.status == .done }
        case .all:
            filtered = tasks
        }

        return filtered.sorted(by: { $0.updatedAt > $1.updatedAt })
    }
}
