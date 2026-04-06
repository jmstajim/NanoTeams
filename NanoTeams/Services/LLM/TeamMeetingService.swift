import Foundation

/// Service for managing team meeting lifecycle.
/// Handles meeting creation, turn completion, conclusion, and summary generation.
/// Streaming and message construction are in MeetingStreamingService.
struct TeamMeetingService {

    /// Context required for a team meeting
    struct MeetingContext {
        let topic: String
        let initiatedBy: Role
        let participants: [Role]
        let additionalContext: String?
        let task: NTMSTask
        let availableArtifacts: [Artifact]
        let artifactReader: (Artifact) -> String?
        let team: Team?
        let coordinatorRole: Role
        let limits: TeamLimits
    }

    /// Result of a single LLM streaming call within a meeting turn.
    struct MeetingStreamResult {
        var content: String
        var thinking: String
        var resolvedToolCalls: [StepToolCall]
        var session: LLMSession? = nil
    }

    /// Extended result from a meeting turn (before tool execution).
    struct MeetingTurnResult {
        var meeting: TeamMeeting
        var shouldContinue: Bool
        var speaker: Role
        var streamResult: MeetingStreamResult
    }

    // MARK: - Meeting Lifecycle

    /// Create a new team meeting
    static func createMeeting(
        topic: String,
        initiatedBy: Role,
        participants: [Role],
        context: String?
    ) -> TeamMeeting {
        TeamMeeting(
            topic: topic,
            initiatedBy: initiatedBy,
            participants: participants,
            context: context,
            status: .pending
        )
    }

    /// Check if meeting limit has been reached for this run
    static func hasReachedMeetingLimit(
        meetings: [TeamMeeting],
        limits: TeamLimits
    ) -> Bool {
        meetings.count >= limits.maxMeetingsPerRun
    }

    /// Check if meeting turn limit has been reached
    static func hasReachedTurnLimit(
        meeting: TeamMeeting,
        limits: TeamLimits
    ) -> Bool {
        meeting.turnCount >= limits.maxMeetingTurns
    }

    /// Complete a turn by adding the final message and checking for conclusion.
    static func completeTurn(
        meeting: inout TeamMeeting,
        speaker: Role,
        content: String,
        thinking: String?,
        toolSummaries: [MeetingToolSummary]?,
        context: MeetingContext
    ) -> Bool {
        let cleanedContent = ModelTokenCleaner.clean(content)
        let message = TeamMessage(
            role: speaker,
            content: cleanedContent,
            messageType: TeamMessageType.determine(from: cleanedContent),
            thinking: thinking,
            toolSummaries: toolSummaries
        )
        meeting.addMessage(message)

        return !shouldConcludeMeeting(meeting: meeting, context: context)
    }

    /// Conclude a meeting with a decision
    static func concludeMeeting(
        meeting: inout TeamMeeting,
        decision: String,
        rationale: String?,
        nextSteps: String?,
        concludedBy: Role
    ) {
        let teamDecision = TeamDecision(
            summary: decision,
            rationale: rationale,
            proposedBy: concludedBy,
            agreedBy: meeting.participants,
            nextSteps: nextSteps?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        )

        meeting.addDecision(teamDecision)
        meeting.complete()
    }

    // MARK: - Private Helpers

    private static func shouldConcludeMeeting(
        meeting: TeamMeeting,
        context: MeetingContext
    ) -> Bool {
        if hasReachedTurnLimit(meeting: meeting, limits: context.limits) {
            return true
        }

        let allParticipated = context.participants.allSatisfy { participant in
            meeting.hasParticipated(participant)
        }

        if allParticipated {
            let recentMessages = meeting.messages.suffix(3)
            let hasAgreement = recentMessages.contains { $0.messageType == .agreement }
            let hasConclusion = recentMessages.contains { $0.messageType == .conclusion }

            if hasAgreement || hasConclusion {
                return true
            }
        }

        return false
    }
}

// MARK: - Meeting Summary Generation

extension TeamMeetingService {

    /// Generate a summary of a completed meeting
    static func generateMeetingSummary(meeting: TeamMeeting) -> String {
        var summary = "Meeting Summary: \(meeting.topic)\n"
        summary += "Status: \(meeting.status.displayName)\n"
        summary += "Participants: \(meeting.participants.map { $0.displayName }.joined(separator: ", "))\n"
        summary += "Messages: \(meeting.messages.count)\n"

        if !meeting.decisions.isEmpty {
            summary += "\nDecisions:\n"
            for decision in meeting.decisions {
                summary += "- \(decision.summary)\n"
                if let rationale = decision.rationale {
                    summary += "  Rationale: \(rationale)\n"
                }
                if !decision.nextSteps.isEmpty {
                    summary += "  Next steps:\n"
                    for step in decision.nextSteps {
                        summary += "    - \(step)\n"
                    }
                }
            }
        }

        return summary
    }

    /// Generate a concise meeting result for injection into conversation
    static func generateMeetingResultForConversation(meeting: TeamMeeting) -> String {
        var result = "Team Meeting Result - \(meeting.topic)\n"
        result += "Participants: \(meeting.participants.map { $0.displayName }.joined(separator: ", "))\n"

        if let lastDecision = meeting.decisions.last {
            result += "\nDecision: \(lastDecision.summary)\n"
            if let rationale = lastDecision.rationale {
                result += "Rationale: \(rationale)\n"
            }
            if !lastDecision.nextSteps.isEmpty {
                result += "Next steps: \(lastDecision.nextSteps.joined(separator: "; "))\n"
            }
        } else {
            let keyMessages = meeting.messages.filter {
                $0.messageType == .proposal || $0.messageType == .agreement || $0.messageType == .conclusion
            }
            if !keyMessages.isEmpty {
                result += "\nKey points discussed:\n"
                for msg in keyMessages.prefix(3) {
                    result += "- [\(msg.role.displayName)]: \(msg.content.prefix(200))...\n"
                }
            }
        }

        return result
    }
}
