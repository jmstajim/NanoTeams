import Foundation

private typealias TN = ToolNames
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
                "teammate": JS.string("Role ID from the current team."),
                "question": JS.string("Question to ask."),
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

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let teammate = try requiredString(args, "teammate")
            let question = try requiredString(args, "question")
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
                "topic": JS.string("Topic to discuss in the meeting"),
                "participants": JS.array(items: JS.string("Role IDs of participants")),
                "context": JS.string("Optional context for the meeting"),
            ],
            required: ["topic", "participants"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let topic = try requiredString(args, "topic")
            let participants: [String]
            if let p = try? requiredStringArray(args, "participants") {
                participants = p
            } else {
                participants = try requiredStringArray(args, "members")
            }
            let ctx = optionalString(args, "context")

            if participants.isEmpty {
                return makeErrorResult(
                    toolName: Self.name,
                    args: args,
                    code: .invalidArgs,
                    message: "At least one participant is required"
                )
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

nonisolated struct ConcludeMeetingTool: ToolHandler {
    static let name = TN.concludeMeeting
    static let schema = ToolSchema(
        name: TN.concludeMeeting,
        description: "Conclude the active meeting with decisions and next steps. Returns the consolidated decision.",
        parameters: JS.object(
            properties: [
                "decision": JS.string("Summary of the decision reached"),
                "rationale": JS.string("Reasoning behind the decision"),
                "next_steps": JS.string("Next steps after the meeting"),
            ],
            required: ["decision"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let decision = try requiredString(args, "decision")
            let rationale = optionalString(args, "rationale")
            let nextSteps = optionalString(args, "next_steps")

            struct ConcludeMeetingData: Codable {
                var decision: String
                var rationale: String?
                var next_steps: String?
                var status: String
            }

            return makeSuccessResult(
                toolName: Self.name,
                args: args,
                data: ConcludeMeetingData(
                    decision: decision,
                    rationale: rationale,
                    next_steps: nextSteps,
                    status: "concluded"
                )
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
                "target_role": JS.string("Role ID of the teammate from the current team."),
                "changes": JS.string("Detailed description of the changes needed"),
                "reasoning": JS.string("Explanation of why these changes are necessary"),
            ],
            required: ["target_role", "changes", "reasoning"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let targetRole = try requiredString(args, "target_role")
            let changes = try requiredString(args, "changes")
            let reasoning = try requiredString(args, "reasoning")
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
