import Foundation

extension NTMSRepository {

    func createTask(at workFolderRoot: URL, title: String, supervisorTask: String, preferredTeamID: NTMSID? = nil) throws -> WorkFolderContext {
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

        var task = NTMSTask(id: taskID, title: title, supervisorTask: supervisorTask, preferredTeamID: preferredTeamID, isChatMode: team.isChatMode)
        task.status = task.derivedStatusFromActiveRun()

        // Create both public and internal task directories.
        let publicTaskDir = paths.taskDir(taskID: task.id)
        if !fileManager.fileExists(atPath: publicTaskDir.path) {
            try fileManager.createDirectory(at: publicTaskDir, withIntermediateDirectories: true)
        }
        let internalTaskDir = paths.internalTaskDir(taskID: task.id)
        if !fileManager.fileExists(atPath: internalTaskDir.path) {
            try fileManager.createDirectory(at: internalTaskDir, withIntermediateDirectories: true,
                                             attributes: Self.internalDirAttributes)
        }

        try store.write(task, to: paths.taskJSON(taskID: task.id))

        // Write index again with the task summary added.
        index.tasks.append(task.toSummary())
        index.tasks.sort(by: { $0.updatedAt > $1.updatedAt })
        try store.write(index, to: paths.tasksIndexJSON)

        state.activeTaskID = task.id
        state.updatedAt = MonotonicClock.shared.now()
        try store.write(state, to: paths.workFolderJSON)

        return try assembleContext(
            paths: paths,
            workFolderState: state,
            teamsFile: teamsFile,
            tasksIndex: index,
            activeTask: task,
            activeTaskProvided: true
        )
    }

    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)

        if let taskID {
            guard fileManager.fileExists(atPath: paths.taskJSON(taskID: taskID).path) else {
                throw NTMSRepositoryError.taskNotFound(taskID)
            }
        }

        state.activeTaskID = taskID
        state.updatedAt = MonotonicClock.shared.now()
        try store.write(state, to: paths.workFolderJSON)

        return try assembleContext(paths: paths, workFolderState: state)
    }

    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)

        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)

        // Verify task exists before attempting deletion
        let existingIndex = try store.read(TasksIndex.self, from: paths.tasksIndexJSON)
        guard existingIndex.tasks.contains(where: { $0.id == taskID }) else {
            throw NTMSRepositoryError.taskNotFound(taskID)
        }

        let tasksIndex = try mutateTasksIndex(paths: paths) { $0.tasks.removeAll { $0.id == taskID } }

        // Remove public task dir (attachments + runs/artifacts) and internal task dir (task.json + runs/logs).
        // Both are recursive — runs are nested inside, so no separate run cleanup needed.
        for dir in [
            paths.taskDir(taskID: taskID),
            paths.internalTaskDir(taskID: taskID)
        ] {
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.removeItem(at: dir)
            }
        }

        if state.activeTaskID == taskID {
            let nextActive = pickFallbackActiveTaskID(from: tasksIndex)
            state.activeTaskID = nextActive
            state.updatedAt = MonotonicClock.shared.now()
            try store.write(state, to: paths.workFolderJSON)
        }

        return try assembleContext(paths: paths, workFolderState: state, tasksIndex: tasksIndex)
    }

    func updateTask(at workFolderRoot: URL, task: NTMSTask) throws -> WorkFolderContext {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)

        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: task.id).path) else {
            throw NTMSRepositoryError.taskNotFound(task.id)
        }

        try store.write(task, to: paths.taskJSON(taskID: task.id))

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
        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: taskID).path) else {
            throw NTMSRepositoryError.taskNotFound(taskID)
        }
        return try store.read(NTMSTask.self, from: paths.taskJSON(taskID: taskID))
    }

    /// Persist a task and update the tasks index WITHOUT rebuilding the full WorkFolderContext.
    /// Used for background (non-active) task mutations.
    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)

        guard fileManager.fileExists(atPath: paths.taskJSON(taskID: task.id).path) else {
            throw NTMSRepositoryError.taskNotFound(task.id)
        }

        try store.write(task, to: paths.taskJSON(taskID: task.id))

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
