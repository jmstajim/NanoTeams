import XCTest

@testable import NanoTeams

/// Pins the C1 invariant from `.claude/plans/snoopy-sprouting-tiger.md`:
/// `mutateTask` must apply the in-memory mutation and snapshot update
/// synchronously on `@MainActor` BEFORE any `await`-suspension. Only the
/// JSON encode + atomic file write may be detached.
///
/// Pre-fix, `await Task.detached { repository.updateTaskOnly(...) }.value`
/// straddled the in-memory commit. Concurrent main-actor callers (parallel
/// role engines per CLAUDE.md invariant #45, streaming + tool-result writes
/// on the same task) would each capture a stale `activeTask`, mutate it,
/// suspend at the disk-write await, and on resume call `applyTaskUpdate`
/// last-writer-wins — earlier mutations were silently dropped.
@MainActor
final class MutateTaskRaceTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// N concurrent `mutateTask` calls each append a distinct `Run` to the
    /// same task. After all calls complete, every Run must be present.
    /// On broken code (in-memory commit after the await) at least one
    /// mutation is overwritten.
    func testConcurrentMutateTask_preservesAllInMemoryMutations() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Race", supervisorTask: "test")!

        // Seed the task with no runs (default state). Each concurrent call
        // appends one Run identified by its `Run.id` so we can recover
        // which mutations landed.
        let n = 10
        let captured = sut!
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<n {
                group.addTask {
                    return await captured.mutateTask(taskID: taskID) { task in
                        task.runs.append(
                            Run(id: i, steps: [], roleStatuses: [:])
                        )
                    }
                }
            }
            for await ok in group {
                XCTAssertTrue(ok, "every concurrent mutateTask must report a successful persist")
            }
        }

        let runIDs = Set((sut.activeTask?.runs ?? []).map { $0.id })
        XCTAssertEqual(
            runIDs,
            Set(0..<n),
            "All \(n) concurrent mutations must be preserved in-memory; missing IDs indicate the C1 race regressed"
        )
    }

    /// Concurrent mutations must also land on disk eventually. The detached
    /// writes themselves race (last-writer-wins), but in-memory state is the
    /// source of truth and the next mutation triggers a fresh write that
    /// catches disk up. After a final settling mutation, disk MUST match
    /// in-memory.
    func testConcurrentMutateTask_finalDiskStateMatchesInMemory() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Race", supervisorTask: "test")!

        let n = 5
        let captured = sut!
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<n {
                group.addTask {
                    return await captured.mutateTask(taskID: taskID) { task in
                        task.runs.append(
                            Run(id: i, steps: [], roleStatuses: [:])
                        )
                    }
                }
            }
            for await ok in group {
                XCTAssertTrue(ok, "every concurrent mutateTask must report a successful persist")
            }
        }

        // Settling mutation: a single non-concurrent mutateTask flushes the
        // current authoritative in-memory state to disk.
        _ = await sut.mutateTask(taskID: taskID) { $0.title = "Race-settled" }

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskPath = paths.taskJSON(taskID: taskID)
        guard let data = try? Data(contentsOf: taskPath),
              let onDisk = try? JSONCoderFactory.makeDateDecoder().decode(NTMSTask.self, from: data) else {
            return XCTFail("task.json must decode after concurrent mutations")
        }
        XCTAssertEqual(
            Set(onDisk.runs.map { $0.id }),
            Set(0..<n),
            "After a settling mutation, disk must match in-memory and contain every concurrent run"
        )
        XCTAssertEqual(onDisk.title, "Race-settled")
    }

    /// `mutateTask` returning `false` due to `CancellationError` must NOT
    /// surface as a red `lastErrorMessage` banner. Pre-fix, every Pause /
    /// work-folder switch / task close that cancelled an in-flight write
    /// posted a misleading "Failed to save task: cancelled" error.
    func testMutateTask_cancelledTaskDoesNotSurfaceErrorBanner() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Cancel", supervisorTask: "test")!

        // Clear any banner from setup so the assertion is meaningful.
        sut.lastErrorMessage = nil

        // Wrap the call in a Task we cancel before the detached write can
        // complete. The cancellation propagates through `Task.value` as
        // `CancellationError`; the new `catch is CancellationError` arm
        // returns false silently.
        let mutator = Task { @MainActor in
            await sut.mutateTask(taskID: taskID) { task in
                task.title = "Should-Not-Persist"
            }
        }
        mutator.cancel()
        _ = await mutator.value

        // The result is allowed to be true (work raced past cancellation) OR
        // false (cancellation observed). Both are correct outcomes, so the
        // assertion must NOT be gated on which one happened — it used to sit
        // inside `if result == false`, and that branch never runs: `mutateTask`
        // awaits a `Task.detached` write, a detached task does not inherit
        // cancellation, and `Task.value` rethrows only the child's own error.
        // So `result` is always true and the whole test asserted nothing.
        // The banner staying nil is the invariant either way — which is exactly
        // what this test's name claims.
        XCTAssertNil(
            sut.lastErrorMessage,
            "CancellationError must not surface as a save-failure banner"
        )
    }
}
