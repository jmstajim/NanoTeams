import SwiftUI

/// The Autovisor's start page — driver, goal, **Enable**. Shown by
/// `MainLayoutView.autovisorDetail` whenever `store.autovisorDetailPane == .setup`, which is
/// every switched-off state of both drivers:
///
/// • **First run** — the built-in manager was never created (`autovisorTaskID == nil`).
/// • **Re-enable** — the Autovisor is switched off. Disabling keeps the manager's task, so
///   this page replaces the chat (or the external agent's pane) for the whole off period;
///   the conversation is untouched and comes back on the next enable.
///
/// The store-facing half: builds `AutovisorSetupPresentation` and hands it, with the three
/// actions, to `AutovisorSetupContent` — split so the page renders from mocked facts in
/// `AutovisorSetupView+Previews.swift`.
///
/// Enable (from the content, `actions.enable`):
/// 1. `updateAutovisorGoal` persists the edited goal.
/// 2. `setAutovisorEnabled(true)` flips the settings flag; under the built-in driver
///    `ensureAutovisorTask` creates the manager team-then-task on first run, or re-arms the
///    review recurrence for an existing one.
/// 3. `autovisorDetail` re-evaluates: the route is now the chat or the agent's pane.
///    No explicit navigation push — the body re-render IS the route.
struct AutovisorSetupView: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AutovisorSetupContent(
            presentation: Self.presentation(of: store),
            actions: AutovisorSetupContent.Actions(
                selectDriver: { driver in
                    Task { await store.setAutovisorDriver(driver) }
                },
                openExternalAgents: {
                    SettingsNavigation.open(tab: .externalAgents, using: openWindow)
                },
                // Ordering matters: `setAutovisorEnabled(true)` → `ensureAutovisorTask` reads
                // the persisted goal when seeding a new manager's brief, so the goal is written
                // FIRST and the brief and the goal start in lock-step.
                enable: { goal in
                    await store.updateAutovisorGoal(goal)
                    await store.setAutovisorEnabled(true)
                }
            )
        )
    }

    static func presentation(of store: NTMSOrchestrator) -> AutovisorSetupPresentation {
        // The agent store is not observable; its revision is what changes on add/revoke.
        _ = store.hostedMCPAgentsRevision
        return AutovisorSetupPresentation.make(
            driver: store.workFolder?.settings.autovisorDriver ?? .builtInModel,
            persistedGoal: store.workFolder?.settings.autovisorGoal ?? "",
            externalAgentsEnabled: store.configuration.externalAgentsEnabled,
            listenerState: store.hostedMCPListenerState,
            configuredPort: store.effectiveHostedMCPPort,
            agentCount: store.hostedMCPAgentStore.agents.count
        )
    }
}
