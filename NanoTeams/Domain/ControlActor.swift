import Foundation

/// Who did something to a task on purpose — pressed Pause or Resume, closed it, deleted it: the
/// person at the app, the built-in Autovisor, or an external agent.
///
/// Recorded where the action lands — the run's pause (`Run.pauseRequestedBy`), its timeline
/// (`SupervisorTimelineEvent.actor`), the event feed's candidate — so every reader names the same
/// author and a relaunch reads the same (CLAUDE.md #365, #371). Until 2026-11-09 nothing recorded
/// it: every Pause read `by_person` to the agent that had pressed it itself, and the agent was
/// told about its own creates, closes and pauses as if somebody else had made them.
nonisolated enum ControlActor: Codable, Hashable, Sendable {
    case person
    case builtInAutovisor
    case externalAgent(AgentIdentity)

    /// Whether this is the external agent `agentID` — what makes an event about the action an
    /// echo for that agent: it already has the result from its own call.
    func isExternalAgent(_ agentID: UUID) -> Bool {
        if case .externalAgent(let identity) = self { return identity.id == agentID }
        return false
    }

    /// Whether an automated supervisor — the built-in Autovisor or an external agent — acted. A
    /// person's pause is not lifted by one of them implicitly (`Run.isPausedByThePerson`).
    var isAutomated: Bool {
        switch self {
        case .person: false
        case .builtInAutovisor, .externalAgent: true
        }
    }

    /// The name this actor signs a timeline event with: the agent's label, the built-in
    /// Autovisor's word, and `Supervisor` for the person — the name the transcript gives their
    /// turns.
    var label: String {
        switch self {
        case .person:
            return Self.personLabel
        case .builtInAutovisor:
            return LLMMessage.automatedSupervisorLabel
        case .externalAgent(let identity):
            let trimmed = identity.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.unnamedAgentLabel : trimmed
        }
    }

    static let personLabel = "Supervisor"
    static let unnamedAgentLabel = "External agent"

    private enum CodingKeys: String, CodingKey {
        case kind
        case agent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "person":
            self = .person
        case "builtInAutovisor":
            self = .builtInAutovisor
        case "externalAgent":
            self = .externalAgent(try container.decode(AgentIdentity.self, forKey: .agent))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown ControlActor kind: \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .person:
            try container.encode("person", forKey: .kind)
        case .builtInAutovisor:
            try container.encode("builtInAutovisor", forKey: .kind)
        case .externalAgent(let identity):
            try container.encode("externalAgent", forKey: .kind)
            try container.encode(identity, forKey: .agent)
        }
    }
}

nonisolated extension AutovisorActor {
    /// The actor as the task records it: the built-in manager is the built-in Autovisor.
    var controlActor: ControlActor {
        switch self {
        case .builtInManager: .builtInAutovisor
        case .externalAgent(let identity, _): .externalAgent(identity)
        }
    }
}
