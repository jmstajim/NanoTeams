import XCTest

@testable import NanoTeams

/// What a NARROW work-folder write is allowed to cost.
///
/// The five narrow writers (`updateWorkFolderContext` / `updateSelectedScheme` /
/// `updateWorkFolderState` / `updateSettings` / `updateTeams`) each write ONE small file
/// and then rebuild a `WorkFolderContext`. Until 2026-08-30 that rebuild ended in
/// `assembleContext` with `activeTaskProvided` defaulted false, so every one of them
/// re-read the active `task.json` AND re-hydrated every `step_log.jsonl` of every step of
/// every run — the exact bytes the 2026-08-22 stream split moved off the write path,
/// paid back on a ~1 KB settings write, synchronously on the MainActor.
///
/// The complexity ratchet could not see it: `a3` ranks a read-whole/write-whole PAIR
/// inside one function span, and `assembleContext` performs no write, so the cost sat one
/// call below a site whose recorded verdict reasoned only about the ~1 KB file.
///
/// Two properties, and the second is not a bonus — it is a correctness bug the same line
/// caused: `mutateTask` commits the task in memory on `@MainActor` and only THEN detaches
/// the disk write (CLAUDE.md invariant #6), so a copy read from disk inside that window is
/// OLDER than the one the orchestrator holds, and `apply(_:)` assigns it straight onto
/// `activeTask` — silently reverting the newest mutation.
final class NarrowWorkFolderWriteCostTests: XCTestCase {

    var root: URL!
    var repository: NTMSRepository!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        root = fm.temporaryDirectory
            .appendingPathComponent("narrow-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        repository = NTMSRepository()
    }

    override func tearDown() {
        if let root { try? fm.removeItem(at: root) }
        root = nil
        repository = nil
        super.tearDown()
    }

    /// A task whose streams genuinely live in `step_log.jsonl`, so hydration has work to do.
    private func makeTaskWithSplitStreams(turns: Int = 12) throws -> NTMSTask {
        _ = try repository.openOrCreateWorkFolder(at: root)
        let id = try repository.createTask(at: root, title: "T", supervisorTask: "s").taskID
        var task = try repository.loadTask(at: root, taskID: id)
        task.runs = [Run(id: 0, steps: [
            StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
        ])]
        try repository.updateTaskOnly(at: root, task: task)
        for i in 0..<turns {
            var t = try repository.loadTask(at: root, taskID: id)
            t.runs[0].steps[0].llmConversation.append(
                LLMMessage(role: .assistant, content: "turn \(i)"))
            t.updatedAt = MonotonicClock.shared.now()
            try repository.updateTaskOnly(at: root, task: t)
        }
        return try repository.loadTask(at: root, taskID: id)
    }

    // MARK: - The headline

    /// RED: drop `activeTask:`/`activeTaskProvided: true` from any narrow writer's
    /// `assembleContext` call → that writer hydrates again and this fails naming the count.
    func testNarrowWrites_doNotRehydrateTheActiveTask() throws {
        let task = try makeTaskWithSplitStreams()

        for (label, write) in narrowWrites(handing: task) {
            TaskStreamStore._testResetHydrateCounters()
            _ = try write()
            XCTAssertEqual(
                TaskStreamStore._testHydrateReads(), 0,
                "\(label) re-read \(TaskStreamStore._testHydrateReads()) step log(s) "
                    + "(\(TaskStreamStore._testHydrateEntries()) entries) while writing a file "
                    + "that cannot change the task — the caller already holds it in memory")
        }
    }

    /// The discriminating control (CLAUDE.md #60). Without it the assertion above passes
    /// in a world where `hydrate` is never reachable at all, and the counter would be
    /// pinning nothing.
    func testWithoutTheCallersTask_theWriterStillReadsFromDisk() throws {
        _ = try makeTaskWithSplitStreams()

        TaskStreamStore._testResetHydrateCounters()
        _ = try repository.updateSettings(at: root, activeTask: nil) { $0.context = "x" }

        XCTAssertGreaterThan(
            TaskStreamStore._testHydrateReads(), 0,
            "with no caller-supplied task the writer must fall back to reading the active "
                + "task from disk — a zero here means the counter cannot observe hydration and "
                + "the headline test above is vacuous")
    }

    // MARK: - The guard

    /// The caller's copy is used only when it IS the active task. A stale or unrelated
    /// task must not be bound as active by a settings write.
    func testAMismatchedTaskID_fallsBackToDisk() throws {
        let task = try makeTaskWithSplitStreams()
        var impostor = task
        impostor.id = task.id + 999

        TaskStreamStore._testResetHydrateCounters()
        let ctx = try repository.updateSettings(at: root, activeTask: impostor) { $0.context = "y" }

        XCTAssertEqual(ctx.activeTask?.id, task.id,
                       "a task whose id is not the active one must not be bound as active")
        XCTAssertGreaterThan(TaskStreamStore._testHydrateReads(), 0,
                             "the id guard must fall back to the disk read, not to nil")
    }

    /// The lost-update half. The orchestrator's in-memory task is NEWER than disk inside
    /// `mutateTask`'s detached-write window; the returned context must carry that copy,
    /// because `apply(_:)` assigns it straight onto `activeTask`.
    func testTheCallersCopyWins_soANarrowWriteCannotRevertANewerMutation() throws {
        var task = try makeTaskWithSplitStreams()
        let unflushed = "typed after the last disk write"
        task.runs[0].steps[0].llmConversation.append(
            LLMMessage(role: .assistant, content: unflushed))

        let ctx = try repository.updateSettings(at: root, activeTask: task) { $0.context = "z" }

        XCTAssertEqual(
            ctx.activeTask?.runs.first?.steps.first?.llmConversation.last?.content, unflushed,
            "the narrow write returned the older DISK copy; apply(_:) would write it onto "
                + "activeTask and silently revert the newest in-memory mutation")
    }

    /// No active task at all: neither a read nor a phantom binding.
    func testNoActiveTask_readsNothingAndBindsNothing() throws {
        _ = try repository.openOrCreateWorkFolder(at: root)

        TaskStreamStore._testResetHydrateCounters()
        let ctx = try repository.updateSettings(at: root, activeTask: nil) { $0.context = "w" }

        XCTAssertNil(ctx.activeTask)
        XCTAssertEqual(TaskStreamStore._testHydrateReads(), 0)
    }

    // MARK: - The orphan-temp sweep

    /// `sweepOrphanTempFiles` is crash recovery: it hunts `.uuid.tmp` files left by a
    /// process killed between `Data.write(to:)` and `replaceItemAt`. Only a PREVIOUS
    /// process can create those, so its correct cadence is once per folder. It was
    /// reached from `bootstrapIfNeeded` on every `preparePaths` — i.e. on all five narrow
    /// writers plus create/delete/setActiveTask — recursively enumerating the whole
    /// `.nanoteams/internal/` tree, which grows with tasks x runs x steps and is never
    /// pruned.
    ///
    /// RED: drop the `markSweptIfNeeded` gate → the second write sweeps too and the
    /// first assertion fails.
    /// RED: make `markSweptIfNeeded` always return false → the control below fails,
    /// catching a "fix" that disables the sweep instead of scheduling it.
    func testOrphanSweep_runsOncePerFolderPerProcess() throws {
        NTMSRepository._testResetSweepRegistry()
        _ = try repository.openOrCreateWorkFolder(at: root)   // the one sweep for this folder

        let orphan = NTMSPaths(workFolderRoot: root).internalDir
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        XCTAssertTrue(fm.createFile(atPath: orphan.path, contents: Data()))

        _ = try repository.updateSettings(at: root, activeTask: nil) { $0.context = "a" }

        XCTAssertTrue(
            fm.fileExists(atPath: orphan.path),
            "a narrow write re-ran the crash-recovery sweep — a recursive enumeration of "
                + "the whole internal tree on the cost path of a ~1 KB file")

        // Control: the sweep itself must still work. Without this, deleting the sweep
        // outright would pass the assertion above.
        NTMSRepository._testResetSweepRegistry()
        _ = try repository.updateSettings(at: root, activeTask: nil) { $0.context = "b" }
        XCTAssertFalse(
            fm.fileExists(atPath: orphan.path),
            "the first bootstrap for a folder must still sweep orphan temp files")
    }

    // MARK: - Helpers

    private func narrowWrites(handing task: NTMSTask) -> [(String, () throws -> WorkFolderContext)] {
        [
            ("updateSettings", { try self.repository.updateSettings(
                at: self.root, activeTask: task) { $0.context = "a" } }),
            ("updateTeams", { try self.repository.updateTeams(
                at: self.root, activeTask: task) { $0[0].updatedAt = MonotonicClock.shared.now() } }),
            ("updateWorkFolderState", { try self.repository.updateWorkFolderState(
                at: self.root, activeTask: task) { $0.name = "renamed" } }),
            ("updateWorkFolderContext", { try self.repository.updateWorkFolderContext(
                at: self.root, context: "b", activeTask: task) }),
            ("updateSelectedScheme", { try self.repository.updateSelectedScheme(
                at: self.root, scheme: "S", activeTask: task) }),
        ]
    }
}
