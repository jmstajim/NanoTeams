import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - delegate_to_team

/// Synchronous role-driven team delegation. Spawns a sub-task on the named team and
/// blocks the parent role's tool loop until the child team produces its required
/// artifacts. Returns the artifacts as the tool result.
///
/// `team_id` accepts either a team id from the catalog embedded in the tool's
/// runtime description (see `buildSchema`) or the
/// `DelegationConstants.generatedTeamSentinel` marker (when the role has
/// `allowDelegationToGeneratedTeams = true`) to generate a fresh team on the fly.
nonisolated struct DelegateToTeamTool: ToolHandler {
    static let name = TN.delegateToTeam
    // The static schema carries the base prose only — the runtime `buildSchema`
    // variant appends the per-role team catalog before the LLM sees it, and the
    // role-editor UI shows this string as-is.
    static let schema = ToolSchema(
        name: TN.delegateToTeam,
        description: baseDescription,
        parameters: parameterSchema
    )
    static let category: ToolCategory = .delegation
    static let excludedInMeetings = true

    /// LLM-facing prose. Stays in `Self.schema` as the user-curated tool surface
    /// shown in the role-editor UI; `buildSchema` reuses this string and appends
    /// the per-role catalog before handing the schema to the LLM.
    private static let baseDescription = """
        Delegate a sub-task to another team and wait for it to finish. You receive the \
        team's final artifacts as the tool result. The team has no other context, so \
        put everything they need into task_brief. Supervisor escalations from the team \
        route back to you for an answer.
        """

    private static let parameterSchema = JS.object(
        properties: [
            "team_id": JS.string("A team id from the list embedded in this tool's description."),
            "task_brief": JS.string("Self-contained description of what the team should produce."),
        ],
        required: ["team_id", "task_brief"]
    )

    /// Builds a per-role `delegate_to_team` schema with the role's allowed delegation
    /// catalog embedded inline in the description. Replaces the discovery round-trip
    /// that `list_teams` used to provide — same filtering rules (whitelist intersection,
    /// chat-mode excluded, `"generated"` sentinel appended iff allowed).
    ///
    /// Called from `LLMExecutionService.toolSchemas(for:team:)` step 7 when the role's
    /// delegation is enabled. The static `Self.schema` is the fallback for any caller
    /// that doesn't need per-role customization.
    static func buildSchema(role: TeamRoleDefinition, allTeams: [Team]) -> ToolSchema {
        let allowedSet = Set(role.allowedDelegationTeamIDs)
        var lines: [String] = []
        for team in allTeams where allowedSet.contains(team.id) && team.isValidDelegationTarget {
            let roleNames = team.nonSupervisorRoles.map(\.name).joined(separator: ", ")
            let descPart = team.description.isEmpty ? "" : ": \(team.description)"
            let rolesPart = roleNames.isEmpty ? "" : ". Roles: \(roleNames)"
            lines.append("- `\(team.id)` — \"\(team.name)\"\(descPart)\(rolesPart)")
        }
        if role.allowDelegationToGeneratedTeams {
            lines.append(
                "- `\(DelegationConstants.generatedTeamSentinel)` — assemble a new team "
                + "(extra LLM call, slower). Use only when no listed team fits."
            )
        }
        let catalogSection = lines.isEmpty
            ? "Available teams to delegate to: (none configured for this role)"
            : "Available teams to delegate to:\n" + lines.joined(separator: "\n")
        return ToolSchema(
            name: TN.delegateToTeam,
            description: baseDescription + "\n\n" + catalogSection,
            parameters: parameterSchema
        )
    }

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Absence / empty / non-string team_id defaults to the "generated" sentinel:
            // the downstream `delegationDenied` envelope is a better signal than INVALID_ARGS
            // when the role isn't allowed to use generated teams.
            let teamID = extractString(args, "team_id") ?? DelegationConstants.generatedTeamSentinel

            let taskBrief = try requiredString(args, "task_brief").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !taskBrief.isEmpty else {
                return makeErrorResult(
                    toolName: Self.name,
                    args: args,
                    code: .invalidArgs,
                    message: "task_brief is empty — describe what the team should produce, including file paths and constraints from your investigation."
                )
            }

            struct DelegateInitData: Codable {
                var team_id: String
                var task_brief: String
                var status: String  // "pending"
            }

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(
                    data: DelegateInitData(
                        team_id: teamID,
                        task_brief: taskBrief,
                        status: "pending"
                    )
                ),
                isError: false,
                signal: .delegateToTeam(teamID: teamID, taskBrief: taskBrief)
            )
        }
    }
}

// MARK: - cancel_delegation / resume_delegation / forward_to_team
//
// These three tools are auto-injected next to `delegate_to_team` whenever a
// role has the delegation tool in its toolset. They surface only after the
// Supervisor interrupts a running delegation (queueing a chat message for
// the delegating role) — `delegate_to_team`'s handler returns a success
// envelope with `status: "paused_by_supervisor"` and the role chooses one
// of the three follow-ups:
//
//  * `cancel_delegation` — abort the delegation. Child engine stops, parent
//    step's delegation fields clear, role re-plans from scratch.
//  * `resume_delegation` — un-pause and keep waiting. Role's tool loop
//    re-enters the awaiter and blocks until the child reaches a terminal
//    state (or the Supervisor interrupts again).
//  * `forward_to_team` — un-pause + inject a Supervisor message into the
//    child team's flow as guidance/corrections, then re-enter the awaiter.
//
// The shape is intentionally minimal: each tool emits a `ToolSignal` and the
// service-layer handler does the actual orchestration (engine pause/resume,
// child Supervisor-input injection, awaiter re-entry).

/// Aborts a delegation paused by a Supervisor interrupt. Stops the child
/// engine and clears the delegation fields on the parent step so the role
/// can re-plan or report status.
nonisolated struct CancelDelegationTool: ToolHandler {
    static let name = TN.cancelDelegation
    static let schema = ToolSchema(
        name: TN.cancelDelegation,
        description: """
            Abort a delegation that is paused_by_supervisor. Stops the delegated \
            team; the sub-task will not complete.
            """,
        parameters: JS.object(
            properties: [
                "child_task_id": JS.integer("Child task id from the paused delegation envelope."),
                "reason": JS.string("Short rationale for the abort (surfaced to the user)."),
            ],
            required: ["child_task_id"]
        )
    )
    static let category: ToolCategory = .delegation
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let childID = optionalInt(args, "child_task_id") else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "child_task_id is required (integer from the paused delegation envelope)."
                )
            }
            let reason = optionalString(args, "reason")
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .cancelDelegation(childTaskID: childID, reason: reason)
            )
        }
    }
}

/// Un-pauses a delegation paused by Supervisor interrupt and re-enters the
/// awaiter loop, blocking the role's tool loop until the child reaches a
/// terminal state (or the Supervisor interrupts again). Use when the
/// Supervisor's message was informational — the team is on track and should
/// continue without modification.
nonisolated struct ResumeDelegationTool: ToolHandler {
    static let name = TN.resumeDelegation
    static let schema = ToolSchema(
        name: TN.resumeDelegation,
        description: """
            Resume a delegation that is paused_by_supervisor and keep waiting for \
            its artifacts. Use when no change of direction is needed.
            """,
        parameters: JS.object(
            properties: [
                "child_task_id": JS.integer("Child task id from the paused delegation envelope."),
            ],
            required: ["child_task_id"]
        )
    )
    static let category: ToolCategory = .delegation
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let childID = optionalInt(args, "child_task_id") else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "child_task_id is required (integer from the paused delegation envelope)."
                )
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .resumeDelegation(childTaskID: childID)
            )
        }
    }
}

/// Forwards a Supervisor message into the child team's running flow as
/// guidance/corrections, then un-pauses and re-enters the awaiter loop.
/// Use when the Supervisor's message contains course-correction the team
/// should act on (e.g. "use library X instead of Y", "skip step 3").
nonisolated struct ForwardToTeamTool: ToolHandler {
    static let name = TN.forwardToTeam
    static let schema = ToolSchema(
        name: TN.forwardToTeam,
        description: """
            Send guidance into a delegation that is paused_by_supervisor and \
            resume it.
            """,
        parameters: JS.object(
            properties: [
                "child_task_id": JS.integer("Child task id from the paused delegation envelope."),
                "message": JS.string("Instructions for the team (they cannot answer questions)."),
            ],
            required: ["child_task_id", "message"]
        )
    )
    static let category: ToolCategory = .delegation
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let childID = optionalInt(args, "child_task_id") else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "child_task_id is required (integer from the paused delegation envelope)."
                )
            }
            let message = try requiredString(args, "message")
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "message must not be empty after trimming."
                )
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .forwardToTeam(childTaskID: childID, message: trimmed)
            )
        }
    }
}
