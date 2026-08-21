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

    /// The task the user is actually LOOKING at, for `PrefixCacheReporter.onScreenTaskID`.
    ///
    /// An exhaustive `switch`, never an `if case` chain: this enum gains cases (`.autovisor` is
    /// itself recent), and an `else` arm would silently map a new task-bearing destination to
    /// `nil` — the cache-miss banner would go quiet there with no compile error anywhere.
    static func onScreenTaskID(
        for item: NavigationItem?, autovisorTaskID: Int?
    ) -> Int? {
        switch item {
        case .task(let taskID): taskID
        case .autovisor: autovisorTaskID
        case .watchtower, nil: nil
        }
    }

    // MARK: - Body

    var body: some View {
        // Split from `mainContent` deliberately: the layout's modifier chain had
        // grown past the type-checker's budget, and SwiftUI reports that as a
        // timeout on whichever line the solver gave up at. Two expressions solve
        // independently (CLAUDE.md #10, same failure mode as large array literals).
        mainContent
            .onChange(of: allTaskWaitStates) { _, newStates in
                // Sweep seen flags for ALL tasks (not just the active one) so a
                // backgrounded task that stops waiting re-triggers the dot on its next
                // question. Its own observer, and keyed on the DURABLE wait state rather
                // than `TaskStatus`: recovery parks every waiting step at launch, which a
                // status-keyed sweep read as "answered" and used to wipe the whole
                // persisted set on startup.
                taskState.reconcileSeenSet(
                    waitStates: newStates,
                    workFolderID: store.snapshot?.projection.id
                )
            }
            .onChange(of: activeTaskObservation) { previous, current in
                let viewing = current.map { selectedItem == .task($0.taskID) } ?? false
                let decision = SupervisorSeenPolicy.onChange(
                    previous: previous, current: current, isViewing: viewing)
                applySeen(decision.seen)
                if let taskID = current?.taskID, !decision.dismissQuestionIDs.isEmpty {
                    // The Supervisor is reading this chat right now, so the questions
                    // that just arrived are already seen. Without this, nothing ever
                    // retires a reply that landed in an OPEN chat — and since every
                    // chat-mode turn is an `ask_supervisor` call and the app always
                    // launches on the Watchtower, the inbox re-listed every reply the
                    // user had already read after each restart.
                    dismissSupervisorInputNotifications(
                        for: taskID, questionIDs: decision.dismissQuestionIDs)
                }
            }
    }

    private var mainContent: some View {
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
        .onChange(of: allTaskStatuses) { _, _ in
            // Immediate Autovisor wake on ANY derived task-status change. The
            // itemizer (`autovisorAttentionItems`) reads BOTH live engine state
            // (needsSupervisor) AND derived summary status (failed / completed /
            // created); the sibling `taskEngineStates` observer below covers only
            // the former. A team-generation failure flips the task to `.failed`
            // WITHOUT an engine transition (no engine is ever created), so without
            // this it would reach the manager only via the ≤60s poll backstop.
            // Mirror the itemizer here so no watchable condition depends on the
            // poll for delivery. Cheap + safe to over-fire: `wakeAutovisorForEvents`
            // self-guards (feature off / no manager → no-op) and is deliver-once —
            // a `.running` transition matches no trigger and no-ops, and a duplicate
            // wake for a condition already recorded in `autovisorLastPassAttentionKeys`
            // bails (the same synchronous serialization the two observers already rely on).
            Task { await store.wakeAutovisorForEvents() }
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
        .onChange(of: selectedItem, initial: true) { _, newValue in
            // What the user is actually LOOKING at, which `store.activeTaskID` is not: that is
            // "last task ever opened", it is never reset to nil, and opening the Autovisor pane
            // calls `switchTask(to:)`. Without this mirror a manager waking every 60 s would
            // banner about its own cache misses while the user sits on the Watchtower.
            store.prefixCacheReporter.onScreenTaskID = Self.onScreenTaskID(
                for: newValue, autovisorTaskID: store.autovisorTaskID)
        }
        .onChange(of: selectedItem) { _, newValue in
            // Deliberately a SECOND observer of the same key, not a merge candidate. The mirror
            // above needs `initial: true` (the first run the user watches must be able to
            // banner); giving THIS block an initial fire would run `switchTask` /
            // `markSupervisorInputSeen` / `.scrollFeedToBottom` once at launch. Merging would
            // therefore need an "is this the initial call" guard around half the closure — more
            // state than the second observer costs.
            if case .task(let taskID) = newValue {
                Task {
                    await store.switchTask(to: taskID)
                    // Opening a task retires ALL of its banners, as before. The seen
                    // flag goes through the policy so opening a QUIET task clears it
                    // instead of freezing it — a frozen flag survives the sweep (which
                    // only clears non-waiting tasks) and would swallow the dot on that
                    // task's next question.
                    autoDismissNotifications(for: taskID)
                    let opened = store.loadedTask(taskID)
                    applySeen(SupervisorSeenPolicy.onOpen(
                        taskID: taskID,
                        questionIDs: opened?.activeSupervisorQuestionIDs ?? [],
                        isWaiting: opened?.hasPendingSupervisorInput ?? false))
                    QuickCaptureController.shared.refreshPanelIfVisible(explicitTaskNavigation: true)
                }
                QuickCaptureController.shared.isTaskSelected = true
                NotificationCenter.default.post(name: .scrollFeedToBottom, object: nil)
            } else {
                QuickCaptureController.shared.isTaskSelected = false
                QuickCaptureController.shared.refreshPanelIfVisible()
            }
        }
        .onChange(of: activeTaskDerivedStatus) { _, _ in
            // Panel refresh only. The seen/dismiss decision moved to the observer
            // below, which watches the QUESTIONS rather than the coarse status —
            // this one still has to fire on every status change for Quick Capture.
            QuickCaptureController.shared.refreshPanelIfVisible()
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
        .modelResidencyHooks(store: store)
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

    /// Sibling of `allTaskStatuses`, carrying the DURABLE "is this task waiting on the
    /// Supervisor" fact instead of the run-control status. Deliberately a separate
    /// projection rather than a widening of the one above: that one drives the
    /// Autovisor wake and must keep firing on `.failed` / `.done`, which this fact
    /// does not distinguish. Equatable-narrow for the same reason — it flips only on
    /// the fact, never on an `updatedAt` tick.
    private var allTaskWaitStates: [Int: SupervisorWaitState] {
        guard let summaries = store.snapshot?.tasksIndex.tasks else { return [:] }
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, SupervisorWaitState($0)) })
    }

    /// The active task's live question identities, for `SupervisorSeenPolicy`.
    ///
    /// Excludes the Autovisor: its manager parks on `wait_for_events`, which is an
    /// `ask_supervisor` call like any other, so viewing that pane would otherwise
    /// churn the policy for a question no human was asked.
    private var activeTaskObservation: SupervisorSeenPolicy.Observation? {
        guard let taskID = store.activeTaskID, taskID != store.autovisorTaskID else { return nil }
        guard let task = store.loadedTask(taskID) else { return nil }
        return SupervisorSeenPolicy.Observation(
            taskID: taskID,
            questionIDs: task.activeSupervisorQuestionIDs,
            isWaiting: task.hasPendingSupervisorInput)
    }

    // MARK: - Seen / Dismiss

    private func applySeen(_ action: SupervisorSeenPolicy.SeenAction) {
        switch action {
        case .mark(let taskID):  taskState.markSupervisorInputSeen(taskID: taskID)
        case .clear(let taskID): taskState.unmarkSupervisorInputSeen(taskID: taskID)
        case .none:              break
        }
    }

    /// Dismisses all Watchtower notifications from the opened task.
    private func autoDismissNotifications(for taskID: Int) {
        dismissNotifications(for: taskID) { _ in true }
    }

    /// Retires only the `.supervisorInput` banners naming the given questions.
    ///
    /// Narrow on purpose: this fires while the Supervisor is READING a chat, and
    /// "dismiss everything for this task" would also silently swallow a `.failed` or
    /// `.acceptance` banner they have not looked at.
    private func dismissSupervisorInputNotifications(for taskID: Int, questionIDs: Set<UUID>) {
        dismissNotifications(for: taskID) { type in
            guard case .supervisorInput(_, _, _, let toolCallID) = type,
                  let toolCallID else { return false }
            return questionIDs.contains(toolCallID)
        }
    }

    private func dismissNotifications(
        for taskID: Int,
        matching predicate: (WatchtowerNotificationType) -> Bool
    ) {
        guard let workFolderID = store.snapshot?.projection.id,
              let task = store.loadedTask(taskID) else { return }
        let notifications = WatchtowerInboxBuilder.build(
            [.init(task: task, teamRoles: store.resolvedTeam(for: task).roles)],
            bashApprovals: Array(store.bashApprovalRequests.values)
        )
        for notification in notifications where predicate(notification.type) {
            config.dismissNotification(workFolderID: workFolderID, key: notification.dismissKey)
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
    /// Shows the setup pane (goal field + Enable) whenever the manager isn't running
    /// — `store.autovisorShowsSetupPane`: never created, OR created but disabled.
    /// A disabled manager keeps its task, so without that rule this would render a
    /// chat nothing can drive, with no visible way to turn it back on. On enable,
    /// `setAutovisorEnabled(true)` creates/re-enables the manager; the next body
    /// evaluation falls into the loader/switchTask branch and lands on the chat,
    /// prior conversation intact.
    @ViewBuilder
    private var autovisorDetail: some View {
        if !store.autovisorShowsSetupPane, let id = store.autovisorTaskID {
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
