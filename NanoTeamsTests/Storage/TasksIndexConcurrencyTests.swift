import XCTest

@testable import NanoTeams

/// Pins the tasks-index write path against concurrent writers.
///
/// `updateTaskOnly` is `mutateTask`'s hot path and arrives on concurrent
/// `Task.detached` writers whenever parallel roles run (CLAUDE.md #45). Until
/// 2026-08-21 it read the whole index twice per call (once for `ancestorIDs`,
/// once inside `mutateTasksIndex`) and neither read-modify-write cycle was
/// serialized against the other — two interleaved cycles could lose whichever
/// summary landed first. The fused body under `NTMSRepository.tasksIndexLock`
/// is one read, one write, atomic against every other index mutation.
///
/// RED: replace `Self.tasksIndexLock.withLock` in `updateTaskOnly` with a bare
/// closure call → the interleaved test below loses updates within a few dozen
/// rounds and fails on a vanished final summary.
///
/// Second theme (2026-09-02): what the index path is allowed to COST. The same
/// hot path walked the index rows TWICE per call — a hop-map build for the
/// ancestor chain, then a `firstIndex(where:)` for the upsert slot — and
/// `deleteTask` read the index once OUTSIDE the lock to decide what to remove
/// inside it. Both bounds below are WORK counters or deterministic seams, never
/// wall-clock (`Ratchet/WallClockPerformancePinTests`).
@MainActor
final class TasksIndexConcurrencyTests: XCTestCase, @unchecked Sendable {

    var workFolderRoot: URL!
    var repository: NTMSRepository!
    var paths: NTMSPaths!

    override func setUp() async throws {
        try await super.setUp()
        workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-idx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        repository = NTMSRepository()
        paths = NTMSPaths(workFolderRoot: workFolderRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workFolderRoot)
        repository = nil
        paths = nil
        workFolderRoot = nil
        try await super.tearDown()
    }

    func testConcurrentUpdateTaskOnly_neitherWriterLosesItsSummary() async throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let idA = try repository.createTask(
            at: workFolderRoot, title: "A", supervisorTask: "a").taskID
        let idB = try repository.createTask(
            at: workFolderRoot, title: "B", supervisorTask: "b").taskID
        let store = AtomicJSONStore()
        var taskA = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: idA))
        var taskB = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: idB))

        // 100 interleaved rounds from two concurrent writers — enough that an
        // unserialized read-modify-write on one file loses updates reliably.
        let repo = repository!
        let root = workFolderRoot!
        for round in 0..<50 {
            taskA.title = "A-\(round)"
            taskA.updatedAt = MonotonicClock.shared.now()
            taskB.title = "B-\(round)"
            taskB.updatedAt = MonotonicClock.shared.now()
            let a = taskA
            let b = taskB
            async let first: Void = Task.detached { try repo.updateTaskOnly(at: root, task: a) }.value
            async let second: Void = Task.detached { try repo.updateTaskOnly(at: root, task: b) }.value
            _ = try await (first, second)
        }

        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let summaryA = index.tasks.first(where: { $0.id == taskA.id })
        let summaryB = index.tasks.first(where: { $0.id == taskB.id })
        XCTAssertEqual(summaryA?.title, "A-49",
                       "task A's final update was lost to a concurrent writer")
        XCTAssertEqual(summaryB?.title, "B-49",
                       "task B's final update was lost to a concurrent writer")
    }

    /// `createTask` is the OTHER index writer: it allocates the id counter and
    /// appends the new summary in a second read-modify-write of the same file.
    /// Until 2026-08-21 the append reused the copy read at allocation time, so
    /// an `updateTaskOnly` landing between the two writes was silently
    /// overwritten by the stale copy.
    ///
    /// The interleave is DETERMINISTIC via `_testCreateTaskBeforeSummaryAppend`
    /// — a wall-clock race cannot reproduce it reliably, because the unlocked
    /// window (two mkdirs + one task.json write) is shorter than a concurrent
    /// index RMW's own critical path, so the "concurrent" writer always
    /// finishes after the stale write and wins by accident.
    ///
    /// RED: revert the summary append to `var index = indexAfterAllocation;
    /// index.tasks.append(...); try store.write(index, ...)` → the hooked
    /// update vanishes and both assertions fail.
    func testUpdateTaskOnlyLandingInsideCreateTaskWindow_survivesTheSummaryAppend() throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let victimID = try repository.createTask(
            at: workFolderRoot, title: "Victim", supervisorTask: "v").taskID
        let store = AtomicJSONStore()
        var victim = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: victimID))
        victim.title = "Victim UPDATED"
        victim.updatedAt = MonotonicClock.shared.now()

        let repo = repository!
        let root = workFolderRoot!
        let v = victim
        NTMSRepository._testCreateTaskBeforeSummaryAppend = {
            try? repo.updateTaskOnly(at: root, task: v)
        }
        defer { NTMSRepository._testCreateTaskBeforeSummaryAppend = nil }

        let newID = try repository.createTask(
            at: workFolderRoot, title: "Interleaved", supervisorTask: "n", makeActive: false).taskID

        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertEqual(index.tasks.first(where: { $0.id == victimID })?.title, "Victim UPDATED",
                       "an update landing inside createTask's window must survive its summary append")
        XCTAssertTrue(index.tasks.contains(where: { $0.id == newID }),
                      "the created task's own summary must land too")
    }

    /// The write-ordering guard: a STALE snapshot's detached flush landing after
    /// a newer one must be dropped WHOLE — under the stream split its shorter
    /// arrays would read as a rollback and emit a log truncate. Deterministic:
    /// no race needed, just two calls out of timestamp order.
    ///
    /// RED: delete the `lastFlushedUpdatedAt` early-return from `updateTaskOnly`
    /// → the stale title lands and both assertions fail.
    func testStaleSnapshotFlush_afterANewerOne_isDroppedWhole() throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let id = try repository.createTask(
            at: workFolderRoot, title: "Original", supervisorTask: "s").taskID
        let store = AtomicJSONStore()
        let base = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id))

        var newer = base
        newer.title = "Newer"
        newer.updatedAt = MonotonicClock.shared.now()
        var stale = base
        stale.title = "Stale"
        stale.updatedAt = base.updatedAt // strictly older than `newer`

        try repository.updateTaskOnly(at: workFolderRoot, task: newer)
        try repository.updateTaskOnly(at: workFolderRoot, task: stale)

        XCTAssertEqual(try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id)).title,
                       "Newer", "the stale blob write must be skipped")
        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertEqual(index.tasks.first(where: { $0.id == id })?.title, "Newer",
                       "and the stale index row too — the flush is dropped WHOLE")
    }

    /// Strictly `<`, never `<=`: the open-time convergence writes pass a task
    /// whose `updatedAt` came off disk unchanged — an EQUAL generation must
    /// still apply, or those rows never converge.
    ///
    /// RED: change the guard to `<=` → the equal-generation write is skipped.
    func testEqualGenerationFlush_stillApplies() throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let id = try repository.createTask(
            at: workFolderRoot, title: "Original", supervisorTask: "s").taskID
        let store = AtomicJSONStore()
        var task = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id))
        task.updatedAt = MonotonicClock.shared.now()
        try repository.updateTaskOnly(at: workFolderRoot, task: task)

        task.title = "Converged"   // same updatedAt — the convergence-write shape
        try repository.updateTaskOnly(at: workFolderRoot, task: task)

        XCTAssertEqual(try store.read(NTMSTask.self, from: paths.taskJSON(taskID: id)).title,
                       "Converged")
    }

    // MARK: - What the index path is allowed to COST

    /// `updateTaskOnly` walks the index rows ONCE per call. Until 2026-09-02 it walked
    /// them twice: `ancestorIDs(of:)` built the hop map over every row, then `upsert(_:)`
    /// searched the same rows again for the slot to replace — two full passes to answer
    /// two questions about one task, on `mutateTask`'s hot path (every LLM message), under
    /// the process-global `tasksIndexLock`. `parentLinks(locating:)` now hands back the
    /// hop map AND the row slot from the same loop, and `upsert(_:at:)` consumes the slot
    /// without a pass of its own.
    ///
    /// RED: revert the upsert to the searching spelling `index.upsert(task.toSummary())`
    /// → `fullScans()` reads 2. Second RED: pass `at: nil` → C is inserted a second time
    /// and the unique-ids assertion trips. Predicted-GREEN control (CLAUDE.md #56): move
    /// the `store.write(stripped…)` above or below the upsert — still one scan.
    func testUpdateTaskOnly_walksTheIndexRowsExactlyOnce() throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let parentID = try repository.createTask(
            at: workFolderRoot, title: "P", supervisorTask: "p").taskID
        // A delegation child, so the ancestor walk has a real hop to take.
        let childID = try repository.createTask(
            at: workFolderRoot, title: "C", supervisorTask: "c",
            parentTaskID: parentID, parentRoleID: "pm", delegationDepth: 1).taskID
        _ = try repository.createTask(
            at: workFolderRoot, title: "Other", supervisorTask: "o").taskID

        var child = try repository.loadTask(at: workFolderRoot, taskID: childID)
        child.title = "touched"
        child.updatedAt = MonotonicClock.shared.now()

        TasksIndexWorkProbe.reset()
        try repository.updateTaskOnly(at: workFolderRoot, task: child)

        XCTAssertEqual(
            TasksIndexWorkProbe.fullScans(), 1,
            "the hot path built the hop map and then searched the same rows again — one "
                + "pass answers both questions")
        XCTAssertEqual(TasksIndexWorkProbe.parentLinksBuilds(), 1,
                       "exactly one hop-map build per updateTaskOnly")

        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertEqual(index.tasks.first(where: { $0.id == childID })?.title, "touched",
                       "the positioned upsert must still land the new row")
        XCTAssertEqual(Set(index.tasks.map(\.id)).count, index.tasks.count,
                       "the positioned upsert must replace, never duplicate")
        let stamps = index.tasks.map(\.updatedAt)
        XCTAssertEqual(stamps, stamps.sorted(by: >), "and keep the descending order")
    }

    /// `deleteTask` derives its existence check, ancestor chain and doomed set from the
    /// SAME index snapshot it mutates, under `tasksIndexLock`. Until 2026-09-02 it read
    /// the index once WITHOUT the lock, computed `doomed` from that copy, and only then
    /// entered the locked read-modify-write — so a delegation child appended by a
    /// concurrent `createTask` in the gap survived the removal as an orphan row pointing
    /// at a deleted directory, which the open-time stale-status sweep re-selects forever.
    ///
    /// The interleave is DETERMINISTIC via `_testMutateTasksIndexAfterRead`, which fires
    /// INSIDE `mutateTasksIndex` between its locked `store.read` and the body — the exact
    /// point where a writer that committed BEFORE us becomes visible. The hook stands in
    /// for that writer by appending the child's row to the freshly read snapshot (what a
    /// completed concurrent `createTask` looks like from here; it cannot call `createTask`
    /// itself — the lock is held and `NSLock` is not reentrant). A hook fired BEFORE the
    /// index read could not tell the fixed layout from the old one: both would read the
    /// child, and the RED below would stay green.
    ///
    /// RED: restore the pre-fix layout — `let existingIndex = try store.read(TasksIndex…)`
    /// and `let doomed = Set([taskID] + existingIndex.descendantIDs(of: taskID))` ABOVE the
    /// `mutateTasksIndex` call, whose body becomes `$0.tasks.removeAll { doomed.contains($0.id) }`
    /// → the stale `doomed` misses the child, its row survives, the `parentTaskID`
    /// assertion fails.
    func testDelegationChildCreatedInsideDeleteTaskWindow_isRemovedWithItsParent() throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let parentID = try repository.createTask(
            at: workFolderRoot, title: "P", supervisorTask: "p").taskID
        _ = try repository.createTask(
            at: workFolderRoot, title: "Survivor", supervisorTask: "s", makeActive: false).taskID

        let lateChild = NTMSTask(
            id: 777, title: "late child", supervisorTask: "c",
            parentTaskID: parentID, parentRoleID: "pm", delegationDepth: 1
        ).toSummary()
        var hookFired = 0
        NTMSRepository._testMutateTasksIndexAfterRead = { index in
            hookFired += 1
            index.tasks.append(lateChild)
        }
        defer { NTMSRepository._testMutateTasksIndexAfterRead = nil }

        _ = try repository.deleteTask(at: workFolderRoot, taskID: parentID)

        XCTAssertEqual(hookFired, 1,
                       "anti-vacuum: the seam fired inside deleteTask's single index RMW")
        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertFalse(index.tasks.contains { $0.id == parentID }, "the parent row is gone")
        XCTAssertFalse(
            index.tasks.contains { $0.parentTaskID == parentID },
            "a child appended inside deleteTask's window survived as an orphan row — the "
                + "stale-status sweep will re-select it forever")
        XCTAssertTrue(index.tasks.contains { $0.title == "Survivor" },
                      "an unrelated row is untouched")
    }

    /// The OTHER direction of moving the existence check under the lock: two `deleteTask`
    /// calls for the same id. Pre-fix, the loser passed the unlocked pre-check (the row was
    /// still on disk when it looked), its `removeAll` then removed nothing, the directories
    /// were already gone (`fileExists` false → skipped) and it returned success for a delete it
    /// never performed. Post-fix the loser sees the row gone in the locked snapshot and throws
    /// `taskNotFound` from INSIDE the RMW body — before the index write, before the directory
    /// removal, before the fallback-active write. That ordering is what makes the row check safe
    /// to move under the lock at all, and nothing else asserts it.
    ///
    /// Same seam as the test above; the hook stands in for the winner by removing the row from
    /// the freshly read snapshot (what a committed concurrent `deleteTask` looks like from here).
    /// The winner's OWN side effects are not simulated — the point is that the LOSER touches
    /// nothing, which the still-present directories and pointer prove.
    ///
    /// RED: move the `contains` guard out of the closure back ABOVE `mutateTasksIndex` (the
    /// unlocked pre-check) → the loser's delete succeeds and `XCTAssertThrowsError` fails.
    /// Second RED: keep the check inside but AFTER the write (a captured `existed` flag tested
    /// once `mutateTasksIndex` returns) → the throw still comes, but the index file was
    /// rewritten and its `FileIdentity` moved.
    func testDeleteTask_rowRemovedByAConcurrentDelete_throwsBeforeAnySideEffect() throws {
        _ = try repository.openOrCreateWorkFolder(at: workFolderRoot)
        let parentID = try repository.createTask(
            at: workFolderRoot, title: "P", supervisorTask: "p").taskID
        _ = try repository.createTask(
            at: workFolderRoot, title: "Survivor", supervisorTask: "s", makeActive: false).taskID
        let store = AtomicJSONStore()
        XCTAssertEqual(try store.read(WorkFolderState.self, from: paths.workFolderJSON).activeTaskID,
                       parentID, "precondition: P is the active task, so a successful delete WOULD "
                           + "rewrite workfolder.json with a fallback pointer")
        let directories = [paths.taskDir(taskID: parentID), paths.internalTaskDir(taskID: parentID)]
        for dir in directories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "precondition: \(dir.lastPathComponent)")
        }
        let indexBefore = try FileIdentity(of: paths.tasksIndexJSON)
        let stateBefore = try FileIdentity(of: paths.workFolderJSON)

        var hookFired = 0
        NTMSRepository._testMutateTasksIndexAfterRead = { index in
            hookFired += 1
            index.tasks.removeAll { $0.id == parentID }
        }
        defer { NTMSRepository._testMutateTasksIndexAfterRead = nil }

        XCTAssertThrowsError(try repository.deleteTask(at: workFolderRoot, taskID: parentID)) { error in
            guard case .taskNotFound(let id)? = error as? NTMSRepositoryError else {
                return XCTFail("expected taskNotFound, got \(error)")
            }
            XCTAssertEqual(id, parentID)
        }

        XCTAssertEqual(hookFired, 1, "anti-vacuum: the seam fired inside deleteTask's single index RMW")
        for dir in directories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                          "the loser must not touch the directories (\(dir.lastPathComponent))")
        }
        XCTAssertEqual(try store.read(WorkFolderState.self, from: paths.workFolderJSON).activeTaskID,
                       parentID, "…nor the active pointer")
        XCTAssertEqual(try FileIdentity(of: paths.workFolderJSON), stateBefore,
                       "workfolder.json was not rewritten")
        XCTAssertEqual(try FileIdentity(of: paths.tasksIndexJSON), indexBefore,
                       "the miss is thrown from the RMW body, BEFORE its sort and write — a "
                           + "byte-identical rewrite would still move the inode/mtime")
    }
}
