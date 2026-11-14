import SwiftUI

/// Main detail pane for the Autovisor destination when `autovisorDriver == .externalAgent` (§11, Ш21).
///
/// The store-facing half: reads the orchestrator, builds the pure
/// `ExternalAutovisorPanePresentation`, and hands it to `ExternalAutovisorPaneContent` with the
/// six actions the pane can take. Split this way so the content can be previewed and rendered
/// from mocked records (`ExternalAutovisorPane+Previews.swift`) — the same shape as
/// `MCPServerStatusCard`, which draws a presentation and nothing else.
struct ExternalAutovisorPane: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedItem: MainLayoutView.NavigationItem?
    /// The activity card's task filter. View-local, like the Watchtower's: what a person is
    /// looking at, not a fact about the folder.
    @State private var activityTaskFilter: Int?

    private var presentation: ExternalAutovisorPanePresentation {
        _ = store.hostedMCPAgentsRevision
        _ = store.lastExternalAutovisorActivityAt
        return ExternalAutovisorPanePresentation.build(
            listenerState: store.hostedMCPListenerState,
            externalAgentsEnabled: store.configuration.externalAgentsEnabled,
            configuredPort: store.effectiveHostedMCPPort,
            isAutovisorEnabled: store.workFolder?.settings.autovisorEnabled ?? false,
            readiness: store.externalAutovisorReadiness,
            agentRecords: store.hostedMCPAgentStore.agents,
            isAgentPresent: { store.isHostedMCPAgentPresent($0) },
            hasActiveWait: { store.hasActiveHostedMCPWait(forAgent: $0) },
            taskSummaries: store.snapshot?.tasksIndex.tasks ?? [],
            loadedTask: { store.loadedTask($0) },
            activityEntries: store.externalActivityLog.entries,
            fullCallIDs: store.externalActivityLog.fullCallIDs,
            activityTaskFilter: activityTaskFilter,
            activityClearedUpTo: store.configuration.timelineClearedUpToDate
        )
    }

    var body: some View {
        ExternalAutovisorPaneContent(
            presentation: presentation,
            onToggleAutovisor: { next in
                Task { await store.setAutovisorEnabled(next) }
            },
            onOpenTask: { taskID in
                selectedItem = .task(taskID)
            },
            onOpenExternalAgents: {
                SettingsNavigation.open(tab: .externalAgents, using: openWindow)
            },
            onOpenFullCall: { item in
                // A person's tap, so a window may open (`ExternalAgentOpensNoWindowPinTests`
                // guards the agent's own path, not this one). The window loads the call itself.
                openWindow(value: item.detailWindow)
            },
            onSelectActivityTaskFilter: { activityTaskFilter = $0 },
            onHideActivity: {
                // The Watchtower's cutoff, not one of our own: hiding here hides Recent Activity
                // on the main screen too, and the other way round.
                store.configuration.timelineClearedUpToDate = MonotonicClock.shared.now()
            }
        )
    }
}
