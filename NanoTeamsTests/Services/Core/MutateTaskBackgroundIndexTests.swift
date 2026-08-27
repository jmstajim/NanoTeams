import XCTest

@testable import NanoTeams

/// Regression pins for the "Step 0" fix: `mutateTask`'s BACKGROUND branch must
/// refresh the in-memory `snapshot.tasksIndex` (not just `loadedTasks` + disk),
/// the same way the active branch does via `applyTaskUpdate`. Without it a
/// background-mutating task (recurrence/timeout firing, delegation, parallel
/// multi-task) shows a stale status label in the sidebar, and the scheduler's
/// in-memory index scan misses background recurrences.
@MainActor
final class MutateTaskBackgroundIndexTests: NTMSOrchestratorTestBase, @unchecked Sendable {

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

    // MARK: - createNewRun's persist failure

    /// A failed persist must SURFACE — the user presses Start, a run appears, and without a
    /// banner it would be gone on the next open with no explanation.
    ///
    /// Induced through the repository's own contract rather than permission games:
    /// `updateTaskOnly` throws `taskNotFound` when the task's `task.json` is absent, so
    /// deleting it while the task is still loaded in memory models exactly the "the store
    /// moved under us" condition the `catch` exists for.
    ///
    /// This arm was previously covered only BY ACCIDENT — some unrelated test happened to
    /// make a write fail — so it appeared and disappeared between coverage runs. Same
    /// treatment as `SearchIndexFailureCoverageTests`' persist arm: a number that oscillates
    /// is a number nobody trusts, and this one carries a real contract.
    ///
    /// **The in-memory half changed on 2026-08-27 and this test now pins the new semantics
    /// rather than the old.** `createNewRun` used to hand-roll its own persistence: build the
    /// run in a local copy, write it with a SYNCHRONOUS `repository.updateTaskOnly` on the
    /// MainActor, and commit to memory only on success — so a failed write left no run. It now
    /// goes through `mutateTask` like every other mutation, whose shape is prescribed by
    /// CLAUDE.md invariant #6: commit in memory synchronously, detach only the encode+write.
    /// The trade-off that invariant states explicitly — in-memory may be ahead of disk, and a
    /// disk failure surfaces a banner without rolling back — therefore now applies here too.
    ///
    /// That is a real change and it is pinned, not papered over: the rollback was never free
    /// either, since `startRun` continues to `engine.start()` regardless and the old behaviour
    /// left the engine running against a run the task no longer had. What matters to the user —
    /// that the failure is REPORTED — is unchanged, and is the first assertion below.
    ///
    /// RED: drop `self.lastErrorMessage = "Failed to save task: …"` from `mutateTask`'s catch →
    /// the first assertion fails and a broken store goes silent. RED: make `createNewRun`
    /// persist by hand again → the second assertion fails, naming the invariant it left.
    func testCreateNewRun_persistFailure_isReported_andKeepsTheInMemoryRun() async throws {
        await sut.openWorkFolder(tempDir)
        let created = await sut.createTask(title: "A", supervisorTask: "x")
        let taskID = try XCTUnwrap(created)
        let runsBefore = sut.loadedTask(taskID)?.runs.count ?? 0

        // Remove the on-disk task the write targets. The in-memory copy stays, so
        // `createNewRun` gets all the way to `updateTaskOnly` before failing.
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.removeItem(at: paths.taskJSON(taskID: taskID))
        sut.lastErrorMessage = nil

        await sut.createNewRun(taskID: taskID)

        XCTAssertNotNil(
            sut.lastErrorMessage,
            "a run that could not be written must be reported, not silently dropped")
        XCTAssertEqual(
            sut.loadedTask(taskID)?.runs.count, runsBefore + 1,
            "invariant #6: the in-memory commit is synchronous and precedes the write, so a "
                + "failed write surfaces a banner without rolling back — the UI and the engine "
                + "keep agreeing about which run is current")
    }
}
