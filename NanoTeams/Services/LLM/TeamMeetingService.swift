import Foundation

/// Service for managing team meeting lifecycle.
/// Handles meeting creation, turn completion, conclusion, and summary generation.
/// Streaming and message construction are in MeetingStreamingService.
nonisolated struct TeamMeetingService {

    /// What the role that convened a meeting does in it. Passed to
    /// `LLMExecutionService.handleTeamMeeting` explicitly — no default — because the two
    /// callers want opposite things and a silent default would hand one of them the other's
    /// behaviour.
    enum InitiatorSeat: Sendable {
        /// `request_team_meeting`: the initiator is a participant by construction (like the
        /// coordinator), takes the first turn after the coordinator's opening — the meeting is
        /// its topic — and bypasses `invitableRoles`. Until 2026-09-07 the initiator never
        /// spoke in a meeting it convened; its whole contribution was the `topic` / `context`.
        case speaks
        /// `request_changes`: the requester's case IS the topic and it must not vote on its
        /// own request — `handleChangeRequest` excludes it from the voters on purpose. It is
        /// announced to the UI as part of the meeting (its node glows) but never speaks.
        ///
        /// Carries the TARGET's role id because the chair rule needs it: a vote must be
        /// chaired by somebody who is neither the requester nor the target, and the seat is
        /// the only thing that knows this meeting is such a vote. Passing it separately
        /// would let a caller pass the seat and forget the target — which is how the
        /// requester ended up chairing its own case for the whole of 2026.
        case presentsOnly(targetRoleID: String)
    }

    /// Context required for a team meeting.
    ///
    /// No `topic` / `additionalContext` / `task` fields, on purpose (wave 32): every
    /// consumer that needs those receives them as its OWN parameters (`createMeeting(topic:)`,
    /// `MeetingCoordinator.buildTurnMessage`) — the stored copies here had zero readers, and
    /// a "context" carrying facts nothing consults misleads the next reader about what a
    /// meeting turn actually depends on.
    struct MeetingContext {
        let initiatedBy: Role
        let participants: [Role]
        let availableArtifacts: [Artifact]
        let artifactReader: (Artifact) -> String?
        let team: Team?
        /// The chair of THIS meeting. For a discussion (`request_team_meeting`) it is the
        /// team's coordinator (`Team.meetingCoordinator`, the mandatory one — there is no
        /// Auto mode), or the initiator only when there is no team to resolve against. For
        /// a `request_changes` vote it may be a STAND-IN: a coordinator that is the
        /// requester or the target is disqualified and another role holds the gavel.
        /// Resolved at the call site via
        /// `LLMExecutionService.effectiveCoordinator(team:initiator:requesterRoleID:seat:targetRoleID:)`
        /// so this stays non-optional and the runtime never branches on nil — and never
        /// compare it to `Team.meetingCoordinatorID`, which names the coordinator, not
        /// the chair.
        let coordinatorRole: Role
        let limits: TeamLimits
        /// The role a `request_changes` vote is ABOUT — the participant whose directive
        /// asks for a defence rather than a ballot (`ChangeRequestService.targetInstruction`),
        /// because `tallyVotes` does not count its vote. `nil` for a discussion meeting.
        let voteTargetRole: Role?
        /// App-wide instruction appended to the resolved system prompt.
        /// Default `""` keeps existing test call sites compiling.
        let globalContext: String
        /// The upstream-artifact grounding turn (segment 1 of every turn's wire), rendered
        /// ONCE here. Reading the bodies per turn — as `buildMeetingMessages` did until
        /// 2026-09-07 — re-derived a "fixed" head from disk on every turn, so an upstream
        /// artifact rewritten mid-meeting changed the leading bytes and re-prefilled the
        /// whole discussion (playbook R4.2.1 / A6.18). `nil` when there is nothing to
        /// ground on.
        let artifactGrounding: String?

        init(
            initiatedBy: Role,
            participants: [Role],
            availableArtifacts: [Artifact],
            artifactReader: @escaping (Artifact) -> String?,
            team: Team?,
            coordinatorRole: Role,
            limits: TeamLimits,
            voteTargetRole: Role? = nil,
            globalContext: String = ""
        ) {
            self.initiatedBy = initiatedBy
            self.participants = participants
            self.availableArtifacts = availableArtifacts
            self.artifactReader = artifactReader
            self.team = team
            self.coordinatorRole = coordinatorRole
            self.limits = limits
            self.voteTargetRole = voteTargetRole
            self.globalContext = globalContext
            self.artifactGrounding = PromptBuilder.buildArtifactSection(
                heading: "Available team artifacts", artifacts: availableArtifacts,
                cap: ArtifactConstants.maxConsultationChars, artifactReader: artifactReader)
        }
    }

    /// Result of a single LLM streaming call within a meeting turn.
    struct MeetingStreamResult {
        var content: String
        var thinking: String
        var resolvedToolCalls: [StepToolCall]
    }

    /// What the coordinator's `conclude_meeting` call carried. Produced by
    /// `MeetingToolExecutor` when the signal arrives, consumed by `handleTeamMeeting`,
    /// which records it through `concludeMeeting` and stops the turn loop.
    struct MeetingConclusion: Equatable {
        var decision: String
        var rationale: String?
        /// Raw `next_steps` text; `concludeMeeting` splits it one step per line.
        var nextSteps: String?
    }

    // MARK: - Meeting Lifecycle

    /// Create a new team meeting
    static func createMeeting(
        topic: String,
        initiatedBy: Role,
        participants: [Role],
        context: String?,
        kind: TeamMeetingKind = .discussion
    ) -> TeamMeeting {
        TeamMeeting(
            topic: topic,
            initiatedBy: initiatedBy,
            participants: participants,
            context: context,
            status: .pending,
            kind: kind
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

    /// Complete a turn by adding the final message. Returns whether the meeting may take
    /// another turn: `false` only at the turn limit. A meeting otherwise ends by the
    /// coordinator's `conclude_meeting` call (handled by the caller), never by reading
    /// agreement into the text — until 2026-09-06 three "I agree"-shaped replies in a row
    /// ended it here, before the coordinator had said anything.
    /// - Parameter messageType: an explicit classification for a turn the runtime already
    ///   understands (the concluding turn is `.conclusion`); `nil` classifies the text.
    static func completeTurn(
        meeting: inout TeamMeeting,
        speaker: Role,
        content: String,
        thinking: String?,
        toolSummaries: [MeetingToolSummary]?,
        context: MeetingContext,
        messageType: TeamMessageType? = nil
    ) -> Bool {
        // A reasoning model can put its whole contribution in the reasoning channel and
        // leave content empty. `MeetingStreamingService` has always COLLECTED that channel
        // and this was the one place that decides what the speaker said — so the turn was
        // added as an empty `TeamMessage`, and every later speaker read a blank line under
        // "Discussion so far" for the rest of the meeting.
        let cleanedContent = ModelTokenCleaner.clean(content)
        let spoken = ModelReplyChannels.answer(
            content: content,
            reasoning: thinking ?? "",
            prepare: { ModelTokenCleaner.clean($0) })
        // Promoted reasoning IS the contribution now; leaving it in the disclosure as well
        // would render the same text twice in the feed.
        let message = TeamMessage(
            role: speaker,
            content: spoken,
            messageType: messageType ?? TeamMessageType.determine(from: spoken),
            thinking: cleanedContent.isEmpty ? nil : thinking,
            toolSummaries: toolSummaries
        )
        meeting.addMessage(message)

        return !hasReachedTurnLimit(meeting: meeting, limits: context.limits)
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
}

// MARK: - Meeting Summary Generation

extension TeamMeetingService {

    /// The concise meeting result the INITIATING role reads as its `request_team_meeting`
    /// tool result. Every name resolves through the team (`MeetingCoordinator.displayName`),
    /// like every other line of a meeting prompt: the initiator's `## Team` block and its
    /// `ask_teammate` schema speak in team role names, and on a generated or renamed team
    /// the enum `displayName` this used to print is a roster the model cannot match
    /// (R1.8.3 — the answer must be in the reader's vocabulary).
    ///
    /// The former `generateMeetingSummary` sibling had no production caller and is gone.
    static func generateMeetingResultForConversation(
        meeting: TeamMeeting, context: MeetingContext
    ) -> String {
        let names = meeting.participants.map { MeetingCoordinator.displayName(of: $0, context: context) }
        var result = "Team Meeting Result - \(meeting.topic)\n"
        result += "Participants: \(names.joined(separator: ", "))\n"
        let coordinatorName = MeetingCoordinator.displayName(of: context.coordinatorRole, context: context)
        switch meeting.conclusionKind {
        case .coordinatorCall:
            result += "Concluded by: \(coordinatorName) via conclude_meeting\n"
        case .turnLimitFallback:
            result += "Concluded at the turn limit — \(coordinatorName) made no conclude_meeting call; "
                + "the decision below is their last contribution.\n"
        case nil:
            break
        }

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
                    let speaker = MeetingCoordinator.displayName(of: msg.role, context: context)
                    result += "- [\(speaker)]: \(msg.content.prefix(200))...\n"
                }
            }
        }

        return result
    }
}
