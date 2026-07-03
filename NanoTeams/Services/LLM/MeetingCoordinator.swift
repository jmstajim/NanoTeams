import Foundation

/// Stateless coordinator for meeting turn orchestration: message building,
/// tool filtering, and excluded tools configuration.
/// All methods are static — no instances needed.
enum MeetingCoordinator {

    /// Tools excluded from meeting turns (collaborative/control tools).
    /// Sourced from `ToolHandler.excludedInMeetings` flags — single source of truth.
    /// `nonisolated`: pure data.
    nonisolated static var meetingExcludedTools: Set<String> {
        ToolHandlerRegistry.meetingExcluded
    }

    /// Filters tool schemas to exclude collaborative tools not allowed in meetings.
    /// `nonisolated`: pure filter, no MainActor state touched.
    nonisolated static func filterMeetingTools(_ tools: [ToolSchema]) -> [ToolSchema] {
        let excluded = meetingExcludedTools
        return tools.filter { !excluded.contains($0.name) }
    }

    /// Builds a meeting turn message to inject into a speaker's consultation chat.
    static func buildTurnMessage(
        speaker: Role,
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext
    ) -> String {
        // Every name in the turn resolves through the team (custom teams rename
        // roles) — a mixed displayName/team-name rendering shows the same role
        // under two names in one prompt.
        func name(_ role: Role) -> String {
            context.team?.findRole(byIdentifier: role.baseID)?.name ?? role.displayName
        }
        let speakerName = name(speaker)
        var msg = "## Team meeting\nTopic: \(meeting.topic)\n"
        msg += "Initiated by: \(name(context.initiatedBy))\n"
        msg += "Participants: \(context.participants.map(name).joined(separator: ", "))\n"

        if let additionalContext = meeting.context {
            msg += "Context: \(additionalContext)\n"
        }

        if !meeting.messages.isEmpty {
            msg += "\nDiscussion so far:\n"
            for prevMsg in meeting.messages {
                msg += "[\(name(prevMsg.role))]: \(prevMsg.content)\n"
            }
        }

        msg += "\n" + Self.turnDirective(
            speakerName: speakerName,
            turnNumber: meeting.turnCount + 1,
            maxTurns: context.limits.maxMeetingTurns,
            isCoordinator: speaker == context.coordinatorRole,
            isDiscussionClub: context.team?.templateID == "discussionClub"
        )

        return msg
    }

    /// Single source of truth for the per-turn directive (conciseness ladder,
    /// coordinator steering/wrap-up). Shared by `buildTurnMessage` (live path)
    /// and `MeetingStreamingService.buildMeetingMessages` so the two renderings
    /// of the same turn cannot drift apart.
    nonisolated static func turnDirective(
        speakerName: String,
        turnNumber: Int,
        maxTurns: Int,
        isCoordinator: Bool,
        isDiscussionClub: Bool
    ) -> String {
        if isDiscussionClub {
            let conciseness: String
            if turnNumber >= maxTurns - 1 {
                conciseness = "1-2 sentences max. Final remarks only."
            } else if turnNumber > maxTurns / 2 {
                conciseness = "2-3 sentences. Be very concise."
            } else {
                conciseness = "3-5 sentences."
            }
            return "Your turn, \(speakerName). \(conciseness) Build on what was said — don't repeat your earlier points."
        }
        if isCoordinator && turnNumber >= maxTurns - 2 {
            return "Final turns: summarize the key points and state the group's conclusion."
        }
        if isCoordinator && turnNumber >= maxTurns / 2 {
            return "As coordinator, start steering toward a conclusion."
        }
        return "Provide your input as \(speakerName). Be concise and focused on the topic."
    }
}
