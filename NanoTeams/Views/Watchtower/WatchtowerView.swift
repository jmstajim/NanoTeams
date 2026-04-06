import SwiftUI

// MARK: - Watchtower View

/// Supervisor's watchtower - observe team activity, take quick actions, review stats
struct WatchtowerView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(OrchestratorEngineState.self) var engineState
    @Environment(StoreConfiguration.self) var config
    var taskState: TaskManagementState
    @Binding var navigationSelection: MainLayoutView.NavigationItem?
    @Binding var clearedUpToDate: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingFinalReviewSheet = false
    @State private var cachedNotifications: [WatchtowerNotification] = []

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                // Keyboard shortcut hints
                shortcutHints

                // Quick actions section
                quickActionsSection

                // Notification banners (from all loaded tasks)
                if !cachedNotifications.isEmpty {
                    NTMSSectionHeader(title: "Notifications", systemImage: "bell.fill")
                        .transition(.opacity)
                    ForEach(cachedNotifications) { notification in
                        WatchtowerNotificationBanner(
                            notification: notification.type,
                            taskTitle: notification.taskTitle,
                            isChatMode: notification.isChatMode,
                            onDismiss: { dismissNotification(notification) },
                            onViewDetails: { navigateToNotificationSource(notification) },
                            onAcceptRole: { roleID in
                                let success = await store.acceptRole(taskID: notification.taskID, roleID: roleID)
                                if success { refreshNotifications() }
                                return success
                            },
                            onAcceptTask: { taskID in
                                let success = await store.closeTask(taskID: taskID)
                                if success { refreshNotifications() }
                                return success
                            },
                            onSubmitAnswer: { stepID, answer, attachments in
                                let success = await store.answerSupervisorQuestion(
                                    stepID: stepID, taskID: notification.taskID,
                                    answer: answer, attachments: attachments
                                )
                                if success { refreshNotifications() }
                                return success
                            },
                            onStageAttachment: { stepID, url in
                                // stepID is a role ID string; staging requires a UUID directory name
                                let draftUUID = UUID()
                                return store.stageAttachment(url: url, draftID: draftUUID)
                            },
                            onRemoveAttachment: { attachment in
                                store.removeStagedAttachment(attachment)
                            }
                        )
                        .transition(.scale(scale: 0.95, anchor: .center).combined(with: .opacity))
                    }
                }

                // Activity timeline section
                activityTimelineSection
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.l)
        }
        .background(NTMSBackground())
        .navigationTitle("Watchtower")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $isShowingFinalReviewSheet) {
            if let task = store.activeTask {
                let team = store.resolvedTeam(for: task)
                SupervisorFinalReviewView(
                    task: task,
                    run: task.runs.last,
                    roleDefinitions: team.roles,
                    requiredArtifactNames: store.resolvedTeam(for: task).supervisorRequiredArtifacts,
                    workFolderURL: store.workFolderURL,
                    onAcceptTask: {
                        let success = await store.closeTask(taskID: task.id)
                        if success { refreshNotifications() }
                        return success
                    },
                    onClose: {
                        isShowingFinalReviewSheet = false
                    }
                )
            } else {
                VStack(spacing: Spacing.m) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No active task to review")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Close") {
                        isShowingFinalReviewSheet = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(minWidth: 480, minHeight: 220)
                .padding()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: cachedNotifications.count)
        .onAppear { refreshNotifications() }
        .onChange(of: engineState.taskEngineStates) { _, _ in refreshNotifications() }
        .onChange(of: store.activeTaskID) { _, _ in refreshNotifications() }
        .onChange(of: config.dismissedNotificationIDs) { _, _ in refreshNotifications() }
    }

    // MARK: - Shortcut Hints

    private var shortcutHints: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xxs) {
                ForEach(["⌃", "⌥", "⌘"], id: \.self) { key in
                    shortcutKey(key)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    shortcutKey("0")
                    Text("Quick Task")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    InfoTip("Open the floating overlay panel to create a task, answer a question, or send a chat message.\n\nShortcut: ⌃ ⌥ ⌘ 0")
                }
                HStack(spacing: Spacing.s) {
                    shortcutKey("K")
                    Text("Context Capture")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    InfoTip("Capture the current selection (text or files) from any app and attach it to the Quick Task panel.\n\nShortcut: ⌃ ⌥ ⌘ K")
                }
            }
            Spacer()
        }
    }

    private func shortcutKey(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.micro, style: .continuous)
                    .fill(Colors.surfaceElevated)
            )
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            NTMSSectionHeader(title: "Quick Actions", systemImage: "bolt.fill")

            HStack(spacing: Spacing.m) {
                ForEach(Array(availableQuickActions.enumerated()), id: \.element.id) { index, action in
                    WatchtowerQuickActionButton(
                        title: action.title,
                        subtitle: action.subtitle,
                        icon: action.icon,
                        color: action.color,
                        isPrimary: action.icon == "play.fill" || action.icon == "arrow.clockwise",
                        action: action.action
                    )
                }
                Spacer()
            }
        }
    }

    private var availableQuickActions: [QuickAction] {
        let activeTask = store.activeTask
        let engineStatus = activeTask.flatMap { engineState.taskEngineStates[$0.id] }
        let requiresFinalReview = activeTask.map { store.resolvedTeam(for: $0).requiresSupervisorFinalReview } ?? false

        return QuickAction.makeActions(
            activeTask: activeTask,
            engineStatus: engineStatus,
            requiresFinalReview: requiresFinalReview,
            onNewTask: { QuickCaptureController.shared.showNewTask() },
            onNavigateToTask: { taskID in navigationSelection = .task(taskID) },
            onPauseRun: { taskID in Task { await store.pauseRun(taskID: taskID) } },
            onShowFinalReview: { isShowingFinalReviewSheet = true },
            onCloseTask: { taskID in Task { _ = await store.closeTask(taskID: taskID) } }
        )
    }

    // MARK: - Activity Timeline

    private var activityTimelineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            NTMSSectionHeader(title: "Recent Activity", systemImage: "clock.fill")

            WatchtowerTimeline(
                onTaskSelect: { taskID in
                    Task {
                        await store.switchTask(to: taskID)
                        navigationSelection = .task(taskID)
                    }
                },
                clearedUpToDate: $clearedUpToDate
            )
            .frame(minHeight: 300)
            .background(Colors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
            .shadow(.card)
        }
    }

    // MARK: - Notifications

    /// Rebuilds the cached notification list. Called from lifecycle/onChange handlers
    /// rather than from `body`, so accessing `store.allLoadedTasks` here does NOT register
    /// observation on `activeTask`/`snapshot` — avoiding body re-evaluation on every
    /// `mutateTask` call. Notification-relevant state changes are tracked via
    /// `engineState.taskEngineStates`, which transitions precisely when a role needs
    /// acceptance, fails, asks the Supervisor, or the task becomes ready for acceptance.
    private func refreshNotifications() {
        cachedNotifications = store.allLoadedTasks.flatMap { task -> [WatchtowerNotification] in
            guard let run = task.runs.last else { return [] }
            let team = store.resolvedTeam(for: task)
            return run.allWatchtowerNotifications(task: task, teamRoles: team.roles)
                .filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
                .map { WatchtowerNotification(taskID: task.id, taskTitle: task.title, isChatMode: task.isChatMode, type: $0) }
        }
    }

    private func dismissNotification(_ notification: WatchtowerNotification) {
        config.dismissNotification(id: notification.id)
        if case .supervisorInput = notification.type {
            taskState.markSupervisorInputSeen(taskID: notification.taskID)
        }
    }

    private func navigateToNotificationSource(_ notification: WatchtowerNotification) {
        let taskID = notification.taskID

        if case .taskDone = notification.type {
            if let task = store.loadedTask(taskID),
               store.resolvedTeam(for: task).requiresSupervisorFinalReview {
                if store.activeTaskID == taskID {
                    isShowingFinalReviewSheet = true
                } else {
                    Task {
                        await store.switchTask(to: taskID)
                        await MainActor.run {
                            isShowingFinalReviewSheet = true
                        }
                    }
                }
            } else {
                navigationSelection = .task(taskID)
            }
            return
        }

        // Switch to the notification's task if needed, then select role
        if store.activeTaskID != taskID {
            Task {
                await store.switchTask(to: taskID)
                selectRoleFromNotification(notification.type, taskID: taskID)
                navigationSelection = .task(taskID)
            }
        } else {
            selectRoleFromNotification(notification.type, taskID: taskID)
            navigationSelection = .task(taskID)
        }
    }

    private func selectRoleFromNotification(_ notification: WatchtowerNotificationType, taskID: Int) {
        switch notification {
        case .acceptance(_, let roleID, _):
            store.selectRole(roleID: roleID)
        case .failed(let stepID, _, _):
            if let task = store.loadedTask(taskID), let run = task.runs.last,
               let step = run.steps.first(where: { $0.id == stepID }) {
                store.selectRole(roleID: step.effectiveRoleID)
            }
        default:
            break
        }
    }

}

// MARK: - Preview

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    WatchtowerView(taskState: TaskManagementState(), navigationSelection: .constant(.watchtower), clearedUpToDate: .constant(nil))
        .environment(store)
        .environment(store.engineState)
        .environment(StoreConfiguration())
        .frame(width: 600, height: 700)
}
