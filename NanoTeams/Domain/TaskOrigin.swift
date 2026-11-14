import Foundation

/// Records which Autovisor driver created a top-level task.
///
/// Human-created tasks (and delegated child tasks) leave `NTMSTask.origin` as `nil`.
nonisolated enum TaskOrigin: Codable, Hashable, Sendable {
    case builtInAutovisor
    case externalAgent(AgentIdentity)

    var isBuiltInAutovisor: Bool {
        if case .builtInAutovisor = self { return true }
        return false
    }

    var isExternalAgent: Bool {
        if case .externalAgent = self { return true }
        return false
    }

    var externalAgentIdentity: AgentIdentity? {
        if case .externalAgent(let identity) = self { return identity }
        return nil
    }

    /// Who wrote the task, as its Supervisor card names them — the agent mark in the feed,
    /// `Supervisor (…)` in `conversation_log.md`. The built-in Autovisor is the word every
    /// unsigned automated Supervisor turn wears (``LLMMessage/automatedSupervisorLabel``), so the
    /// task it created and the messages it sends carry one mark; until 2026-11-08 only an
    /// external agent's task had one. `nil` for a blank agent label: an empty mark names nobody.
    var authorLabel: String? {
        switch self {
        case .builtInAutovisor:
            return LLMMessage.automatedSupervisorLabel
        case .externalAgent(let identity):
            let trimmed = identity.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func matchesExternalAgent(_ id: UUID) -> Bool {
        if case .externalAgent(let identity) = self {
            return identity.id == id
        }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case agent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "builtInAutovisor", "built_in_autovisor":
            self = .builtInAutovisor
        case "externalAgent", "external_agent":
            let agent = try container.decode(AgentIdentity.self, forKey: .agent)
            self = .externalAgent(agent)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown TaskOrigin kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtInAutovisor:
            try container.encode("builtInAutovisor", forKey: .kind)
        case .externalAgent(let identity):
            try container.encode("externalAgent", forKey: .kind)
            try container.encode(identity, forKey: .agent)
        }
    }
}
