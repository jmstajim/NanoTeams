import XCTest
@testable import NanoTeams

/// The Autovisor task is a real top-level task but must NEVER surface in any
/// supervisor-facing task list, and must never be auto-selected as the fallback
/// active task. Both exclusions key off `WorkFolderState.autovisorTaskID`.
///
/// Test methods are `async` so the `@MainActor` sync-test → `abort()` CI pitfall
/// (constructing `TaskService` / `NTMSRepository` classes in-body) can't bite.
@MainActor
final class AutovisorExclusionTests: XCTestCase {

    private func context(managerID: Int?, summaries: [TaskSummary]) -> WorkFolderContext {
        var index = TasksIndex()
        index.tasks = summaries
        return WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "WF", autovisorTaskID: managerID),
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

    // MARK: - taskSummaries

    func testTaskSummaries_excludesManager_allFilters() async {
        let manager = TaskSummary(id: 0, title: "Autovisor", status: .running, isChatMode: true, parentTaskID: nil)
        let normal = TaskSummary(id: 1, title: "Real", status: .running, isChatMode: false, parentTaskID: nil)
        let ctx = context(managerID: 0, summaries: [manager, normal])
        let service = TaskService(repository: NTMSRepository())

        for filter in TaskFilter.allCases {
            let visible = service.taskSummaries(from: ctx, filter: filter)
            XCTAssertFalse(visible.contains { $0.id == 0 },
                           "Autovisor must be hidden for filter=\(filter)")
        }
    }

    func testTaskSummaries_keepsNormalTasks_whenManagerNotSet() async {
        let normal = TaskSummary(id: 1, title: "Real", status: .running, isChatMode: false, parentTaskID: nil)
        let ctx = context(managerID: nil, summaries: [normal])
        let service = TaskService(repository: NTMSRepository())
        XCTAssertEqual(service.taskSummaries(from: ctx, filter: .all).map(\.id), [1])
    }

    // MARK: - pickFallbackActiveTaskID

    func testPickFallback_skipsManager() async {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 0, title: "Autovisor", status: .running, parentTaskID: nil),
            TaskSummary(id: 1, title: "Real", status: .done, parentTaskID: nil),
        ]
        let repo = NTMSRepository()
        // Without exclusion the manager (in-progress) would be chosen…
        XCTAssertEqual(repo.pickFallbackActiveTaskID(from: index, excluding: nil), 0)
        // …with exclusion it falls through to the real (done) task instead.
        XCTAssertEqual(repo.pickFallbackActiveTaskID(from: index, excluding: 0), 1)
    }

    func testPickFallback_excludesChildTasks() async {
        var index = TasksIndex()
        index.tasks = [
            TaskSummary(id: 5, title: "Child", status: .running, parentTaskID: 1),
            TaskSummary(id: 1, title: "Top", status: .done, parentTaskID: nil),
        ]
        let repo = NTMSRepository()
        XCTAssertEqual(repo.pickFallbackActiveTaskID(from: index, excluding: nil), 1,
                       "delegation children are never a fallback active task")
    }
}
