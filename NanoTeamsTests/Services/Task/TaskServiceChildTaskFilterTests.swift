import XCTest
@testable import NanoTeams

/// User-path: child tasks (created via `delegate_to_team`) must NEVER appear in
/// the sidebar/watchtower. They exist only as internal state of the parent's
/// delegate_to_team tool call. The filter lives at `TaskService.taskSummaries(...)`.
@MainActor
final class TaskServiceChildTaskFilterTests: XCTestCase {

    private func makeContext(summaries: [TaskSummary]) -> WorkFolderContext {
        var index = TasksIndex()
        index.tasks = summaries
        return WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "WF"),
                settings: ProjectSettings(),
                teams: []
            ),
            tasksIndex: index,
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil,
            loadedTasks: [:]
        )
    }

    // MARK: - Filter behavior

    func testTaskSummaries_excludesChildTasksFromAllFilters() {
        let topLevel = TaskSummary(id: 1, title: "Top", status: .running, isChatMode: false, parentTaskID: nil)
        let child = TaskSummary(id: 2, title: "Child", status: .running, isChatMode: false, parentTaskID: 1)
        let context = makeContext(summaries: [topLevel, child])
        let service = TaskService(repository: NTMSRepository())

        for filter in TaskFilter.allCases {
            let visible = service.taskSummaries(from: context, filter: filter)
            XCTAssertFalse(visible.contains(where: { $0.parentTaskID != nil }),
                           "Child tasks must be filtered out for filter=\(filter)")
        }
    }

    func testTaskSummaries_doesNotExcludeTopLevelTasksWithChildren() {
        // Top-level "Done" task that itself has children (we only filter children, not parents).
        let parent = TaskSummary(id: 1, title: "Parent", status: .done, isChatMode: false, parentTaskID: nil)
        let child = TaskSummary(id: 2, title: "Child", status: .done, isChatMode: false, parentTaskID: 1)
        let context = makeContext(summaries: [parent, child])
        let service = TaskService(repository: NTMSRepository())

        let done = service.taskSummaries(from: context, filter: .done)
        XCTAssertEqual(done.map(\.id), [1], "Parent task should remain visible; only its child is filtered.")
    }

    // MARK: - Empty/edge cases

    func testTaskSummaries_emptyIndex() {
        let context = makeContext(summaries: [])
        let service = TaskService(repository: NTMSRepository())
        XCTAssertTrue(service.taskSummaries(from: context, filter: .all).isEmpty)
    }

    func testTaskSummaries_onlyChildTasks_returnsEmpty() {
        // Hypothetical: a parent was deleted but child summaries lingered. We still
        // hide them rather than render orphans.
        let child1 = TaskSummary(id: 2, title: "Orphan 1", status: .running, parentTaskID: 99)
        let child2 = TaskSummary(id: 3, title: "Orphan 2", status: .done, parentTaskID: 99)
        let context = makeContext(summaries: [child1, child2])
        let service = TaskService(repository: NTMSRepository())
        XCTAssertTrue(service.taskSummaries(from: context, filter: .all).isEmpty,
                      "Orphan child summaries are still hidden — Supervisor never sees delegated tasks directly.")
    }
}
