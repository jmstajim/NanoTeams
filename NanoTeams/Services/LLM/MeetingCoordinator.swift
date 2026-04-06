import Foundation

/// Stateless coordinator for meeting turn orchestration: message building,
/// tool filtering, and excluded tools configuration.
/// All methods are static — no instances needed.
enum MeetingCoordinator {

    /// Tools excluded from meeting turns (collaborative/control tools).
    /// Sourced from `ToolHandler.excludedInMeetings` flags — single source of truth.
    static var meetingExcludedTools: Set<String> {
        ToolHandlerRegistry.meetingExcluded
    }

    /// Filters tool schemas to exclude collaborative tools not allowed in meetings.
    static func filterMeetingTools(_ tools: [ToolSchema]) -> [ToolSchema] {
        let excluded = meetingExcludedTools
        return tools.filter { !excluded.contains($0.name) }
    }

    /// Builds a meeting turn message to inject into a speaker's consultation chat.
    static func buildTurnMessage(
        speaker: Role,
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext
    ) -> String {
        let speakerName = context.team?.findRole(byIdentifier: speaker.baseID)?.name
            ?? speaker.displayName
        var msg = "=== TEAM MEETING ===\nTopic: \(meeting.topic)\n"
        msg += "Initiated by: \(context.initiatedBy.displayName)\n"
        msg += "Participants: \(context.participants.map(\.displayName).joined(separator: ", "))\n"

        if let additionalContext = meeting.context {
            msg += "Context: \(additionalContext)\n"
        }

        if !meeting.messages.isEmpty {
            msg += "\nDiscussion so far:\n"
            for prevMsg in meeting.messages {
                let name = context.team?.findRole(byIdentifier: prevMsg.role.baseID)?.name
                    ?? prevMsg.role.displayName
                msg += "[\(name)]: \(prevMsg.content)\n"
            }
        }

        let turnNumber = meeting.turnCount + 1
        let maxTurns = context.limits.maxMeetingTurns
        let isCoordinator = speaker == context.coordinatorRole

        if context.team?.templateID == "discussionClub" {
            let conciseness: String
            if turnNumber >= maxTurns - 1 {
                conciseness = "1-2 sentences max. Final remarks only."
            } else if turnNumber > maxTurns / 2 {
                conciseness = "2-3 sentences. Be very concise."
            } else {
                conciseness = "3-5 sentences."
            }
            msg += "\nYour turn, \(speakerName). \(conciseness) Build on what was said — don't repeat your earlier points."
        } else if isCoordinator && turnNumber >= maxTurns - 2 {
            msg += "\nWRAP UP NOW. Summarize the key points and state the group's conclusion."
        } else if isCoordinator && turnNumber >= maxTurns / 2 {
            msg += "\nAs coordinator, start steering toward a conclusion."
        } else {
            msg += "\nPlease provide your input as \(speakerName). Be concise and focused on the topic."
        }
        msg += "\n=== END MEETING CONTEXT ==="

        return msg
    }
}
