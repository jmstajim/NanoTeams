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
        logger: NetworkLogger? = nil,
        stepID: String? = nil
    ) async throws -> TeamMeetingService.MeetingStreamResult {
        var fullContent = ""
        var thinkingCollected = ""
        var toolAccumulator = ToolCallAccumulator()

        // prefix-cache-owner: registered by the caller — this is a stateless transport wrapper
        // with no taskID/meetingID in scope. `LLMExecutionService+TeamMeeting` records the
        // `.chain(id: "meeting:…")` before the initial stream and hands the same bound recorder
        // to `MeetingToolExecutor` for the follow-ups, so both halves of one turn share a chain.
        let stream = client.streamChat(
            config: config,
            messages: messages,
            tools: tools.isEmpty ? [] : tools,
            logger: logger,
            stepID: stepID
        )

        for try await event in stream {
            fullContent += event.contentDelta
            thinkingCollected += event.thinkingDelta
            if !event.toolCallDeltas.isEmpty {
                toolAccumulator.absorb(event.toolCallDeltas)
            }
        }

        let resolvedToolCalls = toolAccumulator.finalize()

        return TeamMeetingService.MeetingStreamResult(
            content: fullContent.trimmingCharacters(in: .whitespacesAndNewlines),
            thinking: thinkingCollected.trimmingCharacters(in: .whitespacesAndNewlines),
            resolvedToolCalls: resolvedToolCalls
        )
    }

    // MARK: - Message Construction

    /// Builds the full conversation for one meeting turn, ordered so that consecutive turns of the
    /// SAME speaker are an append rather than a rebuild:
    ///
    /// 1. the team's MEETING template as system prompt (fixed per speaker),
    /// 2. upstream artifact grounding (fixed),
    /// 3. the meeting header — topic, initiator, participants (fixed),
    /// 4. one message per transcript line, in order (grows by appending),
    /// 5. the turn directive (the only volatile element, and last so it keeps the recency slot).
    ///
    /// The previous shape folded 3-5 into ONE consolidated user turn, re-rendered from scratch
    /// every turn. That put a value which changes every turn (the directive, and the whole
    /// discussion behind it) at the head of the volatile region, so the server re-prefilled the
    /// entire discussion on every single turn — a meeting was the most cache-hostile thing the app
    /// did, and it grew worse as the meeting went on. Now the discussion stays cached and only the
    /// newest contribution plus the directive are new.
    ///
    /// Turns stay attributed `.user` lines rather than becoming `.assistant` for the current
    /// speaker: the speaker rotates, so rendering someone else's words as this model's own output
    /// would be a lie, and rendering only its own turns as assistant would reorder the transcript.
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
            content: MeetingCoordinator.buildMeetingHeader(meeting: meeting, context: context)))

        if !meeting.messages.isEmpty {
            messages.append(ChatMessage(role: .user, content: "Discussion so far:"))
            for previous in meeting.messages {
                messages.append(ChatMessage(
                    role: .user,
                    content: MeetingCoordinator.buildTranscriptLine(previous, context: context)))
            }
        }

        messages.append(ChatMessage(
            role: .user,
            content: MeetingCoordinator.buildTurnDirective(
                speaker: speaker, meeting: meeting, context: context)))

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

        let template = context.team?.meetingPromptTemplate ?? SystemTemplates.genericMeetingTemplate
        let placeholders: [String: String] = [
            "speakerName": roleName(speaker, team: context.team),
            "roleGuidance": rolePrompt,
            "meetingTopic": meeting.topic,
            // `{turnNumber}` and `{coordinatorHint}` are RETIRED (2026-07) and resolve to "".
            // Both were derived from `meeting.turnCount`, so they changed segment 0 — which
            // carries the tool catalog — on every single turn, and the server re-prefilled the
            // whole meeting each time. Same defect and same fix as `{stepInfo}` in the step
            // templates. Both now ride `MeetingCoordinator.turnDirective`, last on the wire.
            // The chips stay resolvable so stored user-edited templates that still carry them
            // do not render a literal token.
            "turnNumber": "",
            "coordinatorHint": "",
            "teamDescription": context.team?.description ?? "",
            "globalContext": PromptBuilder.formatGlobalContext(context.globalContext),
            // Role-attached skills ride the STEP prompt only. Resolvable-but-empty
            // so a hand-typed chip never ships as a literal token.
            "roleSkills": "",
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
