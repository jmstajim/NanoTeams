import Foundation

nonisolated struct StepExecution: Codable, Identifiable, Hashable {
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

    /// Bundled delegation state for this step. Three previously-flat fields
    /// (`delegationSession`, `activeDelegationChildID`, `delegationChildIDs`)
    /// were aggregated here so the cross-field invariant
    /// (`activeChildID == nil ∨ activeChildID ∈ history`) can be enforced
    /// structurally instead of by convention. Mutate via `setActiveDelegation` /
    /// `clearActiveDelegation` / `setDelegationSession` rather than touching
    /// the inner struct directly. The legacy field names are still available
    /// as read-only computed properties below for back-compat with the many
    /// existing read sites.
    private(set) var delegation: DelegationState

    /// Bundled ancillary-query state for the bottom-of-chain escalation flow.
    /// Only the `question` side is set live (via `setAncillaryQuestion`) when a
    /// delegation chain escalates a question that needs Supervisor input — it's
    /// recorded for diagnostics while the delegation aborts. The `answer` field
    /// persists only for backward-compatible Codable decode of legacy
    /// `ancillaryAnswer` keys; nothing writes it at runtime.
    private(set) var ancillary: AncillaryQuery

    // MARK: - Back-compat read accessors (computed, all delegate to bundles)

    /// Stateful chain ID for the side exchange between this role (acting as
    /// Supervisor of a delegated team) and the child team's roles. Seeded
    /// with the role's `llmConversation` on the first child question, then
    /// reused via `previous_response_id` for subsequent questions. Cleared
    /// when `delegate_to_team` completes. Isolated from `llmSessionID` so
    /// the parent's main response chain is not perturbed.
    /// Read via `delegation.session`; back-compat alias for the many
    /// existing read sites.
    var delegationSession: String? { delegation.session }

    /// Question that bubbled up from a delegated child team's `ask_supervisor`
    /// when the escalation chain bottomed out at the human Supervisor.
    var ancillaryQuestion: String? { ancillary.question }

    /// Human's answer to `ancillaryQuestion`. Legacy Codable field — no live
    /// writer; retained so old `task.json` with this key still round-trips.
    var ancillaryAnswer: String? { ancillary.answer }

    /// Child task ID of the in-flight `delegate_to_team` call from this
    /// step. Set when the handler creates the child task; cleared on any
    /// terminal outcome (success / failure / timeout / Supervisor cancel).
    /// Used by `pauseRun`/`resumeRun` to identify mid-delegation steps so
    /// they can be paused without cancelling the awaiting handler.
    var activeDelegationChildID: Int? { delegation.activeChildID }

    /// Append-only history of every child task this step has delegated to,
    /// in chronological order. Includes the in-flight delegation (if any)
    /// and every completed/failed/timed-out one. Preserved on terminal
    /// cleanup (only `activeChildID` and `session` are cleared).
    var delegationChildIDs: [Int] { delegation.history }

    // MARK: - Invariant-enforcing mutators (delegation)

    /// Begins a new active delegation. Appends the child id to history if
    /// not already present, ensuring the invariant `activeChildID ∈ history`.
    /// Idempotent on the same id.
    mutating func setActiveDelegation(childID: Int) {
        delegation.beginActive(childID: childID)
    }

    /// Marks the current delegation terminal: clears `activeChildID` and
    /// `session` while preserving the chronological `history`. Use this on
    /// every terminal exit path so the step is ready for a fresh delegation.
    mutating func clearActiveDelegation() {
        delegation.clearActive()
    }

    /// Sets the seeded-chain `previous_response_id` for the active
    /// delegation. Pass `nil` to drop a poisoned chain (e.g. after HTTP 400)
    /// — independent of `clearActiveDelegation` because we may want a
    /// fresh seed without ending the delegation itself.
    mutating func setDelegationSession(_ id: String?) {
        delegation.session = id
    }

    // MARK: - Invariant-enforcing mutators (ancillary)

    mutating func setAncillaryQuestion(_ q: String?) { ancillary.question = q }

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
        revisionComment: String? = nil,
        delegationSession: String? = nil,
        ancillaryQuestion: String? = nil,
        ancillaryAnswer: String? = nil,
        activeDelegationChildID: Int? = nil,
        delegationChildIDs: [Int] = []
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
        // Aggregate the five legacy delegation/ancillary parameters into the
        // two structs. The DelegationState init enforces
        // `activeChildID ∈ history`, so callers passing an active id without
        // mentioning it in `delegationChildIDs` get the id appended for free.
        self.delegation = DelegationState(
            session: delegationSession,
            activeChildID: activeDelegationChildID,
            history: delegationChildIDs
        )
        self.ancillary = AncillaryQuery(
            question: ancillaryQuestion,
            answer: ancillaryAnswer
        )
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
        // New aggregated shape (preferred on encode + decode).
        case delegation
        case ancillary
        // Legacy flat keys (decode-only fallback for files written by
        // builds prior to the I7 refactor; never re-emitted on encode).
        case delegationSession
        case ancillaryQuestion
        case ancillaryAnswer
        case activeDelegationChildID
        case delegationChildIDs
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
        // Delegation/ancillary: prefer the new nested shape, fall back to
        // the five legacy flat keys for files written by earlier builds.
        // Both decodes use `decodeIfPresent` so missing keys default to
        // empty/nil — `DelegationState.init(...)` enforces the
        // `activeChildID ∈ history` invariant in either branch.
        if let bundled = try c.decodeIfPresent(DelegationState.self, forKey: .delegation) {
            self.delegation = bundled
        } else {
            let legacySession = try c.decodeIfPresent(String.self, forKey: .delegationSession)
            let legacyActive = try c.decodeIfPresent(Int.self, forKey: .activeDelegationChildID)
            let legacyHistory = try c.decodeIfPresent([Int].self, forKey: .delegationChildIDs) ?? []
            self.delegation = DelegationState(
                session: legacySession,
                activeChildID: legacyActive,
                history: legacyHistory
            )
        }
        if let bundled = try c.decodeIfPresent(AncillaryQuery.self, forKey: .ancillary) {
            self.ancillary = bundled
        } else {
            self.ancillary = AncillaryQuery(
                question: try c.decodeIfPresent(String.self, forKey: .ancillaryQuestion),
                answer: try c.decodeIfPresent(String.self, forKey: .ancillaryAnswer)
            )
        }
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
        // Encode the new bundled shape only when non-empty (preserves the
        // pre-fix policy of omitting empty delegation/ancillary state from
        // the JSON for non-delegating roles — keeps `task.json` small).
        if !delegation.isEmpty {
            try c.encode(delegation, forKey: .delegation)
        }
        if !ancillary.isEmpty {
            try c.encode(ancillary, forKey: .ancillary)
        }
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
            sections.append("## Attached Files\n\(pathList)")
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
        // `reset` clears delegation history too — this is a full re-run, not a
        // continuation, so the audit trail starts fresh.
        delegation = DelegationState()
        ancillary = AncillaryQuery()
        updatedAt = MonotonicClock.shared.now()
    }
}

// MARK: - Factory

nonisolated extension StepExecution {
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

nonisolated enum StepStatus: String, Codable, CaseIterable, Hashable {
    case pending
    case running
    case paused
    case needsSupervisorInput
    case needsApproval
    case failed
    case done
}

// MARK: - DelegationState

/// Aggregated state for the delegation cluster on `StepExecution`. Replaces
/// three previously-flat fields (`delegationSession`, `activeDelegationChildID`,
/// `delegationChildIDs`) so the cross-field invariant — "if `activeChildID`
/// is set, it must appear in `history`" — can be enforced structurally.
///
/// Mutations go through `beginActive(childID:)` / `clearActive()`; the
/// inner `history` array is `private(set)` to prevent
/// `step.delegation.history.append(...)` from drifting from the active marker.
///
/// Encoded JSON shape:
///   `{"session": "resp_…"?, "activeChildID": 42?, "history": [42, 17]?}`
/// (omitted entirely from `step.json` when `isEmpty`).
nonisolated struct DelegationState: Codable, Hashable {
    /// Stateful chain id (`previous_response_id`) for the seeded side
    /// exchange between the parent role and the child team's `ask_supervisor`
    /// flow. Survives across calls within one delegation; cleared on
    /// terminal cleanup or by passing `nil` to `setDelegationSession` on
    /// the owning step (e.g. HTTP 400 chain invalidation).
    var session: String?
    /// In-flight delegation marker — `nil` when no delegation is currently
    /// blocking the parent step's tool loop.
    private(set) var activeChildID: Int?
    /// Append-only chronological log of every child task this step has
    /// delegated to — including completed/failed/timed-out ones. Preserved
    /// across terminal cleanup (only `activeChildID` and `session` clear).
    private(set) var history: [Int]

    /// Designated init. Enforces the `activeChildID ∈ history` invariant by
    /// auto-appending `activeChildID` to `history` when the caller forgot
    /// (matches the legacy "set + append" double-write pattern at write
    /// sites). Idempotent on duplicates.
    init(session: String? = nil, activeChildID: Int? = nil, history: [Int] = []) {
        self.session = session
        self.activeChildID = activeChildID
        var h = history
        if let id = activeChildID, !h.contains(id) {
            h.append(id)
        }
        self.history = h
    }

    /// `true` iff every field is at its default — used by Codable to omit
    /// the bundle from JSON for non-delegating roles.
    var isEmpty: Bool {
        session == nil && activeChildID == nil && history.isEmpty
    }

    /// Begins (or re-begins) an active delegation. Appends to history if
    /// new; idempotent on the same id. Use this in place of two separate
    /// writes (`activeDelegationChildID = N` then `delegationChildIDs.append(N)`)
    /// — the invariant is now structural, not by-convention.
    mutating func beginActive(childID: Int) {
        activeChildID = childID
        if !history.contains(childID) {
            history.append(childID)
        }
    }

    /// Marks the delegation terminal: clears `activeChildID` + `session`,
    /// preserves `history` for audit / graph history layers.
    mutating func clearActive() {
        activeChildID = nil
        session = nil
    }
}

// MARK: - AncillaryQuery

/// Bundles the two previously-flat fields (`ancillaryQuestion`,
/// `ancillaryAnswer`) on `StepExecution` for atomic Codable round-trips.
///
/// **This type is a grouping convenience, NOT an invariant-bearing
/// aggregation.** Both fields are plain `var`. The live flow only sets the
/// `question` side (via `setAncillaryQuestion`) when a delegation chain
/// escalates a question that requires Supervisor input — the question is
/// recorded on the step for diagnostics while the delegation aborts. The
/// `answer` field is retained solely for backward-compatible Codable decode
/// of legacy `ancillaryAnswer` keys.
nonisolated struct AncillaryQuery: Codable, Hashable {
    var question: String?
    var answer: String?

    init(question: String? = nil, answer: String? = nil) {
        self.question = question
        self.answer = answer
    }

    /// `true` iff both fields are nil — used by Codable to omit the bundle
    /// from JSON for steps that never bottomed out.
    var isEmpty: Bool {
        question == nil && answer == nil
    }
}

