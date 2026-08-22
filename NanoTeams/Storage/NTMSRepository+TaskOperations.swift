import Foundation

nonisolated extension NTMSRepository {

    func createTask(
        at workFolderRoot: URL,
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID? = nil,
        parentTaskID: Int? = nil,
        parentRoleID: String? = nil,
        delegationDepth: Int = 0,
        makeActive: Bool = true
    ) throws -> (snapshot: WorkFolderContext, taskID: Int) {
        let paths = try preparePaths(at: workFolderRoot)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        let teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)

        // Resolve team to set isChatMode at creation. Seeded from
        // `seedChatModeForNewTask`, never bare `isChatMode` — see that predicate for why
        // the Generated Team placeholder must not latch a vacuous `true` onto the task.
        let team: Team
        if let preferredTeamID, let t = teamsFile.teams.first(where: { $0.id == preferredTeamID }) {
            team = t
        } else if let activeID = state.activeTeamID,
                  let t = teamsFile.teams.first(where: { $0.id == activeID }) {
            team = t
        } else {
            team = teamsFile.teams.first ?? Team.default
        }

        // Allocate sequential task ID from the index counter.
        // Write the incremented counter BEFORE creating files — on crash, the counter
        // has already advanced (safe orphan) rather than risking ID collision.
        // Through `mutateTasksIndex` (tasksIndexLock): `updateTaskOnly` writes the
        // same file from concurrent detached tasks, and an unserialized
        // read-modify-write here could hand out one id twice or clobber a
        // summary landing between this write and the append below.
        var taskID = 0
        let indexAfterAllocation = try mutateTasksIndex(paths: paths) { index in
            taskID = index.nextTaskID
            index.nextTaskID += 1
        }

        // Capture the resolved team's ID on the task so subsequent active-team
        // switches don't retroactively re-assign it. Callers that pass nil
        // (the common UI path) still get a stable pointer to the team that
        // was active at creation.
        // Parentage is set at creation so the task's storage path is nested under
        // its ancestors from day one — no later "move on disk" step.
        var task = NTMSTask(
            id: taskID,
            title: title,
            supervisorTask: supervisorTask,
            preferredTeamID: team.id,
            isChatMode: team.seedChatModeForNewTask,
            parentTaskID: parentTaskID,
            parentRoleID: parentRoleID,
            delegationDepth: delegationDepth
        )
        task.status = task.derivedStatusFromActiveRun()

        // Compute ancestor chain BEFORE adding this task to the index — for child tasks,
        // ancestors come from the parent's existing chain in the index.
        let ancestors = parentTaskID.map { _ in
            // The new task isn't in the index yet; its parentTaskID is `parentTaskID`.
            // Walk parent's own ancestors plus parentTaskID itself.
            indexAfterAllocation.ancestorIDs(of: parentTaskID!) + [parentTaskID!]
        } ?? []

        // Create both public and internal task directories at the nested path.
        let publicTaskDir = paths.taskDir(taskID: task.id, ancestors: ancestors)
        if !fileManager.fileExists(atPath: publicTaskDir.path) {
            try fileManager.createDirectory(at: publicTaskDir, withIntermediateDirectories: true)
        }
        let internalTaskDir = paths.internalTaskDir(taskID: task.id, ancestors: ancestors)
        if !fileManager.fileExists(atPath: internalTaskDir.path) {
            try fileManager.createDirectory(at: internalTaskDir, withIntermediateDirectories: true,
                                            attributes: Self.internalDirAttributes)
        }

        try store.write(task, to: paths.taskJSON(taskID: task.id, ancestors: ancestors))

        #if DEBUG
        // Deterministic seam for TasksIndexConcurrencyTests: runs a concurrent
        // writer's work exactly inside the window between the task-file writes
        // above and the summary append below — the interleave a wall-clock race
        // cannot reproduce reliably (the window is shorter than a full index
        // RMW's critical path).
        Self._testCreateTaskBeforeSummaryAppend?()
        #endif

        // Write index again with the task summary added — a FRESH read under the
        // lock, never the pre-file-creation copy: an `updateTaskOnly` that landed
        // while the directories and task.json were being written above must
        // survive into this write, not be overwritten by a stale snapshot.
        let summary = task.toSummary()
        let index = try mutateTasksIndex(paths: paths) { index in
            index.tasks.append(summary)
        }

        // Top-level tasks become active; child tasks do NOT change the active selection
        // (the supervisor is still focused on the parent task in the UI). `makeActive: false`
        // also opts a top-level task out of becoming active — used for the hidden Folder
        // Manager task and for the manager's fire-and-forget `create_managed_task` so a
        // background-created task never steals the user's UI focus.
        let becomesActive = parentTaskID == nil && makeActive
        if becomesActive {
            state.activeTaskID = task.id
            state.updatedAt = MonotonicClock.shared.now()
            try store.write(state, to: paths.workFolderJSON)
        }

        let snapshot = try assembleContext(
            paths: paths,
            workFolderState: state,
            teamsFile: teamsFile,
            tasksIndex: index,
            activeTask: becomesActive ? task : nil,
            activeTaskProvided: becomesActive
        )
        return (snapshot, task.id)
    }

    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)
        let state = try writeActiveTaskID(paths: paths, taskID: taskID)
        return try assembleContext(paths: paths, workFolderState: state)
    }

    func setActiveTaskID(at workFolderRoot: URL, taskID: Int?) throws {
        let paths = try preparePaths(at: workFolderRoot)
        _ = try writeActiveTaskID(paths: paths, taskID: taskID)
    }

    /// Validates `taskID` exists (when non-nil), then writes `activeTaskID` +
    /// bumped `updatedAt` to `workfolder.json`. Shared by `setActiveTask` (which
    /// follows up with `assembleContext` for the full snapshot) and
    /// `setActiveTaskID` (which skips the rebuild).
    private func writeActiveTaskID(paths: NTMSPaths, taskID: Int?) throws -> WorkFolderState {
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)

        if let taskID {
            let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
            let ancestors = index.ancestorIDs(of: taskID)
            guard fileManager.fileExists(atPath: paths.taskJSON(taskID: taskID, ancestors: ancestors).path) else {
                throw NTMSRepositoryError.taskNotFound(taskID)
            }
        }

        state.activeTaskID = taskID
        state.updatedAt = MonotonicClock.shared.now()
        try store.write(state, to: paths.workFolderJSON)
        return state
    }

    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)

        // Verify task exists before attempting deletion
        let existingIndex = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        guard existingIndex.tasks.contains(where: { $0.id == taskID }) else {
            throw NTMSRepositoryError.taskNotFound(taskID)
        }
        // Capture ancestor chain BEFORE removing from the index — once removed,
        // the chain can't be reconstructed.
        let ancestors = existingIndex.ancestorIDs(of: taskID)

        // The on-disk delete below is recursive — it takes every delegated
        // child's subtree with it — so the index must drop the DESCENDANT rows
        // too, or every later open's stale-status sweep re-selects orphan rows
        // pointing at deleted paths and reports "could not recover" forever.
        let doomed = Set([taskID] + existingIndex.descendantIDs(of: taskID))
        let tasksIndex = try mutateTasksIndex(paths: paths) {
            $0.tasks.removeAll { doomed.contains($0.id) }
        }

        // Remove public task dir (attachments + runs/artifacts) and internal task dir (task.json + runs/logs).
        // Both are recursive — runs AND any nested subtasks are removed together.
        for dir in [
            paths.taskDir(taskID: taskID, ancestors: ancestors),
            paths.internalTaskDir(taskID: taskID, ancestors: ancestors)
        ] {
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.removeItem(at: dir)
            }
        }

        if state.activeTaskID == taskID {
            let nextActive = pickFallbackActiveTaskID(from: tasksIndex, excluding: state.autovisorTaskID)
            state.activeTaskID = nextActive
            state.updatedAt = MonotonicClock.shared.now()
            try store.write(state, to: paths.workFolderJSON)
        }

        return try assembleContext(paths: paths, workFolderState: state, tasksIndex: tasksIndex)
    }

    /// Load a single task from disk without rebuilding the full WorkFolderContext.
    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let ancestors = index.ancestorIDs(of: taskID)
        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: taskID, ancestors: ancestors).path) else {
            throw NTMSRepositoryError.taskNotFound(taskID)
        }
        var task = try store.read(NTMSTask.self, from: paths.taskJSON(taskID: taskID, ancestors: ancestors))
        hydrateStreams(&task, paths: paths, ancestors: ancestors)
        return task
    }

    /// Persist a task and update the tasks index WITHOUT rebuilding the full WorkFolderContext.
    /// Used for background (non-active) task mutations.
    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
        // A split task that was never hydrated has EMPTY stream arrays — the
        // diff would read them as a rollback and truncate every step log.
        // Loud refusal; production never trips it (every producer hydrates).
        guard task.streamsHydrated else {
            throw NTMSRepositoryError.unhydratedTask(task.id)
        }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)

        // ONE index read under the index lock — this is `mutateTask`'s hot path
        // (every LLM step, message and status change), and it used to read the
        // whole index TWICE per call: once for `ancestorIDs`, then again inside
        // `mutateTasksIndex`. Fusing them under the lock also closes a real
        // race: parallel roles (CLAUDE.md #45) reach here through concurrent
        // `Task.detached` writers, and two unserialized read-modify-write
        // cycles on one file can lose whichever summary lands first.
        try Self.tasksIndexLock.withLock {
            var index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
            let ancestors = index.ancestorIDs(of: task.id)
            let taskURL = paths.taskJSON(taskID: task.id, ancestors: ancestors)
            guard fileManager.fileExists(atPath: taskURL.path) else {
                throw NTMSRepositoryError.taskNotFound(task.id)
            }

            // WRITE-ORDERING GUARD. Detached flushes race (`mutateTask` hops to
            // `Task.detached` per mutation), and with whole-blob writes the race
            // was benign — last-writer-wins, the next mutation caught disk up
            // (`MutateTaskRaceTests` documents it). A STALE snapshot landing
            // after a newer one must now be dropped whole: under the stream
            // split its shorter arrays would read as a rollback and emit a log
            // TRUNCATE — data loss, not staleness. `updatedAt` is a valid write
            // generation: `mutateTask` stamps `MonotonicClock` (strictly
            // increasing) synchronously on `@MainActor` before the detached
            // hop. Strictly `<`, never `<=` — the open-time convergence writes
            // pass a task whose `updatedAt` came off disk unchanged and must
            // still apply. Keyed by the task FILE's path, not by taskID: ids
            // are per-folder sequential, and a bare `[Int: Date]` would let
            // folder A's task 3 silently swallow folder B's task 3 forever
            // (the loadedTasks/QuickCapture cleanup bug class, avoided here
            // structurally instead of by remembering to clean up).
            let orderKey = taskURL.standardizedFileURL.path
            let generation = Self.writeGeneration(of: task.updatedAt)
            if let flushed = Self.lastFlushedGeneration[orderKey], generation < flushed {
                return
            }
            Self.lastFlushedGeneration[orderKey] = generation

            // Streams first, then metadata (crash recovery resolves toward the
            // log); the blob receives the STRIPPED shape — see +StreamSplit.
            let stripped = try splittingStreams(task, paths: paths, ancestors: ancestors)
            try store.write(stripped, to: taskURL)

            index.upsert(task.toSummary())
            try store.write(index, to: paths.tasksIndexJSON)
        }
    }

    // MARK: - Private Helpers

    /// Process-global: `NTMSRepository` is a struct, copies share the same files,
    /// and index writers arrive on concurrent detached tasks — the lock belongs
    /// to the FILE (same reasoning as `JSONLFileLog`'s per-path queues).
    static let tasksIndexLock = NSLock()

    /// Write generations for the ordering guard in `updateTaskOnly`, keyed by
    /// the task FILE's canonical path (see the guard's comment for why not by
    /// id). Guarded by `tasksIndexLock` — every reader/writer already holds it.
    nonisolated(unsafe) static var lastFlushedGeneration: [String: Int64] = [:]

    /// `updatedAt` quantized to the precision DISK carries. The persistence
    /// encoder ROUNDS fractional seconds to milliseconds (measured 2026-08-22:
    /// `.9996` encodes as the next whole second, `.1237` as `.124`), so an
    /// in-memory stamp and its disk round-trip land on the SAME generation —
    /// comparing raw `Date`s made every convergence write of a disk-loaded task
    /// read as sub-millisecond "older" than its own flush. `MonotonicClock`
    /// spaces stamps ≥1 ms apart, so distinct stamps keep distinct generations.
    nonisolated static func writeGeneration(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    #if DEBUG
    /// Test seam: invoked by `createTask` between its task-file writes and its
    /// summary append, i.e. inside the exact unlocked window a concurrent
    /// `updateTaskOnly` must survive. Set only from tests; nil in production.
    nonisolated(unsafe) static var _testCreateTaskBeforeSummaryAppend: (() -> Void)?
    #endif

    /// Reads, mutates, sorts, and writes the tasks index — under `tasksIndexLock`.
    /// Returns the updated index for callers that need to pass it to `assembleContext`.
    ///
    /// **This sort is the boundary that ESTABLISHES the descending-`updatedAt` order, and
    /// is why it may stay here while five per-mutation copies of it were removed.** `body`
    /// is an arbitrary closure (create appends, delete removes, reconcile rewrites rows),
    /// so order cannot be maintained incrementally here — and this runs at user cadence
    /// (task create / delete / switch), not per LLM message. Every other writer of this
    /// file goes through `TasksIndex.upsert`, which PRESERVES the order rather than
    /// recomputing it; since both writers hold `tasksIndexLock` and an empty index is
    /// trivially sorted, the file on disk is sorted by induction — which is what lets
    /// `upsert`'s binary search be correct after a read.
    @discardableResult
    func mutateTasksIndex(paths: NTMSPaths, _ body: (inout TasksIndex) throws -> Void) throws -> TasksIndex {
        try Self.tasksIndexLock.withLock {
            var index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
            try body(&index)
            index.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
            try store.write(index, to: paths.tasksIndexJSON)
            return index
        }
    }
}
