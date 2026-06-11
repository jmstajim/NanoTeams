import SwiftUI

/// Watchtower "Quick Actions" row. The Autovisor state it shows
/// (`autovisorEnabled` / `autovisorTaskID`) is snapshot-derived, and the
/// manager reassigns the work-folder snapshot frequently while "Reviewing…" (memory
/// writes + background task mutations). Reading it here, in a leaf subview, keeps
/// that churn from re-evaluating the whole `WatchtowerView` body (which would hitch
/// scrolling). See CLAUDE.md #11.
struct WatchtowerQuickActionsBar: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(OrchestratorEngineState.self) private var engineState

    @Binding var navigationSelection: MainLayoutView.NavigationItem?
    let onShowFinalReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            NTMSSectionHeader(title: "Quick Actions", systemImage: "bolt.fill")

            HStack(spacing: Spacing.m) {
                ForEach(actions) { action in
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

    private var actions: [QuickAction] {
        let activeTask = store.activeTask
        let engineStatus = activeTask.flatMap { engineState.taskEngineStates[$0.id] }
        let requiresFinalReview = activeTask.map { store.resolvedTeam(for: $0).requiresSupervisorFinalReview } ?? false
        let autovisorEnabled = store.workFolder?.settings.autovisorEnabled ?? false
        let autovisorRunning = store.autovisorTaskID.flatMap { engineState.taskEngineStates[$0] } == .running

        return QuickAction.makeActions(
            activeTask: activeTask,
            engineStatus: engineStatus,
            requiresFinalReview: requiresFinalReview,
            autovisorEnabled: autovisorEnabled,
            autovisorRunning: autovisorRunning,
            hasWorkFolder: store.hasRealWorkFolder,
            onNewTask: { QuickCaptureController.shared.showNewTask() },
            onToggleAutovisor: { Task { await store.setAutovisorEnabled(!autovisorEnabled) } },
            onNavigateToTask: { navigationSelection = .task($0) },
            onPauseRun: { taskID in Task { await store.pauseRun(taskID: taskID) } },
            onShowFinalReview: onShowFinalReview,
            onCloseTask: { taskID in Task { _ = await store.closeTask(taskID: taskID) } }
        )
    }
}
