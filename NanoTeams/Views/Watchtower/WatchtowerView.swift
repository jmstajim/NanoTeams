import SwiftUI

// MARK: - Watchtower View

/// Supervisor's watchtower - observe team activity, take quick actions, review stats
struct WatchtowerView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(OrchestratorEngineState.self) var engineState
    @Environment(StoreConfiguration.self) var config
    @Environment(AppUpdateState.self) var appUpdateState
    var taskState: TaskManagementState
    @Binding var navigationSelection: MainLayoutView.NavigationItem?
    @Binding var clearedUpToDate: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingFinalReviewSheet = false
    @State private var cachedNotifications: [WatchtowerNotification] = []

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                // Brand masthead — figlet + WATCHTOWER label + "N tasks need you"
                // headline + subtitle + AUTOVISOR toggle + new-task button, per
                // DesignSystemByClaude/.../Watchtower.jsx lines 199-223.
                WatchtowerHeader(
                    needsYouCount: WatchtowerNotification.needsYouCount(cachedNotifications),
                    onNewTask: { QuickCaptureController.shared.showNewTask() }
                )

                if let release = appUpdateState.availableRelease {
                    WatchtowerAppUpdateCard(
                        release: release,
                        onUpdate: {
                            URLOpener.open(release.htmlURL) { store.lastErrorMessage = $0 }
                        },
                        onSkip: {
                            appUpdateState.skip(release.tag)
                        }
                    )
                    .transition(.scale(scale: 0.95, anchor: .center).combined(with: .opacity))
                }

                // Autovisor goal + live memory + chat box. Self-gating (renders
                // only while the manager is on); the on/off toggle is in Quick Actions.
                WatchtowerAutovisorCard()

                // Setup tips for unconfigured advanced features (own subview; reads its
                // own state so its updates don't churn the rest of Watchtower).
                WatchtowerSetupSection()

                // Notification banners (from all loaded tasks)
                if !cachedNotifications.isEmpty {
                    MonoLabel(text: "Inbox", rule: true)
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
                            onSubmitAnswer: { stepID, answer, attachments, clips in
                                let embedFiles = config.embedFilesInPrompt
                                let built = AnswerTextBuilder.build(
                                    text: answer,
                                    clips: clips,
                                    attachments: attachments,
                                    embedFiles: embedFiles
                                )
                                if !built.failedFiles.isEmpty {
                                    store.lastErrorMessage = "Could not embed \(built.failedFiles.count) file(s) as text: \(built.failedFiles.joined(separator: ", ")). They may be binary files."
                                }
                                let success = await store.answerSupervisorQuestion(
                                    stepID: stepID, taskID: notification.taskID,
                                    answer: built.answer, attachments: attachments
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
                            },
                            skillsProjectRoot: store.hasRealWorkFolder ? store.workFolderURL : nil
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
        .navigationTitle("")
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
                        .foregroundStyle(Colors.textTertiary)
                        .accessibilityHidden(true)
                    Text("No active task to review")
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textSecondary)
                    Button("Close") {
                        isShowingFinalReviewSheet = false
                    }
                    .buttonStyle(.terminalSecondary)
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
        .onChange(of: config.dismissedNotificationKeys) { _, _ in refreshNotifications() }
        // A held bash command keeps the step `.running`, so the engine-state watcher
        // above never fires for it — observe the approval map directly so the banner
        // surfaces (and clears) as commands are held/resolved across any task.
        .onChange(of: store.bashApprovalRequests) { _, _ in refreshNotifications() }
    }

    // MARK: - Activity Timeline

    private var activityTimelineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            MonoLabel(text: "Recent Activity", rule: true)

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
            .background(Colors.surfaceCard, in: RoundedRectangle.squircle(CornerRadius.medium))
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
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
        guard let workFolderID = store.snapshot?.projection.id else {
            cachedNotifications = []
            return
        }
        let loaded = store.allLoadedTasks
        let all = WatchtowerInboxBuilder.build(
            loaded.map {
                WatchtowerInboxBuilder.TaskInput(task: $0, teamRoles: store.resolvedTeam(for: $0).roles)
            },
            bashApprovals: Array(store.bashApprovalRequests.values)
        )

        // Expire dismissals whose notification is genuinely gone (the step was
        // answered, the role accepted) — but ONLY for tasks we can actually see.
        // `loadedTasks` is populated lazily and the startup sweep evicts each task
        // right after recovering it, so scoping this to "is anything loaded" deleted
        // every non-resident task's dismissals on every launch.
        let dismissed = config.dismissedKeys(forWorkFolder: workFolderID)
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: dismissed,
            active: Set(all.map(\.dismissKey)),
            loadedTaskIDs: Set(loaded.map(\.id)),
            knownTaskIDs: Set(store.snapshot?.tasksIndex.tasks.map(\.id) ?? [])
        )
        config.undismissNotifications(workFolderID: workFolderID, keys: stale)

        cachedNotifications = WatchtowerInboxBuilder.visible(all, dismissed: dismissed.subtracting(stale))
    }

    private func dismissNotification(_ notification: WatchtowerNotification) {
        guard let workFolderID = store.snapshot?.projection.id else { return }
        config.dismissNotification(workFolderID: workFolderID, key: notification.dismissKey)
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

        // Dismiss supervisor input when navigating to chat — user will see the question there
        if case .supervisorInput = notification.type {
            dismissNotification(notification)
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
    @Previewable @State var appUpdateState = AppUpdateState(config: StoreConfiguration())
    @Previewable @State var llmStatusMonitor = LLMStatusMonitor()
    WatchtowerView(taskState: TaskManagementState(), navigationSelection: .constant(.watchtower), clearedUpToDate: .constant(nil))
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(appUpdateState)
        .environment(llmStatusMonitor)
        .frame(width: 600, height: 700)
}
