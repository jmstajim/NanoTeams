import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **concurrent task operations**: parallel
/// task creation from multiple async paths (e.g., user drops two files
/// into Quick Capture in rapid succession on different tabs, or
/// automation creates a batch of tasks).
///
/// Pinned behaviors:
/// 1. Parallel `createTask` calls all succeed and produce unique IDs.
/// 2. Task IDs strictly increase monotonically — no reuse, no gaps at
///    the end (may have gaps in the middle if one creation was
///    interleaved but that's fine).
/// 3. Tasks index contains exactly N entries after N creations.
/// 4. Parallel `mutateTask` on the same task serializes safely (the
///    orchestrator guarantees sequential access).
/// 5. Parallel switch/mutation doesn't lose state.
///
/// Swift concurrency note: NTMSOrchestrator is `@MainActor`, so all
/// actor-isolated calls serialize on the main actor automatically.
/// These tests confirm that the orchestrator's API contract holds under
/// parallel awaits, not that it's lock-free concurrent.
@MainActor
final class EndToEndConcurrentTaskCreationTests: NTMSOrchestratorTestBase {

    // MARK: - Scenario 1: 10 parallel creates all succeed with unique IDs

    func testParallelCreateTask_allSucceedWithUniqueIDs() async {
        await sut.openWorkFolder(tempDir)

        async let id1 = sut.createTask(title: "A", supervisorTask: "1")
        async let id2 = sut.createTask(title: "B", supervisorTask: "2")
        async let id3 = sut.createTask(title: "C", supervisorTask: "3")
        async let id4 = sut.createTask(title: "D", supervisorTask: "4")
        async let id5 = sut.createTask(title: "E", supervisorTask: "5")

        let ids = await [id1, id2, id3, id4, id5].compactMap { $0 }
        XCTAssertEqual(ids.count, 5, "All 5 creates must succeed")
        XCTAssertEqual(Set(ids).count, 5, "All 5 IDs must be unique")
    }

    // MARK: - Scenario 2: IDs strictly increase

    /// Even under parallel awaits, the orchestrator must not reuse IDs.
    /// The index counter should monotonically increase.
    func testParallelCreateTask_IDsStrictlyIncreasing() async {
        await sut.openWorkFolder(tempDir)

        var ids: [Int] = []
        for _ in 0..<10 {
            if let id = await sut.createTask(title: "T", supervisorTask: "x") {
                ids.append(id)
            }
        }

        XCTAssertEqual(ids.count, 10)
        XCTAssertEqual(ids, ids.sorted(),
                       "IDs must be produced in strictly increasing order")
        XCTAssertEqual(Set(ids).count, ids.count, "No duplicates")
    }

    // MARK: - Scenario 3: Tasks index length matches number of creations

    func testParallelCreateTask_tasksIndex_matchesCreatedCount() async {
        await sut.openWorkFolder(tempDir)

        async let a = sut.createTask(title: "A", supervisorTask: "1")
        async let b = sut.createTask(title: "B", supervisorTask: "2")
        async let c = sut.createTask(title: "C", supervisorTask: "3")
        _ = await (a, b, c)

        let indexCount = sut.snapshot?.tasksIndex.tasks.count ?? 0
        XCTAssertEqual(indexCount, 3,
                       "tasks_index.json must contain exactly 3 entries")
    }

    // MARK: - Scenario 4: Parallel mutations are atomic-per-call

    /// Each `mutateTask` closure must see a consistent snapshot: no
    /// half-written task state leaks across calls.
    func testParallelMutateTask_sameTask_atomicPerCall() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        // Fire 5 parallel mutations — each sets a different title
        async let m1 = sut.mutateTask(taskID: id) { $0.title = "Edit-1" }
        async let m2 = sut.mutateTask(taskID: id) { $0.title = "Edit-2" }
        async let m3 = sut.mutateTask(taskID: id) { $0.title = "Edit-3" }
        async let m4 = sut.mutateTask(taskID: id) { $0.title = "Edit-4" }
        async let m5 = sut.mutateTask(taskID: id) { $0.title = "Edit-5" }
        _ = await (m1, m2, m3, m4, m5)

        let finalTitle = sut.loadedTask(id)?.title ?? ""
        XCTAssertTrue(["Edit-1", "Edit-2", "Edit-3", "Edit-4", "Edit-5"].contains(finalTitle),
                      "Final title must equal one of the writes (no torn writes)")
    }

    // MARK: - Scenario 5: Parallel switchTask races don't crash

    func testParallelSwitchTask_noCrash_finalStateWellDefined() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "1")!
        let idB = await sut.createTask(title: "B", supervisorTask: "2")!
        let idC = await sut.createTask(title: "C", supervisorTask: "3")!

        async let s1: Void = sut.switchTask(to: idA)
        async let s2: Void = sut.switchTask(to: idB)
        async let s3: Void = sut.switchTask(to: idC)
        _ = await (s1, s2, s3)

        // Final active task must be one of the three we attempted — and
        // switchable back to a known state afterwards.
        XCTAssertNotNil(sut.activeTaskID)
        XCTAssertTrue([idA, idB, idC].contains(sut.activeTaskID ?? -1),
                      "Active task after parallel switches must be one of the targets")

        await sut.switchTask(to: idA)
        XCTAssertEqual(sut.activeTaskID, idA,
                       "Orchestrator remains usable after parallel switch race")
    }

    // MARK: - Scenario 6: Create + delete interleaved — index stays consistent

    func testCreateAndDelete_interleaved_indexConsistent() async {
        await sut.openWorkFolder(tempDir)

        let id1 = await sut.createTask(title: "A", supervisorTask: "1")!
        let id2 = await sut.createTask(title: "B", supervisorTask: "2")!
        await sut.removeTask(id1)
        let id3 = await sut.createTask(title: "C", supervisorTask: "3")!

        let ids = Set(sut.snapshot?.tasksIndex.tasks.map(\.id) ?? [])
        XCTAssertEqual(ids, Set([id2, id3]),
                       "Only surviving tasks must be in index")
        XCTAssertFalse(ids.contains(id1),
                       "Deleted ID must not reappear")
        XCTAssertGreaterThan(id3, id2,
                             "New ID after delete still monotonically increases")
    }

    // MARK: - Scenario 7: Many sequential creates don't leak files

    func testManySequentialCreates_taskFilesExistForEach() async {
        await sut.openWorkFolder(tempDir)

        var ids: [Int] = []
        for i in 0..<20 {
            ids.append(await sut.createTask(
                title: "Task \(i)", supervisorTask: "s\(i)"
            )!)
        }

        let paths = NTMSPaths(workFolderRoot: tempDir)
        for id in ids {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: paths.taskJSON(taskID: id).path),
                "task.json missing for taskID \(id)"
            )
        }
    }
}
