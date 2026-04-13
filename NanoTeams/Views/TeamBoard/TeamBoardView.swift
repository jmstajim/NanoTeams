import SwiftUI

// MARK: - Team Board View

/// Main view for task execution with team graph on the left and chat on the right.
/// Uses HSplitView with layout wrappers so content does not dictate split widths.
///
/// Split across extension files:
/// - `TeamBoardToolbar.swift` — toolbar components (run history, team selector, control buttons)
/// - `TeamBoardKeyboardShortcuts.swift` — keyboard shortcut handlers
/// - `TeamBoardView+Actions.swift` — acceptance, revision, restart, review artifact lookup handlers
/// - `TeamBoardView+Previews.swift` — `#Preview` blocks + fixtures
struct TeamBoardView: View {
    let workFolder: WorkFolderProjection?

    @Environment(NTMSOrchestrator.self) var store
    @Environment(OrchestratorEngineState.self) var engineState

    /// Reactive task from store - ensures UI updates when task changes
    var task: NTMSTask? {
        store.activeTask
    }
    // Note: selectedRoleID, isShowingFinalReviewSheet, isGraphPanelVisible accessed from TeamBoardToolbar/KeyboardShortcuts extensions
    @AppStorage(UserDefaultsKeys.graphPanelVisible) var isGraphPanelVisible: Bool = true
    @State var selectedRoleID: String?
    @State private var restartRoleID: String?
    @State private var isShowingRestartSheet: Bool = false
    @State var isShowingFinalReviewSheet: Bool = false
    @State private var restartComment: String = ""

    /// The currently active (latest) run
    var activeRun: Run? {
        task?.runs.last
    }

    /// The run being displayed (selected or falls back to active)
    var displayedRun: Run? {
        store.selectedRunSnapshot
    }

    /// Whether we're viewing a historical (non-active) run
    var isHistoricalRun: Bool {
        guard let displayedRun = displayedRun, let activeRun = activeRun else { return false }
        return displayedRun.id != activeRun.id
    }

    /// Role statuses from the displayed run (for graph and UI)
    var roleStatuses: [String: RoleExecutionStatus] {
        displayedRun?.roleStatuses ?? [:]
    }

    /// Ordered list of role IDs for keyboard navigation
    var orderedRoleIDs: [String] {
        resolvedTeam.roles.map(\.id)
    }

    /// Selected role's status for keyboard shortcut context
    var selectedRoleStatus: RoleExecutionStatus? {
        guard let roleID = selectedRoleID else { return nil }
        return roleStatuses[roleID]
    }

    /// Resolved team for the current task — computed once, shared across graph, chat, and toolbar.
    var resolvedTeam: Team {
        store.resolvedTeam(for: task)
    }

    /// Whether the task is ready for final acceptance (all roles individually accepted).
    var isFinalReviewStage: Bool {
        guard let task, !isHistoricalRun else { return false }
        return task.isReadyForFinalAcceptance
    }

    var body: some View {
        if let task = task {
            content(for: task)
        } else {
            NTMSEmptyState(
                title: "No Active Task",
                message: "Select a task from the sidebar to view the team board.",
                systemImage: "hammer.circle"
            )
            .background(NTMSBackground())
        }
    }

    @ViewBuilder
    private func content(for task: NTMSTask) -> some View {
        Group {
            if isGraphPanelVisible {
                HSplitView {
                    chatPanel(for: task)
                        .frame(minWidth: WindowLayout.teamBoardActivityMinWidth)
                    graphPanel(for: task)
                        .frame(minWidth: WindowLayout.teamBoardGraphMinWidth)
                }
            } else {
                chatPanel(for: task)
                    .frame(minWidth: WindowLayout.teamBoardActivityMinWidth)
            }
        }
        .background(NTMSBackground())
        .overlay(alignment: .top) {
            historicalRunBanner
        }
        .toolbar {
            // Play/pause left
            ToolbarItemGroup(placement: .navigation) {
                playPauseButton
            }

            // Right side actions
            ToolbarItemGroup(placement: .primaryAction) {
                acceptTaskButton
                moreActionsMenu
                graphToggleButton
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(task.title)
        .navigationSubtitle("")
        .onAppear {
            if let roleID = store.pendingRoleSelection {
                selectedRoleID = roleID
                store.pendingRoleSelection = nil
            }
        }
        .onChange(of: roleStatuses) { _, newStatuses in
            // Auto-select role that needs attention
            autoSelectAttentionRole(statuses: newStatuses)
        }
        .sheet(isPresented: $isShowingRestartSheet) {
            let roleName = restartRoleID.flatMap { rid in
                resolvedTeam.roles.first(where: { $0.id == rid })?.name
            } ?? "Role"
            RestartRoleSheet(
                roleName: roleName,
                comment: $restartComment,
                isPresented: $isShowingRestartSheet
            ) {
                if let roleID = restartRoleID {
                    handleRestartRole(roleID: roleID, comment: restartComment)
                }
            }
        }
        .sheet(isPresented: $isShowingFinalReviewSheet) {
            SupervisorFinalReviewView(
                task: task,
                run: displayedRun,
                roleDefinitions: resolvedTeam.roles,
                requiredArtifactNames: cachedSupervisorReviewArtifacts,
                workFolderURL: store.workFolderURL,
                onAcceptTask: {
                    await store.closeTask(taskID: task.id)
                },
                onClose: {
                    isShowingFinalReviewSheet = false
                }
            )
        }
        // Keyboard shortcuts
        .background {
            keyboardShortcuts
        }
    }

    // MARK: - Historical Run Banner

    @ViewBuilder
    private var historicalRunBanner: some View {
        if isHistoricalRun {
            HStack(spacing: Spacing.s) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Colors.warning)
                Text("Viewing historical run")
                    .font(.caption)
                Spacer()
                Button("Back to current") {
                    store.selectedRunID = nil
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(Colors.warningTint)
            )
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.s)
        }
    }

    // MARK: - Panels

    /// Produced artifacts for the displayed run — computed once, shared by graph and chat panels.
    /// Uses the canonical engine logic (includes Supervisor Task, filters pending-acceptance roles).
    private var displayedRunProducedArtifacts: Set<String> {
        guard let task, let run = displayedRun else { return [] }
        return TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)
    }

    /// Supervisor review artifacts — computed once, shared by chat panel and final review sheet.
    var cachedSupervisorReviewArtifacts: [String] {
        guard task != nil else { return [] }
        return supervisorReviewArtifacts()
    }

    private func graphPanel(for task: NTMSTask) -> some View {
        let restartClosure: ((String) -> Void)? = isHistoricalRun ? nil : { roleID in
            restartRoleID = roleID
            isShowingRestartSheet = true
        }
        let finishClosure: ((String) -> Void)? = isHistoricalRun ? nil : { roleID in
            store.finishAdvisoryRole(taskID: task.id, roleID: roleID)
        }
        let retryClosure: (() -> Void)? = isHistoricalRun ? nil : {
            Task { await store.retryTeamGeneration(taskID: task.id) }
        }
        return GraphPanelView(
            task: task,
            workFolder: workFolder,
            roleStatuses: roleStatuses,
            roleDefinitions: resolvedTeam.roles,
            producedArtifacts: displayedRunProducedArtifacts,
            selectedRoleID: $selectedRoleID,
            onRestartRole: restartClosure,
            onFinishRole: finishClosure,
            onRetryGeneration: retryClosure,
            isChatMode: resolvedTeam.isChatMode,
            isPaused: engineState.taskEngineStates[task.id] == .paused,
            isEngineRunning: engineState.taskEngineStates[task.id] == .running,
            meetingParticipants: engineState.activeMeetingParticipants[task.id] ?? [],
            isTaskInReview: isFinalReviewStage
        )
    }

    private func chatPanel(for task: NTMSTask) -> some View {

        let restartClosure: ((String, String) -> Void)? = isHistoricalRun ? nil : { roleID, comment in
            handleRestartRole(roleID: roleID, comment: comment)
        }
        return ActivityPanelView(
            run: displayedRun,
            roleDefinitions: resolvedTeam.roles,
            selectedRoleID: $selectedRoleID,
            supervisorReviewArtifacts: cachedSupervisorReviewArtifacts,
            producedArtifacts: displayedRunProducedArtifacts,
            isFinalReviewStage: isFinalReviewStage,
            isChatMode: resolvedTeam.isChatMode,
            isReadOnly: isHistoricalRun,
            onReviewTask: { isShowingFinalReviewSheet = true },
            onRequestChanges: handleRevisionRequest,
            onRestartRole: restartClosure,
            isPaused: engineState.taskEngineStates[task.id] == .paused,
            meetingParticipants: engineState.activeMeetingParticipants[task.id] ?? []
        )
    }

    // Actions (handleAcceptance, handleRevisionRequest, handleRestartRole,
    // autoSelectAttentionRole, supervisorReviewArtifacts) live in TeamBoardView+Actions.swift.
}

