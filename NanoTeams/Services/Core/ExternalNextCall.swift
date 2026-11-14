import Foundation

/// The call an external agent is told to make after a refusal — every refusal, by construction.
///
/// The server's instructions say "Refused calls and errors carry a next suggestion; follow it."
/// Until 2026-11-12 (F6 L1/T2) that held on the read surface alone: `NOT_OWNER` named no call by
/// design, and `FOLDER_CHANGED`, the folder states, `schedule_task`'s and `set_timeout`'s
/// `INVALID_ARGS`, `LIMIT_REACHED` on create, `RATE_LIMITED` and every argument refusal the shared
/// decoder writes went out with none. Two things close it:
/// - a site that knows the right call names a case here (`hint(after:taskID:)`);
/// - the exit seam (`ensuringNext`) gives a refusal that still carries none the case its CODE
///   answers (`fallback(for:taskID:)`), so no site can forget. The switch over `ToolErrorCode` has
///   no `default`: a new code is a compile error until someone decides what follows it.
///
/// The reasons are one place, registered (`RuntimePromptRegistry`, `.externalAgent`): until
/// 2026-11-12 about thirty were inline literals in the handlers (T4), three of them spelling
/// "Work folder changed; check folder status." and none in the fingerprint.
nonisolated enum ExternalNextCall: String, CaseIterable, Sendable {
    /// `FOLDER_CHANGED`: the folder the call began in is no longer open.
    case folderChanged
    /// A missing or wrong `folder_id`.
    case folderID
    /// The folder is opening, open in another NanoTeams, or not open at all.
    case folderNotReady
    /// `AUTOVISOR_OFF`.
    case autovisorOff
    /// A task id that names nothing, or none given.
    case taskIDs
    /// `REQUEST_IN_PROGRESS`.
    case requestInProgress
    /// `LIMIT_REACHED` on create.
    case limitReached
    /// `TEAM_REFUSED`.
    case teams
    /// `NOT_OWNER`: `task_status` answers for any task in the folder.
    case foreignTask
    /// `ROLE_NOT_FOUND`.
    case roles
    /// A `schedule_task` refusal, or a schedule that did not land.
    case schedule
    /// A `set_timeout` value at or below the age of a run still going.
    case timeout
    /// `COMMAND_FAILED` on a task.
    case taskState
    /// `COMMAND_FAILED` with no task.
    case folderState
    /// `NOT_WAITING`.
    case whoSpoke
    /// `PAUSED_BY_PERSON`: the person lifts their pause, and the agent hears it as `resumed`. The
    /// refused call carries no cursor, so the hint names none — the agent's own goes on.
    case personsResume
    /// `NOT_ALLOWED`: only the person grants the call. The hint names the refused tool again, after
    /// the asking, with the folder it was refused in; nothing else the call sent was read yet, so
    /// its reason promises no outcome.
    case personMustAllow
    /// `CONFLICT` on `set_work_folder_context`: the text was replaced after the agent read it.
    case currentContext
    /// `task_changes` could not read the pass.
    case passLog
    /// An artifact file that could not be read.
    case deliverableLog
    /// `ARTIFACT_NOT_FOUND`, a missing name, a path that is not the task's.
    case artifacts
    /// `PERMISSION_DENIED`: `task_changes` does not read a protected folder.
    case protectedFolder
    /// A `round` that is not a round of the latest run.
    case currentRound
    /// A `page` below 1.
    case firstPage
    /// `wait_for_events` with a `timeout_seconds` out of range.
    case waitTimeout
    /// A tool name the server does not publish — the one refusal whose own tool cannot be named
    /// again (`fixArgument` would send the agent back to the name it got wrong).
    case unknownTool
    /// `INVALID_ARGS` with nothing better to say: the same call, the argument fixed.
    case fixArgument
    /// An argument the published schema does not declare.
    case dropUndeclared
    /// `RATE_LIMITED`.
    case afterRateLimit
    /// `CANCELLED`, `COMMAND_TIMED_OUT`: nothing happened, and the call may be made again.
    case retry

    /// The tool the hint names, or `nil` for the refused tool itself.
    var command: String? {
        switch self {
        case .folderChanged, .folderID, .folderNotReady, .autovisorOff, .folderState, .unknownTool,
             .currentContext:
            ExternalAutovisorToolNames.folderStatus
        case .taskIDs, .requestInProgress, .limitReached:
            ExternalAutovisorToolNames.listTasks
        case .teams:
            ExternalAutovisorToolNames.listTeams
        case .foreignTask, .roles, .schedule, .timeout, .taskState:
            ExternalAutovisorToolNames.taskStatus
        case .whoSpoke, .passLog, .deliverableLog:
            ExternalAutovisorToolNames.taskLog
        case .artifacts, .protectedFolder:
            ExternalAutovisorToolNames.taskResult
        case .currentRound, .firstPage:
            ExternalAutovisorToolNames.taskChanges
        case .waitTimeout, .personsResume:
            ExternalAutovisorToolNames.waitForEvents
        case .fixArgument, .dropUndeclared, .afterRateLimit, .retry, .personMustAllow:
            nil
        }
    }

    /// runtime-prompt
    ///
    /// What the named call returns or why it is the one to make — never a default value, and
    /// never what the agent's own tool list already says.
    var reason: String {
        switch self {
        case .folderChanged:
            "Returns the folder open now with its folder_id; the message says what this call did before the change."
        case .folderID:
            "Returns the open folder's id and path."
        case .folderNotReady:
            "Says when the folder is ready again; the message says what has to happen first."
        case .autovisorOff:
            "Shows what switched the Autovisor off and when, to tell the person."
        case .taskIDs:
            "Lists the open folder's tasks with their ids, yours marked mine."
        case .requestInProgress:
            "Its task appears there with this request_key once it is created."
        case .limitReached:
            "Lists your running and open tasks: closing one frees a running or open slot, while a spent creation window reopens only at details.retry_at."
        case .teams:
            "Lists the teams a task may run on in this folder."
        case .foreignTask:
            "Answers for any task in this folder; for one that is not yours, what belongs to its owner is left out."
        case .roles:
            "Lists the task's roles with their role_id and status."
        case .schedule:
            "Reads back the schedule the task has now; send one kind of schedule with the fields the message names."
        case .timeout:
            "Shows how long the run has been going; a new timeout must be longer than that."
        case .taskState:
            "Shows the task's state now; the message says what failed."
        case .folderState:
            "Shows the folder's readiness now; the message says what failed."
        case .whoSpoke:
            "Its from names who answered or spoke last."
        case .personsResume:
            "A resumed event by the person comes when they lift their pause; pass the cursor your last wait returned."
        case .personMustAllow:
            "Only the person can allow it; ask them, then call it again."
        case .currentContext:
            "Returns the work folder context as it stands now with its revision; start from that text."
        case .passLog:
            "Shows what the team did in this pass, which task_changes could not read."
        case .deliverableLog:
            "Shows what the team did, errors while writing the deliverable included."
        case .artifacts:
            "Lists the task's deliverables and artifacts by name, with their paths."
        case .protectedFolder:
            "Lists the files the team wrote with its file tools; task_changes does not read a protected folder."
        case .currentRound:
            "Without round it reads the current round of the latest run."
        case .firstPage:
            "Pages count from 1."
        case .waitTimeout:
            "timeout_seconds runs from 0 to \(HostedMCPConstants.maxWaitSeconds)."
        case .unknownTool:
            "The tools this server answers are the ones tools/list publishes; folder_status begins a session."
        case .fixArgument:
            "Call it again with the argument the message names corrected."
        case .dropUndeclared:
            "Call it again with each value sent under one of the arguments the message lists, or without it."
        case .afterRateLimit:
            "Call it again once details.retry_after_ms has passed."
        case .retry:
            "Nothing was done; the same call may be made again."
        }
    }

    /// The hint after a refusal of `tool`. `taskID` is the task the site resolved; `call` is the
    /// refused call's own arguments, of which the hint sends again what its case carries
    /// (`carriedArguments`) and its target declares — minus `correcting`, the arguments the
    /// refusal is about. Every argument is written as text; `HostedMCPNextHintCompletion` then
    /// types it as the hosted schema does and adds the folder the call proved.
    ///
    /// Until 2026-11-12 (E1 review R1, R4, R5, R8) a hint carried `task_id` at most, so an agent
    /// that followed one dropped its cursor (`after`), its `task_ids` or its `round` and read
    /// something other than what it had asked for.
    func hint(
        after tool: String, taskID: Int? = nil, call: [String: Any] = [:], correcting: Set<String> = []
    ) -> NextHint {
        let target = command ?? tool
        let carried = carriedArguments.subtracting(correcting)
        var args: [String: String] = [:]
        if let task = taskID ?? (carried.contains(Self.taskIDKey) ? optionalInt(call, Self.taskIDKey) : nil),
           Self.declares(target, Self.taskIDKey) {
            args[Self.taskIDKey] = "\(task)"
        }
        for key in carried where key != Self.taskIDKey && Self.declares(target, key) {
            if let value = Self.text(of: call[key]) { args[key] = value }
        }
        switch self {
        case .firstPage:
            args["page"] = "1"
        case .waitTimeout:
            args["timeout_seconds"] = "\(HostedMCPConstants.defaultWaitSeconds)"
        default:
            break
        }
        return NextHint(suggested_cmd: target, suggested_args: args.isEmpty ? nil : args, reason: reason)
    }

    /// The hint of a case that names its own tool — every case but the five that name the refused
    /// tool again, which take `hint(after:taskID:call:correcting:)`.
    func hint(taskID: Int? = nil, call: [String: Any] = [:], correcting: Set<String> = []) -> NextHint {
        assert(command != nil, "\(self) repeats the refused call: name it with hint(after:taskID:)")
        return hint(after: command ?? "", taskID: taskID, call: call, correcting: correcting)
    }

    /// The arguments that say WHERE a call reads — which task, which round, which events after
    /// which cursor. An agent that repeats the call has to send them again, so a hint that names
    /// the same tool carries them; a hint for another tool carries the task alone.
    static let placeArguments: Set<String> = ["task_id", "round", "after", "before", "task_ids"]

    /// What of the refused call this case's hint sends again. A call nothing judged (the rate
    /// limit, a cancel, a timeout) is sent back with its own `folder_id` too: the hint is that
    /// call, and the folder is the agent's, not one the app vouches for. `currentRound` drops the
    /// round on purpose — its reason says so.
    var carriedArguments: Set<String> {
        switch self {
        case .afterRateLimit, .retry:
            Self.placeArguments.union([Self.folderIDKey])
        case .dropUndeclared, .waitTimeout, .firstPage, .fixArgument:
            Self.placeArguments
        case .currentRound:
            Self.placeArguments.subtracting(["round"])
        case .folderChanged, .folderID, .folderNotReady, .autovisorOff, .taskIDs, .requestInProgress,
             .limitReached, .teams, .foreignTask, .roles, .schedule, .timeout, .taskState, .folderState,
             .whoSpoke, .personsResume, .passLog, .deliverableLog, .artifacts, .protectedFolder, .unknownTool,
             .currentContext:
            [Self.taskIDKey]
        // The refused tool again, with its folder and place: a hint copies only what the target
        // declares of these, so `set_work_folder_context`'s carries `folder_id` alone, and its
        // `content` and `expected_revision` are the agent's to send again.
        case .personMustAllow:
            Self.placeArguments.union([Self.folderIDKey])
        }
    }

    /// The call that follows a refusal by its code, for a site that named none. Exhaustive on
    /// purpose: a new `ToolErrorCode` does not compile until it is given one. `taskIDMissing`:
    /// the refused tool requires a task and the call named none it can read — then the argument
    /// to fix is one the agent has to look up, and `list_tasks` is where (E1 review R3: until
    /// 2026-11-12 the four write tools sent it back to the same call without one).
    static func fallback(for code: ToolErrorCode, taskID: Int?, taskIDMissing: Bool = false) -> ExternalNextCall {
        switch code {
        case .invalidArgs: taskIDMissing ? .taskIDs : .fixArgument
        case .folderChanged: .folderChanged
        case .autovisorOff: .autovisorOff
        case .taskNotFound: .taskIDs
        case .notOwner: .foreignTask
        case .limitReached: .limitReached
        case .artifactNotFound: .artifacts
        case .roleNotFound: .roles
        case .notWaiting: .whoSpoke
        case .pausedByPerson: .personsResume
        case .notAllowed: .personMustAllow
        case .teamRefused: .teams
        case .requestInProgress: .requestInProgress
        case .snapshotsUnavailable: .passLog
        case .permissionDenied: .protectedFolder
        case .rateLimited: .afterRateLimit
        case .cancelled, .commandTimedOut: .retry
        // `COMMAND_FAILED`, and the codes only the in-app tools return: what stands now, of the
        // task the call named or of the folder.
        case .commandFailed, .fileNotFound, .notAFile, .notADirectory, .rangeOutOfBounds,
             .anchorNotFound, .anchorAmbiguous, .patchApplyFailed, .conflict, .delegationDenied,
             .delegationTimedOut, .delegationInterrupted, .bashDenied, .computerUseDenied,
             .approvalUnavailable, .questionnaireRequired, .mcpToolError, .mcpTimedOut,
             .mcpServerUnavailable, .mcpDenied, .mcpJudgeUnavailable:
            taskID == nil ? .folderState : .taskState
        }
    }

    /// `result` as it leaves for the agent: a refusal that names no next call gets the one its
    /// code answers; anything else comes back exactly as it went in. The envelope is rewritten
    /// through `JSONValue`'s canonical rendering — the bytes the wire encoder writes — which is
    /// safe on a refusal, whose members carry no order of their own.
    static func ensuringNext(_ result: ToolExecutionResult, toolName: String, args: [String: Any]) -> ToolExecutionResult {
        guard result.isError,
              case .object(var envelope)? = JSONValue(json: result.outputJSON),
              case .object(let error)? = envelope["error"],
              envelope["next"]?.isNull ?? true
        else { return result }
        let taskID = optionalInt(args, taskIDKey)
        let code = error["code"]?.stringValue.flatMap(ToolErrorCode.init(rawValue:)) ?? .commandFailed
        let taskIDMissing = taskID == nil && requires(toolName, taskIDKey)
        let hint = fallback(for: code, taskID: taskID, taskIDMissing: taskIDMissing)
            .hint(after: toolName, taskID: taskID, call: args)
        var hintObject: [String: JSONValue] = [:]
        if let command = hint.suggested_cmd { hintObject["suggested_cmd"] = .string(command) }
        if let args = hint.suggested_args { hintObject["suggested_args"] = .object(args.mapValues(JSONValue.string)) }
        if let reason = hint.reason { hintObject["reason"] = .string(reason) }
        envelope["next"] = .object(hintObject)
        var delivered = result
        delivered.outputJSON = JSONValue.object(envelope).canonicalJSONString()
        return delivered
    }

    private static let taskIDKey = "task_id"
    private static let folderIDKey = "folder_id"

    private static func schema(of tool: String) -> JSONSchema? {
        HostedMCPCatalog.allTools.first { $0.name == tool }?.inputSchema
    }

    private static func declares(_ tool: String, _ argument: String) -> Bool {
        schema(of: tool)?.declaredArgumentNames.contains(argument) ?? false
    }

    private static func requires(_ tool: String, _ argument: String) -> Bool {
        schema(of: tool)?.required?.contains(argument) ?? false
    }

    /// An argument as a hint writes it: a string as it came, a number as its digits, a list as
    /// its JSON text — `nil` for an absent or `null` value, or one no hint can spell.
    private static func text(of value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let string as String:
            return string
        case let list as [Any]:
            guard JSONSerialization.isValidJSONObject(list),
                  let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
            else { return nil }
            return String(data: data, encoding: .utf8)
        default:
            return optionalInt(["v": value as Any], "v").map { "\($0)" }
        }
    }
}
