import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - Teammate Consultation Data Types

struct AskTeammateData: Codable {
    var teammate: String
    var question: String
    var context: String?
    var status: String  // "pending"
}

struct RequestMeetingData: Codable {
    var topic: String
    var participants: [String]
    var context: String?
    var status: String
    var note: String?
}

struct RequestChangesData: Codable {
    var targetRole: String
    var changes: String
    var reasoning: String
    var status: String  // "pending"
}

// MARK: - Result Builders (signaling)

func makeTeammateQuestionResult(
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

func makeMeetingRequestResult(
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

func makeChangeRequestResult(
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

struct AskTeammateTool: ToolHandler {
    static let name = TN.askTeammate
    static let schema = ToolSchema(
        name: TN.askTeammate,
        description: "Ask a teammate for their expertise on a specific question. The teammate will respond based on their role's knowledge and the current task context. You have a limited number of consultations per step — avoid asking the same teammate the same thing twice.",
        parameters: JS.object(
            properties: [
                "teammate": JS.string("Role ID of the teammate to ask (e.g., 'softwareEngineer', 'techLead', 'productManager')"),
                "question": JS.string("The question to ask the teammate"),
                "context": JS.string("Optional additional context for the question"),
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

struct RequestTeamMeetingTool: ToolHandler {
    static let name = TN.requestTeamMeeting
    static let schema = ToolSchema(
        name: TN.requestTeamMeeting,
        description: "Request a team meeting to discuss a topic with multiple teammates. Call ONCE to start — the system runs the discussion automatically and you will receive the full result. Do NOT call again while a meeting is running. Meetings are limited per run.",
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

struct ConcludeMeetingTool: ToolHandler {
    static let name = TN.concludeMeeting
    static let schema = ToolSchema(
        name: TN.concludeMeeting,
        description: "Conclude a team meeting with decisions and next steps. Auto-granted only to the team's Meeting Coordinator (configured per team) — call this to finalize the current meeting.",
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

struct RequestChangesTool: ToolHandler {
    static let name = TN.requestChanges
    static let schema = ToolSchema(
        name: TN.requestChanges,
        description: "Request changes to a completed teammate's work. PREREQUISITES: The target role's step must be complete (status=done). You must have specific, actionable issues to cite. Triggers a team vote before applying changes. If approved, the target role re-executes with amendments. Only use when issues are critical enough to warrant rework.",
        parameters: JS.object(
            properties: [
                "target_role": JS.string("Role ID of the teammate whose work needs changes (e.g., 'softwareEngineer', 'techLead')"),
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
