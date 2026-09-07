import Foundation

private typealias TN = ToolNames

/// The one description of a roster-valued argument. Three properties take a teammate by
/// name (`ask_teammate.teammate`, `request_changes.target_role`,
/// `request_team_meeting.participants` items); the model reads the roster under
/// `Members`, and the three used to say it in two wordings plus "Role IDs", which the
/// prompt never shows. Pinned equal by `ToolSchemaTextPinTests`.
nonisolated enum TeammateSchemaText {
    static let rosterName = "The teammate's name, as listed under Members."
}
private typealias JS = JSONSchema

// MARK: - Teammate Consultation Data Types

nonisolated struct AskTeammateData: Codable {
    var teammate: String
    var question: String
    var context: String?
    var status: String  // "pending"
}

nonisolated struct RequestMeetingData: Codable {
    var topic: String
    var participants: [String]
    var context: String?
    var status: String
    var note: String?
}

nonisolated struct RequestChangesData: Codable {
    var targetRole: String
    var changes: String
    var reasoning: String
    var status: String  // "pending"
}

// MARK: - Result Builders (signaling)

nonisolated func makeTeammateQuestionResult(
    toolName: String,
    args: [String: Any],
    teammate: String,
    question: String,
    context: String?
) -> ToolExecutionResult {
    ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeSuccessEnvelope(
            data: AskTeammateData(
                teammate: teammate,
                question: question,
                context: context,
                status: "pending"
            )
        ),
        isError: false,
        signal: .teammateConsultation(id: teammate, question: question, context: context)
    )
}

nonisolated func makeMeetingRequestResult(
    toolName: String,
    args: [String: Any],
    topic: String,
    participants: [String],
    context: String?
) -> ToolExecutionResult {
    ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeSuccessEnvelope(
            data: RequestMeetingData(
                topic: topic,
                participants: participants,
                context: context,
                status: "meeting_started",
                note: "The meeting is now running. Participants will discuss the topic and you will receive the full discussion result. Do NOT call request_team_meeting again — wait for the meeting result."
            )
        ),
        isError: false,
        signal: .teamMeeting(topic: topic, participants: participants, context: context)
    )
}

nonisolated func makeChangeRequestResult(
    toolName: String,
    args: [String: Any],
    targetRole: String,
    changes: String,
    reasoning: String
) -> ToolExecutionResult {
    ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeSuccessEnvelope(
            data: RequestChangesData(
                targetRole: targetRole,
                changes: changes,
                reasoning: reasoning,
                status: "pending"
            )
        ),
        isError: false,
        signal: .changeRequest(targetRole: targetRole, changes: changes, reasoning: reasoning)
    )
}

// MARK: - ask_teammate

nonisolated struct AskTeammateTool: ToolHandler {
    static let name = TN.askTeammate
    static let schema = ToolSchema(
        name: TN.askTeammate,
        description: "Ask a teammate a question. Limited per step.",
        parameters: JS.object(
            properties: [
                "teammate": JS.string(TeammateSchemaText.rosterName),
                "question": JS.string(),
                "context": JS.string("Optional extra context."),
            ],
            required: ["teammate", "question"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true


    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // `teammate` stays on `requiredString` — it is an IDENTIFIER, and the
            // exclusion rule applies: `+TeammateConsultation` answers an empty one
            // with "Unknown teammate role: . Available teammates: …", enumerating
            // the legal values. Rejecting it here as "must not be empty" would
            // replace the only actionable half of that message with less.
            //
            // `question` is different: nothing downstream inspects it.
            // `+TeammateConsultation` builds `"<Role> asks: "` and spends a full LLM
            // round-trip on the consulted role's own model, then files the blank in
            // `step.consultations` against `TeamLimits.maxConsultationsPerStep` —
            // per STEP, not per run.
            let teammate = try requiredString(args, "teammate")
            let question = try requiredNonEmptyString(args, "question")
            let ctx = optionalString(args, "context")
            return makeTeammateQuestionResult(
                toolName: Self.name,
                args: args,
                teammate: teammate,
                question: question,
                context: ctx
            )
        }
    }
}

// MARK: - request_team_meeting

nonisolated struct RequestTeamMeetingTool: ToolHandler {
    static let name = TN.requestTeamMeeting
    static let schema = ToolSchema(
        name: TN.requestTeamMeeting,
        description: "Start a multi-participant meeting on `topic`. Blocks until the meeting concludes; the full discussion is returned. Limited per run.",
        parameters: JS.object(
            properties: [
                "topic": JS.string(),
                "participants": JS.array(items: JS.string(TeammateSchemaText.rosterName)),
                "context": JS.string(),
            ],
            required: ["topic", "participants"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // The topic is the meeting's whole framing — it heads every
            // participant's turn message. Empty, it convenes N roles for M turns
            // apiece against the per-run meeting limit with nothing to discuss,
            // which is the most expensive no-op any tool in this file can buy.
            // The participants list already refuses to be empty a few lines down;
            // this is the same rule for the other half of the same call.
            let topic = try requiredNonEmptyString(args, "topic")
            let participants = try requiredStringArray(args, aliases: ["participants", "members"])
            let ctx = optionalString(args, "context")

            if participants.isEmpty {
                throw ToolArgumentError.invalidValue(
                    key: "participants",
                    detail: "is empty — name at least one role to invite.")
            }

            return makeMeetingRequestResult(
                toolName: Self.name,
                args: args,
                topic: topic,
                participants: participants,
                context: ctx
            )
        }
    }
}

// MARK: - conclude_meeting

/// The meeting coordinator's own end of a meeting.
///
/// Never in a STEP schema: `availableToRoles == false`, so neither `toolIDs` nor an
/// auto-injection can grant it, and the resolver's `unavailableToRoles` strip removes a
/// legacy `toolIDs` entry. Never stripped from a MEETING turn either — `excludedInMeetings`
/// stays `false` and `MeetingCoordinator.speakerTools` appends it to the coordinator's
/// turn only. Its `ToolSignal` is read by `MeetingToolExecutor`, which stops the turn, and
/// by `handleTeamMeeting`, which records the decision and stops the meeting. Until
/// 2026-09-06 this handler was an echo whose payload no consumer read: `excludedInMeetings`
/// was `true`, the step resolver injected it where no meeting was ever active, and every
/// meeting ended by turn limit or by a text heuristic instead of by its coordinator.
nonisolated struct ConcludeMeetingTool: ToolHandler {
    static let name = TN.concludeMeeting
    static let schema = ToolSchema(
        name: TN.concludeMeeting,
        description: "End the meeting: record the decision, its rationale and the next steps, drawn from the whole discussion.",
        parameters: JS.object(
            properties: [
                "decision": JS.string("What the group settled on, in one or two sentences."),
                "rationale": JS.string("The arguments that carried it."),
                "next_steps": JS.string("One per line."),
            ],
            required: ["decision"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let availableToRoles = false

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // The decision IS the meeting's outcome: it is recorded on the meeting and
            // returned to the initiator as the result of `request_team_meeting`. An empty
            // one would end the meeting with nothing, so it is refused with what to send.
            let decision = try requiredNonEmptyString(args, "decision")
            let rationale = optionalString(args, "rationale")
            let nextSteps = optionalString(args, "next_steps")

            struct ConcludeMeetingData: Codable {
                var status: String
            }

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ConcludeMeetingData(status: "concluded")),
                isError: false,
                signal: .concludeMeeting(decision: decision, rationale: rationale, nextSteps: nextSteps)
            )
        }
    }
}

// MARK: - request_changes

nonisolated struct RequestChangesTool: ToolHandler {
    static let name = TN.requestChanges
    static let schema = ToolSchema(
        name: TN.requestChanges,
        description: "Request changes to a teammate's completed work. Triggers a team vote; on approval the target role re-executes with your amendments.",
        parameters: JS.object(
            properties: [
                "target_role": JS.string(TeammateSchemaText.rosterName),
                "changes": JS.string("What must change."),
                "reasoning": JS.string("Why the change is necessary."),
            ],
            required: ["target_role", "changes", "reasoning"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // `target_role` stays on `requiredString`, same reason as
            // `ask_teammate`'s `teammate`: `ChangeRequestService.validateChangeRequest`
            // rejects an unresolvable id — `""` included — BEFORE any meeting is
            // convened, and its message enumerates ("Target role '' not found in the
            // team. Available roles: …").
            //
            // `changes` and `reasoning` have no such reader.
            // `ChangeRequestService.buildVotingContext` renders them verbatim into
            // the meeting CONTEXT as `"Changes requested: …\nReasoning: …"`, and a
            // vote carried on a blank request has `executeAmendment` reset the target
            // role and every started downstream role for a revision with nothing to
            // revise.
            let targetRole = try requiredString(args, "target_role")
            let changes = try requiredNonEmptyString(args, "changes")
            let reasoning = try requiredNonEmptyString(args, "reasoning")
            return makeChangeRequestResult(
                toolName: Self.name,
                args: args,
                targetRole: targetRole,
                changes: changes,
                reasoning: reasoning
            )
        }
    }
}
