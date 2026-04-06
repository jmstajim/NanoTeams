import Foundation

// MARK: - Message Source Context

/// Context indicating how an injected message was produced.
enum MessageSourceContext: String, Codable {
    case consultation
    case meeting
    case changeRequest
    case supervisorAnswer

    private static let displayLabelMap: [MessageSourceContext: String] = [
        .consultation: "consultation",
        .meeting: "meeting",
        .changeRequest: "change request",
        .supervisorAnswer: "supervisor answer",
    ]

    var displayLabel: String { Self.displayLabelMap[self] ?? rawValue }
}

// MARK: - LLM Role

/// OpenAI-compatible role for LLM conversation messages.
enum LLMRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - LLM Message

/// Represents a single message in the LLM conversation (full prompts sent to the model).
struct LLMMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var role: LLMRole
    var content: String
    /// Reasoning / thinking content from the LLM (e.g. reasoning_content from DeepSeek/QwQ).
    var thinking: String?
    /// The originating role for injected messages (e.g. teammate consultation responses).
    /// When set, views use this for avatar/title instead of inferring from ``role``.
    var sourceRole: Role?
    /// How this message was produced (consultation, meeting, etc.).
    var sourceContext: MessageSourceContext?

    enum CodingKeys: String, CodingKey {
        case id, createdAt, role, content, thinking, sourceRole, sourceContext
    }

    init(id: UUID = UUID(), createdAt: Date = MonotonicClock.shared.now(), role: LLMRole, content: String, thinking: String? = nil, sourceRole: Role? = nil, sourceContext: MessageSourceContext? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.content = content
        self.thinking = thinking
        self.sourceRole = sourceRole
        self.sourceContext = sourceContext
    }

    /// Display label for the message's source context (e.g. "(consultation)", "(input)").
    /// Returns nil for regular assistant/system messages without special context.
    var sourceContextDisplayLabel: String? {
        if let ctx = sourceContext { return ctx.displayLabel }
        if role == .user && sourceRole == nil { return "input" }
        if sourceRole != nil { return "consultation" }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        // Decode as String for backward compatibility, then convert to LLMRole
        let roleString = try c.decode(String.self, forKey: .role)
        self.role = LLMRole(rawValue: roleString) ?? .user
        self.content = try c.decode(String.self, forKey: .content)
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.sourceRole = try c.decodeIfPresent(Role.self, forKey: .sourceRole)
        self.sourceContext = try c.decodeIfPresent(MessageSourceContext.self, forKey: .sourceContext)
    }
}
