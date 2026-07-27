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
    /// Every name in a meeting prompt resolves through the team (custom teams rename roles) — a
    /// mixed displayName/team-name rendering shows the same role under two names in one prompt.
    static func displayName(
        of role: Role, context: TeamMeetingService.MeetingContext
    ) -> String {
        context.team?.findRole(byIdentifier: role.baseID)?.name ?? role.displayName
    }

    /// The meeting's fixed preamble: topic, initiator, participants, extra context.
    ///
    /// Split out of the old single consolidated turn message because it never changes across the
    /// meeting, and the wire is only as cacheable as its most volatile leading byte. Together with
    /// one message per transcript line (below) and the directive last, a meeting turn becomes an
    /// APPEND onto the previous turn's request instead of a full re-consolidation — so the server
    /// re-prefills the newest contribution rather than the entire discussion.
    static func buildMeetingHeader(
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext
    ) -> String {
        var msg = "## Team meeting\nTopic: \(meeting.topic)\n"
        msg += "Initiated by: \(displayName(of: context.initiatedBy, context: context))\n"
        let names = context.participants.map { displayName(of: $0, context: context) }
        msg += "Participants: \(names.joined(separator: ", "))\n"
        if let additionalContext = meeting.context {
            msg += "Context: \(additionalContext)\n"
        }
        return msg
    }

    /// One already-spoken turn, rendered as its own message so the transcript grows by appending.
    static func buildTranscriptLine(
        _ message: TeamMessage,
        context: TeamMeetingService.MeetingContext
    ) -> String {
        "[\(displayName(of: message.role, context: context))]: \(message.content)"
    }

    /// The directive for the speaker whose turn it is. Rides LAST, in the recency slot, and is the
    /// only volatile element — which is why everything cacheable sits ahead of it.
    static func buildTurnDirective(
        speaker: Role,
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext
    ) -> String {
        Self.turnDirective(
            speakerName: displayName(of: speaker, context: context),
            turnNumber: meeting.turnCount + 1,
            maxTurns: context.limits.maxMeetingTurns,
            isCoordinator: speaker == context.coordinatorRole,
            isDiscussionClub: context.team?.templateID == "discussionClub"
        )
    }

    /// Single source of truth for the per-turn directive (conciseness ladder,
    /// coordinator steering/wrap-up). Shared by `buildTurnMessage` (live path)
    /// and `MeetingStreamingService.buildMeetingMessages` so the two renderings
    /// of the same turn cannot drift apart.
    /// Carries EVERY turn-dependent instruction, including the turn counter and the coordinator's
    /// steering hint that used to sit in the speaker's system prompt.
    ///
    /// They moved here because a turn counter in the system prompt changes segment 0 on every
    /// turn, and segment 0 is where the tool catalog lives — so the server re-prefilled the entire
    /// meeting each time, growing worse as the discussion went on. Exactly the reason `{stepInfo}`
    /// was retired from the step templates. Nothing is lost: this string rides last, in the
    /// recency slot, which is the better place for an instruction anyway [Liu2024].
    nonisolated static func turnDirective(
        speakerName: String,
        turnNumber: Int,
        maxTurns: Int,
        isCoordinator: Bool,
        isDiscussionClub: Bool
    ) -> String {
        let counter = "Turn \(turnNumber) of \(maxTurns)."
        if isDiscussionClub {
            let conciseness: String
            if turnNumber >= maxTurns - 1 {
                conciseness = "1-2 sentences max. Final remarks only."
            } else if turnNumber > maxTurns / 2 {
                conciseness = "2-3 sentences. Be very concise."
            } else {
                conciseness = "3-5 sentences."
            }
            return "\(counter) Your turn, \(speakerName). \(conciseness) "
                + "Build on what was said — don't repeat your earlier points."
        }
        if isCoordinator && turnNumber >= maxTurns - 2 {
            return "\(counter) Final turns: summarize the key points and state the group's conclusion."
        }
        if isCoordinator && turnNumber >= maxTurns / 2 {
            return "\(counter) As coordinator, start steering toward a conclusion. "
                + "Summarize agreements and remaining disagreements."
        }
        if isCoordinator {
            return "\(counter) As the coordinator, help guide the discussion toward a decision. "
                + "Provide your input as \(speakerName)."
        }
        return "\(counter) Provide your input as \(speakerName). "
            + "Be concise and focused on the topic."
    }
}
