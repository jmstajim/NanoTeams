import SwiftUI

// MARK: - Team Board View

/// Main view for task execution with team graph on the left and chat on the right.
/// Uses HSplitView with layout wrappers so content does not dictate split widths.
///
/// Split across extension files:
/// - `TeamBoardToolbar.swift` — toolbar components (run history, team selector, control buttons)
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
    // Note: selectedRoleID, isShowingFinalReviewSheet, isGraphPanelVisible accessed from TeamBoardToolbar/TeamBoardView+Actions extensions
    @AppStorage(UserDefaultsKeys.graphPanelVisible) var isGraphPanelVisible: Bool = true
    @State var selectedRoleID: String?
    @State private var resizeMonitor = WindowResizeMonitor()
    @State private var restartRoleID: String?
    @State private var isShowingRestartSheet: Bool = false
    @State var isShowingFinalReviewSheet: Bool = false
    @State private var restartComment: String = ""
    @State private var correctRoleID: String?
    @State private var isShowingCorrectSheet: Bool = false
    @State private var correctComment: String = ""
    // Accessed from TeamBoardToolbar's `automationButton` (extension, separate file) — keep internal.
    @State var isShowingAutomationSheet: Bool = false

    /// Whether the displayed run's audit logs exist — probed when the SELECTION changes,
    /// not on every body pass.
    ///
    /// Read by `TeamBoardToolbar`'s two log menu items (extension, separate file), which
    /// is why it is `internal`. They used to call `store.conversationLogExists` /
    /// `store.networkLogExists` directly from inside a `Menu`'s `@ViewBuilder` — content
    /// SwiftUI builds EAGERLY — so up to four `stat(2)` syscalls and two whole-index
    /// `parentLinks()` allocations ran on the MainActor on every pass of this body, i.e.
    /// on every `mutateTask`. See `NTMSOrchestrator.runLogAvailability`.
    @State var runLogAvailability = RunLogAvailability()

    /// `.task(id:)` key for the probe above. A plain `(taskID, runID)` would never
    /// re-probe when the ACTIVE run starts writing its logs a moment after it is
    /// selected, so the engine state joins the key: it moves on exactly the discrete
    /// transitions (start / pause / finish) around which a log first appears, and it is
    /// a cheap `Equatable` enum, not a projection (CLAUDE.md #113 — the mistake this
    /// whole change is undoing was an expensive key).
    private struct RunLogProbeKey: Equatable {
        var taskID: Int?
        var runID: Int?
        var engineState: TeamEngineState?
    }

    /// Everything one body pass derives from the store, computed ONCE at the top of
    /// `content(for:)` and threaded down.
    ///
    /// These were computed properties, and SwiftUI re-evaluates a computed property at
    /// EVERY reference. Measured on the graph-plus-chat layout: `isHistoricalRun` ≈ 16
    /// evaluations per pass (a `Menu`'s content ViewBuilder is eager, and so is
    /// `TeamBoardTopBar`'s stored `@ViewBuilder` actions), each of which called
    /// `displayedRun` — itself ≈ 8 more directly, and every one a
    /// `RunService.selectedRunSnapshot` linear scan plus a whole `Run` copy. `resolvedTeam`
    /// was worse per call: ≈ 9 + `teams.count` evaluations, each a linear scan plus a whole
    /// `Team` copy (roles, artifacts, settings, layout, three prompt templates). This
    /// board reads `store.snapshot`, so the pass runs on every `mutateTask`.
    ///
    /// The multiplier here is the REFERENCE COUNT, not N (CLAUDE.md #109) — runs and
    /// teams are both small. Fixing one of the two and leaving the other in the same body
    /// would be a guard at one of N sites (#51), so both moved together.
    nonisolated struct BoardContext {
        let run: Run?
        let team: Team
        let isHistorical: Bool
        let roleStatuses: [String: RoleExecutionStatus]
        let producedArtifacts: Set<String>
        let reviewArtifacts: [String]
        let isFinalReviewStage: Bool
    }

    /// Pure predicate behind `BoardContext.isHistorical`.
    nonisolated static func isHistoricalRun(displayedRunID: Int?, activeRunID: Int?) -> Bool {
        guard let displayedRunID, let activeRunID else { return false }
        return displayedRunID != activeRunID
    }

    /// True when this board is showing the hidden Autovisor manager task.
    /// Drives the Autovisor-only "Run now" toolbar button and hides "New Run".
    var isAutovisorBoard: Bool {
        Self.isAutovisorBoard(taskID: task?.id, autovisorTaskID: store.autovisorTaskID)
    }

    /// Pure predicate behind `isAutovisorBoard` — `WorkFolderState.autovisorTaskID`
    /// is the single source of truth for "which task is the manager".
    nonisolated static func isAutovisorBoard(taskID: Int?, autovisorTaskID: Int?) -> Bool {
        guard let taskID, let autovisorTaskID else { return false }
        return taskID == autovisorTaskID
    }

    /// Whether the task is ready for final acceptance (all roles individually accepted).
    nonisolated static func isFinalReviewStage(task: NTMSTask?, isHistoricalRun: Bool) -> Bool {
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
        // ONE `selectedRunSnapshot`, ONE `resolvedTeam(for:)`, ONE produced-artifact
        // recomputation per body pass — see `BoardContext`.
        let run = store.selectedRunSnapshot
        let team = store.resolvedTeam(for: task)
        let isHistorical = Self.isHistoricalRun(displayedRunID: run?.id,
                                                activeRunID: task.runs.last?.id)
        let ctx = BoardContext(
            run: run,
            team: team,
            isHistorical: isHistorical,
            roleStatuses: run?.roleStatuses ?? [:],
            producedArtifacts: run.map {
                TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: $0)
            } ?? [],
            reviewArtifacts: team.supervisorRequiredArtifacts,
            isFinalReviewStage: Self.isFinalReviewStage(task: task, isHistoricalRun: isHistorical)
        )
        let probeKey = RunLogProbeKey(taskID: task.id,
                                      runID: run?.id,
                                      engineState: store.taskEngineStates[task.id])

        VStack(spacing: 0) {
            Group {
                if isGraphPanelVisible {
                    HSplitView {
                        chatPanel(for: task, ctx: ctx)
                            .frame(minWidth: WindowLayout.teamBoardActivityMinWidth)
                        graphPanel(for: task, ctx: ctx)
                            .frame(minWidth: WindowLayout.teamBoardGraphMinWidth)
                    }
                } else {
                    chatPanel(for: task, ctx: ctx)
                        .frame(minWidth: WindowLayout.teamBoardActivityMinWidth)
                }
            }
            .frame(maxHeight: .infinity)
            .background(WindowResizeMonitorAccessor(monitor: resizeMonitor))
            .environment(\.windowResizeMonitor, resizeMonitor)
            .background(NTMSBackground())
            .overlay(alignment: .top) {
                historicalRunBanner(isHistorical: ctx.isHistorical)
            }
        }
        // `TeamBoardTopBar` is the SOLE navbar — task/title + pause/resume +
        // all right-side actions. Replaces the native `.toolbar` block so there's no round
        // AppKit chrome sitting above the in-view bar.
        .safeAreaInset(edge: .top, spacing: 0) {
            TeamBoardTopBar(
                taskTitle: task.title,
                teamName: ctx.team.name,
                runLabel: ctx.run.map { "run #\($0.id)" },
                engineState: engineState.taskEngineStates[task.id],
                isHistoricalRun: ctx.isHistorical,
                isInitializingRun: engineState.isInitializingRun(task.id),
                onPause: { Task { await store.pauseRun(taskID: task.id) } },
                onResume: { Task { await store.resumeRun(taskID: task.id) } },
                onStart: { Task { await store.startRun(taskID: task.id) } }
            ) {
                autovisorRunNowButton(ctx: ctx)
                acceptTaskButton(ctx: ctx)
                automationButton(ctx: ctx)
                moreActionsMenu(ctx: ctx)
                graphToggleButton
            }
        }
        .navigationTitle("")
        .onAppear {
            if let roleID = store.pendingRoleSelection {
                selectedRoleID = roleID
                store.pendingRoleSelection = nil
            }
        }
        .task(id: probeKey) {
            // Read the identifiers off the KEY, not off `task`/`ctx.run` again: the probe
            // must describe the selection the key was formed from, and re-deriving them
            // here would let the two drift on a mid-await change. The key is now the
            // CAPTURED local rather than a recomputed property, which makes that stronger
            // — there is only one value, formed once with the rest of the pass.
            guard let taskID = probeKey.taskID, let runID = probeKey.runID else {
                runLogAvailability = RunLogAvailability()
                return
            }
            runLogAvailability = store.runLogAvailability(taskID: taskID, runID: runID)
        }
        .onChange(of: ctx.roleStatuses) { _, newStatuses in
            // Auto-select role that needs attention
            autoSelectAttentionRole(statuses: newStatuses)
        }
        .sheet(isPresented: $isShowingRestartSheet) {
            let roleName = restartRoleID.flatMap { rid in
                ctx.team.roles.first(where: { $0.id == rid })?.name
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
        .sheet(isPresented: $isShowingCorrectSheet) {
            let roleName = correctRoleID.flatMap { rid in
                ctx.team.roles.first(where: { $0.id == rid })?.name
            } ?? "Role"
            CorrectRoleSheet(
                roleName: roleName,
                comment: $correctComment,
                isPresented: $isShowingCorrectSheet
            ) {
                if let roleID = correctRoleID {
                    handleCorrectRole(roleID: roleID, comment: correctComment)
                }
            }
        }
        .sheet(isPresented: $isShowingFinalReviewSheet) {
            SupervisorFinalReviewView(
                task: task,
                run: ctx.run,
                roleDefinitions: ctx.team.roles,
                requiredArtifactNames: ctx.reviewArtifacts,
                workFolderURL: store.workFolderURL,
                onAcceptTask: {
                    await store.closeTask(taskID: task.id)
                },
                onClose: {
                    isShowingFinalReviewSheet = false
                }
            )
        }
        .sheet(isPresented: $isShowingAutomationSheet) {
            TaskAutomationSheet(
                currentRecurrence: task.recurrence,
                currentTimeoutSeconds: task.runTimeoutSeconds,
                isPresented: $isShowingAutomationSheet
            ) { recurrence, timeout in
                Task {
                    await store.setTaskRecurrence(taskID: task.id, recurrence: recurrence)
                    await store.setTaskRunTimeout(taskID: task.id, seconds: timeout)
                }
            }
        }
    }

    // MARK: - Historical Run Banner

    @ViewBuilder
    private func historicalRunBanner(isHistorical: Bool) -> some View {
        if isHistorical {
            HStack(spacing: Spacing.s) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Colors.warning)
                Text("Viewing historical run")
                    .font(Typography.caption)
                Spacer()
                Button("Back to current") {
                    store.selectedRunID = nil
                }
                .font(Typography.caption)
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.warningTint)
            )
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.s)
        }
    }

    // MARK: - Panels

    private func graphPanel(for task: NTMSTask, ctx: BoardContext) -> some View {
        let restartClosure: ((String) -> Void)? = ctx.isHistorical ? nil : { roleID in
            restartRoleID = roleID
            isShowingRestartSheet = true
        }
        let finishClosure: ((String) -> Void)? = ctx.isHistorical ? nil : { roleID in
            store.finishAdvisoryRole(taskID: task.id, roleID: roleID)
        }
        let correctClosure: ((String) -> Void)? = ctx.isHistorical ? nil : { roleID in
            correctRoleID = roleID
            isShowingCorrectSheet = true
        }
        let retryClosure: (() -> Void)? = ctx.isHistorical ? nil : {
            Task { await store.retryTeamGeneration(taskID: task.id) }
        }
        return GraphPanelView(
            task: task,
            workFolder: workFolder,
            roleStatuses: ctx.roleStatuses,
            roleDefinitions: ctx.team.roles,
            producedArtifacts: ctx.producedArtifacts,
            selectedRoleID: $selectedRoleID,
            onRestartRole: restartClosure,
            onFinishRole: finishClosure,
            onCorrectRole: correctClosure,
            onRetryGeneration: retryClosure,
            isChatMode: ctx.team.isChatMode,
            isPaused: engineState.taskEngineStates[task.id] == .paused,
            isEngineRunning: engineState.taskEngineStates[task.id] == .running,
            meetingParticipants: engineState.activeMeetingParticipants[task.id] ?? [],
            isTaskInReview: ctx.isFinalReviewStage
        )
    }

    private func chatPanel(for task: NTMSTask, ctx: BoardContext) -> some View {

        let restartClosure: ((String, String) -> Void)? = ctx.isHistorical ? nil : { roleID, comment in
            handleRestartRole(roleID: roleID, comment: comment)
        }
        let correctClosure: ((String, String) -> Void)? = ctx.isHistorical ? nil : { roleID, comment in
            handleCorrectRole(roleID: roleID, comment: comment)
        }
        return ActivityPanelView(
            run: ctx.run,
            roleDefinitions: ctx.team.roles,
            selectedRoleID: $selectedRoleID,
            supervisorReviewArtifacts: ctx.reviewArtifacts,
            producedArtifacts: ctx.producedArtifacts,
            isFinalReviewStage: ctx.isFinalReviewStage,
            isChatMode: ctx.team.isChatMode,
            isReadOnly: ctx.isHistorical,
            onReviewTask: { isShowingFinalReviewSheet = true },
            onRequestChanges: handleRevisionRequest,
            onRestartRole: restartClosure,
            onCorrectRole: correctClosure,
            isPaused: engineState.taskEngineStates[task.id] == .paused,
            meetingParticipants: engineState.activeMeetingParticipants[task.id] ?? []
        )
    }

    // Actions (handleRevisionRequest, handleRestartRole, handleCorrectRole,
    // autoSelectAttentionRole, supervisorReviewArtifacts) live in TeamBoardView+Actions.swift.
}

