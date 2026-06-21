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
    @State private var taskState = TaskManagementState()

    // MARK: - Navigation Item

    enum NavigationItem: Hashable {
        case watchtower
        case autovisor
        case task(Int)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Custom flat sidebar — replaces NavigationSplitView's native column
                // (whose vibrancy material can't be removed with a SwiftUI background).
                SidebarView(taskState: taskState, selectedItem: $selectedItem)
                    .frame(width: WindowLayout.sidebarIdealWidth)
                    .frame(maxHeight: .infinity)
                    .background(Colors.surfaceBackground.ignoresSafeArea())
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Colors.borderSubtle)
                            .frame(width: 1)
                            .ignoresSafeArea()
                    }

                // Detail in a NavigationStack so detail toolbars / titles still work.
                NavigationStack {
                    detailView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // tmux-style status bar + keybind footer (sits below ALL panes,
            // including the sidebar — single source of truth for live LLM /
            // run state). Reads model/URL from its own `config` environment so a
            // model switch re-evaluates only the bar, not this whole layout.
            TerminalStatusBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Colors.surfacePrimary)
        .toggleStyle(.terminal)
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
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAutovisor)) { _ in
            selectedItem = .autovisor
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
            // Immediate event-wake for the Autovisor (a task entered
            // needsSupervisorInput / failed / completed). Debounced (fresh pass)
            // or injected live into the conversation (manager mid-review) inside;
            // the poll loop is the level-triggered backstop.
            Task { await store.wakeAutovisorForEvents() }
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
        case .autovisor:
            autovisorDetail
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

    /// The Autovisor's activity feed — its hidden task rendered through the
    /// standard TeamBoard (switchTask makes it active; the sidebar still hides it).
    /// Shows the first-time setup pane (goal field + Enable) whenever the manager
    /// isn't ready to run — `store.autovisorNeedsSetup`: never created, OR created
    /// but disabled with an unset goal. Routing on the SAME predicate the pill /
    /// sidebar use guarantees a "go to setup" click actually lands here, not on a
    /// chat for a manager that won't run. On enable, `setAutovisorEnabled(true)`
    /// creates/re-enables the manager; the next body evaluation sees
    /// `autovisorNeedsSetup == false`, falls into the loader/switchTask branch, and
    /// lands on the chat.
    @ViewBuilder
    private var autovisorDetail: some View {
        if let id = store.autovisorTaskID, !store.autovisorNeedsSetup {
            if store.activeTask?.id == id {
                TeamBoardView(workFolder: store.workFolder).id(id)
            } else {
                NTMSLoader(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NTMSBackground())
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .task { await store.switchTask(to: id) }
            }
        } else {
            AutovisorSetupView()
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
