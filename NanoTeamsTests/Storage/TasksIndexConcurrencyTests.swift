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
}
