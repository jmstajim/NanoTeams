import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - Autovisor management tools
//
// TEN tools available ONLY to the hidden "Manager" role of the Autovisor
// team (gated by that role's `toolIDs`). All are category `.collaboration` so they
// route through the deferred-handler path (`appendCollaborationResult`) — sandbox
// tool handlers can't reach the orchestrator, so even the read tools emit a signal.
// All `excludedInMeetings`. Each handler validates args and emits a `pending`
// envelope + a `ToolSignal`.
//
// NINE of the ten do their real work in `LLMExecutionService+Autovisor.swift`, which
// is why that file's header says nine and this one says ten — the two counts are
// different sets, not a contradiction. `wait_for_events` is the tenth: it has no
// service-layer handler, because it asks for a STATE CHANGE rather than an action.
// Its signal is dispatched in `+ToolResultDispatching` and flips the step's
// `parkForEventsRequested`, which the tool loop reads at the top of the next
// iteration to park the pass. Count these from the struct declarations below, never
// from this sentence — it said "Nine" from the day `wait_for_events` landed until
// 2026-08-10.

/// `list_tasks` — enumerate every task in the folder with status.
nonisolated struct ListTasksTool: ToolHandler {
    static let name = TN.listTasks
    static let schema = ToolSchema(
        name: TN.listTasks,
        description: "List every task in this folder with its id, title, and status.",
        parameters: JS.object(properties: [:], required: [])
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .listTasks
            )
        }
    }
}

/// `task_status` — detailed status of one task: per-role statuses, produced
/// artifacts (with content), any pending supervisor question, and last error.
nonisolated struct TaskStatusTool: ToolHandler {
    static let name = TN.taskStatus
    static let schema = ToolSchema(
        name: TN.taskStatus,
        description: "Inspect one task: role statuses, produced artifacts (each a name + path; read_file the path for full content), any pending question, and last error.",
        parameters: JS.object(
            properties: ["task_id": JS.integer("The task's id.")],
            required: ["task_id"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let taskID = optionalInt(args, "task_id") else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "task_id is required (integer).")
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .taskStatus(taskID: taskID)
            )
        }
    }
}

/// `create_managed_task` — fire-and-forget create + start of a top-level task.
nonisolated struct CreateManagedTaskTool: ToolHandler {
    static let name = TN.createManagedTask
    static let schema = ToolSchema(
        name: TN.createManagedTask,
        description: baseDescription
            + "\n\nThe team catalog of valid team_ids is appended to this description at runtime.",
        parameters: parameterSchema
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    private static let baseDescription = """
    Create and start a new top-level task in this folder. It runs independently \
    — you do NOT block waiting for it; check back on its status later. The team \
    has no other context, so put everything they need into `brief`.
    """

    private static let parameterSchema = parameters(allowGeneration: true, omitIsViable: true)

    /// The `team_id` param description varies with what is actually valid for this folder:
    /// the `"generated"` sentinel is mentioned only when generation is allowed, and the
    /// "omit it" clause only when the active team can actually receive a task. Advertising
    /// either while the runtime refuses it is advertise-then-reject.
    private static func parameters(allowGeneration: Bool, omitIsViable: Bool) -> JSONSchema {
        var teamIDDescription = "A team id from the catalog in this description"
        if allowGeneration { teamIDDescription += ", or \"generated\" to assemble a new team" }
        teamIDDescription += omitIsViable ? ". Omit to use the folder's active team." : "."
        return JS.object(
            properties: [
                "title": JS.string("Short task title."),
                "brief": JS.string("Self-contained description of what the team should produce, including paths/constraints."),
                "team_id": JS.string(teamIDDescription),
            ],
            required: ["title", "brief"]
        )
    }

    /// Per-build schema embedding the team catalog inline (same pattern as
    /// `delegate_to_team`). The manager has no other way to discover team ids.
    ///
    /// The `policy` gates both halves of the catalog: `blockedTeamIDs` filters the bullets
    /// (via `selectableTeams(from:)`, so this list and the Settings card can never disagree),
    /// and `allowGeneration` gates the `"generated"` bullet AND the `team_id` description, so
    /// the model never sees an option the runtime would refuse. Runtime enforcement lives in
    /// `AutovisorTeamPolicy.classify` (defense in depth).
    ///
    /// `create_managed_task` is NEVER stripped when the catalog is empty, unlike the
    /// `delegate_to_team` pack: it is in `managerMandatoryToolIDs` ("Removing any breaks the
    /// manager") and the manager's prompt names it in three places, so withholding it would
    /// leave the model told by an unstoppable prompt to call a tool that vanished. Instead
    /// the catalog says so outright, and `classify` fails with a terminal message.
    static func buildSchema(
        allTeams: [Team],
        policy: AutovisorTeamPolicy = .unrestricted
    ) -> ToolSchema {
        // Derived, not threaded — at the cost of being APPROXIMATE, deliberately in the
        // conservative direction. A usable active team would itself appear in the catalog, so
        // an empty catalog is strong evidence omitting `team_id` will be refused, and dropping
        // the clause avoids advertise-then-reject in the state that matters (everything
        // blocked). It is not an iff: with a NON-empty catalog the active team can still be
        // chat-mode and be refused (pre-existing, unchanged), and with an EMPTY team list and
        // no active team at all the runtime accepts the omit this description withheld. Both
        // residuals cost at most one wasted turn; threading the active team through the whole
        // resolution chain to close them would re-create the second gate this policy exists to
        // avoid. The runtime message is the precise one.
        let omitIsViable = !policy.hasNoSelectableTeam(in: allTeams)
        var lines: [String] = []
        for team in policy.selectableTeams(from: allTeams) {
            let roleNames = team.nonSupervisorRoles.map(\.name).joined(separator: ", ")
            let descPart = team.description.isEmpty ? "" : ": \(team.description)"
            let rolesPart = roleNames.isEmpty ? "" : ". Roles: \(roleNames)"
            // Chat teams are usable (the manager can close them — unlike a blocking
            // delegate_to_team), but marked so the model knows the task won't finish on
            // its own and it must `control_task close` when done.
            let chatPart = team.isChatMode ? " [chat — open-ended dialog, no deliverables; you must control_task close it]" : ""
            lines.append("- `\(team.id)` — \"\(team.name)\"\(descPart)\(rolesPart)\(chatPart)")
        }
        if policy.allowGeneration {
            lines.append("- `\(DelegationConstants.generatedTeamSentinel)` — assemble a fresh team for a novel task (slower; prefer an existing team when one fits).")
        }
        var catalog = "Available teams:\n" + lines.joined(separator: "\n")
        // Emitted only when BLOCKING is what emptied the catalog. A folder that simply has no
        // non-infrastructure teams keeps the historical bare header, so a default (empty)
        // block list leaves these prompt bytes byte-identical to before this feature.
        if policy.blockingNarrowedCatalog(in: allTeams), lines.isEmpty {
            catalog += "(none — every team in this folder is excluded from Autovisor task creation"
                + (policy.allowGeneration ? "" : ", and team generation is off")
                + "). Report this to your Supervisor and carry on with the rest of the pass."
        }
        return ToolSchema(
            name: TN.createManagedTask,
            description: baseDescription + "\n\n" + catalog,
            parameters: parameters(allowGeneration: policy.allowGeneration, omitIsViable: omitIsViable)
        )
    }

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let brief = try requiredString(args, "brief").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "brief is required and must be non-empty.")
            }
            // Missing/empty/non-string title is a known small-model emission quirk —
            // recover by deriving one from the brief instead of failing the whole
            // creation. Strict String read: `extractString`'s String(describing:)
            // coercion would turn JSON `null` into a literal "<null>" task title.
            let title: String = {
                if let explicit = (args["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !explicit.isEmpty { return explicit }
                let firstLine = brief.components(separatedBy: .newlines).first ?? brief
                let truncated = firstLine.prefix(30)
                return truncated.count < firstLine.count ? String(truncated) + "…" : String(truncated)
            }()
            let teamID = extractString(args, "team_id")
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .createManagedTask(title: title, brief: brief, teamID: teamID)
            )
        }
    }
}

/// `control_task` — task lifecycle verb dispatcher.
nonisolated struct ControlTaskTool: ToolHandler {
    static let name = TN.controlTask
    static let verbs = ControlVerb.actionNames
    static let schema = ToolSchema(
        name: TN.controlTask,
        description: """
        Control a task's lifecycle. `action`:
        - start / pause / resume — run control
        - stop — hard-stop the engine (cascades to any delegated subtasks)
        - close — accept all the task's roles and close it
        - delete — permanently remove it (irreversible; prefer stop/close)
        - rename — set a new title (pass it in `arg`)
        - set_timeout — set per-run timeout in seconds (pass seconds in `arg`; 0 clears)
        You cannot control your own manager task.
        """,
        parameters: JS.object(
            properties: [
                "task_id": JS.integer("The task's id."),
                "action": JS.string("The lifecycle action.", enumValues: verbs),
                "arg": JS.string("New title (rename) or seconds (set_timeout). Ignored otherwise."),
            ],
            required: ["task_id", "action"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let taskID = optionalInt(args, "task_id") else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "task_id is required (integer).")
            }
            // Single decode boundary: string `action` (+ `arg`) → typed `ControlVerb`.
            switch ControlVerb.parse(action: extractString(args, "action") ?? "", arg: extractString(args, "arg")) {
            case .failure(let error):
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs, message: error.message)
            case .success(let verb):
                return ToolExecutionResult(
                    toolName: Self.name,
                    argumentsJSON: encodeArgsToJSON(args),
                    outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                    isError: false,
                    signal: .controlTask(taskID: taskID, verb: verb)
                )
            }
        }
    }
}

/// `manage_role` — role-level verb dispatcher within a task.
nonisolated struct ManageRoleTool: ToolHandler {
    static let name = TN.manageRole
    static let verbs = RoleVerb.actionNames
    static let schema = ToolSchema(
        name: TN.manageRole,
        description: """
        Act on a specific role within a task. `action`:
        - restart — re-runs the role and its downstream dependents from zero, discarding their messages, tool calls and artifacts; `comment` is the only text that survives into the re-run
        - accept — accept a role awaiting acceptance; on a chat-mode task's advisory role this finishes the role and closes the task once no other role is active
        - request_changes — send a role that finished its work back for revision; `comment` = what to change
        - correct — feed mid-run correction to a paused role; `comment` = the correction
        - finish_advisory — finish an advisory (chat) role
        """,
        parameters: JS.object(
            properties: [
                "task_id": JS.integer("The task's id."),
                "role_id": JS.string("The role's id."),
                "action": JS.string("The role action.", enumValues: verbs),
                "comment": JS.string("Guidance / feedback for restart, request_changes, or correct. Draw it from the task's existing brief."),
            ],
            required: ["task_id", "role_id", "action"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let taskID = optionalInt(args, "task_id") else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "task_id is required (integer).")
            }
            let roleID = try requiredString(args, "role_id").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !roleID.isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "role_id is required.")
            }
            // Single decode boundary: string `action` (+ `comment`) → typed `RoleVerb`.
            switch RoleVerb.parse(action: extractString(args, "action") ?? "", comment: extractString(args, "comment")) {
            case .failure(let error):
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs, message: error.message)
            case .success(let verb):
                return ToolExecutionResult(
                    toolName: Self.name,
                    argumentsJSON: encodeArgsToJSON(args),
                    outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                    isError: false,
                    signal: .manageRole(taskID: taskID, roleID: roleID, verb: verb)
                )
            }
        }
    }
}

/// `answer_task_question` — answer a task's pending supervisor question.
nonisolated struct AnswerTaskQuestionTool: ToolHandler {
    static let name = TN.answerTaskQuestion
    static let schema = ToolSchema(
        name: TN.answerTaskQuestion,
        description: "Answer a task's pending supervisor question (status `needsSupervisorInput`). Unblocks and resumes the task.",
        parameters: JS.object(
            properties: [
                "task_id": JS.integer("The waiting task's id."),
                "answer": JS.string("Your answer to the task's supervisor question."),
            ],
            required: ["task_id", "answer"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let taskID = optionalInt(args, "task_id") else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "task_id is required (integer).")
            }
            let answer = try requiredString(args, "answer").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "answer must not be empty.")
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .answerTaskQuestion(taskID: taskID, answer: answer)
            )
        }
    }
}

/// `message_task` — queue a steering message to a running task.
nonisolated struct MessageTaskTool: ToolHandler {
    static let name = TN.messageTask
    static let schema = ToolSchema(
        name: TN.messageTask,
        description: "Send a steering message to a running task (delivered on its next iteration). Optionally target a specific role. Use to nudge or redirect work in progress without stopping it.",
        parameters: JS.object(
            properties: [
                "task_id": JS.integer("The task's id."),
                "message": JS.string("The steering message."),
                "role_id": JS.string("Optional role id to target; omit to address the whole team."),
            ],
            required: ["task_id", "message"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let taskID = optionalInt(args, "task_id") else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "task_id is required (integer).")
            }
            let message = try requiredString(args, "message").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "message must not be empty.")
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .messageTask(taskID: taskID, text: message, roleID: extractString(args, "role_id"))
            )
        }
    }
}

/// `schedule_task` — set a task's review recurrence to a fixed interval.
nonisolated struct ScheduleTaskTool: ToolHandler {
    static let name = TN.scheduleTask
    static let schema = ToolSchema(
        name: TN.scheduleTask,
        description: "Make a task recur on a fixed interval (minimum 1 minute).",
        parameters: JS.object(
            properties: [
                "task_id": JS.integer("The task's id."),
                "interval_minutes": JS.integer("Interval in minutes between runs; 0 clears the schedule."),
            ],
            required: ["task_id", "interval_minutes"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let taskID = optionalInt(args, "task_id") else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "task_id is required (integer).")
            }
            guard let minutes = optionalInt(args, "interval_minutes"), minutes >= 0 else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "interval_minutes is required (>= 0; 0 clears).")
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .scheduleTask(taskID: taskID, intervalMinutes: minutes)
            )
        }
    }
}

/// `set_work_folder_context` — replace the folder-wide shared context.
nonisolated struct SetWorkFolderContextTool: ToolHandler {
    static let name = TN.setWorkFolderContext
    static let schema = ToolSchema(
        name: TN.setWorkFolderContext,
        description: "Replace the shared Work Folder Context — a project description (purpose, conventions, architecture, current state) injected into EVERY role's prompt on EVERY task. Write only durable facts about the project so all future work is better grounded. Worker roles read this and do NOT share your tools or Supervisor role — never include your own review-pass steps, role guidance, or tool names here.",
        parameters: JS.object(
            properties: ["content": JS.string("The full replacement text.")],
            required: ["content"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Every sibling text field (`brief`, `answer`, `message`, `role_id`) trims and
            // rejects empty. This one did not — and what it writes is injected into every
            // role's prompt on every task in the folder, so an accidental empty emission
            // silently wiped it.
            // Validated on the trimmed value, CARRIED verbatim: the folder context is
            // prose whose leading and trailing structure is the author's.
            let content = try requiredString(args, "content")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "content must not be empty — it replaces the work-folder context for every role.")
            }
            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .setWorkFolderContext(content: content)
            )
        }
    }
}

/// `wait_for_events` — end the current review pass and go idle (parked, session
/// preserved). A Supervisor message continues this same conversation; task events and
/// the schedule start a fresh pass instead.
nonisolated struct WaitForEventsTool: ToolHandler {
    static let name = TN.waitForEvents
    static let schema = ToolSchema(
        name: TN.waitForEvents,
        description: "End this review pass and go idle. A message from your Supervisor continues this conversation; task events and the schedule start a fresh pass.",
        parameters: JS.object(properties: [:], required: [])
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: .waitForEvents
            )
        }
    }
}
