import Foundation

/// Observable state for task filter, search, deletion, and renaming in the sidebar.
/// Owned by MainLayoutView and passed to SidebarView.
@MainActor @Observable final class TaskManagementState {
    var taskFilter: TaskFilter = .all
    var taskSearchText: String = ""
    var isSearchExpanded: Bool = false
    var taskToDelete: Int? = nil
    var isShowingDeleteConfirmation: Bool = false
    var taskToRename: Int? = nil
    var renameText: String = ""

    /// Task IDs marked seen while in `.needsSupervisorInput`. Persisted via
    /// `StoreConfiguration` namespaced by `(workFolderID, taskID)`. Auto-cleared
    /// when the task leaves `.needsSupervisorInput` so the next question
    /// re-triggers the dot.
    private(set) var seenSupervisorInputTaskIDs: Set<Int> = []

    @ObservationIgnored
    private weak var config: StoreConfiguration?
    @ObservationIgnored
    private(set) var currentWorkFolderID: UUID?

    /// Wires the persistence backend. Call once after MainLayoutView has access
    /// to its injected `StoreConfiguration` environment value.
    func bind(config: StoreConfiguration) {
        self.config = config
    }

    /// Hydrates the in-memory mirror from persisted state for `workFolderID`,
    /// and sets that folder as the destination for subsequent mark/unmark calls.
    /// Pass `nil` when no work folder is open (clears the mirror; persistence is
    /// skipped until a folder is loaded again).
    func loadSeenSet(for workFolderID: UUID?) {
        currentWorkFolderID = workFolderID
        if let workFolderID, let config {
            seenSupervisorInputTaskIDs = config.seenTaskIDs(forWorkFolder: workFolderID)
        } else {
            seenSupervisorInputTaskIDs = []
        }
    }

    func markSupervisorInputSeen(taskID: Int) {
        seenSupervisorInputTaskIDs.insert(taskID)
        if let folderID = currentWorkFolderID, let config {
            config.markTaskSeen(workFolderID: folderID, taskID: taskID)
        }
    }

    func unmarkSupervisorInputSeen(taskID: Int) {
        seenSupervisorInputTaskIDs.remove(taskID)
        if let folderID = currentWorkFolderID, let config {
            config.unmarkTaskSeen(workFolderID: folderID, taskID: taskID)
        }
    }

    /// Clears stale seen flags for tasks no longer `.needsSupervisorInput` or
    /// absent from the index. Sweeps ALL tasks so backgrounded transitions out
    /// of `.needsSupervisorInput` re-trigger the dot on the next question.
    ///
    /// Three guards keep this from destroying persisted state:
    /// 1. Empty mirror → nothing to sweep.
    /// 2. Empty `activeStatuses` → snapshot teardown; every entry would otherwise
    ///    match `nil != .needsSupervisorInput` and get wiped on every folder-close.
    /// 3. Folder-identity mismatch → the caller's snapshot describes a different
    ///    folder than the bound one (folder-switch race); routing unmarks
    ///    through `currentWorkFolderID` would scribble on the wrong namespace.
    func reconcileSeenSet(activeStatuses: [Int: TaskStatus], workFolderID: UUID? = nil) {
        guard !seenSupervisorInputTaskIDs.isEmpty else { return }
        guard !activeStatuses.isEmpty else { return }
        if let workFolderID, let bound = currentWorkFolderID, workFolderID != bound {
            return
        }
        let stale = seenSupervisorInputTaskIDs.filter { taskID in
            activeStatuses[taskID] != .needsSupervisorInput
        }
        for taskID in stale {
            unmarkSupervisorInputSeen(taskID: taskID)
        }
    }

    // MARK: - Actions

    func requestDelete(taskID: Int) {
        taskToDelete = taskID
        isShowingDeleteConfirmation = true
    }

    func requestRename(taskID: Int, currentName: String) {
        renameText = currentName
        taskToRename = taskID
    }

    func collapseSearch() {
        isSearchExpanded = false
        taskSearchText = ""
    }

    func cancelRename() {
        taskToRename = nil
        renameText = ""
    }

    func confirmDelete(store: NTMSOrchestrator) async -> Bool {
        guard let id = taskToDelete else { return false }
        let wasActive = store.activeTaskID == id
        // Drop any queued chat message before the task is gone — prevents leaking
        // into a reincarnated task ID (sequential IDs don't reuse today, but the
        // queue is task-scoped either way).
        QuickCaptureController.shared.discardQueuedChatMessage(taskID: id)
        await store.removeTask(id)
        unmarkSupervisorInputSeen(taskID: id)
        taskToDelete = nil
        return wasActive
    }

    func confirmRename(store: NTMSOrchestrator) async {
        guard let id = taskToRename, !renameText.isEmpty else {
            cancelRename()
            return
        }
        await store.updateTaskTitle(id: id, title: renameText)
        cancelRename()
    }

    // MARK: - Filtering

    func filteredTasks(from tasks: [SidebarTaskItem]) -> [SidebarTaskItem] {
        var result = tasks

        if !taskSearchText.isEmpty {
            // Search always spans ALL tasks, ignoring the active filter tab
            result = result.filter { $0.title.localizedCaseInsensitiveContains(taskSearchText) }
        } else {
            switch taskFilter {
            case .running:   result = result.filter { $0.status != .done }
            case .done:      result = result.filter { $0.status == .done }
            case .recurring: result = result.filter { $0.isRecurring }
            case .all:       break
            }
        }

        return result.sorted { $0.updatedAt > $1.updatedAt }
    }
    nonisolated deinit {}
}
