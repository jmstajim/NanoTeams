import Foundation

/// Observable state for task filter, search, deletion, and renaming in the sidebar.
/// Owned by MainLayoutView and passed to SidebarView.
@MainActor @Observable final class TaskManagementState {
    var taskFilter: TaskFilter = .all
    var taskSearchText: String = ""
    var isSearchExpanded: Bool = false
    var isPresentingNewTask: Bool = false
    var taskToDelete: Int? = nil
    var isShowingDeleteConfirmation: Bool = false
    var taskToRename: Int? = nil
    var renameText: String = ""

    /// Task IDs the user has already "seen" while in needsSupervisorInput status.
    /// Ephemeral — resets on app relaunch so any pending input re-triggers the indicator.
    var seenSupervisorInputTaskIDs: Set<Int> = []

    /// Form state for the in-app new-task sheet. Consolidated from the previous
    /// sheet-* bag of fields so `QuickCaptureFormView` can take a single `@Bindable`.
    let sheetFormState: QuickCaptureFormState = QuickCaptureFormState()

    func markSupervisorInputSeen(taskID: Int) {
        seenSupervisorInputTaskIDs.insert(taskID)
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
        await store.removeTask(id)
        seenSupervisorInputTaskIDs.remove(id)
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
            case .running: result = result.filter { $0.status != .done }
            case .done:    result = result.filter { $0.status == .done }
            case .all:     break
            }
        }

        return result.sorted { $0.updatedAt > $1.updatedAt }
    }
    nonisolated deinit {}
}
