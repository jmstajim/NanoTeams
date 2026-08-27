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

    // Note: isPresentingFolderPicker and recentProjects are intentionally
    // internal — accessed from SidebarWorkFolderCards.swift.
    @State var isPresentingFolderPicker = false
    @State private var showCloseProjectConfirmation = false
    @State private var showDeleteManagerConfirmation = false
    @State var recentProjects: [URL] = []
    @State private var isWatchtowerHovered = false
    @State private var isAutovisorHovered = false
    @State private var isSearchButtonHovered = false
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Body

    var body: some View {
        // Computed ONCE per body pass and threaded down. Both used to be computed
        // PROPERTIES, which SwiftUI re-evaluates at every reference — measured 9
        // references per pass (`tasksHeader`, 4× inside `ForEach(TaskFilter.allCases)`
        // in `filterChips`, `expandedSearchField`, and 3× in `taskList`). Each
        // evaluation rebuilt the whole `SidebarTaskItem` array from `tasksIndex`, and
        // this view is always mounted and reads `store.snapshot` — so the pass ran on
        // every `mutateTask`, i.e. on every LLM message.
        let tasks = allTasks
        let visibleTasks = taskState.filteredTasks(from: tasks)
        taskList(visibleTasks)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    // Watchtower — primary nav (full-width flat row)
                    watchtowerButton
                        .padding(.top, Spacing.m)

                    // Autovisor — full-width flat nav row, shown only while enabled.
                    // Sits directly under Watchtower so the two top-level nav
                    // surfaces cluster together above the work-folder context block.
                    if let info = autovisorInfo {
                        autovisorButton(info)
                    }

                    // Work folder — flat full-width DS block (bottom border, no card)
                    if let folder = store.workFolderURL {
                        if store.hasRealWorkFolder {
                            projectInfoCard(folder: folder)
                        } else {
                            defaultStorageCard
                        }
                    }

                    // Tasks section header
                    tasksHeader(tasks)
                        .padding(.leading, Spacing.m)
                        .padding(.trailing, Spacing.m)
                        .padding(.top, Spacing.m)
                        .padding(.bottom, Spacing.s)

                    if !tasks.isEmpty || taskState.taskFilter != .all || taskState.isSearchExpanded {
                        taskFilterRow(tasks, visibleTasks)
                            .padding(.horizontal, Spacing.m)
                            .padding(.bottom, Spacing.s)
                    }
                }
                .background(Colors.surfaceBackground)
            }
            // Flat DS sidebar — fill the whole column (incl. the titlebar strip
            // behind the traffic lights) with the opaque `void` surface so the
            // native NavigationSplitView vibrancy never shows, and draw the
            // design's hairline right border.
            .background(Colors.surfaceBackground.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Colors.borderSubtle)
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
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
                // ds:allow-custom-input native .alert accessory — SwiftUI owns this field's chrome
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
            .confirmationDialog(
                "Delete Autovisor?",
                isPresented: $showDeleteManagerConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        let wasAutovisorSelected = (selectedItem == .autovisor)
                        await store.deleteAutovisor()
                        if wasAutovisorSelected { selectedItem = .watchtower }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the Autovisor and its history, and turns the feature off. You can re-enable it later in Settings → Autovisor.")
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
            // The URL flips at the START of an open, so it says which folder was ASKED for,
            // not which one loaded. Cancelling a generation is right on that signal — it
            // belongs to the folder being left either way.
            .onChange(of: store.workFolderURL) { _, _ in
                store.cancelWorkFolderContextGeneration()
            }
            // Recents, by contrast, must only ever record a folder that actually opened. The
            // snapshot's folder id changes on `apply` (success) and goes nil on the failure
            // path's `discardWorkFolderState`, so it is the outcome signal the URL is not.
            // Keyed here rather than in the orchestrator because `NSDocumentController` is
            // AppKit; the paired `lastOpenedWorkFolderPath` write moved into `openWorkFolder`,
            // which is the only place that knows the open succeeded.
            .onChange(of: store.snapshot?.projection.id) { _, newValue in
                guard newValue != nil, let url = store.workFolderURL, store.hasRealWorkFolder
                else { return }
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
        SidebarViewLogic.buildSidebarTaskItems(
            summaries: store.taskSummaries(filter: .all),
            seenSupervisorInputTaskIDs: taskState.seenSupervisorInputTaskIDs,
            bashApprovalTaskIDs: Set(store.bashApprovalRequests.keys.map(\.taskID)),
            engineStates: engineState.taskEngineStates,
            initializingTaskIDs: engineState.initializingRunTaskIDs
        )
    }

    /// Live state for the Autovisor nav entry (resolution delegated to
    /// `SidebarViewLogic.resolveManagerRowInfo`). `nil` (entry hidden) ONLY when
    /// there's no real work folder — Autovisor is folder-scoped and refuses to
    /// enable in default storage. In a folder the row is always visible:
    /// configured → routes to the chat; unconfigured → routes to the first-time
    /// setup pane (`AutovisorSetupView`).
    private var autovisorInfo: SidebarViewLogic.ManagerRowInfo? {
        let isManagerActive = store.autovisorTaskID != nil
            && store.workFolder?.settings.autovisorEnabled == true
        let state = store.autovisorTaskID.flatMap { engineState.taskEngineStates[$0] }
        return SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: store.hasRealWorkFolder,
            isManagerActive: isManagerActive,
            engineState: state,
            isIdleParked: store.autovisorIsIdleParked
        )
    }

    // MARK: - Watchtower Button

    private var watchtowerButton: some View {
        Button {
            selectedItem = .watchtower
        } label: {
            terminalNavRowContent(
                icon: "binoculars",
                title: "watchtower",
                accessibilityName: "Watchtower",
                isSelected: selectedItem == .watchtower,
                status: .none
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .terminalNavRowLabelInset()
        }
        .buttonStyle(.plain)
        .terminalNavRowChrome(
            isSelected: selectedItem == .watchtower,
            isHovered: isWatchtowerHovered
        )
        .onHover { isWatchtowerHovered = $0 }
        .accessibilityHint("Observe team activity and take quick actions")
    }

    /// Live state for a terminal nav-row's trailing indicator.
    /// `none` keeps the trailing edge empty (no ambient noise); `working` and
    /// `needsInput` render a glyph + uppercase-mono label per the design's tmux
    /// pane-status pattern.
    private enum NavRowStatus: Equatable {
        case none
        case working
        case needsInput
    }

    /// Inner content of a terminal nav row: leading SF Symbol anchor + lowercase
    /// mono identity (CLI namespace style) + tmux-style trailing status badge.
    /// The icon telegraphs "navigable destination" — without it, the lowercase
    /// title visually competes with the uppercase section headers below
    /// (`WORK FOLDER`, `TASKS`) and reads as a label, not a button. Wrapped by
    /// `terminalNavRowChrome` to add the inset squircle accentTint fill on
    /// selection and hover fill. Splitting content from chrome lets the Autovisor
    /// row include a trailing ⋯ Menu inside the same selection envelope without
    /// double-painting the fill.
    private func terminalNavRowContent(
        icon: String,
        title: String,
        accessibilityName: String,
        isSelected: Bool,
        status: NavRowStatus
    ) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                // Fixed-width slot keeps title baseline aligned across rows
                // even when icons have different intrinsic widths.
                .font(Typography.subheadlineMedium)
                .foregroundStyle(isSelected ? Colors.accent : Colors.textSecondary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
                // Fixed weight across selected / unselected so the cell
                // doesn't reflow on selection.
                .font(Typography.subheadlineMedium)
                .foregroundStyle(isSelected ? Colors.accent : Colors.textPrimary)
                .lineLimit(1)
                .accessibilityLabel(accessibilityName)
            Spacer(minLength: Spacing.s)
            navStatusIndicator(for: status)
        }
    }

    /// Trailing status badge for `terminalNavRow`. `NTMSLoader` carries
    /// motion (mid-stream LLM work); the `◆` glyph + `WAITING` label calls out
    /// human-blocking states without re-using the accent color (info hue).
    @ViewBuilder
    private func navStatusIndicator(for status: NavRowStatus) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .working:
            HStack(spacing: Spacing.xs) {
                NTMSLoader(font: Typography.term2xs, color: Colors.accent)
                Text("WORKING")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.accent)
            }
            // Breathing room so the label doesn't butt against a trailing ⋯ menu.
            .padding(.trailing, Spacing.xs)
            .accessibilityLabel("Working")
        case .needsInput:
            HStack(spacing: Spacing.xs) {
                Text(TerminalGlyph.review)
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.info)
                Text("WAITING")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.info)
            }
            .padding(.trailing, Spacing.xs)
            .accessibilityLabel("Waiting on Supervisor input")
        }
    }

    // MARK: - Tasks Header & Search

    private func tasksHeader(_ tasks: [SidebarTaskItem]) -> some View {
        HStack(spacing: Spacing.xs) {
            MonoLabel(text: "Tasks", marker: true)
            // `(N)` count chip per the design's tmux ledger heading.
            Text("(\(tasks.count))")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textTertiary)
                .monospacedDigit()
                .accessibilityHidden(true)
            Spacer()
            Button { QuickCaptureController.shared.showNewTask() } label: {
                Image(systemName: "plus")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.surfaceElevated)
                            .overlay(
                                RoundedRectangle.squircle(CornerRadius.small)
                                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help("Create new task (⌘N)")
        }
    }

    private func taskFilterRow(
        _ tasks: [SidebarTaskItem], _ visibleTasks: [SidebarTaskItem]
    ) -> some View {
        ZStack {
            if taskState.isSearchExpanded {
                expandedSearchField(visibleTasks)
                    .transition(.opacity)
            } else {
                HStack(spacing: Spacing.xs) {
                    searchToggleButton
                        .fixedSize()
                    filterChips(SidebarViewLogic.filterCounts(from: tasks))
                        .fixedSize()
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .frame(height: 28)
    }

    /// Takes the already-counted pills rather than the item array: the `ForEach`
    /// below runs its body once per filter, so a per-filter count here was four
    /// whole-array passes (three of them allocating) per body pass.
    private func filterChips(_ counts: SidebarViewLogic.FilterCounts) -> some View {
        HStack(spacing: Spacing.xs) {
            ForEach(TaskFilter.allCases, id: \.self) { filter in
                SidebarFilterButton(
                    title: filter.displayName,
                    icon: filter.icon,
                    count: counts[filter],
                    isSelected: taskState.taskFilter == filter,
                    iconOnly: filter.isIconOnly
                ) {
                    withAnimation(Animations.quick) { taskState.taskFilter = filter }
                }
            }
        }
    }

    /// Flat DS — drop the rounded card / border / surfaceCard fill. The chip is
    /// just the SF Symbol glyph; selection chrome is reserved for the filters
    /// themselves. Hover supplies the only ambient affordance.
    private var searchToggleButton: some View {
        Button {
            withAnimation(Animations.quick) {
                taskState.isSearchExpanded = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textTertiary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background {
                    if isSearchButtonHovered {
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.surfaceHover)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isSearchButtonHovered = $0 }
        .accessibilityLabel("Search tasks")
        .help("Search tasks")
    }

    /// Terminal search input: `/` prompt prefix (vim/less idiom) + mono field,
    /// no rounded card. An accent hairline along the bottom marks the focused
    /// element; a mono `ESC` mini-label on the right doubles as a tap target
    /// AND teaches the keyboard shortcut (canonical terminal pattern).
    private func expandedSearchField(_ visibleTasks: [SidebarTaskItem]) -> some View {
        HStack(spacing: Spacing.xs) {
            Text("/")
                .font(Typography.termBase)
                .foregroundStyle(Colors.accent)
                .accessibilityHidden(true)

            // An accent bottom hairline IS the chrome here, deliberately not a box — see the
            // doc comment on `expandedSearchField`.
            // ds:allow-custom-input vim-`/` prompt line, deliberately unboxed
            TextField("search…", text: $taskState.taskSearchText)
                .textFieldStyle(.plain)
                .font(Typography.termSm)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    if let firstTask = visibleTasks.first {
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
                Text("ESC")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, Spacing.xs)
        .frame(height: 28)
        .background(Colors.surfaceElevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Colors.accent)
                .frame(height: 1)
        }
        .task {
            isSearchFieldFocused = true
        }
    }

    // MARK: - Task List

    private func taskList(_ visibleTasks: [SidebarTaskItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.xxs) {
                if visibleTasks.isEmpty {
                    taskEmptyState
                } else {
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { offset, task in
                        Button { selectedItem = .task(task.id) } label: {
                            SidebarTaskRow(
                                task: task,
                                isSelected: selectedItem == .task(task.id),
                                displayIndex: offset + 1
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
        }
        .background(Colors.surfaceBackground)
    }

    /// Top-level, Watchtower-style selectable nav entry for the Autovisor,
    /// shown under the work-folder card while the manager is enabled. Tapping routes
    /// to `.autovisor` (its chat); the ⋯ menu offers Open Chat, Disable,
    /// Delete, and Autovisor Settings (mirroring the work-folder card's menu affordance).
    @ViewBuilder
    private func autovisorButton(_ info: SidebarViewLogic.ManagerRowInfo) -> some View {
        let isSelected = selectedItem == .autovisor
        // `needsInput` outranks `running` — a Supervisor-blocking question is the
        // louder signal even while the engine is technically also live.
        let status: NavRowStatus = {
            if info.needsInput { return .needsInput }
            if info.running    { return .working }
            return .none
        }()
        HStack(spacing: 0) {
            Button {
                selectedItem = .autovisor
            } label: {
                terminalNavRowContent(
                    icon: AutovisorConstants.symbolName,
                    title: "autovisor",
                    accessibilityName: "Autovisor",
                    isSelected: isSelected,
                    status: status
                )
                // Stretch the label across the row so the empty area between the
                // status indicator and the ⋯ Menu is part of the button's tap
                // target, then bake the chrome's leading + vertical inner padding
                // INTO the label (via `terminalNavRowLabelInset`) so the visible
                // squircle's interior is fully clickable. Without these, the
                // Button takes only its intrinsic width (icon + title + status)
                // and the surrounding squircle pixels read as the row but tap
                // through to nothing.
                .frame(maxWidth: .infinity, alignment: .leading)
                .terminalNavRowLabelInset(trailing: 0)
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                store.autovisorShowsSetupPane
                    ? "Opens the Autovisor setup pane"
                    : "Open the Autovisor chat"
            )

            Menu {
                Button { selectedItem = .autovisor } label: {
                    // Label names the destination `autovisorDetail` actually routes
                    // to, from the same predicate — a disabled manager lands on
                    // setup, so calling it "Open Chat" would be a lie.
                    Label(
                        store.autovisorShowsSetupPane ? "Open Setup" : "Open Chat",
                        systemImage: "arrow.right.circle"
                    )
                }
                // Disable / Delete only make sense for a configured manager —
                // an unconfigured row has nothing to disable or delete.
                if info.isEnabled {
                    Divider()
                    Button {
                        // Stay on `.autovisor` if that's where we are: disabling now
                        // flips the pane to setup, which IS the answer to "how do I
                        // turn this back on". Bouncing to the Watchtower would hide it.
                        Task { await store.setAutovisorEnabled(false) }
                    } label: {
                        Label("Disable", systemImage: "pause.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteManagerConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Divider()
                Button {
                    SettingsNavigation.open(tab: .autovisor, using: openWindow)
                } label: {
                    Label("Autovisor Settings", systemImage: "gearshape")
                }
            } label: {
                SidebarIconButton(icon: "ellipsis")
                    // Vertical-only inset preserves the menu's tap target
                    // height to match the row chrome; horizontal positioning
                    // is handled entirely by the chrome + .offset below so
                    // the autovisor ⋯ visually aligns with the work-folder
                    // card's ⋯ regardless of SwiftUI's borderlessButton
                    // menu-label internal centering.
                    .terminalNavRowLabelInset(leading: 0, trailing: 0)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // Both ⋯ menus share the same SidebarIconButton + .borderlessButton
            // label. This row's chrome trails by `chromeHInset`; the folder card
            // trails by `menuTrailingInset`. Nudge this ⋯ LEFT by the difference
            // (`autovisorMenuNudge`, derived) so the two line up at the same x.
            .offset(x: -SidebarNavRowMetrics.autovisorMenuNudge)
        }
        // Shared chrome: inset squircle accentTint fill on selection, hover
        // fill, outer horizontal margin. The trailing ⋯ menu sits inside the
        // same selection envelope so the row reads as one unit; tap routing
        // still splits between the row's Button and the Menu.
        .terminalNavRowChrome(
            isSelected: isSelected,
            isHovered: isAutovisorHovered
        )
        .onHover { isAutovisorHovered = $0 }
    }

    @ViewBuilder
    private var taskEmptyState: some View {
        let emptyState = TaskFilterEmptyState.for(taskState.taskFilter, searchText: taskState.taskSearchText)
        VStack(spacing: Spacing.l) {
            Image(systemName: emptyState.icon)
                .font(Typography.term2xl)
                .foregroundStyle(Colors.textTertiary)
            VStack(spacing: Spacing.xs) {
                Text(emptyState.title).font(Typography.subheadlineSemibold)
                Text(emptyState.subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
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
                .foregroundStyle(Colors.textOnAccent)
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.s)
                .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Spacing.xl)
    }

    private var emptyStateCTALabel: String {
        SidebarViewLogic.resolveCTALabel(searchText: taskState.taskSearchText, filter: taskState.taskFilter)
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

// MARK: - Nav-Row Metrics

/// Geometry shared between the Autovisor nav row and the work-folder card so their
/// trailing ⋯ menus align at the same x from the sidebar edge. Single source of
/// truth for what used to be three independent magic numbers across two files
/// (chrome H-inset + an ⋯ offset on the nav row, hand-matched to the card's trailing
/// pad). `autovisorMenuNudge` is DERIVED from the inset difference, so the
/// `chromeHInset + autovisorMenuNudge == menuTrailingInset` alignment invariant
/// holds by construction — changing either inset keeps the two menus aligned.
enum SidebarNavRowMetrics {
    /// Symmetric horizontal inset of a nav-row's squircle chrome from the sidebar edge.
    static let chromeHInset: CGFloat = Spacing.s        // 8

    /// Distance from the sidebar edge to the trailing ⋯ glyph (both rows agree here).
    static let menuTrailingInset: CGFloat = Spacing.m   // 12

    /// Extra leftward nudge the Autovisor ⋯ needs ON TOP of the chrome inset to
    /// reach `menuTrailingInset`. A `.offset` (not trailing padding) so it bypasses
    /// the `.borderlessButton` menu-label's internal centering.
    static let autovisorMenuNudge: CGFloat = menuTrailingInset - chromeHInset  // 4
}

// MARK: - Terminal Nav-Row Chrome

private extension View {
    /// Inner inset for a terminal nav-row's Button label — applied BEFORE
    /// `.contentShape(Rectangle())` so the visible squircle's interior padding
    /// becomes part of the Button's hit-test area. If this padding were applied
    /// outside the Button (the old chrome shape), the squircle would visually
    /// suggest a full-width target but only the label's intrinsic frame (icon +
    /// title + status badge) would actually tap.
    func terminalNavRowLabelInset(
        leading: CGFloat = Spacing.s,
        trailing: CGFloat = Spacing.s,
        vertical: CGFloat = Spacing.s
    ) -> some View {
        self
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
    }

    /// Background + outer margin for a terminal nav-row. Inner padding is the
    /// responsibility of each Button/Menu label (via `terminalNavRowLabelInset`)
    /// so the padded area is tappable. Splitting chrome from row content also
    /// lets rows include a trailing affordance (e.g. the Autovisor ⋯ menu)
    /// inside the SAME selection envelope, so the row reads as one unit
    /// visually while tap routing still splits between the row's Button and
    /// the trailing control.
    ///
    /// Deliberately NOT the flat edge-to-edge fill + 2px left accent bar pattern
    /// used by `SidebarTaskRow` — that vocabulary is reserved for list items.
    /// Nav destinations get the squircle "pill" treatment so they read as
    /// destinations, not list rows.
    @ViewBuilder
    func terminalNavRowChrome(isSelected: Bool, isHovered: Bool) -> some View {
        self
            .background {
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(
                        isSelected
                            ? Colors.accentTint
                            : (isHovered ? Colors.surfaceHover : Color.clear)
                    )
            }
            .padding(.horizontal, SidebarNavRowMetrics.chromeHInset)
    }
}

// MARK: - Preview Helpers

// periphery:ignore - used in #Preview macros below
private func makePreviewStore(
    folder: URL? = nil,
    engineRunning: Bool = false,
    tasks: [TaskSummary] = [],
    activeTaskID: Int? = nil
) -> NTMSOrchestrator {
    let s = PreviewStore.make()
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

// periphery:ignore - used in #Preview macros below
private func makeFilteredTaskState() -> TaskManagementState {
    let s = TaskManagementState()
    s.taskFilter = .running
    return s
}

// periphery:ignore - used in #Preview macros below
private let previewTaskIDs: (Int, Int, Int) = (1, 2, 3)

// periphery:ignore - used in #Preview macros below
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

/// Dedicated task ID for the Autovisor singleton in previews — kept out of
/// the visible task list (the orchestrator filters it out of `taskSummaries`)
/// and high enough not to collide with `previewTaskIDs`.
// periphery:ignore - used in #Preview macros below
private let previewAutovisorTaskID = 99

/// Builds a preview store with Autovisor enabled — the hidden manager task ID
/// pinned on `WorkFolderState`, `autovisorEnabled = true` on settings, and an
/// optional engine state for the manager task (drives the nav row's pulse and
/// accent treatments per `SidebarViewLogic.resolveManagerRowInfo`).
// periphery:ignore - used in #Preview macros below
private func makePreviewStoreWithAutovisor(
    folder: URL = URL(fileURLWithPath: "/Users/dev/MyProject"),
    autovisorEngineState: TeamEngineState? = nil,
    tasks: [TaskSummary] = []
) -> NTMSOrchestrator {
    let store = PreviewStore.make()
    store.workFolderURL = folder
    var settings = ProjectSettings.defaults
    settings.autovisorEnabled = true
    settings.autovisorGoal = "Keep the codebase shippable."
    store.snapshot = WorkFolderContext(
        projection: WorkFolderProjection(
            state: WorkFolderState(
                name: folder.lastPathComponent,
                autovisorTaskID: previewAutovisorTaskID
            ),
            settings: settings,
            teams: Team.defaultTeams
        ),
        tasksIndex: TasksIndex(tasks: tasks),
        toolDefinitions: [],
        activeTaskID: nil
    )
    if let autovisorEngineState {
        store.engineState[previewAutovisorTaskID] = autovisorEngineState
    }
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
        .environment(LLMStatusMonitor())
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
        .environment(LLMStatusMonitor())
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
        .environment(LLMStatusMonitor())
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
        .environment(LLMStatusMonitor())
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — Autovisor Enabled (Idle)") {
    @Previewable @State var store = makePreviewStoreWithAutovisor()
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(LLMStatusMonitor())
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — Autovisor Running") {
    @Previewable @State var store = makePreviewStoreWithAutovisor(autovisorEngineState: .running)
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(LLMStatusMonitor())
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — Autovisor Needs Input") {
    @Previewable @State var store = makePreviewStoreWithAutovisor(autovisorEngineState: .needsSupervisorInput)
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(LLMStatusMonitor())
        .frame(width: 280, height: 600)
}

#Preview("Sidebar — Autovisor Selected") {
    @Previewable @State var store = makePreviewStoreWithAutovisor(autovisorEngineState: .running)
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .autovisor
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(LLMStatusMonitor())
        .frame(width: 280, height: 600)
}
