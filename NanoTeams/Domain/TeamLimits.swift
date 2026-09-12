import Foundation

nonisolated struct TeamLimits: Codable, Hashable {
    /// Maximum consultations per step
    var maxConsultationsPerStep: Int

    /// Maximum meetings per run
    var maxMeetingsPerRun: Int

    /// Maximum turns/messages in a single meeting
    var maxMeetingTurns: Int

    /// Maximum questions to the same teammate
    var maxSameTeammateAsks: Int

    /// Maximum iterations for autonomous team engine loop
    var autoIterationLimit: Int

    /// Maximum tool call iterations per meeting turn
    var maxMeetingToolIterationsPerTurn: Int

    /// Maximum change requests per run
    var maxChangeRequestsPerRun: Int

    /// Maximum amendments per step (prevents infinite revision loops)
    var maxAmendmentsPerStep: Int

    static let `default` = TeamLimits(
        maxConsultationsPerStep: 5,
        maxMeetingsPerRun: 3,
        maxMeetingTurns: 10,
        maxSameTeammateAsks: 2,
        autoIterationLimit: 10000,
        maxMeetingToolIterationsPerTurn: 3,
        maxChangeRequestsPerRun: 3,
        maxAmendmentsPerStep: 2
    )

    /// Ultra Team's own preset. The `.default` 3 / 3 / 2 was exactly the pipeline's planned
    /// spend — one firing per checker — so every checker could fire ONCE with no right to a
    /// second shot: a build still red after the first repair met "Change request limit
    /// reached" and the run ended red with its repair channel spent. The requirement the
    /// whole team exists for would have failed on a constant rather than on the model.
    ///
    /// Derived, not chosen: each checker must be able to fire twice (found → repaired →
    /// rechecked → found again). Two checkers hold `request_changes` — the Diff Reviewer and
    /// the Change Verifier, both targeting the engineer — so four votes, and four amendments
    /// on the engineer's step. It was three checkers and six votes until 2026-09-12, when the
    /// Feasibility Critic retired with the team's Swift binding; the budget came down with it
    /// rather than being left as slack, because an unspent allowance is indistinguishable from
    /// a chosen one the next time somebody reads this. `maxMeetingsPerRun` matches
    /// `maxChangeRequestsPerRun` because every vote persists as a meeting and is counted by
    /// `hasReachedMeetingLimit` — one budget wearing two names, which holds only while no
    /// Ultra role carries `request_team_meeting`
    /// (`testUltraMeetingBudgetIsReservedForChangeRequestVotes`).
    ///
    /// Still counted and still finite, as REC.7 requires; what changed is that it stops
    /// biting on the first honest second round.
    static let ultra = TeamLimits(
        maxConsultationsPerStep: 5,
        maxMeetingsPerRun: 4,
        maxMeetingTurns: 10,
        maxSameTeammateAsks: 2,
        autoIterationLimit: 10000,
        maxMeetingToolIterationsPerTurn: 3,
        maxChangeRequestsPerRun: 4,
        maxAmendmentsPerStep: 4
    )

    static let discussionClub = TeamLimits(
        maxConsultationsPerStep: 10,
        maxMeetingsPerRun: 10,
        maxMeetingTurns: 10,
        maxSameTeammateAsks: 4,
        autoIterationLimit: 10000,
        maxMeetingToolIterationsPerTurn: 3,
        maxChangeRequestsPerRun: 0,
        maxAmendmentsPerStep: 0
    )

    init(
        maxConsultationsPerStep: Int = 5,
        maxMeetingsPerRun: Int = 3,
        maxMeetingTurns: Int = 10,
        maxSameTeammateAsks: Int = 2,
        autoIterationLimit: Int = 10000,
        maxMeetingToolIterationsPerTurn: Int = 3,
        maxChangeRequestsPerRun: Int = 3,
        maxAmendmentsPerStep: Int = 2
    ) {
        self.maxConsultationsPerStep = maxConsultationsPerStep
        self.maxMeetingsPerRun = maxMeetingsPerRun
        self.maxMeetingTurns = maxMeetingTurns
        self.maxSameTeammateAsks = maxSameTeammateAsks
        self.autoIterationLimit = autoIterationLimit
        self.maxMeetingToolIterationsPerTurn = maxMeetingToolIterationsPerTurn
        self.maxChangeRequestsPerRun = maxChangeRequestsPerRun
        self.maxAmendmentsPerStep = maxAmendmentsPerStep
    }

    enum CodingKeys: String, CodingKey {
        case maxConsultationsPerStep
        case maxMeetingsPerRun
        case maxMeetingTurns
        case maxSameTeammateAsks
        case autoIterationLimit
        case maxMeetingToolIterationsPerTurn
        case maxChangeRequestsPerRun
        case maxAmendmentsPerStep
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.maxConsultationsPerStep =
            try c.decodeIfPresent(Int.self, forKey: .maxConsultationsPerStep) ?? 5
        self.maxMeetingsPerRun = try c.decodeIfPresent(Int.self, forKey: .maxMeetingsPerRun) ?? 3
        self.maxMeetingTurns = try c.decodeIfPresent(Int.self, forKey: .maxMeetingTurns) ?? 10
        self.maxSameTeammateAsks =
            try c.decodeIfPresent(Int.self, forKey: .maxSameTeammateAsks) ?? 2
        self.autoIterationLimit =
            try c.decodeIfPresent(Int.self, forKey: .autoIterationLimit) ?? 10000
        self.maxMeetingToolIterationsPerTurn =
            try c.decodeIfPresent(Int.self, forKey: .maxMeetingToolIterationsPerTurn) ?? 3
        self.maxChangeRequestsPerRun =
            try c.decodeIfPresent(Int.self, forKey: .maxChangeRequestsPerRun) ?? 3
        self.maxAmendmentsPerStep =
            try c.decodeIfPresent(Int.self, forKey: .maxAmendmentsPerStep) ?? 2
    }
}
