import XCTest

@testable import NanoTeams

/// Regression pins for the "Step 0" fix: `mutateTask`'s BACKGROUND branch must
/// refresh the in-memory `snapshot.tasksIndex` (not just `loadedTasks` + disk),
/// the same way the active branch does via `applyTaskUpdate`. Without it a
/// background-mutating task (recurrence/timeout firing, delegation, parallel
/// multi-task) shows a stale status label in the sidebar, and the scheduler's
/// in-memory index scan misses background recurrences.
@MainActor
final class MutateTaskBackgroundIndexTests: NTMSOrchestratorTestBase {

    func testBackgroundMutation_refreshesInMemoryTaskSummaryStatus() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB, "B is active; A is now a loaded background task")

        // Mutate the BACKGROUND task into a state whose derived status is .failed.
        await sut.mutateTask(taskID: idA) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .failed)],
                roleStatuses: ["a": .failed]
            )]
        }

        let summaryA = sut.taskSummaries(filter: .all).first { $0.id == idA }
        XCTAssertEqual(
            summaryA?.status, .failed,
            "background mutateTask must refresh the in-memory index — otherwise the sidebar label stays stale until a switchTask"
        )
    }

    func testBackgroundRecurrence_propagatesToInMemoryIndex() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")! // A → background
        let fire = Date().addingTimeInterval(3_600)

        await sut.mutateTask(taskID: idA) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: fire)
        }

        let summaryA = sut.snapshot?.tasksIndex.tasks.first { $0.id == idA }
        XCTAssertEqual(
            summaryA?.nextRecurrenceFireAt, fire,
            "a background task's recurrence must reach the in-memory index — the scheduler scans it with zero per-tick disk I/O"
        )
    }

    /// Set/clear symmetry: disabling a BACKGROUND task's recurrence must drop the
    /// badge from the in-memory index, exactly as enabling adds it. A path that
    /// refreshed on set-but-not-clear would leave a phantom "recurring" badge.
    func testBackgroundRecurrence_disable_dropsFromInMemoryIndex() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")! // A → background
        await sut.mutateTask(taskID: idA) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: Date().addingTimeInterval(3_600))
        }
        XCTAssertNotNil(sut.snapshot?.tasksIndex.tasks.first { $0.id == idA }?.nextRecurrenceFireAt, "sanity: badge present")

        await sut.mutateTask(taskID: idA) { $0.recurrence?.isEnabled = false }

        XCTAssertNil(
            sut.snapshot?.tasksIndex.tasks.first { $0.id == idA }?.nextRecurrenceFireAt,
            "disabling a background recurrence must drop the badge from the in-memory index (set/clear symmetry)"
        )
    }

    /// `createNewRun` is the *other* background write path (alongside `mutateTask`).
    /// It must refresh the in-memory index summary too — otherwise a just-restarted
    /// background task (recurrence fire, parallel multi-task start) shows a stale
    /// sidebar status until the next `mutateTask` happens to refresh it. (Review M5.)
    func testCreateNewRun_backgroundTask_refreshesInMemoryIndexSummary() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")! // A → background
        // Put A's index summary into a recognizable stale state first.
        await sut.mutateTask(taskID: idA) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "a", role: .custom(id: "a"), title: "C", status: .failed)],
                roleStatuses: ["a": .failed]
            )]
        }
        XCTAssertEqual(sut.taskSummaries(filter: .all).first { $0.id == idA }?.status, .failed, "sanity: index shows the failed run")

        await sut.createNewRun(taskID: idA)

        let loaded = sut.loadedTask(idA)!
        let summary = sut.snapshot?.tasksIndex.tasks.first { $0.id == idA }
        XCTAssertNotEqual(summary?.status, .failed, "the fresh run must supersede the stale .failed status in the index")
        XCTAssertEqual(summary?.status, loaded.toSummary().status, "index summary status must track the loaded task after createNewRun")
        XCTAssertEqual(summary?.updatedAt, loaded.updatedAt, "index summary must be the loaded task's summary, not a stale copy")
    }
}
