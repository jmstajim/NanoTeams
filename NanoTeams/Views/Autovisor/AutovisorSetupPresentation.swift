import Foundation

/// What the Autovisor's start page shows around the goal editor: the chosen driver, what it
/// means, and — for an external agent — whether one can connect yet. Pure: `AutovisorSetupView`
/// builds it from the store, the previews from mocked facts.
nonisolated struct AutovisorSetupPresentation: Equatable, Sendable {

    /// Whether an external agent can reach this folder now — one line beside the button that
    /// opens Settings → External Agents.
    nonisolated struct ExternalAgentsLine: Equatable, Sendable {
        let text: String
        /// The server is listening and at least one agent holds a token: the green dot.
        let isReady: Bool
    }

    let driver: AutovisorDriver
    /// The saved goal — the editor's first text (`initialGoalDraft`).
    let persistedGoal: String
    /// `nil` under the built-in driver, which needs no server.
    let externalAgents: ExternalAgentsLine?

    var driverCaption: String { AutovisorDriverPicker.caption(for: driver) }

    /// Where the goal goes, and whether it is needed at all. The built-in manager RUNS on it —
    /// it is that manager's system prompt, and `AutovisorPolicy.requiresSetupBeforeEnabling`
    /// gates activation on a real one. An external agent arrives with instructions of its own
    /// and nothing gates it, so there the field is optional — and the caption has to say both
    /// that and what it is still for: the one direction that survives the agent's session, read
    /// off `folder_status` by whichever agent connects next. The other half of that contract is
    /// `HostedMCPInstructions`, which has to claim the field by name (CLAUDE.md #386).
    var goalCaption: String {
        switch driver {
        case .builtInModel:
            "Injected into the manager's system prompt. You can edit it any time from the chat or Settings → Autovisor."
        case .externalAgent:
            "Optional — the agent brings its own instructions. A goal set here outlives its session: the agent reads it with the folder's status. Editable any time in Settings → Autovisor."
        }
    }

    static func make(
        driver: AutovisorDriver,
        persistedGoal: String,
        externalAgentsEnabled: Bool,
        listenerState: HostedMCPListenerState,
        configuredPort: UInt16,
        agentCount: Int
    ) -> AutovisorSetupPresentation {
        AutovisorSetupPresentation(
            driver: driver,
            persistedGoal: persistedGoal,
            externalAgents: driver == .externalAgent
                ? externalAgentsLine(
                    enabled: externalAgentsEnabled,
                    listenerState: listenerState,
                    configuredPort: configuredPort,
                    agentCount: agentCount)
                : nil)
    }

    /// The server's state as Settings → External Agents reads it
    /// (`ExternalAgentsSettingsPresentation`), said from the Autovisor's side: can an agent
    /// connect, and if not, what is missing.
    static func externalAgentsLine(
        enabled: Bool,
        listenerState: HostedMCPListenerState,
        configuredPort: UInt16,
        agentCount: Int
    ) -> ExternalAgentsLine {
        let status = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: enabled,
            configuredPort: configuredPort,
            listenerState: listenerState,
            agents: [],
            presenceByAgent: [:],
            openTasksByAgent: [:],
            bashWarnings: []
        ).listenerStatus
        switch status {
        case .disabled:
            return ExternalAgentsLine(text: "The server for external agents is off: no agent can connect.", isReady: false)
        case .listening where agentCount == 0:
            return ExternalAgentsLine(text: "The server for external agents is on, but no agent has a token.", isReady: false)
        case .listening:
            let agents = agentCount == 1 ? "1 agent" : "\(agentCount) agents"
            return ExternalAgentsLine(text: "The server for external agents is on · \(agents) with a token.", isReady: true)
        case .starting:
            return ExternalAgentsLine(text: "The server for external agents is starting…", isReady: false)
        case .portInUse(let port):
            return ExternalAgentsLine(text: "The server for external agents could not start: port \(port) is in use.", isReady: false)
        case .failed:
            return ExternalAgentsLine(text: "The server for external agents could not start.", isReady: false)
        case .stopped:
            return ExternalAgentsLine(text: "The server for external agents is stopped.", isReady: false)
        }
    }

    /// The editor's first text: the saved goal, or — when none is saved — the default "explore
    /// and wait" directive, so the field is never blank and enabling without editing yields a
    /// manager that waits rather than one with nothing to do.
    static func initialGoalDraft(persisted: String) -> String {
        persisted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AutovisorConstants.defaultGoal
            : persisted
    }
}
