import Foundation

// MARK: - Message Source Context

/// Context indicating how an injected message was produced.
nonisolated enum MessageSourceContext: String, Codable {
    case consultation
    case meeting
    case changeRequest
    case supervisorAnswer
    /// Unsolicited Supervisor message injected mid-iteration from the queued-chat
    /// pipeline (see `NTMSOrchestrator.consumeQueuedSupervisorMessage`). Distinct
    /// from `.supervisorAnswer` — those are paired with `ask_supervisor` tool calls
    /// and rendered separately by `ActivityFeedBuilder`.
    case supervisorMessage
    /// Question that arrived from a delegated child team's `ask_supervisor` call
    /// while this role's `delegate_to_team` handler was awaiting completion. The
    /// question is appended to this role's `step.llmConversation` for activity-feed
    /// visibility; the actual answering happens in
    /// `DelegatedSupervisorAnswerService`, which seeds a one-shot side exchange
    /// from that same conversation.
    case delegatedQuestion
    /// Question that bubbled up the delegation chain (a delegated team's role asked
    /// `ask_supervisor`, the immediate parent role couldn't answer and itself called
    /// `ask_supervisor`, escalating to its own supervisor). Tagged so the activity
    /// feed of each ancestor can show the escalation chain.
    case delegationEscalation
    /// Transient retry-status note written while a recoverable LLM error keeps
    /// retrying (server unreachable, 5xx, …). Rendered as a red error bubble in the
    /// activity feed and collapsed in place across attempts (see
    /// `TaskMutationService.appendOrReplaceRetryNotice`). Display-only — never sent
    /// to the model.
    case serverError
    /// Correction appended after an in-stream thinking loop broke the stream and the
    /// looping generation was discarded (`LoopRecoveryPolicy.retryWithNudge`).
    /// Unlike `.serverError` this one IS sent — it is the entire recovery, since a
    /// stateless resend without it is byte-identical to the request that looped. The
    /// context exists so the turn survives the activity feed's `.user`-with-no-context
    /// filter; without it the only record of a loop break would be a `cancelled` row
    /// in `network_log.json`, which is off by default in Release.
    case loopCorrection
    /// A retry nudge the runtime appended after a turn produced no usable tool call —
    /// the drift reminder, the repetition warning, the malformed-envelope retry, the
    /// missing-artifacts reminder, the planning-phase plan note, the generic
    /// "you replied with text" nudge. Like `.loopCorrection` these ARE sent; the context
    /// exists so they survive the activity feed's `.user`-with-no-context filter.
    ///
    /// Without it the user watches a role emit the same reply N times with nothing on
    /// screen explaining why it is being asked again — which is exactly how the wedged
    /// Autovisor pass presented: identical bubbles, no visible cause. A nudge is the
    /// app talking to the model on the user's behalf, so it belongs on the record.
    ///
    /// Deliberately NOT `.loopCorrection`: that one means "the stream looped and was
    /// discarded", and labelling a tokens-only retry with it would be a new lie.
    case retryNudge

    private static let displayLabelMap: [MessageSourceContext: String] = [
        .consultation: "consultation",
        .meeting: "meeting",
        .changeRequest: "change request",
        .supervisorAnswer: "supervisor answer",
        .supervisorMessage: "message",
        .delegatedQuestion: "delegated question",
        .delegationEscalation: "escalation",
        .loopCorrection: "loop correction",
        .retryNudge: "retry",
    ]

    var displayLabel: String { Self.displayLabelMap[self] ?? rawValue }

    /// Shared attribution marker prepended to queued Supervisor turns. Single
    /// source of truth so the write side (`NTMSOrchestrator.consumeQueuedSupervisorMessage`)
    /// and the read side (`LLMMessage.displayContent`) can't drift on rename.
    static let supervisorMessagePrefix = "Supervisor:\n"

    /// Attribution marker prepended to supervisor ANSWER turns (`.supervisorAnswer`).
    /// Single source of truth across the write sides
    /// (`StepMessagingService.answerSupervisorQuestion`, the auto-answer append in
    /// `LLMExecutionService+ToolLoopState`, the stateless rebuild in `PromptBuilder`)
    /// and the read sides (`LLMMessage.displayContent`, the answered-notification
    /// extraction in `ActivityFeedBuilder.emitItems`).
    static let supervisorAnswerPrefix = "Supervisor answer: "

    /// Attribution marker for revision/correction feedback turns. `step.revisionComment`
    /// holds the RAW text; this prefix is attached exactly once where the feedback
    /// reaches the LLM — at the stateful send site (`LLMExecutionService+StepLifecycle`)
    /// or baked into the single `StepMessage` copy that the stateless rebuild relays
    /// (`PromptBuilder` reads `step.messages`). Single source of truth across the
    /// write sites (`requestRevision`, `correctRole`) and the send site.
    static let supervisorFeedbackPrefix = "Supervisor Feedback: "

    /// Normalizes incoming feedback to its RAW form: trims whitespace and strips a
    /// leading ``supervisorFeedbackPrefix`` if the author already included one — the
    /// Autovisor's LLM sees the prefixed pattern in conversation history and can emit
    /// it inside the `comment` argument; legacy `revisionComment` values persisted by
    /// pre-fix builds carry it too. Idempotent, so every prefix-attaching site can
    /// apply it unconditionally without double-stripping user text.
    static func rawFeedback(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match the marker without its trailing space: the outer trim can eat that
        // space when the prefix arrives bare ("Supervisor Feedback:"), and model
        // emissions sometimes omit it ("Supervisor Feedback:text").
        let bareMarker = supervisorFeedbackPrefix.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(bareMarker) else { return trimmed }
        return String(trimmed.dropFirst(bareMarker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - LLM Role

/// OpenAI-compatible role for LLM conversation messages.
nonisolated enum LLMRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - LLM Message

/// Represents a single message in the LLM conversation (full prompts sent to the model).
nonisolated struct LLMMessage: Codable, Identifiable, Hashable {
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
        // The red bubble + self-describing content already convey "server error";
        // a "(serverError)" label would be redundant noise.
        if sourceContext == .serverError { return nil }
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
    ///
    /// `.supervisorAnswer` turns strip `supervisorAnswerPrefix` the same way —
    /// unpaired answers (escalation / Autovisor idle park) render as durable
    /// Supervisor bubbles whose header already attributes the speaker.
    var displayContent: String {
        switch sourceContext {
        case .supervisorMessage:
            let multiline = MessageSourceContext.supervisorMessagePrefix
            if content.hasPrefix(multiline) {
                return String(content.dropFirst(multiline.count))
            }
            let inline = "Supervisor: "
            if content.hasPrefix(inline) {
                return String(content.dropFirst(inline.count))
            }
            return content
        case .supervisorAnswer:
            let prefix = MessageSourceContext.supervisorAnswerPrefix
            if content.hasPrefix(prefix) {
                return String(content.dropFirst(prefix.count))
            }
            return content
        default:
            return content
        }
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
        // Decode tolerantly (string + rawValue lookup, same as `role` above): an
        // unknown context raw — e.g. a case added by a newer build, read after a
        // downgrade — degrades to `nil` instead of throwing and failing the whole
        // message (and the step / task) to decode.
        let sourceContextRaw = try c.decodeIfPresent(String.self, forKey: .sourceContext)
        self.sourceContext = sourceContextRaw.flatMap(MessageSourceContext.init(rawValue:))
    }
}
