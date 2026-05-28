import SwiftUI

// MARK: - Main Layout View

/// Primary navigation structure using NavigationSplitView.
/// Main layout with sidebar navigation.
struct MainLayoutView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(OrchestratorEngineState.self) var engineState
    @Environment(StoreConfiguration.self) var config

    @State private var selectedItem: NavigationItem? = .watchtower
    @State private var isPresentingCommandPalette = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var taskState = TaskManagementState()

    // MARK: - Navigation Item

    enum NavigationItem: Hashable {
        case watchtower
        case task(Int)
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(taskState: taskState, selectedItem: $selectedItem)
                .navigationSplitViewColumnWidth(
                    min: WindowLayout.sidebarMinWidth,
                    ideal: WindowLayout.sidebarIdealWidth,
                    max: WindowLayout.sidebarMaxWidth
                )
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .background(Colors.surfacePrimary)
        .sheet(isPresented: $isPresentingCommandPalette) {
            CommandPaletteView(
                selectedItem: $selectedItem,
                isPresented: $isPresentingCommandPalette
            )
        }
        .background {
            Button("Command Palette") { isPresentingCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .errorBanner()
        .onAppear {
            taskState.taskFilter = config.sidebarTaskFilter
            taskState.bind(config: config)
            taskState.loadSeenSet(for: store.snapshot?.projection.id)
        }
        .onChange(of: taskState.taskFilter) { _, newFilter in
            config.sidebarTaskFilter = newFilter
        }
        .onChange(of: store.snapshot?.projection.id) { _, newID in
            // Rehydrate the seen-set mirror on work-folder open/close/switch.
            // Also covers the cold-launch race where `.onAppear` reads
            // `projection.id` as nil and it only becomes non-nil once async
            // bootstrap completes.
            taskState.loadSeenSet(for: newID)
        }
        .onChange(of: allTaskStatuses) { _, newStatuses in
            // Sweep seen flags for ALL tasks (not just the active one) so a
            // backgrounded task transitioning out of `.needsSupervisorInput`
            // re-triggers the dot on its next question.
            taskState.reconcileSeenSet(
                activeStatuses: newStatuses,
                workFolderID: store.snapshot?.projection.id
            )
        }
        .task {
            await store.bootstrapDefaultStorageIfNeeded()
            // Amortize NSOpenPanel allocation so the first `+` click in
            // MessageComposer doesn't pay the AppKit/XPC cold-start cost.
            FilePickerWarmup.warmup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToWatchtower)) { _ in
            selectedItem = .watchtower
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToActiveTask)) { _ in
            if let task = store.activeTask { selectedItem = .task(task.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startRun)) { _ in
            if let taskID = store.activeTaskID { Task { await store.startRun(taskID: taskID) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pauseRun)) { _ in
            if let taskID = store.activeTaskID { Task { await store.pauseRun(taskID: taskID) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeRun)) { _ in
            if let taskID = store.activeTaskID { Task { await store.resumeRun(taskID: taskID) } }
        }
        .onChange(of: selectedItem) { _, newValue in
            if case .task(let taskID) = newValue {
                Task {
                    await store.switchTask(to: taskID)
                    autoDismissNotifications(for: taskID)
                    QuickCaptureController.shared.refreshPanelIfVisible(explicitTaskNavigation: true)
                }
                QuickCaptureController.shared.isTaskSelected = true
                taskState.markSupervisorInputSeen(taskID: taskID)
                NotificationCenter.default.post(name: .scrollFeedToBottom, object: nil)
            } else {
                QuickCaptureController.shared.isTaskSelected = false
                QuickCaptureController.shared.refreshPanelIfVisible()
            }
        }
        .onChange(of: activeTaskDerivedStatus) { oldStatus, newStatus in
            QuickCaptureController.shared.refreshPanelIfVisible()
            // Clear "seen" when task leaves needsSupervisorInput so the indicator
            // can re-trigger on the next question. Also mark seen if the active task
            // enters needsSupervisorInput while the user is already viewing it.
            if let taskID = store.activeTaskID {
                if oldStatus == .needsSupervisorInput, newStatus != .needsSupervisorInput {
                    taskState.unmarkSupervisorInputSeen(taskID: taskID)
                } else if newStatus == .needsSupervisorInput {
                    if case .task(taskID) = selectedItem {
                        taskState.markSupervisorInputSeen(taskID: taskID)
                    } else {
                        // User is on Watchtower or another task — clear "seen" so sidebar shows unread
                        taskState.unmarkSupervisorInputSeen(taskID: taskID)
                    }
                }
            }
        }
        .onChange(of: engineState.taskEngineStates) {
            // Single handler: refreshes the panel + drives queue flush. The controller
            // owns both concerns so the wiring is testable without mounting the view.
            QuickCaptureController.shared.handleEngineStateChanged()
        }
        .onChange(of: store.activeTask?.closedAt) { _, newValue in
            QuickCaptureController.shared.handleActiveTaskClosedAtChanged(
                newValue: newValue, taskID: store.activeTaskID
            )
        }
    }

    /// Derived status from tasksIndex (updated on every mutateTask), not stored task.status.
    private var activeTaskDerivedStatus: TaskStatus? {
        guard let taskID = store.activeTaskID else { return nil }
        return store.snapshot?.tasksIndex.tasks.first { $0.id == taskID }?.status
    }

    /// All-tasks (id, status) dictionary used to drive the reconcile sweep. The
    /// dictionary shape is intentionally Equatable-narrow: it changes only when
    /// a task's status changes (or a task appears/disappears), not on every
    /// `updatedAt` tick — so the `onChange` watcher doesn't churn.
    private var allTaskStatuses: [Int: TaskStatus] {
        guard let summaries = store.snapshot?.tasksIndex.tasks else { return [:] }
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.status) })
    }

    // MARK: - Auto-Dismiss Notifications

    /// Dismisses all Watchtower notifications from the opened task.
    private func autoDismissNotifications(for taskID: Int) {
        guard let task = store.loadedTask(taskID),
              let run = task.runs.last else { return }
        let team = store.resolvedTeam(for: task)
        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: team.roles)
        for notification in notifications {
            config.dismissNotification(id: notification.dismissID)
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .watchtower, .none:
            @Bindable var config = config
            WatchtowerView(taskState: taskState, navigationSelection: $selectedItem, clearedUpToDate: $config.timelineClearedUpToDate)
        case .task(let id):
            if store.activeTask?.id == id {
                TeamBoardView(workFolder: store.workFolder)
                    .id(id)
            } else {
                NTMSLoader(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NTMSBackground())
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .task { await store.switchTask(to: id) }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    MainLayoutView()
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(FolderAccessManager())
        .frame(width: 1000, height: 700)
}
