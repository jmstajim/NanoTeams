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

    /// Builds the full conversation for one meeting turn: the team's MEETING
    /// template as system prompt, upstream artifact grounding, and ONE
    /// consolidated user turn (meeting header + discussion-so-far + turn
    /// directive, via `MeetingCoordinator.buildTurnMessage`). Each turn is a
    /// stateless full re-consolidation — no cross-turn chain to drift.
    static func buildMeetingMessages(
        speaker: Role,
        meeting: TeamMeeting,
        context: TeamMeetingService.MeetingContext,
        tools: [ToolSchema] = []
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        let systemPrompt = buildSpeakerSystemPrompt(
            speaker: speaker,
            meeting: meeting,
            context: context,
            tools: tools
        )
        messages.append(ChatMessage(role: .system, content: systemPrompt))

        if let artifactContext = buildArtifactGrounding(context: context) {
            messages.append(ChatMessage(role: .user, content: artifactContext))
        }

        messages.append(ChatMessage(
            role: .user,
            content: MeetingCoordinator.buildTurnMessage(
                speaker: speaker, meeting: meeting, context: context
            )
        ))

        return messages
    }

    /// Upstream artifact grounding for meeting speakers — same shape and cap as
    /// the consultation chat's artifact context. `nil` when there is nothing
    /// to ground on (no empty user turns).
    private static func buildArtifactGrounding(
        context: TeamMeetingService.MeetingContext
    ) -> String? {
        guard !context.availableArtifacts.isEmpty else { return nil }
        var artifactContext = "Available team artifacts:\n"
        for artifact in context.availableArtifacts {
            artifactContext += "\n[\(artifact.name)]:"
            if let content = context.artifactReader(artifact) {
                let cap = ArtifactConstants.maxConsultationChars
                let truncated = String(content.prefix(cap))
                artifactContext += "\n```\n\(truncated)\(content.count > cap ? "\n... (truncated)" : "")\n```"
            }
        }
        return artifactContext
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
        context: TeamMeetingService.MeetingContext,
        tools: [ToolSchema] = []
    ) -> String {
        let rolePrompt = context.team?.findRole(byIdentifier: speaker.baseID)?.prompt
            ?? (SystemTemplates.roles[speaker.baseID]?.prompt ?? "")

        let isCoordinator = speaker == context.coordinatorRole
        let turnNumber = meeting.turnCount + 1
        let maxTurns = context.limits.maxMeetingTurns
        let coordinatorHint: String
        if isCoordinator && turnNumber >= maxTurns - 2 {
            coordinatorHint = "- Final turns: summarize the key points and state the group's conclusion."
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
            "globalContext": PromptBuilder.formatGlobalContext(context.globalContext),
            "toolCalling": PromptBuilder.formatToolCallingBlock(tools: tools),
            // Backwards-compat alias for stored templates with the older
            // `{toolCallingBlock}` placeholder name.
            "toolCallingBlock": PromptBuilder.formatToolCallingBlock(tools: tools),
        ]

        return TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: placeholders,
            globalContext: context.globalContext
        )
    }

    /// Resolve a role's display name using team context when available.
    private static func roleName(_ role: Role, team: Team?) -> String {
        if let def = team?.findRole(byIdentifier: role.baseID) { return def.name }
        return role.displayName
    }
}
