import Foundation

// MARK: - Team Meeting

/// Represents a formal team meeting initiated via request_team_meeting tool
struct TeamMeeting: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date

    /// Topic/agenda of the meeting
    var topic: String

    /// Role that initiated the meeting
    var initiatedBy: Role

    /// Roles participating in the meeting
    var participants: [Role]

    /// Optional context provided when requesting the meeting
    var context: String?

    /// Messages exchanged during the meeting
    var messages: [TeamMessage]

    /// Decisions made during the meeting
    var decisions: [TeamDecision]

    /// Current status of the meeting
    var status: MeetingStatus

    /// Number of turns (messages) in this meeting
    var turnCount: Int {
        messages.count
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        topic: String,
        initiatedBy: Role,
        participants: [Role],
        context: String? = nil,
        messages: [TeamMessage] = [],
        decisions: [TeamDecision] = [],
        status: MeetingStatus = .pending
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.topic = topic
        self.initiatedBy = initiatedBy
        self.participants = participants
        self.context = context
        self.messages = messages
        self.decisions = decisions
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case topic
        case initiatedBy
        case participants
        case context
        case messages
        case decisions
        case status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.topic = try c.decode(String.self, forKey: .topic)
        self.initiatedBy = try c.decode(Role.self, forKey: .initiatedBy)
        self.participants = try c.decode([Role].self, forKey: .participants)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
        self.messages = try c.decodeIfPresent([TeamMessage].self, forKey: .messages) ?? []
        self.decisions = try c.decodeIfPresent([TeamDecision].self, forKey: .decisions) ?? []
        self.status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .pending
    }
}

// MARK: - Meeting Status

enum MeetingStatus: String, Codable, Hashable {
    /// Meeting requested but not yet started
    case pending

    /// Meeting is currently in progress
    case inProgress

    /// Meeting completed successfully
    case completed

    /// Meeting escalated to Supervisor
    case escalatedToSupervisor

    /// Meeting was cancelled
    case cancelled

    private static let metadata: [MeetingStatus: (displayName: String, icon: String)] = [
        .pending:                ("Pending",                  "clock"),
        .inProgress:             ("In Progress",              "person.3.fill"),
        .completed:              ("Completed",                "checkmark.circle"),
        .escalatedToSupervisor:  ("Escalated to Supervisor",  "exclamationmark.triangle"),
        .cancelled:              ("Cancelled",                "xmark.circle"),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var icon: String { Self.metadata[self]?.icon ?? "questionmark.circle" }

    var isActive: Bool {
        self == .pending || self == .inProgress
    }
}

// MARK: - Meeting Helpers

extension TeamMeeting {
    /// Add a message to the meeting
    mutating func addMessage(_ message: TeamMessage) {
        messages.append(message)
        updatedAt = MonotonicClock.shared.now()
    }

    /// Add a decision to the meeting
    mutating func addDecision(_ decision: TeamDecision) {
        decisions.append(decision)
        updatedAt = MonotonicClock.shared.now()
    }

    /// Start the meeting
    mutating func start() {
        status = .inProgress
        updatedAt = MonotonicClock.shared.now()
    }

    /// Complete the meeting
    mutating func complete() {
        status = .completed
        updatedAt = MonotonicClock.shared.now()
    }

    /// Escalate to Supervisor
    mutating func escalateToSupervisor() {
        status = .escalatedToSupervisor
        updatedAt = MonotonicClock.shared.now()
    }

    /// Cancel the meeting
    mutating func cancel() {
        status = .cancelled
        updatedAt = MonotonicClock.shared.now()
    }

    /// Get messages from a specific role
    func messages(from role: Role) -> [TeamMessage] {
        messages.filter { $0.role == role }
    }

    /// Check if a role has participated
    func hasParticipated(_ role: Role) -> Bool {
        messages.contains { $0.role == role }
    }
}

// MARK: - Hashable

extension TeamMeeting: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeamMeeting, rhs: TeamMeeting) -> Bool {
        lhs.id == rhs.id
    }
}
