import Foundation

/// Handles LLM streaming, message construction, and turn orchestration for team meetings.
/// Extracted from TeamMeetingService for SRP: streaming/LLM interaction vs meeting lifecycle.
enum MeetingStreamingService {

    // MARK: - Streaming

    /// Stream a single LLM call for a meeting turn. Captures content, thinking, and tool call deltas.
    static func streamParticipantResponse(
        messages: [ChatMessage],
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        session: LLMSession? = nil,
        logger: NetworkLogger? = nil,
        stepID: String? = nil
    ) async throws -> TeamMeetingService.MeetingStreamResult {
        var fullContent = ""
        var thinkingCollected = ""
        var toolAccumulator = ToolCallAccumulator()
        var capturedSession: LLMSession?

        let stream = client.streamChat(
            config: config,
            messages: messages,
            tools: tools.isEmpty ? [] : tools,
            session: session,
            logger: logger,
            stepID: stepID
        )

        for try await event in stream {
            fullContent += event.contentDelta
            thinkingCollected += event.thinkingDelta
            if !event.toolCallDeltas.isEmpty {
                toolAccumulator.absorb(event.toolCallDeltas)
            }
            if let s = event.session { capturedSession = s }
        }

        let resolvedToolCalls = toolAccumulator.finalize()

        return TeamMeetingService.MeetingStreamResult(
            content: fullContent.trimmingCharacters(in: .whitespacesAndNewlines),
            thinking: thinkingCollected.trimmingCharacters(in: .whitespacesAndNewlines),
            resolvedToolCalls: resolvedToolCalls,
            session: capturedSession
        )
    }

    // MARK: - Message Construction

    static func buildMeetingMessages(
        speaker: Role,
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        let systemPrompt = buildSpeakerSystemPrompt(
            speaker: speaker,
            meeting: meeting,
            context: context
        )
        messages.append(ChatMessage(role: .system, content: systemPrompt))

        var meetingCtx = "Initiated by: \(roleName(meeting.initiatedBy, team: context.team))\nParticipants: \(context.participants.map { roleName($0, team: context.team) }.joined(separator: ", "))"
        if let additionalContext = meeting.context {
            meetingCtx += "\nContext: \(additionalContext)"
        }
        messages.append(ChatMessage(role: .user, content: meetingCtx))

        if !meeting.messages.isEmpty {
            var discussionHistory = "Discussion so far:\n"
            for msg in meeting.messages {
                discussionHistory += "\n[\(roleName(msg.role, team: context.team))]: \(msg.content)\n"
            }
            messages.append(ChatMessage(role: .user, content: discussionHistory))
        }

        let turnNumber = meeting.turnCount + 1
        let maxTurns = context.limits.maxMeetingTurns
        let turnPrompt: String
        if context.team?.templateID == "discussionClub" {
            let conciseness: String
            if turnNumber >= maxTurns - 1 {
                conciseness = "1-2 sentences max. Final remarks only."
            } else if turnNumber > maxTurns / 2 {
                conciseness = "2-3 sentences. Be very concise."
            } else {
                conciseness = "3-5 sentences."
            }
            turnPrompt = "Your turn, \(roleName(speaker, team: context.team)). \(conciseness) Build on what was said — don't repeat your earlier points."
        } else {
            turnPrompt = "Please provide your input as \(roleName(speaker, team: context.team)). Be concise and focused on the topic."
        }
        messages.append(ChatMessage(role: .user, content: turnPrompt))

        return messages
    }

    // MARK: - Turn Orchestration

    static func determineNextSpeaker(
        meeting: TeamMeeting,
        participants: [Role],
        coordinator: Role
    ) -> Role {
        if meeting.messages.isEmpty {
            return coordinator
        }

        let recentSpeakers = meeting.messages.suffix(participants.count).map { $0.role }
        let pendingSpeakers = participants.filter { !recentSpeakers.contains($0) }

        if let next = pendingSpeakers.first {
            return next
        }

        return coordinator
    }

    // MARK: - Private Helpers

    private static func buildSpeakerSystemPrompt(
        speaker: Role,
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext
    ) -> String {
        let rolePrompt = context.team?.findRole(byIdentifier: speaker.baseID)?.prompt
            ?? (SystemTemplates.roles[speaker.baseID]?.prompt ?? "")

        let isCoordinator = speaker == context.coordinatorRole
        let turnNumber = meeting.turnCount + 1
        let maxTurns = context.limits.maxMeetingTurns
        let coordinatorHint: String
        if isCoordinator && turnNumber >= maxTurns - 2 {
            coordinatorHint = "- WRAP UP NOW. Summarize the key points and state the group's conclusion. This is one of the final turns."
        } else if isCoordinator && turnNumber >= maxTurns / 2 {
            coordinatorHint = "- As the coordinator, start steering toward a conclusion. Summarize agreements and remaining disagreements."
        } else if isCoordinator {
            coordinatorHint = "- As the coordinator, help guide the discussion toward a decision."
        } else {
            coordinatorHint = ""
        }

        let template = context.team?.meetingPromptTemplate ?? SystemTemplates.genericMeetingTemplate
        let placeholders: [String: String] = [
            "speakerName": roleName(speaker, team: context.team),
            "roleGuidance": rolePrompt,
            "meetingTopic": meeting.topic,
            "turnNumber": "\(meeting.turnCount + 1)",
            "coordinatorHint": coordinatorHint,
            "teamDescription": context.team?.description ?? "",
        ]

        return TemplateResolver.resolve(template, placeholders: placeholders)
    }

    /// Resolve a role's display name using team context when available.
    private static func roleName(_ role: Role, team: Team?) -> String {
        if let def = team?.findRole(byIdentifier: role.baseID) { return def.name }
        return role.displayName
    }
}
