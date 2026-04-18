import Foundation

struct StepExecution: Codable, Identifiable, Hashable {
    /// The role ID that owns this step (e.g., "faang_team_software_engineer").
    var id: String
    var role: Role
    var title: String

    /// Lightweight expectation snapshot for this run (artifact names).
    var expectedArtifacts: [String]

    var status: StepStatus
    var createdAt: Date
    var updatedAt: Date
    /// Set exactly once when step transitions to `.done` or `.failed`. Never modified after.
    var completedAt: Date?

    var messages: [StepMessage]
    var artifacts: [Artifact]

    /// Structured tool calls captured from OpenAI-compatible responses.
    var toolCalls: [StepToolCall]

    /// LLM-managed scratchpad for planning and tracking progress within a step.
    /// Updated via the update_scratchpad tool. Uses markdown with ~~strikethrough~~ for completed items.
    var scratchpad: String?

    /// Teammate consultations during this step (via ask_teammate tool).
    var consultations: [TeammateConsultation]

    /// IDs of team meetings initiated during this step.
    var meetingIDs: [UUID]

    /// Amendments applied to this step (from change requests by other roles).
    var amendments: [StepAmendment]

    /// Whether the assistant requested Supervisor input.
    var needsSupervisorInput: Bool
    var supervisorQuestion: String?
    var supervisorAnswer: String?

    /// Work-folder-root-relative file paths attached to the supervisor's answer.
    var supervisorAnswerAttachmentPaths: [String]

    /// Optional Supervisor comment that should be injected as an extra message into the next step.
    var supervisorCommentForNext: String?

    /// Cumulative token usage across all LLM iterations in this step.
    var tokenUsage: TokenUsage?

    /// Full LLM conversation (all prompts and responses sent to/from the model).
    var llmConversation: [LLMMessage]

    /// Saved LLM session ID (previous_response_id) for resuming after Supervisor pause or revision.
    /// Set when step completes or pauses for `needsSupervisorInput`; kept on revision reset.
    var llmSessionID: String?

    /// Non-nil when the step is in revision mode (Supervisor requested changes).
    /// Contains the Supervisor's feedback. Cleared when LLM creates a new artifact via `create_artifact`.
    /// While set, `checkArtifactCompleteness` is skipped to prevent premature auto-completion
    /// from artifacts created in the prior execution.
    var revisionComment: String?

    init(
        id: String,
        role: Role,
        title: String,
        expectedArtifacts: [String] = [],
        status: StepStatus = .pending,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        completedAt: Date? = nil,
        messages: [StepMessage] = [],
        artifacts: [Artifact] = [],
        toolCalls: [StepToolCall] = [],
        scratchpad: String? = nil,
        consultations: [TeammateConsultation] = [],
        meetingIDs: [UUID] = [],
        amendments: [StepAmendment] = [],
        needsSupervisorInput: Bool = false,
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil,
        supervisorAnswerAttachmentPaths: [String] = [],
        supervisorCommentForNext: String? = nil,
        tokenUsage: TokenUsage? = nil,
        llmConversation: [LLMMessage] = [],
        llmSessionID: String? = nil,
        revisionComment: String? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.expectedArtifacts = expectedArtifacts
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.messages = messages
        self.artifacts = artifacts
        self.toolCalls = toolCalls
        self.scratchpad = scratchpad
        self.consultations = consultations
        self.meetingIDs = meetingIDs
        self.amendments = amendments
        self.needsSupervisorInput = needsSupervisorInput
        self.supervisorQuestion = supervisorQuestion
        self.supervisorAnswer = supervisorAnswer
        self.supervisorAnswerAttachmentPaths = supervisorAnswerAttachmentPaths
        self.supervisorCommentForNext = supervisorCommentForNext
        self.tokenUsage = tokenUsage
        self.llmConversation = llmConversation
        self.llmSessionID = llmSessionID
        self.revisionComment = revisionComment
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case title
        case expectedArtifacts
        case status
        case createdAt
        case updatedAt
        case completedAt
        case messages
        case artifacts
        case toolCalls
        case scratchpad
        case consultations
        case meetingIDs
        case amendments
        case needsSupervisorInput
        case supervisorQuestion
        case supervisorAnswer
        case supervisorAnswerAttachmentPaths
        case supervisorCommentForNext
        case tokenUsage
        case llmConversation
        case llmSessionID
        case revisionComment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.title = try c.decode(String.self, forKey: .title)
        self.expectedArtifacts = try c.decodeIfPresent([String].self, forKey: .expectedArtifacts) ?? []
        self.status = try c.decodeIfPresent(StepStatus.self, forKey: .status) ?? .pending
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.messages = try c.decodeIfPresent([StepMessage].self, forKey: .messages) ?? []
        self.artifacts = try c.decodeIfPresent([Artifact].self, forKey: .artifacts) ?? []
        self.toolCalls = try c.decodeIfPresent([StepToolCall].self, forKey: .toolCalls) ?? []
        self.scratchpad = try c.decodeIfPresent(String.self, forKey: .scratchpad)
        self.consultations = try c.decodeIfPresent([TeammateConsultation].self, forKey: .consultations) ?? []
        self.meetingIDs = try c.decodeIfPresent([UUID].self, forKey: .meetingIDs) ?? []
        self.amendments = try c.decodeIfPresent([StepAmendment].self, forKey: .amendments) ?? []
        self.needsSupervisorInput = try c.decodeIfPresent(Bool.self, forKey: .needsSupervisorInput) ?? false
        self.supervisorQuestion = try c.decodeIfPresent(String.self, forKey: .supervisorQuestion)
        self.supervisorAnswer = try c.decodeIfPresent(String.self, forKey: .supervisorAnswer)
        self.supervisorAnswerAttachmentPaths = try c.decodeIfPresent([String].self, forKey: .supervisorAnswerAttachmentPaths) ?? []
        self.supervisorCommentForNext = try c.decodeIfPresent(String.self, forKey: .supervisorCommentForNext)
        self.tokenUsage = try c.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        self.llmConversation =
            try c.decodeIfPresent([LLMMessage].self, forKey: .llmConversation) ?? []
        self.llmSessionID = try c.decodeIfPresent(String.self, forKey: .llmSessionID)
        self.revisionComment = try c.decodeIfPresent(String.self, forKey: .revisionComment)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(title, forKey: .title)
        try c.encode(expectedArtifacts, forKey: .expectedArtifacts)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(messages, forKey: .messages)
        try c.encode(artifacts, forKey: .artifacts)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(scratchpad, forKey: .scratchpad)
        try c.encode(consultations, forKey: .consultations)
        try c.encode(meetingIDs, forKey: .meetingIDs)
        try c.encode(amendments, forKey: .amendments)
        try c.encode(needsSupervisorInput, forKey: .needsSupervisorInput)
        try c.encodeIfPresent(supervisorQuestion, forKey: .supervisorQuestion)
        try c.encodeIfPresent(supervisorAnswer, forKey: .supervisorAnswer)
        if !supervisorAnswerAttachmentPaths.isEmpty {
            try c.encode(supervisorAnswerAttachmentPaths, forKey: .supervisorAnswerAttachmentPaths)
        }
        try c.encodeIfPresent(supervisorCommentForNext, forKey: .supervisorCommentForNext)
        try c.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try c.encode(llmConversation, forKey: .llmConversation)
        try c.encodeIfPresent(llmSessionID, forKey: .llmSessionID)
        try c.encodeIfPresent(revisionComment, forKey: .revisionComment)
    }

    /// The role ID — same as `id` (kept for backward compatibility at call sites).
    var effectiveRoleID: String { id }

    /// Combines `supervisorAnswer` text with attachment paths (mirrors `NTMSTask.effectiveSupervisorBrief`).
    /// Returns nil only when both answer and attachments are empty.
    var effectiveSupervisorAnswer: String? {
        let hasAnswer = supervisorAnswer.map { !$0.isEmpty } ?? false
        let hasAttachments = !supervisorAnswerAttachmentPaths.isEmpty
        guard hasAnswer || hasAttachments else { return nil }

        var sections: [String] = []
        if let answer = supervisorAnswer, !answer.isEmpty {
            sections.append(answer)
        }
        if hasAttachments {
            let pathList = supervisorAnswerAttachmentPaths.map { "- \($0)" }.joined(separator: "\n")
            sections.append("--- Attached Files ---\n\(pathList)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Whether all non-diagnostic expected artifacts have been created.
    /// Returns `false` if there are no expected artifacts (advisory/observer roles).
    var isArtifactComplete: Bool {
        let expected = expectedArtifacts.filter { $0 != ArtifactConstants.buildDiagnosticsName }
        guard !expected.isEmpty else { return false }
        let existing = Set(artifacts.map(\.name))
        return expected.allSatisfy { existing.contains($0) }
    }

    /// Resets all execution state so the step can be re-run from scratch.
    /// Preserves identity fields (id, role, title, expectedArtifacts, createdAt).
    /// - Parameter supervisorComment: If provided, prepended as a Supervisor message to guide the retry.
    mutating func reset(supervisorComment: String? = nil) {
        status = .pending
        completedAt = nil
        messages = supervisorComment.map {
            [StepMessage(role: .supervisor, content: $0)]
        } ?? []
        artifacts = []
        toolCalls = []
        scratchpad = nil
        consultations = []
        meetingIDs = []
        amendments = []
        needsSupervisorInput = false
        supervisorQuestion = nil
        supervisorAnswer = nil
        supervisorAnswerAttachmentPaths = []
        supervisorCommentForNext = nil
        tokenUsage = nil
        llmConversation = []
        llmSessionID = nil
        revisionComment = nil
        updatedAt = MonotonicClock.shared.now()
    }
}

// MARK: - Factory

extension StepExecution {
    /// Creates a new pending StepExecution from a TeamRoleDefinition.
    /// GRASP Expert: StepExecution is the expert on its own initialization requirements.
    static func make(for roleDef: TeamRoleDefinition) -> StepExecution {
        let role = Role.fromDefinition(roleDef)
        let deps = roleDef.dependencies
        let title = deps.producesArtifacts.isEmpty
            ? "work"
            : deps.producesArtifacts.joined(separator: ", ")
        let now = MonotonicClock.shared.now()
        return StepExecution(
            id: roleDef.id,
            role: role,
            title: title,
            expectedArtifacts: deps.producesArtifacts,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )
    }
}

enum StepStatus: String, Codable, CaseIterable, Hashable {
    case pending
    case running
    case paused
    case needsSupervisorInput
    case needsApproval
    case failed
    case done
}

