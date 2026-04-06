import Foundation

struct TeamLimits: Codable, Hashable {
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
