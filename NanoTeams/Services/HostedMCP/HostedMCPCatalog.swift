import Foundation

/// Static catalog of the MCP tools NanoTeams exposes to external Autovisor agents (§8.1).
///
/// Invariants:
/// - Exposes the tools of `ExternalAutovisorToolNames.all`.
/// - Every schema uses `JSONSchema` with nesting depth <= 3 (`CLAUDE.md` #46).
/// - `annotations.readOnlyHint` is `true` for read operations and `wait_for_events`, and `false`
///   for write operations; `openWorldHint` is never set.
/// - `_meta["anthropic/maxResultSizeChars"]` is attached only to `read_artifact` (500 000) and
///   `task_changes` (250 000).
nonisolated enum HostedMCPCatalog: Sendable {

    nonisolated struct ToolDescriptor: Sendable, Equatable {
        let name: String
        let title: String
        let description: String
        let inputSchema: JSONSchema
        let readOnlyHint: Bool
        let maxResultSizeChars: Int?

        var wireJSON: JSONValue {
            var dict: [String: JSONValue] = [
                "name": .string(name),
                "title": .string(title),
                "description": .string(description),
                "inputSchema": Self.encodeSchema(inputSchema),
                "annotations": .object([
                    "readOnlyHint": .bool(readOnlyHint),
                ]),
            ]
            if let maxResultSizeChars {
                dict["_meta"] = .object([
                    "anthropic/maxResultSizeChars": .int(maxResultSizeChars),
                ])
            }
            return .object(dict)
        }

        private static func encodeSchema(_ schema: JSONSchema) -> JSONValue {
            guard let data = try? JSONEncoder().encode(schema),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
            else {
                return .object(["type": .string("object")])
            }
            return decoded
        }
    }

    static let toolNames: [String] = ExternalAutovisorToolNames.all

    static let readOnlyToolNames: Set<String> = [
        ExternalAutovisorToolNames.folderStatus,
        ExternalAutovisorToolNames.listTeams,
        ExternalAutovisorToolNames.listTasks,
        ExternalAutovisorToolNames.taskStatus,
        ExternalAutovisorToolNames.waitForEvents,
        ExternalAutovisorToolNames.taskResult,
        ExternalAutovisorToolNames.readArtifact,
        ExternalAutovisorToolNames.taskLog,
        ExternalAutovisorToolNames.taskChanges,
    ]

    static func isReadOnlyTool(_ name: String) -> Bool {
        readOnlyToolNames.contains(name)
    }

    /// The refusal for a call that sent an argument `toolName`'s published schema does not
    /// declare, or `nil`. Refused by name rather than dropped: until 2026-11-09 each operation
    /// read the keys it knew and an undeclared one vanished, so an agent that misspelled an
    /// argument got the call it did not ask for under `ok:true` — the defect the in-app tools
    /// close with `ToolArgumentVocabulary`. `nil` for a name the catalog does not publish (the
    /// dispatcher answers that itself).
    /// The tools that CHECK a `folder_id` their published schema does not declare — the
    /// session key the server's instructions ask an agent to carry (`validateActiveFolderID`
    /// with `required: false`). Anywhere else an undeclared `folder_id` is refused like any key:
    /// `folder_status` and `wait_for_events` never read it, so accepting it there would drop it
    /// in silence — a stale id after `folder_changed` waited on the current folder unremarked.
    private static let toolsCheckingAnUnpublishedFolderID: Set<String> = [
        ExternalAutovisorToolNames.listTeams, ExternalAutovisorToolNames.listTasks,
    ]
    private static let folderIDKey = "folder_id"

    static func undeclaredArgumentsRefusal(toolName: String, args: [String: Any]) -> ToolExecutionResult? {
        guard let tool = allTools.first(where: { $0.name == toolName }) else { return nil }
        let declared = tool.inputSchema.declaredArgumentNames
        let accepted = toolsCheckingAnUnpublishedFolderID.contains(toolName) ? declared.union([folderIDKey]) : declared
        let unknown = args.keys.filter { !accepted.contains($0) && !(args[$0] is NSNull) }.sorted()
        guard !unknown.isEmpty else { return nil }
        return makeErrorResult(
            toolName: toolName, args: args, code: .invalidArgs,
            message: ToolArgumentVocabulary.unknownArgumentsMessage(
                tool: toolName, keys: unknown, accepted: declared.sorted()),
            next: ExternalNextCall.dropUndeclared.hint(after: toolName, call: args))
    }

    /// The input schema of `toolName` as the agent reads it beside the description — every
    /// property's description and bounds — as JSON with sorted keys, so the external fingerprint
    /// covers that wording too (it did not until 2026-11-07).
    /// runtime-prompt
    static func inputSchemaText(for toolName: String) -> String {
        guard let tool = allTools.first(where: { $0.name == toolName }) else { return "(unknown tool)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(tool.inputSchema)).flatMap { String(data: $0, encoding: .utf8) } ?? "(unencodable)"
    }

    /// runtime-prompt
    static func toolDescription(for toolName: String) -> String {
        switch toolName {
        case ExternalAutovisorToolNames.folderStatus:
            return "Inspect the active work folder in NanoTeams: folder_id, filesystem path, readiness state, active driver, agent identity, local LLM status, goal, read-only memory, creation and concurrency limits, unattended approval availability by family, event cursor, and server version. Each family's availability says what runs with nobody to approve it, though a deny rule or the Auto judge may refuse a call: available — everything; read_only_and_allow_rules (bash) — read-only commands and those an allow_rules entry covers unless an ask rule matches, any other refused APPROVAL_UNAVAILABLE; read_only_unattended (computer_use) — the read-only actions; withheld — nothing, with a reason and what_the_person_must_do. Under approvals.mcp.servers, a server's cross_server_transfer is what happens to a call to it from a step that already used another server: auto — judged without a person, APPROVAL_UNAVAILABLE — refused. readiness.changed_by and readiness.since say what last switched the Autovisor on or off — person, auto_off or deleted — and when. llm.reachable absent means the local model server is not yet probed, false means it is down and no team here can run a step — check it before handing work off. work_folder_context is the text that rides every role's system prompt on a team whose reads_work_folder_context is true, with the instruction files injected into it and the ones a role only sees listed; stale true means project files changed since it was written: read it before writing a brief, so you neither repeat what the team has nor assume a convention it was never given. auto_off is the inactivity deadline — it counts from the end of your last call, a wait still in progress counts as activity, and when it fires every write is refused until a person turns the Autovisor back on. xcode_scheme absent means no role holds the build or test tools. event_cursor marks the end of the event feed as of this call: waiting from it yields only events after now, so a question or review already standing is not among them."
        case ExternalAutovisorToolNames.listTeams:
            return "List all teams selectable for managed tasks in the active work folder, including each team's id, name, description, chat_mode, deliverables, model, roles with their tools, supervisor_mode, acceptance_mode, delegation flag, and whether automatic team generation is allowed. chat_mode true means the team has no deliverables and its roles keep answering until someone ends the task. supervisor_mode: manual routes questions to you (autonomous mode does not answer in your place under the external Autovisor, routing to you as well), off withholds the asking tools so no role can reach anyone. acceptance_mode says how often a role's output stops for a decision. reads_work_folder_context false means the team's roles never see the work folder context, so a brief for that team carries the project facts itself."
        case ExternalAutovisorToolNames.listTasks:
            return "List all top-level tasks in the active work folder with each task's id, title, status, chat_mode, origin, ownership flag (mine), request_key on your own, updated_seconds_ago, waiting_for_supervisor, pending_question_count and roles_awaiting_acceptance. status is one of running, waiting, question, acceptance_gate, review, paused, failed or closed — the names the events use; acceptance_gate means a role waits for you to accept its work or request changes. chat_mode true means the task runs on a team with no deliverables and will not finish on its own. next_run_at is present only while a schedule is armed."
        case ExternalAutovisorToolNames.taskStatus:
            return "Inspect one top-level task in the active work folder, yours or another's: status, chat_mode, origin, ownership flag (mine), request_key when it is yours, elapsed_seconds, steps, pending supervisor questions with role_id, queued_messages not yet delivered, and absolute paths of produced deliverables. status is one of running, waiting, question, acceptance_gate, review, paused, failed or closed. Each step names its role_id, status (pending, running, paused, question, acceptance_gate, failed or done), model, and phase (planning or implementation) for a role that plans first; llm_retry is what the model server last failed with while the role retries, and awaiting_approval is a command or action held for a person's Allow or Deny — nothing you can answer, so tell the person. elapsed_seconds stops when the run's work does. chat_mode true means the task has no deliverables and will not finish on its own. Everything here describes run_id, the latest of run_count runs — a schedule fire appends another, so an earlier run's deliverables and transcript are not reachable from here. pause_reason says WHY a paused task is paused — by_person, by_agent, timed_out, iteration_limit or recovered — and each needs a different remedy. recurrence reads the schedule back — next_run_at while it is armed, last_run_at when it last started a run — and enabled false after you set one means the rule resolved to no future occurrence and disabled itself. A step's delegated_task_id means that role is waiting on another team's task, not stalled. round_summary covers the run's current pass: round, tool_error_count with tool_errors, and bash_runs, each command with its exit_code and outcome. For another's task awaiting_approval carries only its kind, and round_summary only round, bash_run_count and tool_error_count."
        case ExternalAutovisorToolNames.createManagedTask:
            return "Create a new task owned by this agent in the active work folder. Execution begins asynchronously in the background. Repeating schedules start immediately; a one-shot scheduled task waits for its time and does not start right away. A one-shot occurrence missed because a run was active is dropped."
        case ExternalAutovisorToolNames.controlTask:
            return "Drive a task created by this agent through its lifecycle. The watchdog monitors runs in running or waiting for input. A pause the person made (pause_reason by_person) only they can lift: resume and start refuse it with PAUSED_BY_PERSON and change nothing."
        case ExternalAutovisorToolNames.manageRole:
            return "Act on one role inside a task created by this agent."
        case ExternalAutovisorToolNames.answerTaskQuestion:
            return "Reply to a waiting supervisor question on a task created by this agent."
        case ExternalAutovisorToolNames.messageTask:
            return "Send supervisor guidance to a task created by this agent. Queues for the next iteration when running, delivers as an answer when waiting for input, resumes the same run when paused — except a pause the person made, where it waits for their resume — or starts the task when not yet started."
        case ExternalAutovisorToolNames.scheduleTask:
            return "Set or remove a recurring or one-shot schedule on a task created by this agent."
        case ExternalAutovisorToolNames.setWorkFolderContext:
            return "Replace the whole work_folder_context of the active work folder. The person allows this for each agent; until they do, every call is refused and nothing changes. The text rides the system prompt of every role on a team whose reads_work_folder_context is true, on every task in this folder, the person's tasks included; a role reads all of it when its step starts and keeps that version for the rest of the step, so keep it to what every task needs. Write the durable facts: purpose, conventions, architecture, build and test commands, current state. One task's steps and acceptance criteria belong in that task's brief, and your own notes do not belong here. Start from the current text and keep what is still true in it: the person reads and edits the same text, and no earlier version is kept to restore. Put nothing here from a team's output that you have not checked."
        case ExternalAutovisorToolNames.waitForEvents:
            return "Long-poll for new lifecycle events (question, acceptance_gate, review, failed, paused, stuck, resumed, closed, deleted) on tasks created by this agent. A paused event carries pause_reason — by_person, by_agent, timed_out, iteration_limit or recovered — and they need different remedies. resumed, closed and deleted carry by, person or agent, naming who did it; what you did yourself is never echoed back as an event. A result may also carry cursor_reset_reason (folder_changed, restarted, gap, filter_changed), which makes its events a snapshot of what stands now rather than a delta — snapshot events carry no seq, conditions you already handled can repeat, and a gap loses the events between; or stop_reason (superseded, folder_changed, driver_changed, not_ready, shutting_down), meaning this server ended the wait before its timeout — not_ready says the Autovisor is off, so do not retry it in a loop. On timeout (timed_out: true), returns heartbeat tasks summarizing active watched tasks. A review event carries round_summary with pass metrics and bash command history."
        case ExternalAutovisorToolNames.taskResult:
            return "Read the final outcome of a task created by this agent: begins with the deliverable index (name, role_id, absolute path, byte size), followed by full deliverable contents, missing deliverables, files written by the team, and recent_messages — the latest ten turns of the conversation, each with at, from, kind and text."
        case ExternalAutovisorToolNames.readArtifact:
            return "Read the full UTF-8 text of a named artifact produced inside a task created by this agent, verified to reside under the task's artifact directory."
        case ExternalAutovisorToolNames.taskLog:
            return "Read a task created by this agent as a chronological transcript, without truncating any entry. Each row carries at, from, kind and text. from names who acted — a role by its id, this agent by its name, autovisor for an automated answerer, supervisor for the person at the keyboard — so a turn you did not write is identifiable. kind is one of message, question, answer, supervisor_message, supervisor_feedback, tool_call, meeting, meeting_decision, consultation, change_request, accepted, closed, paused or resumed. A tool_call row is one line: the tool, its arguments abridged, and for a command, a test run or a build its outcome — the exit code and the last line printed, the failures, the errors; a failed or refused call says why. Pages run back from the newest entry: next_before reaches older entries, next_after reads on from where a page ended. Both are moments, not positions, so a restart that clears a role's entries does not move them."
        case ExternalAutovisorToolNames.taskChanges:
            return "Inspect what changed in the active work folder during a pass of a task, even in a folder without version control: every change to a file there, whoever made it — the task's file tools and bash, another task, the person or any other process. NanoTeams' own .nanoteams folder is never read, nor are the places NanoTeams hides from a team's tools. Files ignored by .gitignore, by .git/info/exclude, by the person's global git excludes file or by a repository enclosing the folder are excluded, and not listed, under the rules in place when the pass started: an ignore rule written during the pass hides no file until the next pass — a directory the pass created that it covers is listed in not_tracked instead — and the edited ignore file is itself a change. Embedded repositories and submodules are not compared. Returns changed files with path, change_type, and old_path on renames, plus binary or encoding (not_utf8) on the files whose diffs this result carries; complete unified diffs, in which a byte that is not UTF-8 reads <0xNN> and a hidden character <U+XXXX>, as it does in a path; pagination fields total_pages and has_more; and not_tracked, each entry a path and a reason: embedded_repository, or hidden_by_round_rules for what an ignore rule written during the pass covers and this result does not show: a directory the pass created, with a trailing / and its contents not read, or a file past the limit on such files or that could not be read; when those files are many, their directories are listed instead."
        default:
            return "External Autovisor tool."
        }
    }

    static let allTools: [ToolDescriptor] = [
        ToolDescriptor(
            name: ExternalAutovisorToolNames.folderStatus,
            title: "Folder Status",
            description: toolDescription(for: ExternalAutovisorToolNames.folderStatus),
            inputSchema: JSONSchema.object(
                properties: [
                    "include_context": JSONSchema.boolean(
                        "Pass false to leave the text of the work folder context out of the result."
                    ),
                ],
                required: []
            ),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.listTeams,
            title: "List Teams",
            description: toolDescription(for: ExternalAutovisorToolNames.listTeams),
            inputSchema: JSONSchema.object(properties: [:], required: []),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.listTasks,
            title: "List Tasks",
            description: toolDescription(for: ExternalAutovisorToolNames.listTasks),
            inputSchema: JSONSchema.object(properties: [:], required: []),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.taskStatus,
            title: "Task Status",
            description: toolDescription(for: ExternalAutovisorToolNames.taskStatus),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The top-level task's id."),
                ],
                required: ["folder_id", "task_id"]
            ),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.createManagedTask,
            title: "Create Managed Task",
            description: toolDescription(for: ExternalAutovisorToolNames.createManagedTask),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "brief": JSONSchema.string("Self-contained task specification with scope, files, constraints, and acceptance criteria."),
                    "title": JSONSchema.string("Optional short title. When omitted, derived from the first line of the brief."),
                    "team_id": JSONSchema.string("Optional team id from the folder's team catalog, or 'generated' to assemble a fresh team. When omitted, uses the active team of the work folder."),
                    "attachments": JSONSchema.array(
                        items: JSONSchema.string(),
                        description: "Optional relative file paths inside the work folder to attach."
                    ),
                    "run_timeout_seconds": JSONSchema.integer(
                        "Optional per-run timeout in seconds (0 clears).",
                        minimum: 0
                    ),
                    "repeat_every_minutes": JSONSchema.integer(
                        "Optional interval recurrence in minutes (>= 1).",
                        minimum: 1
                    ),
                    "repeat_daily_at": JSONSchema.string("Optional daily recurrence time in HH:MM (24-hour)."),
                    "repeat_weekdays": JSONSchema.array(
                        items: JSONSchema.integer(minimum: 1, maximum: 7),
                        description: "Optional ISO weekdays (1=Monday ... 7=Sunday) for repeat_daily_at."
                    ),
                    "repeat_monthly_day": JSONSchema.integer(
                        "Optional day of the month (1...31) for monthly recurrence (uses 09:00 if repeat_daily_at is omitted).",
                        minimum: 1,
                        maximum: 31
                    ),
                    "run_once_at": JSONSchema.string("Optional ISO-8601 timestamp for one-shot scheduled execution (interpreted as local time without an offset)."),
                    "request_key": JSONSchema.string("Optional key that makes a retry safe: while a task you created with this key exists, the call returns it instead of creating another, across app restarts too."),
                ],
                required: ["folder_id", "brief"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.controlTask,
            title: "Control Task",
            description: toolDescription(for: ExternalAutovisorToolNames.controlTask),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "action": JSONSchema.string(
                        "Lifecycle verb: start begins execution, pause temporarily halts, resume continues, stop hard-stops the engine (cascades to delegated subtasks), close accepts all roles and completes the task, delete permanently removes it (irreversible; prefer stop or close), rename changes title using arg, set_timeout configures per-run watchdog in timeout_seconds (0 to clear).",
                        enumValues: ControlVerb.actionNames
                    ),
                    "arg": JSONSchema.string("New title for rename."),
                    "timeout_seconds": JSONSchema.integer(
                        "Per-run watchdog timeout in seconds for set_timeout (0 clears). Measured from run start, covering revision rounds and review waiting. A run still going — running, waiting for an answer or paused — refuses a value at or below its elapsed time; a run in review or failed takes any value, and continuing it counts from its start. The reply's timeout carries deadline_at and remaining only for a run still going.",
                        minimum: 0
                    ),
                ],
                required: ["folder_id", "task_id", "action"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.manageRole,
            title: "Manage Role",
            description: toolDescription(for: ExternalAutovisorToolNames.manageRole),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "role_id": JSONSchema.string("The target role's id."),
                    "action": JSONSchema.string(
                        "Role action: restart re-runs the role and downstream dependents from zero, discarding messages, tool calls and artifacts (comment is the only text surviving into the re-run); accept approves output while awaiting acceptance (on chat advisory role, finishes role and closes task once no other role is active); request_changes returns output for revision with required comment; correct steers a paused role with required comment and resumes it, refused while the pause is the person's (by_person); finish_advisory finishes an advisory chat role.",
                        enumValues: RoleVerb.actionNames
                    ),
                    "comment": JSONSchema.string("Required guidance for request_changes and correct; optional guidance for restart (the only text that survives into the re-run)."),
                ],
                required: ["folder_id", "task_id", "role_id", "action"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.answerTaskQuestion,
            title: "Answer Task Question",
            description: toolDescription(for: ExternalAutovisorToolNames.answerTaskQuestion),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The waiting task's id."),
                    "answer": JSONSchema.string("Your answer to the waiting supervisor question. For a structured questionnaire, use the Q1/Q2 grammar shown in the question text."),
                    "role_id": JSONSchema.string("Optional role id when multiple roles have pending questions."),
                ],
                required: ["folder_id", "task_id", "answer"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.messageTask,
            title: "Message Task",
            description: toolDescription(for: ExternalAutovisorToolNames.messageTask),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "message": JSONSchema.string("Supervisor message text to deliver."),
                    "role_id": JSONSchema.string("Optional target role id for chat-mode tasks."),
                ],
                required: ["folder_id", "task_id", "message"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.scheduleTask,
            title: "Schedule Task",
            description: toolDescription(for: ExternalAutovisorToolNames.scheduleTask),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "repeat_every_minutes": JSONSchema.integer(
                        "Optional interval recurrence in minutes (>= 1).",
                        minimum: 1
                    ),
                    "repeat_daily_at": JSONSchema.string("Optional daily recurrence time in HH:MM (24-hour)."),
                    "repeat_weekdays": JSONSchema.array(
                        items: JSONSchema.integer(minimum: 1, maximum: 7),
                        description: "Optional ISO weekdays (1=Monday ... 7=Sunday) for repeat_daily_at."
                    ),
                    "repeat_monthly_day": JSONSchema.integer(
                        "Optional day of the month (1...31) for monthly recurrence (uses 09:00 if repeat_daily_at is omitted).",
                        minimum: 1,
                        maximum: 31
                    ),
                    "run_once_at": JSONSchema.string("Optional ISO-8601 timestamp for one-shot scheduled execution (interpreted as local time without an offset)."),
                    "clear": JSONSchema.boolean("Pass true to remove the task's schedule."),
                ],
                required: ["folder_id", "task_id"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.setWorkFolderContext,
            title: "Set Work Folder Context",
            description: toolDescription(for: ExternalAutovisorToolNames.setWorkFolderContext),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "content": JSONSchema.string("The new text in full."),
                    "expected_revision": JSONSchema.string(
                        "The revision of the work_folder_context you read; a text replaced since then is refused, never overwritten."),
                ],
                required: ["folder_id", "content", "expected_revision"]
            ),
            readOnlyHint: false,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.waitForEvents,
            title: "Wait For Events",
            description: toolDescription(for: ExternalAutovisorToolNames.waitForEvents),
            inputSchema: JSONSchema.object(
                properties: [
                    "after": JSONSchema.string("Opaque event cursor. Omit it on a session's first call, which answers with what already stands; then pass the cursor the previous call returned, so no event is missed."),
                    "task_ids": JSONSchema.array(
                        items: JSONSchema.integer(),
                        description: "Optional subset of this agent's task ids to watch. A cursor returned for these ids resumes them or fewer; with any other task, the call starts over with a snapshot."
                    ),
                    "timeout_seconds": JSONSchema.integer(
                        "Maximum wait duration in seconds (0...\(HostedMCPConstants.maxWaitSeconds)).",
                        minimum: 0,
                        maximum: HostedMCPConstants.maxWaitSeconds
                    ),
                ],
                required: []
            ),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.taskResult,
            title: "Task Result",
            description: toolDescription(for: ExternalAutovisorToolNames.taskResult),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                ],
                required: ["folder_id", "task_id"]
            ),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.readArtifact,
            title: "Read Artifact",
            description: toolDescription(for: ExternalAutovisorToolNames.readArtifact),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "name": JSONSchema.string("Artifact name or filename."),
                    "role_id": JSONSchema.string("Optional producing role id when disambiguating artifacts."),
                ],
                required: ["folder_id", "task_id", "name"]
            ),
            readOnlyHint: true,
            maxResultSizeChars: HostedMCPConstants.readArtifactMaxResultSizeChars
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.taskLog,
            title: "Task Log",
            description: toolDescription(for: ExternalAutovisorToolNames.taskLog),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "role_id": JSONSchema.string("Only this role's entries, and an accept of it."),
                    "before": JSONSchema.integer(
                        "A next_before from an earlier page: the entries recorded before it.",
                        minimum: 1
                    ),
                    "after": JSONSchema.integer(
                        "A next_after from an earlier page: the entries recorded after it.",
                        minimum: 0
                    ),
                    "limit": JSONSchema.integer(
                        "Entries per page, 1 to 200; a page never splits entries recorded in the same millisecond.",
                        minimum: 1,
                        maximum: 200
                    ),
                ],
                required: ["folder_id", "task_id"]
            ),
            readOnlyHint: true,
            maxResultSizeChars: nil
        ),
        ToolDescriptor(
            name: ExternalAutovisorToolNames.taskChanges,
            title: "Task Changes",
            description: toolDescription(for: ExternalAutovisorToolNames.taskChanges),
            inputSchema: JSONSchema.object(
                properties: [
                    "folder_id": JSONSchema.string("The active work folder's id."),
                    "task_id": JSONSchema.integer("The task's id."),
                    "round": JSONSchema.integer(
                        "Optional 1-based index to inspect a specific execution pass. When omitted, inspects the latest pass.",
                        minimum: 1
                    ),
                    "page": JSONSchema.integer(
                        "Optional 1-based number for paginated diff output.",
                        minimum: 1
                    ),
                    "file_path": JSONSchema.string("Optional relative path, as listed in files, to restrict changes and diff to a single file.")
                ],
                required: ["folder_id", "task_id"]
            ),
            readOnlyHint: true,
            maxResultSizeChars: HostedMCPConstants.taskChangesMaxResultSizeChars
        ),
    ]

    static let allToolsWireJSON: [JSONValue] = allTools.map(\.wireJSON)
}
