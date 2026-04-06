import Foundation

// MARK: - Team Message

/// A single message in a team meeting
struct TeamMessage: Codable, Identifiable {
    var id: UUID
    var createdAt: Date

    /// Role that sent the message
    var role: Role

    /// Content of the message
    var content: String

    /// Optional reply to a specific message
    var replyToID: UUID?

    /// Type of message
    var messageType: TeamMessageType

    /// LLM reasoning content (chain-of-thought / thinking)
    var thinking: String?

    /// Tool calls made during this turn
    var toolSummaries: [MeetingToolSummary]?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        role: Role,
        content: String,
        replyToID: UUID? = nil,
        messageType: TeamMessageType = .discussion,
        thinking: String? = nil,
        toolSummaries: [MeetingToolSummary]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.content = content
        self.replyToID = replyToID
        self.messageType = messageType
        self.thinking = thinking
        self.toolSummaries = toolSummaries
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case role
        case content
        case replyToID
        case messageType
        case thinking
        case toolSummaries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.replyToID = try c.decodeIfPresent(UUID.self, forKey: .replyToID)
        self.messageType = try c.decodeIfPresent(TeamMessageType.self, forKey: .messageType) ?? .discussion
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.toolSummaries = try c.decodeIfPresent([MeetingToolSummary].self, forKey: .toolSummaries)
    }
}

// MARK: - Hashable

extension TeamMessage: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeamMessage, rhs: TeamMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Team Message Type

enum TeamMessageType: String, Codable, Hashable {
    case discussion     // Regular discussion message
    case question       // Asking for clarification
    case proposal       // Proposing a solution/approach
    case objection      // Raising a concern
    case agreement      // Agreeing with a proposal
    case summary        // Coordinator summarizing points
    case conclusion     // Final conclusion/wrap-up
}

// MARK: - Message Type Classification

extension TeamMessageType {

    // MARK: Marker Data (OCP — add/remove markers without changing logic)

    private static let summaryMarkers = ["in summary", "to summarize", "summing up"]
    private static let conclusionMarkers = ["we've decided", "final decision", "in conclusion",
                                            "the decision", "we can conclude", "as agreed"]
    private static let agreementMarkers = ["i agree", "sounds good", "let's go with", "i'm on board",
                                           "absolutely", "exactly right", "well said", "couldn't agree more"]
    private static let concessiveMarkers = ["fine, but", "sure, but", "okay, but", "fair enough, but",
                                            "fair point, but", "i appreciate", "i hear you, but"]
    private static let skepticalMarkers = ["i hate to", "let's not forget", "hold on", "not so fast",
                                           "let's be real", "let's check", "pointing out"]
    private static let proposalMarkers = ["suggest", "propose", "we could", "how about", "what if",
                                          "imagine", "picture this", "let's", "i'd recommend",
                                          "the upside", "opportunity", "playbook",
                                          "let me sketch", "draft a plan", "action item"]
    private static let objectionMarkers = ["i'm worried", "risk", "pitfall", "downside", "danger",
                                           "unrealistic", "won't work", "overlooking", "hidden cost",
                                           "not convinced", "fraught", "erode", "minefield",
                                           "concern", "suffer", "issue with"]

    // MARK: Classification

    private static func score(_ markers: [String], in text: String) -> Int {
        markers.count { text.contains($0) }
    }

    /// Classifies meeting message content into a message type using pattern matching.
    static func determine(from content: String) -> TeamMessageType {
        let full = content.lowercased()
        let opening = String(full.prefix(500))

        // Conclusion / summary — check first, these are usually explicit.
        if score(summaryMarkers, in: full) > 0 || (full.contains("overall") && full.contains("takeaway")) {
            return .summary
        }
        if score(conclusionMarkers, in: opening) > 0 { return .conclusion }

        // Agreement — strong positive markers in the opening.
        let agreementHits = score(agreementMarkers, in: opening)
        if agreementHits >= 2 { return .agreement }

        // Concessive/skeptical objection — opening concedes then pushes back.
        if score(concessiveMarkers, in: opening) > 0 || score(skepticalMarkers, in: opening) > 0 {
            return .objection
        }

        // Score-based classification for proposal vs objection.
        let propScore = score(proposalMarkers, in: full)
        let objScore = score(objectionMarkers, in: full)

        if agreementHits >= 1 && objScore == 0 { return .agreement }
        if propScore > 0 && propScore >= objScore { return .proposal }
        if objScore > 0 { return .objection }

        // Question — if opening contains question marks and nothing else matched.
        if opening.contains("?") { return .question }

        return .discussion
    }
}
