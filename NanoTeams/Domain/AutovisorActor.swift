import Foundation

/// Identifies the caller executing an Autovisor action (`performAutovisorAction`).
nonisolated enum AutovisorActor: Hashable, Sendable {
    case builtInManager
    case externalAgent(AgentIdentity, session: String?)

    static func externalAgent(_ identity: AgentIdentity) -> AutovisorActor {
        .externalAgent(identity, session: nil)
    }

    var taskOrigin: TaskOrigin {
        switch self {
        case .builtInManager:
            return .builtInAutovisor
        case .externalAgent(let identity, _):
            return .externalAgent(identity)
        }
    }

    /// The label this actor signs its Supervisor turns and timeline events with: the external
    /// agent's, and none for the built-in manager — whose turns still record that an automated
    /// path wrote them (`LLMMessage.isFromAutomatedSupervisor`, DEBTS D-M15).
    var agentLabel: String? {
        switch self {
        case .builtInManager:
            return nil
        case .externalAgent(let identity, _):
            return identity.label
        }
    }
}
