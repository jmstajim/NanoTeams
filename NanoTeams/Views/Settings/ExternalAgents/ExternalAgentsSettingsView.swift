import SwiftUI

/// Settings tab for the hosted External Agents MCP server (`SettingsTab.externalAgents`, §11 & Appendix C).
///
/// The store-facing half: reads the orchestrator into an `ExternalAgentsSettingsPresentation` and
/// performs every action the tab offers — the content view (`ExternalAgentsSettingsContent`) draws
/// the presentation and calls back through `Actions`. Split so the tab's states can be rendered
/// from mocked records (`ExternalAgentsSettingsView+Previews.swift`) without a Keychain: issuing an
/// agent through `HostedMCPAgentStore` writes a real secret.
///
/// Adding an agent and reissuing a token happen in `ExternalAgentSheet`, which the Settings
/// window presents (`agentSheet` is its binding) — see that type for why not this tab.
struct ExternalAgentsSettingsView: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(\.openWindow) private var openWindow

    /// The Add agent / Reissue sheet the Settings window presents; the tab only opens it.
    @Binding var agentSheet: ExternalAgentSheet.Entry?

    /// A token as the sheet hands it over, once: copied there for a client that sends it in a
    /// header, and written to its token file for the bridge (`delivery` says whether the file
    /// took it). Nothing holds one past that sheet.
    struct IssuedAgentTokenItem: Identifiable, Equatable {
        let id: UUID
        let label: String
        let shortID: String
        let token: String
        let delivery: HostedMCPTokenHandoff.Delivery
    }

    /// The tab's facts, read from the store. The agent list is re-read whenever
    /// `hostedMCPAgentsRevision` moves — the agent store bumps it on every create, rotate and
    /// revoke — so an action needs no counter of its own to refresh the list.
    static func presentation(of store: NTMSOrchestrator) -> ExternalAgentsSettingsPresentation {
        _ = store.hostedMCPAgentsRevision
        _ = store.lastExternalAutovisorActivityAt
        let records = store.hostedMCPAgentStore.listAgents()
        var presence: [UUID: Bool] = [:]
        var openCounts: [UUID: Int] = [:]
        for record in records {
            presence[record.id] = store.isHostedMCPAgentPresent(record.id)
            openCounts[record.id] = store.openExternalTaskCount(for: record.id)
        }
        return ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: store.configuration.externalAgentsEnabled,
            configuredPort: store.effectiveHostedMCPPort,
            listenerState: store.hostedMCPListenerState,
            agents: records,
            presenceByAgent: presence,
            openTasksByAgent: openCounts,
            bashWarnings: store.activeBashSecurityWarnings,
            inheritedTokenAtLaunch: NanoTeamsLauncher.inheritedTokenAtLaunch
        )
    }

    /// The three actions that issue a token, against the store — what the sheet calls.
    static func tokenIssuers(of store: NTMSOrchestrator) -> ExternalAgentSheet.TokenIssuers {
        ExternalAgentSheet.TokenIssuers(
            addAgent: { label in
                [IssuedAgentTokenItem(try store.addHostedMCPAgent(label: label))]
            },
            rotateToken: { agentID in
                [IssuedAgentTokenItem(try store.reissueHostedMCPAgentToken(agentID: agentID))]
            },
            rotateAllTokens: {
                ExternalAgentSheet.IssueResult(bulk: store.rotateAllHostedMCPAgentTokens())
            }
        )
    }

    /// The tab's revoke, against the store: the agent and its token file. Revoked either way; a
    /// verifier or a token file left behind is worth one line, which this returns.
    static func agentRevoker(of store: NTMSOrchestrator) -> @MainActor (UUID) throws -> String? {
        { agentID in
            // NanoTeams removes the token file; the entry the person added in the client still
            // names it, and a client that keeps dialling a file that is gone reports a failed
            // server with nothing to explain it — so the revoke says what to remove there (#376).
            let leftBehind = try store.revokeHostedMCPAgent(agentID: agentID)
            return [leftBehind, ExternalAgentsConnectionFacts.removalHint].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// A task, or a background command of one, may have a live role — one that can read the
    /// clipboard with `pbpaste`.
    ///
    /// `.needsAcceptance` and `.needsSupervisorInput` count, because an engine reports what the
    /// TASK is waiting for while its other roles keep working (CLAUDE.md #45: ready roles run in
    /// parallel). Reading `.running` alone withheld the warning in exactly the states a parked
    /// question creates — one role waiting on the Supervisor, another mid-tool-loop (#376).
    static let statesWithPossiblyLiveRoles: Set<TeamEngineState> = [
        .running, .needsAcceptance, .needsSupervisorInput,
    ]

    static func rolesAreRunning(in store: NTMSOrchestrator) -> Bool {
        store.taskEngineStates.values.contains { statesWithPossiblyLiveRoles.contains($0) }
            || BackgroundBashRegistry.shared.hasRunningCommands
    }

    var body: some View {
        ExternalAgentsSettingsContent(
            presentation: Self.presentation(of: store),
            isEnabled: Binding(
                get: { store.configuration.externalAgentsEnabled },
                set: { store.configuration.externalAgentsEnabled = $0 }
            ),
            storedPort: store.configuration.externalAgentsPort,
            agentSheet: $agentSheet,
            actions: actions
        )
    }

    private var actions: ExternalAgentsSettingsContent.Actions {
        ExternalAgentsSettingsContent.Actions(
            restartServer: {
                _ = try await store.startHostedMCPServer()
            },
            setPort: { port in
                store.configuration.externalAgentsPort = port
            },
            revokeAgent: Self.agentRevoker(of: store),
            setMayReplaceWorkFolderContext: { agentID, allowed in
                try store.setHostedMCPAgentMayReplaceWorkFolderContext(allowed, agentID: agentID)
            },
            openBashSettings: {
                SettingsNavigation.open(tab: .bash, using: openWindow)
            }
        )
    }
}

extension ExternalAgentsSettingsView.IssuedAgentTokenItem {
    init(_ handoff: HostedMCPTokenHandoff) {
        let record = handoff.agent.record
        self.init(
            id: record.id, label: record.label, shortID: record.shortID, token: handoff.agent.token,
            delivery: handoff.delivery)
    }
}

/// The store-facing half of `ExternalAgentSheet`, presented by the Settings window: the
/// roster for the duplicate-name check, the port and binary the connection facts name, and the
/// issuers.
/// Re-evaluated as the store moves; the sheet's own stage survives it (its `@State`).
struct ExternalAgentSheetHost: View {
    @Environment(NTMSOrchestrator.self) private var store
    let entry: ExternalAgentSheet.Entry

    var body: some View {
        ExternalAgentSheet(
            opening: entry.initialStage,
            existingAgents: ExternalAgentsSettingsView.presentation(of: store).agentRows,
            port: store.effectiveHostedMCPPort,
            executablePath: ExternalAgentsConnectionFacts.runningExecutablePath,
            clientHome: store.hostedMCPEnvironment.clientHomeDirectory(),
            rolesAreRunning: ExternalAgentsSettingsView.rolesAreRunning(in: store),
            issuers: ExternalAgentsSettingsView.tokenIssuers(of: store)
        )
    }
}
