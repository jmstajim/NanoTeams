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

        // Resolve team to set isChatMode at creation.
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
        var index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let taskID = index.nextTaskID
        index.nextTaskID += 1
        try store.write(index, to: paths.tasksIndexJSON)

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
            isChatMode: team.isChatMode,
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
            index.ancestorIDs(of: parentTaskID!) + [parentTaskID!]
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

        // Write index again with the task summary added.
        index.tasks.append(task.toSummary())
        index.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
        try store.write(index, to: paths.tasksIndexJSON)

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

        let tasksIndex = try mutateTasksIndex(paths: paths) { $0.tasks.removeAll { $0.id == taskID } }

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

    func updateTask(at workFolderRoot: URL, task: NTMSTask) throws -> WorkFolderContext {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)

        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let ancestors = index.ancestorIDs(of: task.id)
        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: task.id, ancestors: ancestors).path) else {
            throw NTMSRepositoryError.taskNotFound(task.id)
        }

        try store.write(task, to: paths.taskJSON(taskID: task.id, ancestors: ancestors))

        let refreshed = task.toSummary()
        let tasksIndex = try mutateTasksIndex(paths: paths) { index in
            if let idx = index.tasks.firstIndex(where: { $0.id == refreshed.id }) {
                index.tasks[idx] = refreshed
            } else {
                index.tasks.append(refreshed)
            }
        }

        // Determine if this task is the active task to avoid re-reading it from disk
        let state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        let isActiveTask = (state.activeTaskID == task.id)

        return try assembleContext(
            paths: paths,
            workFolderState: state,
            tasksIndex: tasksIndex,
            activeTask: isActiveTask ? task : nil,
            activeTaskProvided: isActiveTask
        )
    }

    /// Load a single task from disk without rebuilding the full WorkFolderContext.
    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let ancestors = index.ancestorIDs(of: taskID)
        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: taskID, ancestors: ancestors).path) else {
            throw NTMSRepositoryError.taskNotFound(taskID)
        }
        return try store.read(NTMSTask.self, from: paths.taskJSON(taskID: taskID, ancestors: ancestors))
    }

    /// Persist a task and update the tasks index WITHOUT rebuilding the full WorkFolderContext.
    /// Used for background (non-active) task mutations.
    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)

        let index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        let ancestors = index.ancestorIDs(of: task.id)
        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: task.id, ancestors: ancestors).path) else {
            throw NTMSRepositoryError.taskNotFound(task.id)
        }

        try store.write(task, to: paths.taskJSON(taskID: task.id, ancestors: ancestors))

        let refreshed = task.toSummary()
        try mutateTasksIndex(paths: paths) { index in
            if let idx = index.tasks.firstIndex(where: { $0.id == refreshed.id }) {
                index.tasks[idx] = refreshed
            } else {
                index.tasks.append(refreshed)
            }
        }
    }

    // MARK: - Private Helpers

    /// Reads, mutates, sorts, and writes the tasks index.
    /// Returns the updated index for callers that need to pass it to `assembleContext`.
    @discardableResult
    func mutateTasksIndex(paths: NTMSPaths, _ body: (inout TasksIndex) throws -> Void) throws -> TasksIndex {
        var index = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        try body(&index)
        index.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
        try store.write(index, to: paths.tasksIndexJSON)
        return index
    }
}
