import Foundation

// MARK: - Team Decision

/// A decision made during a team meeting
struct TeamDecision: Codable, Identifiable {
    var id: UUID
    var createdAt: Date

    /// Summary of the decision
    var summary: String

    /// Rationale for the decision
    var rationale: String?

    /// Role that proposed the decision
    var proposedBy: Role

    /// Roles that agreed to the decision
    var agreedBy: [Role]

    /// Next steps resulting from this decision
    var nextSteps: [String]

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        summary: String,
        rationale: String? = nil,
        proposedBy: Role,
        agreedBy: [Role] = [],
        nextSteps: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.summary = summary
        self.rationale = rationale
        self.proposedBy = proposedBy
        self.agreedBy = agreedBy
        self.nextSteps = nextSteps
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case summary
        case rationale
        case proposedBy
        case agreedBy
        case nextSteps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.summary = try c.decode(String.self, forKey: .summary)
        self.rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
        self.proposedBy = try c.decode(Role.self, forKey: .proposedBy)
        self.agreedBy = try c.decodeIfPresent([Role].self, forKey: .agreedBy) ?? []
        self.nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
    }
}

// MARK: - Hashable

extension TeamDecision: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeamDecision, rhs: TeamDecision) -> Bool {
        lhs.id == rhs.id
    }
}
