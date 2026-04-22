import Foundation

// MARK: - Message Source Context

/// Context indicating how an injected message was produced.
enum MessageSourceContext: String, Codable {
    case consultation
    case meeting
    case changeRequest
    case supervisorAnswer
    /// Unsolicited Supervisor message injected mid-iteration from the queued-chat
    /// pipeline (see `NTMSOrchestrator.consumeQueuedSupervisorMessage`). Distinct
    /// from `.supervisorAnswer` — those are paired with `ask_supervisor` tool calls
    /// and rendered separately by `ActivityFeedBuilder`.
    case supervisorMessage

    private static let displayLabelMap: [MessageSourceContext: String] = [
        .consultation: "consultation",
        .meeting: "meeting",
        .changeRequest: "change request",
        .supervisorAnswer: "supervisor answer",
        .supervisorMessage: "message",
    ]

    var displayLabel: String { Self.displayLabelMap[self] ?? rawValue }

    /// Shared attribution marker prepended to queued Supervisor turns. Single
    /// source of truth so the write side (`NTMSOrchestrator.consumeQueuedSupervisorMessage`)
    /// and the read side (`LLMMessage.displayContent`) can't drift on rename.
    static let supervisorMessagePrefix = "Supervisor:\n"
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
        // `.supervisorMessage` is rendered with bubble styling matching the
        // initial Supervisor task brief — the avatar + role name already convey
        // the context, so no secondary "(message)" label.
        if sourceContext == .supervisorMessage { return nil }
        if let ctx = sourceContext { return ctx.displayLabel }
        if role == .user && sourceRole == nil { return "input" }
        if sourceRole != nil { return "consultation" }
        return nil
    }

    /// Content ready for rendering in the activity feed. For `.supervisorMessage`
    /// turns, strips the leading attribution marker (`MessageSourceContext.supervisorMessagePrefix`)
    /// — it's there so the LLM can identify the speaker when the turn lands in a
    /// combined `input` string alongside tool results and memory blocks, but the
    /// bubble already shows the role name above, so the prefix is redundant UI noise.
    ///
    /// Also accepts the legacy single-line `"Supervisor: "` form so messages
    /// persisted by earlier builds still render cleanly after upgrade.
    var displayContent: String {
        guard sourceContext == .supervisorMessage else { return content }
        let multiline = MessageSourceContext.supervisorMessagePrefix
        if content.hasPrefix(multiline) {
            return String(content.dropFirst(multiline.count))
        }
        let inline = "Supervisor: "
        if content.hasPrefix(inline) {
            return String(content.dropFirst(inline.count))
        }
        return content
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
