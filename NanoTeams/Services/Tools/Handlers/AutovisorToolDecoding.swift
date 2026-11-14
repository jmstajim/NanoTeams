import Foundation

/// Failure of `AutovisorToolDecoding.decode`, carrying the ready-to-return `ToolExecutionResult`
/// (with `INVALID_ARGS` envelope in `outputJSON`).
nonisolated struct AutovisorDecodeFailure: Error, Hashable, Sendable {
    let result: ToolExecutionResult

    var outputJSON: String { result.outputJSON }
    var isError: Bool { result.isError }
}

/// Single argument decoding and schema-type validation boundary for Autovisor tools across
/// both surfaces (`.inApp` and `.externalMCP`).
nonisolated enum AutovisorToolDecoding {

    /// The schema a shared Autovisor tool is decoded and type-checked against. The same on both
    /// surfaces since 2026-11-13: `answer_task_question` lost its in-app variant on 2026-11-09 and
    /// `set_work_folder_context` was the last tool absent from `.externalMCP`. What still differs
    /// between the surfaces is decided where the call is decoded (`decode(tool:args:surface:)`)
    /// or by the hosted handler, never by which schema applies.
    static func schema(for tool: String) -> ToolSchema? {
        switch tool {
        case ToolNames.listTasks:
            return ListTasksTool.schema
        case ToolNames.taskStatus:
            return TaskStatusTool.schema
        case ToolNames.createManagedTask:
            return CreateManagedTaskTool.schema
        case ToolNames.controlTask:
            return ControlTaskTool.schema
        case ToolNames.manageRole:
            return ManageRoleTool.schema
        case ToolNames.answerTaskQuestion:
            // One schema for both surfaces since 2026-11-09: the in-app one lacked `role_id`,
            // so the built-in manager's answer to one of several waiting roles went to the first.
            return AnswerTaskQuestionTool.schema
        case ToolNames.messageTask:
            return MessageTaskTool.schema
        case ToolNames.scheduleTask:
            return ScheduleTaskTool.schema
        case ToolNames.setWorkFolderContext:
            // One schema for both surfaces since 2026-11-13, when the person could let an external
            // agent replace the context (decision A3, revised). Whether THIS agent may is the
            // hosted handler's question (`HostedMCPAgentRecord.mayReplaceWorkFolderContext`),
            // asked before anything is decoded.
            return SetWorkFolderContextTool.schema
        case ToolNames.waitForEvents:
            return WaitForEventsTool.schema
        default:
            return nil
        }
    }

    static func decode(
        tool: String,
        rawArgs: String,
        surface: AutovisorSurface = .inApp
    ) -> Result<AutovisorCommand, AutovisorDecodeFailure> {
        let args: [String: Any]
        do {
            args = try ToolRuntime.dispatchedArguments(rawArgs, toolName: tool)
        } catch {
            return .failure(AutovisorDecodeFailure(
                result: ToolErrorHandler.envelope(for: error, toolName: tool, args: [:])
            ))
        }
        return decode(tool: tool, args: args, surface: surface, checkSchemaTypes: true)
    }

    static func decode(
        tool: String,
        args: [String: Any],
        surface: AutovisorSurface = .inApp,
        checkSchemaTypes: Bool = true
    ) -> Result<AutovisorCommand, AutovisorDecodeFailure> {
        guard let toolSchema = schema(for: tool) else {
            return .failure(notOnThisSurface(tool: tool, args: args))
        }

        if checkSchemaTypes {
            let violations = argumentTypeViolations(args: args, schema: toolSchema.parameters)
            if !violations.isEmpty {
                return .failure(AutovisorDecodeFailure(
                    result: makeErrorResult(
                        toolName: tool,
                        args: args,
                        code: .invalidArgs,
                        message: violations.joined(separator: " ") + " Fix the value, or omit the argument."
                    )
                ))
            }
        }

        do {
            switch tool {
            case ToolNames.listTasks:
                return .success(.listTasks)

            case ToolNames.taskStatus:
                let taskID = try requiredInt(args, "task_id")
                return .success(.taskStatus(taskID: taskID))

            case ToolNames.createManagedTask:
                let brief = try requiredNonEmptyString(args, "brief")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Missing/empty title is a known small-model emission quirk — a number arrives
                // here already read as its text (`ToolArgumentVocabulary.readingDeclaredText`) —
                // recover by deriving one from the brief instead of failing the whole
                // creation. Strict String read: `extractString`'s String(describing:)
                // coercion would turn JSON `null` into a literal "<null>" task title.
                let title: String = {
                    if let explicit = (args["title"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !explicit.isEmpty { return explicit }
                    let firstLine = brief.components(separatedBy: .newlines)[0]
                    let truncated = firstLine.prefix(30)
                    return truncated.count < firstLine.count ? String(truncated) + "…" : String(truncated)
                }()
                let teamID = extractString(args, "team_id")
                return .success(.createManagedTask(title: title, brief: brief, teamID: teamID))

            case ToolNames.controlTask:
                let taskID = try requiredInt(args, "task_id")
                let action = extractString(args, "action") ?? ""
                let arg = extractString(args, "arg")
                let timeoutSeconds: Int?
                if surface == .externalMCP {
                    if let raw = args["timeout_seconds"], !(raw is NSNull) {
                        if let intVal = raw as? Int {
                            timeoutSeconds = intVal
                        } else if raw is Double || raw is Float {
                            timeoutSeconds = nil
                        } else if let str = raw as? String, let intVal = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            timeoutSeconds = intVal
                        } else {
                            timeoutSeconds = nil
                        }
                    } else {
                        timeoutSeconds = nil
                    }
                } else {
                    timeoutSeconds = optionalInt(args, "timeout_seconds")
                }
                let rawTimeout = (timeoutSeconds == nil) ? args["timeout_seconds"] : nil
                switch ControlVerb.parse(
                    action: action,
                    arg: arg,
                    timeoutSeconds: timeoutSeconds,
                    rawTimeout: rawTimeout,
                    surface: surface
                ) {
                case .failure(let error):
                    return .failure(AutovisorDecodeFailure(
                        result: makeErrorResult(toolName: tool, args: args, code: .invalidArgs, message: error.message)
                    ))
                case .success(let verb):
                    return .success(.controlTask(taskID: taskID, verb: verb))
                }

            case ToolNames.manageRole:
                let taskID = try requiredInt(args, "task_id")
                let roleID = try requiredNonEmptyString(args, "role_id")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch RoleVerb.parse(action: extractString(args, "action") ?? "", comment: extractString(args, "comment")) {
                case .failure(let error):
                    return .failure(AutovisorDecodeFailure(
                        result: makeErrorResult(toolName: tool, args: args, code: .invalidArgs, message: error.message)
                    ))
                case .success(let verb):
                    return .success(.manageRole(taskID: taskID, roleID: roleID, verb: verb))
                }

            case ToolNames.answerTaskQuestion:
                let taskID = try requiredInt(args, "task_id")
                let answer = try requiredNonEmptyString(args, "answer")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(.answerTaskQuestion(
                    taskID: taskID, answer: answer, roleID: extractString(args, "role_id")))

            case ToolNames.messageTask:
                let taskID = try requiredInt(args, "task_id")
                let message = try requiredNonEmptyString(args, "message")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(.messageTask(taskID: taskID, text: message, roleID: extractString(args, "role_id")))

            case ToolNames.scheduleTask:
                let taskID = try requiredInt(args, "task_id")
                let minutes = try requiredInt(args, "interval_minutes")
                guard minutes >= 0 else {
                    throw ToolArgumentError.invalidValue(
                        key: "interval_minutes",
                        detail: "must be >= 0 minutes; pass 0 to clear the interval."
                    )
                }
                return .success(.scheduleTask(taskID: taskID, intervalMinutes: minutes))

            case ToolNames.setWorkFolderContext:
                let content = try requiredString(args, "content")
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolArgumentError.invalidValue(key: "content", detail: Self.emptyContextDetail)
                }
                return .success(.setWorkFolderContext(content: content))

            case ToolNames.waitForEvents:
                return .success(.waitForEvents)

            default:
                // `schema(for:)` admitted a tool this switch has no case for: the two
                // lists drifted. Loud in DEBUG; in release the call is refused rather than read as
                // another tool — read as `wait_for_events` it would park the manager, and on the
                // external write path it would surface as a folder change that never happened.
                assertionFailure("AutovisorToolDecoding: '\(tool)' has a schema but no decode case")
                return .failure(notOnThisSurface(tool: tool, args: args))
            }
        } catch {
            return .failure(AutovisorDecodeFailure(
                result: ToolErrorHandler.envelope(for: error, toolName: tool, args: args)
            ))
        }
    }

    /// What an empty `set_work_folder_context` is told, after "Argument 'content' ". Shared by
    /// both surfaces since 2026-11-13: the built-in manager and an external agent replace the
    /// same text, and only the person may clear it.
    /// runtime-prompt
    static let emptyContextDetail = "must not be empty — it replaces the whole work-folder context."

    /// The refusal of a tool this surface does not decode — one builder for the schema guard and
    /// the switch's default, so the two can never answer the same name differently.
    private static func notOnThisSurface(tool: String, args: [String: Any]) -> AutovisorDecodeFailure {
        AutovisorDecodeFailure(
            result: makeErrorResult(
                toolName: tool,
                args: args,
                code: .invalidArgs,
                message: "Tool '\(tool)' is not available on this surface. Check the tool list and retry."
            )
        )
    }

    static func decodeToToolResult(
        tool: String,
        args: [String: Any],
        surface: AutovisorSurface = .inApp
    ) -> ToolExecutionResult {
        switch decode(tool: tool, args: args, surface: surface, checkSchemaTypes: false) {
        case .success(let command):
            return ToolExecutionResult(
                toolName: tool,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
                isError: false,
                signal: command.toolSignal
            )
        case .failure(let failure):
            return failure.result
        }
    }
}
