import Foundation

// MARK: - Teammate Consultation

/// Represents a quick consultation between team members (via ask_teammate tool)
nonisolated struct TeammateConsultation: Codable, Identifiable {
    var id: UUID
    var createdAt: Date

    /// Role that asked the question
    var requestingRole: Role

    /// Role that was consulted
    var consultedRole: Role

    /// The question asked
    var question: String

    /// Additional context provided by the requester
    var context: String?

    /// The teammate's response (nil if not yet answered)
    var response: String?

    /// Current status of the consultation
    var status: ConsultationStatus

    /// Time taken to generate response (for analytics)
    var responseTimeMs: Int?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        requestingRole: Role,
        consultedRole: Role,
        question: String,
        context: String? = nil,
        response: String? = nil,
        status: ConsultationStatus = .pending,
        responseTimeMs: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestingRole = requestingRole
        self.consultedRole = consultedRole
        self.question = question
        self.context = context
        self.response = response
        self.status = status
        self.responseTimeMs = responseTimeMs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case requestingRole
        case consultedRole
        case question
        case context
        case response
        case status
        case responseTimeMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.requestingRole = try c.decode(Role.self, forKey: .requestingRole)
        self.consultedRole = try c.decode(Role.self, forKey: .consultedRole)
        self.question = try c.decode(String.self, forKey: .question)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
        self.response = try c.decodeIfPresent(String.self, forKey: .response)
        self.status = try c.decodeIfPresent(ConsultationStatus.self, forKey: .status) ?? .pending
        self.responseTimeMs = try c.decodeIfPresent(Int.self, forKey: .responseTimeMs)
    }
}

// MARK: - Consultation Status

nonisolated enum ConsultationStatus: String, Codable, Hashable {
    /// Waiting for teammate response
    case pending

    /// Teammate has responded
    case completed

    /// Failed to get response (timeout, error, etc.)
    case failed

    /// Consultation was cancelled
    case cancelled

    private static let displayNameMap: [ConsultationStatus: String] = [
        .pending: "Pending",
        .completed: "Completed",
        .failed: "Failed",
        .cancelled: "Cancelled",
    ]

    var displayName: String { Self.displayNameMap[self] ?? rawValue.capitalized }

    private static let iconMap: [ConsultationStatus: String] = [
        .pending: "clock",
        .completed: "checkmark.circle",
        .failed: "xmark.circle",
        .cancelled: "slash.circle",
    ]

    var icon: String { Self.iconMap[self] ?? "questionmark.circle" }
}

// MARK: - Consultation Helpers

nonisolated extension TeammateConsultation {
    /// Mark consultation as completed with response
    mutating func complete(with response: String, responseTimeMs: Int? = nil) {
        self.response = response
        self.status = .completed
        self.responseTimeMs = responseTimeMs
    }

    /// Mark consultation as failed, storing `message` (transport error or
    /// empty-answer sentinel) in `response` so the reason surfaces in the
    /// structured consultations panel (red body) instead of an empty failed card.
    /// The reason is required — a reason-less failure is exactly the "red card with
    /// no diagnostics" state this is meant to avoid.
    mutating func fail(with message: String) {
        self.status = .failed
        self.response = message
    }

    /// Mark consultation as cancelled
    mutating func cancel() {
        self.status = .cancelled
    }

    /// Check if this is a duplicate question to the same teammate
    func isDuplicateOf(_ other: TeammateConsultation) -> Bool {
        return consultedRole == other.consultedRole &&
               question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
               other.question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Hashable

nonisolated extension TeammateConsultation: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeammateConsultation, rhs: TeammateConsultation) -> Bool {
        lhs.id == rhs.id
    }
}
