import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full sidebar for MainLayoutView — bold navigation hierarchy.
///
/// Split across extension files:
/// - `SidebarProjectCards.swift` — project info card, default storage card
/// - `SidebarComponents.swift` — SidebarTaskRow, SidebarFilterButton, TaskFilterEmptyState, footer
struct SidebarView: View {
    @Bindable var taskState: TaskManagementState
    @Binding var selectedItem: MainLayoutView.NavigationItem?

    @Environment(NTMSOrchestrator.self) var store
    @Environment(OrchestratorEngineState.self) var engineState
    @Environment(\.openWindow) var openWindow
    @AppStorage(UserDefaultsKeys.selectedSettingsTab) var selectedSettingsTab: SettingsView.SettingsTab = .llm

    // Note: isGeneratingDescription, isPresentingFolderPicker, recentProjects
    // are intentionally internal — accessed from SidebarProjectCards.swift
    @State var isGeneratingDescription = false
    @State var isPresentingFolderPicker = false
    @State private var showCloseProjectConfirmation = false
    @State var recentProjects: [URL] = []
    @State private var isWatchtowerHovered = false
    @State private var isSearchButtonHovered = false
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Body

    var body: some View {
        taskList
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    // Watchtower — primary nav
                    watchtowerButton
                        .padding(.horizontal, Spacing.m)
                        .padding(.top, Spacing.s)
                        .padding(.bottom, Spacing.xs)

                    // Work folder card
                    if let folder = store.workFolderURL {
                        if store.hasRealWorkFolder {
                            projectInfoCard(folder: folder)
                                .padding(.horizontal, Spacing.m)
                                .padding(.bottom, Spacing.xs)
                        } else {
                            defaultStorageCard
                                .padding(.horizontal, Spacing.m)
                                .padding(.bottom, Spacing.xs)
                        }
                    }

                    // Tasks section header
                    tasksHeader
                        .padding(.leading, Spacing.m + Spacing.xs)
                        .padding(.trailing, Spacing.m)
                        .padding(.top, Spacing.m)
                        .padding(.bottom, Spacing.s)

                    if !allTasks.isEmpty || taskState.taskFilter != .all || taskState.isSearchExpanded {
                        taskFilterRow
                            .padding(.horizontal, Spacing.m)
                            .padding(.bottom, Spacing.s)
                    }
                }
                .background(Colors.surfaceBackground)
            }
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
            .confirmationDialog(
                "Remove Task?",
                isPresented: $taskState.isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        let wasActive = await taskState.confirmDelete(store: store)
                        if wasActive { selectedItem = .watchtower }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove the task and all its runs. This action cannot be undone.")
            }
            .alert("Rename Task", isPresented: .init(
                get: { taskState.taskToRename != nil },
                set: { if !$0 { taskState.cancelRename() } }
            )) {
                TextField("Task name", text: $taskState.renameText)
                Button("Rename") { Task { await taskState.confirmRename(store: store) } }
                Button("Cancel", role: .cancel) { taskState.cancelRename() }
            }
            .confirmationDialog(
                "Close Work Folder?",
                isPresented: $showCloseProjectConfirmation,
                titleVisibility: .visible
            ) {
                Button("Close Work Folder", role: .destructive) {
                    Task { await store.closeProject() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tasks are currently running. Closing the work folder will stop all active tasks.")
            }
            .fileImporter(
                isPresented: $isPresentingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await store.openWorkFolder(url) }
                }
            }
            .onAppear { refreshRecentProjects() }
            .onChange(of: store.workFolderURL) { _, newValue in
                guard let url = newValue, store.hasRealWorkFolder else { return }
                store.configuration.lastOpenedWorkFolderPath = url.path
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                refreshRecentProjects()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openProject)) { _ in
                isPresentingFolderPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeProject)) { _ in
                handleCloseProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .createNewTask)) { _ in
                QuickCaptureController.shared.showNewTask()
            }
    }

    // MARK: - Task Data

    private var allTasks: [SidebarTaskItem] {
        store.taskSummaries(filter: .all).map { task in
            let hasUnread = task.isChatMode
                && task.status == .needsSupervisorInput
                && !taskState.seenSupervisorInputTaskIDs.contains(task.id)
            return SidebarTaskItem(
                id: task.id, title: task.title, status: task.status,
                updatedAt: task.updatedAt, isChatMode: task.isChatMode,
                hasUnreadInput: hasUnread
            )
        }
    }

    private var filteredTasks: [SidebarTaskItem] {
        taskState.filteredTasks(from: allTasks)
    }

    // MARK: - Watchtower Button

    private var watchtowerButton: some View {
        let isSelected = selectedItem == .watchtower
        return Button {
            selectedItem = .watchtower
        } label: {
            HStack(spacing: Spacing.s) {
                // Icon circle — accent when selected
                ZStack {
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(isSelected ? Colors.accent : Colors.surfaceElevated)
                        .frame(width: 30, height: 30)
                    Image(systemName: "binoculars.fill")
                        .font(Typography.caption)
                        .foregroundStyle(isSelected ? Colors.surfaceBackground : .secondary)
                }

                Text("Watchtower")
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(isWatchtowerHovered
                        ? Colors.surfaceHover
                        : Colors.surfaceCard)
            )
        }
        .buttonStyle(.plain)
        .onHover { isWatchtowerHovered = $0 }
        .accessibilityHint("Observe team activity and take quick actions")
    }

    // MARK: - Tasks Header & Search

    private var tasksHeader: some View {
        HStack {
            Text("Tasks & Chats")
                .font(Typography.subheadlineSemibold)
                .foregroundStyle(.primary)
            Spacer()
            Button { QuickCaptureController.shared.showNewTask() } label: {
                Image(systemName: "plus")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(Colors.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
            .help("Create new task (⌘N)")
        }
    }

    private var taskFilterRow: some View {
        ZStack {
            if taskState.isSearchExpanded {
                expandedSearchField
                    .transition(.opacity)
            } else {
                filterChips
                    .fixedSize()
                    .transition(.opacity)

                HStack {
                    searchToggleButton
                        .fixedSize()
                    Spacer()
                }
            }
        }
        .frame(height: 28)
    }

    private var filterChips: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(TaskFilter.allCases, id: \.self) { filter in
                SidebarFilterButton(
                    title: filter.displayName,
                    icon: filter.icon,
                    count: filterCount(for: filter),
                    isSelected: taskState.taskFilter == filter
                ) {
                    withAnimation(Animations.quick) { taskState.taskFilter = filter }
                }
            }
        }
    }

    private var searchToggleButton: some View {
        Button {
            withAnimation(Animations.quick) {
                taskState.isSearchExpanded = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(Typography.captionSemibold)
                .padding(.horizontal, 6)
                .padding(.vertical, Spacing.xs)
                .foregroundStyle(.secondary)
                .background(
                    Capsule(style: .continuous).fill(
                        isSearchButtonHovered
                            ? Colors.surfaceElevated
                            : Colors.surfaceCard
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isSearchButtonHovered = $0 }
        .accessibilityLabel("Search tasks")
    }

    private var expandedSearchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .accessibilityHidden(true)

            TextField("Search...", text: $taskState.taskSearchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    if let firstTask = filteredTasks.first {
                        selectedItem = .task(firstTask.id)
                    }
                }
                .onExitCommand {
                    withAnimation(Animations.quick) {
                        taskState.collapseSearch()
                    }
                }

            Button {
                withAnimation(Animations.quick) {
                    taskState.collapseSearch()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Colors.surfacePrimary)
        )
        .task {
            isSearchFieldFocused = true
        }
    }

    private func filterCount(for filter: TaskFilter) -> Int {
        switch filter {
        case .all:     return allTasks.count
        case .running: return allTasks.filter { $0.status != .done }.count
        case .done:    return allTasks.filter { $0.status == .done }.count
        }
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.xxs) {
                if filteredTasks.isEmpty {
                    taskEmptyState
                } else {
                    ForEach(filteredTasks) { task in
                        Button { selectedItem = .task(task.id) } label: {
                            SidebarTaskRow(
                                task: task,
                                isActive: store.activeTaskID == task.id,
                                isSelected: selectedItem == .task(task.id)
                            )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { selectedItem = .task(task.id) } label: {
                                Label("Open Task", systemImage: "arrow.right.circle")
                            }
                            Divider()
                            Button { taskState.requestRename(taskID: task.id, currentName: task.title) } label: {
                                Label("Rename...", systemImage: "pencil")
                            }
                            if task.status != .done {
                                Button {
                                    Task { _ = await store.closeTask(taskID: task.id) }
                                } label: {
                                    Label(
                                        task.isChatMode ? "Close Chat" : "Accept & Close",
                                        systemImage: task.isChatMode ? "xmark.circle" : "checkmark.circle"
                                    )
                                }
                                .disabled(!task.isChatMode && engineState.taskEngineStates[task.id] == .running)
                            }
                            Divider()
                            Button(role: .destructive) {
                                taskState.requestDelete(taskID: task.id)
                            } label: {
                                Label("Remove Task", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.m)
        }
        .background(Colors.surfaceBackground)
    }

    @ViewBuilder
    private var taskEmptyState: some View {
        let emptyState = TaskFilterEmptyState.for(taskState.taskFilter, searchText: taskState.taskSearchText)
        VStack(spacing: Spacing.l) {
            Image(systemName: emptyState.icon)
                .font(.title)
                .foregroundStyle(.tertiary)
            VStack(spacing: Spacing.xs) {
                Text(emptyState.title).font(Typography.subheadlineSemibold)
                Text(emptyState.subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                if !taskState.taskSearchText.isEmpty {
                    withAnimation(Animations.quick) { taskState.collapseSearch() }
                } else if taskState.taskFilter != .all {
                    withAnimation(Animations.quick) { taskState.taskFilter = .all }
                } else {
                    QuickCaptureController.shared.showNewTask()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    if taskState.taskSearchText.isEmpty && taskState.taskFilter == .all {
                        Image(systemName: "plus")
                            .font(Typography.captionSemibold)
                    }
                    Text(emptyStateCTALabel)
                        .font(Typography.captionSemibold)
                }
                .foregroundStyle(Colors.surfaceBackground)
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.s)
                .background(Capsule(style: .continuous).fill(Colors.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Spacing.xl)
    }

    private var emptyStateCTALabel: String {
        if !taskState.taskSearchText.isEmpty { return "Clear Search" }
        if taskState.taskFilter != .all { return "Show All" }
        return "New Task"
    }

    // MARK: - Helpers

    func handleCloseProject() {
        if store.hasRunningTasks { showCloseProjectConfirmation = true }
        else { Task { await store.closeProject() } }
    }

    private func refreshRecentProjects() {
        recentProjects = NSDocumentController.shared.recentDocumentURLs
    }
}

// MARK: - Preview Helpers

private func makePreviewStore(
    folder: URL? = nil,
    engineRunning: Bool = false,
    tasks: [TaskSummary] = [],
    activeTaskID: Int? = nil
) -> NTMSOrchestrator {
    let s = NTMSOrchestrator(repository: NTMSRepository())
    s.workFolderURL = folder
    if !tasks.isEmpty {
        s.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: folder?.lastPathComponent ?? "Preview"),
                settings: .defaults,
                teams: Team.defaultTeams
            ),
            tasksIndex: TasksIndex(tasks: tasks),
            toolDefinitions: [],
            activeTaskID: activeTaskID
        )
    }
    if engineRunning { s.engineState[0] = .running }
    return s
}

private func makeFilteredTaskState() -> TaskManagementState {
    let s = TaskManagementState()
    s.taskFilter = .running
    return s
}

private let previewTaskIDs: (Int, Int, Int) = (1, 2, 3)

private func makePreviewStoreWithTasks() -> NTMSOrchestrator {
    let (idA, idB, idC) = previewTaskIDs
    let tasks = [
        TaskSummary(id: idA, title: "Implement sorting algorithm", status: .running),
        TaskSummary(id: idB, title: "Fix login screen layout", status: .paused),
        TaskSummary(id: idC, title: "Add user authentication", status: .needsSupervisorInput),
    ]
    let store = makePreviewStore(folder: URL(fileURLWithPath: "/Users/dev/MyProject"), tasks: tasks)
    #if DEBUG
    store._setActiveTaskID(idC)
    #endif
    return store
}

// MARK: - Previews

#Preview("Sidebar — No Folder") {
    @Previewable @State var store = makePreviewStore(folder: NTMSOrchestrator.defaultStorageURL)
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — Work Folder") {
    @Previewable @State var store = makePreviewStore(folder: URL(fileURLWithPath: "/Users/dev/MyProject"))
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — Engine Running") {
    @Previewable @State var store = makePreviewStore(folder: URL(fileURLWithPath: "/Users/dev/MyProject"), engineRunning: true)
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — With Tasks") {
    @Previewable @State var store = makePreviewStoreWithTasks()
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .task(previewTaskIDs.0)
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 600)
}
