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

    /// The sidebar's row cache. `@ObservationIgnored` so a body pass may write it
    /// (`sidebarRows` runs inside `SidebarView.body`, and a view may not write its own
    /// `@State` there; an observed property written during body would re-invalidate the
    /// view that is being evaluated). Lives here rather than on the projection because its
    /// inputs are view-side facts this class already owns or is handed (#91: the seen set
    /// has one home, and it is this one).
    @ObservationIgnored
    private var rowsMemo = SidebarViewLogic.RowsMemo()

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

    /// Drops every persisted UI marker for a task that no longer exists — both the
    /// sidebar seen flag and the Watchtower dismissals. The sampling GC would reclaim
    /// the dismissals too (`WatchtowerInboxBuilder.staleDismissals` expires a key whose
    /// task is gone from the index), but only at a Watchtower refresh, and only while
    /// one is mounted; forgetting them at the deletion itself keeps a deleted task's
    /// keys from riding the set through sessions that never show the Watchtower.
    func forgetTask(taskID: Int) {
        unmarkSupervisorInputSeen(taskID: taskID)
        if let folderID = currentWorkFolderID, let config {
            config.forgetDismissals(workFolderID: folderID, taskID: taskID)
        }
    }

    /// Clears stale seen flags for tasks that are no longer waiting on the
    /// Supervisor, or absent from the index. Sweeps ALL tasks so backgrounded
    /// transitions out of "waiting" re-trigger the dot on the next question.
    ///
    /// Keyed on `SupervisorWaitState`, never on `TaskStatus`: recovery parks every
    /// waiting step to `.paused` at launch while leaving the question intact, so a
    /// status-keyed sweep read "parked but still waiting" as "answered" and deleted
    /// the persisted flag on every single launch.
    ///
    /// Four guards keep this from destroying persisted state:
    /// 1. Empty mirror → nothing to sweep.
    /// 2. Empty `waitStates` → snapshot teardown; every entry would otherwise look
    ///    absent-from-index and get wiped on every folder-close.
    /// 3. Folder-identity mismatch → the caller's snapshot describes a different
    ///    folder than the bound one (folder-switch race); routing unmarks
    ///    through `currentWorkFolderID` would scribble on the wrong namespace.
    /// 4. `.unknown` per task → a legacy index row carries no information, and
    ///    treating it as "answered" would wipe every flag on the first launch
    ///    after the upgrade — the exact failure this sweep is being fixed for.
    func reconcileSeenSet(waitStates: [Int: SupervisorWaitState], workFolderID: UUID? = nil) {
        guard !seenSupervisorInputTaskIDs.isEmpty else { return }
        guard !waitStates.isEmpty else { return }
        if let workFolderID, let bound = currentWorkFolderID, workFolderID != bound {
            return
        }
        let stale = seenSupervisorInputTaskIDs.filter { taskID in
            switch waitStates[taskID] {
            case .none:            return true   // gone from the index → task deleted
            case .some(.notWaiting): return true
            case .some(.waiting), .some(.unknown): return false
            }
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
        forgetTask(taskID: id)
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

    // MARK: - Sidebar rows

    /// The sidebar's `[SidebarTaskItem]`, memoised on `TaskFactsProjection.rowsRevision`,
    /// `store.autovisorTaskID` (the second input of `TaskService.taskSummaries`) and the four
    /// view-side inputs (seen / bash / engine states / initializing) — `SidebarViewLogic.RowsKey`.
    ///
    /// This is the body of what used to be `SidebarView.allTasks`, which rebuilt the whole
    /// array on every body pass — and `SidebarView` is always mounted and reads
    /// `store.snapshot`, so that was Θ(T) per `mutateTask`, i.e. per LLM message, while a
    /// message append changes no row the sidebar shows. `store.taskSummaries(filter:)` is
    /// evaluated ONLY inside the miss closure, so on a hit the body never walks the index
    /// through this path. (It still re-runs per `mutateTask` through its other
    /// `store.snapshot` roots — `autovisorTaskID` below is one — so this removes the index
    /// walk and the row build from the pass; `filteredTasks` / `filterCounts` still run Θ(T)
    /// over the cached array, and the pass count is unchanged.)
    func sidebarRows(store: NTMSOrchestrator, engineState: OrchestratorEngineState) -> [SidebarTaskItem] {
        let key = SidebarViewLogic.RowsKey(
            rowsRevision: store.taskFacts.rowsRevision,
            autovisorTaskID: store.autovisorTaskID,
            seenSupervisorInputTaskIDs: seenSupervisorInputTaskIDs,
            bashApprovalTaskIDs: Set(store.bashApprovalRequests.keys.map(\.taskID)),
            engineStates: engineState.taskEngineStates,
            initializingTaskIDs: engineState.initializingRunTaskIDs
        )
        return rowsMemo.items(for: key) {
            SidebarViewLogic.buildSidebarTaskItems(
                summaries: store.taskSummaries(filter: .all),
                seenSupervisorInputTaskIDs: key.seenSupervisorInputTaskIDs,
                bashApprovalTaskIDs: key.bashApprovalTaskIDs,
                engineStates: key.engineStates,
                initializingTaskIDs: key.initializingTaskIDs
            )
        }
    }

    // MARK: - Filtering

    func filteredTasks(from tasks: [SidebarTaskItem]) -> [SidebarTaskItem] {
        var result = tasks

        if !taskSearchText.isEmpty {
            // Search always spans ALL tasks, ignoring the active filter tab
            result = result.filter { $0.title.localizedCaseInsensitiveContains(taskSearchText) }
        } else if taskFilter != .all {
            // Through `SidebarViewLogic.matches` on purpose: the pill COUNTS and
            // the row filter answered the same question from two hand-written
            // copies of the same three predicates. One home, so a pill can never
            // promise a row count the list does not show.
            result = result.filter { SidebarViewLogic.matches(taskFilter, $0) }
        }

        // No sort, for the same reason as `TaskService.taskSummaries`: the order is
        // established on the write side by `TasksIndex.upsert` and preserved by `filter`.
        // This was the SECOND re-sort of the same already-sorted rows on one read path.
        return result
    }
    nonisolated deinit {}
}
