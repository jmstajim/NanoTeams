import XCTest
@testable import NanoTeams

/// Tests for TasksIndex, TaskSummary, and NTMSTask conversion methods
final class TaskIndexTests: XCTestCase {

    // MARK: - TasksIndex Initialization Tests

    func testTasksIndexDefaultValues() {
        let index = TasksIndex()

        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertTrue(index.tasks.isEmpty)
    }

    func testTasksIndexWithTasks() {
        let summary = TaskSummary(id: 0, title: "Test Task", status: .running)
        let index = TasksIndex(schemaVersion: 2, tasks: [summary])

        XCTAssertEqual(index.schemaVersion, 2)
        XCTAssertEqual(index.tasks.count, 1)
    }

    // MARK: - TasksIndex Hashable Tests

    func testTasksIndexHashable() {
        let summary = TaskSummary(id: 0, title: "Test", status: .done)
        let index1 = TasksIndex(schemaVersion: 1, tasks: [summary])
        let index2 = TasksIndex(schemaVersion: 1, tasks: [summary])

        XCTAssertEqual(index1, index2)
    }

    // MARK: - TaskSummary Tests

    func testTaskSummaryInitialization() {
        let id = 42
        let date = Date()
        let summary = TaskSummary(id: id, title: "Test Task", status: .done, updatedAt: date)

        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.title, "Test Task")
        XCTAssertEqual(summary.status, .done)
        XCTAssertEqual(summary.updatedAt, date)
    }

    func testTaskSummaryDefaultUpdatedAt() {
        let before = MonotonicClock.shared.now()
        let summary = TaskSummary(id: 0, title: "Test", status: .running)
        let after = MonotonicClock.shared.now()

        XCTAssertGreaterThanOrEqual(summary.updatedAt, before)
        XCTAssertLessThanOrEqual(summary.updatedAt, after)
    }

    func testTaskSummaryIdentifiable() {
        let id = 42
        let summary = TaskSummary(id: id, title: "Test", status: .running)

        XCTAssertEqual(summary.id, id)
    }

    func testTaskSummaryHashable() {
        let id = 42
        let date = Date()
        let summary1 = TaskSummary(id: id, title: "Test", status: .running, updatedAt: date)
        let summary2 = TaskSummary(id: id, title: "Test", status: .running, updatedAt: date)

        var summarySet = Set<TaskSummary>()
        summarySet.insert(summary1)
        summarySet.insert(summary2)

        XCTAssertEqual(summarySet.count, 1)
    }

    // MARK: - NTMSTask.derivedStatusFromActiveRun Tests

    func testDerivedStatusWithNoRuns() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusWithEmptyRun() {
        let run = Run(id: 0, steps: [])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run])
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusWithFailedStep() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run])

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusWithNeedsSupervisorInputStep() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run])

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorInput)
    }

    func testDerivedStatusWithPausedStep() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .paused)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run])

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusAllStepsDoneWithoutClose() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .done)
        ]
        let run = Run(id: 0, steps: steps)
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run])

        // Without closedAt, all steps done → .needsSupervisorAcceptance
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    func testDerivedStatusAllStepsDoneWithClose() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .done)
        ]
        let run = Run(id: 0, steps: steps)
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run], closedAt: Date())

        // With closedAt set, all steps done → .done
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    func testDerivedStatusUsesLastRun() {
        let firstRun = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
        ])
        let lastRun = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        ])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [firstRun, lastRun])

        // Should use the last run's status
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusIgnoresPreviousRuns() {
        let failedRun = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        ])
        let doneRun = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
        ])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [failedRun, doneRun])

        // Should use the last (done) run, not the failed one. Without closedAt → .needsSupervisorAcceptance
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    // MARK: - NTMSTask.toSummary Tests

    func testToSummaryBasic() {
        let taskID = 0
        let task = NTMSTask(id: taskID, title: "Test Task", supervisorTask: "Goal", status: .running)
        let summary = task.toSummary()

        XCTAssertEqual(summary.id, taskID)
        XCTAssertEqual(summary.title, "Test Task")
        XCTAssertEqual(summary.status, .running)
    }

    func testToSummaryUsesDerivedStatus() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running, runs: [run])

        let summary = task.toSummary()

        // Summary should use derived status (failed), not persisted status (running)
        XCTAssertEqual(summary.status, .failed)
    }

    func testToSummaryPreservesUpdatedAt() {
        let taskID = 0
        let updateDate = Date(timeIntervalSince1970: 1000)
        let task = NTMSTask(id: taskID, title: "Test", supervisorTask: "Goal", updatedAt: updateDate)

        let summary = task.toSummary()

        XCTAssertEqual(summary.updatedAt, updateDate)
    }

    // MARK: - Multiple Tasks in Index

    func testTasksIndexWithMultipleTasks() {
        let summaries = [
            TaskSummary(id: 0, title: "Task 1", status: .running),
            TaskSummary(id: 0, title: "Task 2", status: .done),
            TaskSummary(id: 0, title: "Task 3", status: .failed)
        ]
        let index = TasksIndex(tasks: summaries)

        XCTAssertEqual(index.tasks.count, 3)
    }

    func testFilteringTasksByStatus() {
        let summaries = [
            TaskSummary(id: 0, title: "Task 1", status: .running),
            TaskSummary(id: 0, title: "Task 2", status: .done),
            TaskSummary(id: 0, title: "Task 3", status: .running),
            TaskSummary(id: 0, title: "Task 4", status: .failed)
        ]
        let index = TasksIndex(tasks: summaries)

        let runningTasks = index.tasks.filter { $0.status == .running }
        let doneTasks = index.tasks.filter { $0.status == .done }
        let failedTasks = index.tasks.filter { $0.status == .failed }

        XCTAssertEqual(runningTasks.count, 2)
        XCTAssertEqual(doneTasks.count, 1)
        XCTAssertEqual(failedTasks.count, 1)
    }

    func testFindingTaskById() {
        let targetID = 99
        let summaries = [
            TaskSummary(id: 1, title: "Task 1", status: .running),
            TaskSummary(id: targetID, title: "Target Task", status: .done),
            TaskSummary(id: 3, title: "Task 3", status: .failed)
        ]
        let index = TasksIndex(tasks: summaries)

        let found = index.tasks.first { $0.id == targetID }

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Target Task")
    }

    func testSortingTasksByUpdatedAt() {
        let oldDate = Date(timeIntervalSince1970: 1000)
        let midDate = Date(timeIntervalSince1970: 2000)
        let newDate = Date(timeIntervalSince1970: 3000)

        let summaries = [
            TaskSummary(id: 0, title: "Old Task", status: .done, updatedAt: oldDate),
            TaskSummary(id: 0, title: "New Task", status: .running, updatedAt: newDate),
            TaskSummary(id: 0, title: "Mid Task", status: .paused, updatedAt: midDate)
        ]
        let index = TasksIndex(tasks: summaries)

        let sorted = index.tasks.sorted { $0.updatedAt > $1.updatedAt }

        XCTAssertEqual(sorted[0].title, "New Task")
        XCTAssertEqual(sorted[1].title, "Mid Task")
        XCTAssertEqual(sorted[2].title, "Old Task")
    }

    // MARK: - TaskSummary Status Display

    func testTaskSummaryStatusDisplayLabels() {
        let statuses: [(TaskStatus, String)] = [
            (.running, "Working"),
            (.done, "Done"),
            (.paused, "Paused"),
            (.needsSupervisorInput, "Needs Supervisor"),
            (.needsSupervisorAcceptance, "Review"),
            (.failed, "Failed")
        ]

        for (status, expectedLabel) in statuses {
            let summary = TaskSummary(id: 0, title: "Test", status: status)
            XCTAssertEqual(summary.status.displayLabel, expectedLabel)
        }
    }
}
