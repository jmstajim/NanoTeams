import XCTest
@testable import NanoTeams

/// The other agent-facing text: the tool descriptions. The connect-time instructions are
/// capped at 4096 characters and sit at ~4088, so a field's MEANING belongs here — and a
/// description may not name a sibling tool (`PromptFormatConventionsTests`), which is why each
/// of these says what its own result means and stops there.
///
/// The rule under all of it is CLAUDE.md #386: a key the agent receives and no text claims
/// arrives as an anonymous JSON key with no direction attached.
final class HostedMCPCatalogTextTests: XCTestCase {

    private func description(_ tool: String) -> String {
        HostedMCPCatalog.toolDescription(for: tool)
    }

    /// `supervisor_mode` was a field name in a comma list. Its three values decide whether the
    /// agent will EVER be asked anything by that team: `manual` routes a role's question to it,
    /// `autonomous` has a local model answer in its place (the default on FAANG, Engineering and
    /// Quest Party — the teams an agent is likeliest to pick), and `off` withholds the asking
    /// tools entirely. In two of the three the agent's event loop stays silent while decisions
    /// are made for it, and it reads that silence as progress.
    func testListTeamsGivesTheMeaningOfSupervisorMode() {
        let d = description(ExternalAutovisorToolNames.listTeams)
        XCTAssertTrue(d.contains("supervisor_mode"), d)
        for value in ["manual", "autonomous", "off"] {
            XCTAssertTrue(d.contains(value), "supervisor_mode value \(value) has no meaning here")
        }
        XCTAssertTrue(
            d.contains("in your place"),
            "`autonomous` answering FOR the agent is the half that surprises it")
    }

    /// `chat_mode` is returned by three tools. Each one's description has to carry it, because an
    /// agent that reached `task_status` never necessarily read `list_teams`.
    func testEveryToolThatReturnsChatModeSaysWhatItMeans() {
        for tool in [
            ExternalAutovisorToolNames.listTeams,
            ExternalAutovisorToolNames.listTasks,
            ExternalAutovisorToolNames.taskStatus,
        ] {
            let d = description(tool)
            XCTAssertTrue(d.contains("chat_mode"), "\(tool) returns chat_mode and never names it: \(d)")
            XCTAssertTrue(
                d.contains("no deliverables"),
                "\(tool) names chat_mode without its consequence: \(d)")
        }
    }

    /// Three fields on a `wait_for_events` result change what the result MEANS, and none of them
    /// is an event: `pause_reason` picks the remedy, `cursor_reset_reason` turns a delta into a
    /// snapshot, `stop_reason` says the server ended the wait early.
    func testWaitForEventsNamesTheThreeFieldsThatAreNotEvents() {
        let d = description(ExternalAutovisorToolNames.waitForEvents)
        for field in ["pause_reason", "cursor_reset_reason", "stop_reason"] {
            XCTAssertTrue(d.contains(field), "\(field) is returned and unnamed: \(d)")
        }
        for value in ["by_person", "iteration_limit", "gap", "not_ready"] {
            XCTAssertTrue(d.contains(value), "value \(value) is unnamed: \(d)")
        }
    }

    /// `task_log`'s rows are not all a role's. `from` was built (D-M15, 2026-11-07) precisely so
    /// the person's own turns are distinguishable from the automated answerer's and the agent's
    /// — and the description described the rows as if every one were a role's.
    func testTaskLogNamesTheAuthorFieldAndEveryKindItReturns() {
        let d = description(ExternalAutovisorToolNames.taskLog)
        XCTAssertTrue(d.contains("from"), d)
        for kind in [
            "message", "supervisor_feedback", "question", "answer", "supervisor_message",
            "tool_call", "meeting", "meeting_decision", "consultation", "change_request",
        ] {
            XCTAssertTrue(d.contains(kind), "task_log emits kind `\(kind)` and never names it")
        }
    }

    /// `llm.reachable` is tri-state on purpose — absent means nobody has probed yet, and
    /// `AppDependencyWiring` keeps it absent rather than reporting a server down before anyone
    /// asked. Both misreads cost: `false` ignored spends a creation slot on a task that cannot
    /// run; absent read as `false` stops the agent working for the first two minutes after launch.
    func testFolderStatusSaysHowToReadReachability() {
        let d = description(ExternalAutovisorToolNames.folderStatus)
        XCTAssertTrue(d.contains("llm.reachable"), d)
        XCTAssertTrue(d.contains("absent"), "the unprobed state is the one that misreads: \(d)")
    }

    /// Wave 3 added fields that answer questions the agent could not ask before. A field added
    /// and left unclaimed is the same defect in a new place, so each is named where it lands.
    func testEveryFieldAddedForTheAgentIsClaimedByItsOwnTool() {
        let status = description(ExternalAutovisorToolNames.folderStatus)
        for field in ["work_folder_context", "auto_off", "xcode_scheme"] {
            XCTAssertTrue(status.contains(field), "folder_status returns \(field) and never names it")
        }
        // Since 2026-11-13: which teams' roles read the context at all (a template without the
        // chip renders none of it), named where the team is.
        XCTAssertTrue(
            description(ExternalAutovisorToolNames.listTeams).contains("reads_work_folder_context"),
            "list_teams returns reads_work_folder_context and never names it")
        // The sleep timer is an INACTIVITY deadline — that is the whole surprise — and since
        // 2026-11-08 it counts from the END of a call, with a wait in progress counting as
        // activity: "from your last request" told an agent parking an hour-long wait that the
        // timer had started when it asked.
        XCTAssertTrue(
            status.contains("counts from the end of your last call"),
            "when the inactivity deadline starts: \(status)")
        XCTAssertTrue(
            status.contains("a wait still in progress counts as activity"),
            "what holds it off: \(status)")
        XCTAssertFalse(status.contains("counts from your last request"), status)

        let task = description(ExternalAutovisorToolNames.taskStatus)
        for field in [
            "run_id", "run_count", "pause_reason", "recurrence", "delegated_task_id", "round_summary",
            "bash_runs", "bash_run_count", "tool_error_count", "tool_errors", "exit_code",
        ] {
            XCTAssertTrue(task.contains(field), "task_status returns \(field) and never names it")
        }
        // Another's task comes back with its held command and its bash commands withheld, and
        // the description says so (F6 S6: it promised "bash command history" for any task).
        XCTAssertTrue(
            task.contains("For another's task awaiting_approval carries only its kind, and round_summary only round, bash_run_count and tool_error_count."),
            task)
        XCTAssertFalse(task.contains("bash command history"), task)
        XCTAssertTrue(
            task.contains("not stalled"),
            "a delegating role LOOKS stalled; saying so is the point: \(task)")

        XCTAssertTrue(description(ExternalAutovisorToolNames.listTasks).contains("next_run_at"))

        let wait = description(ExternalAutovisorToolNames.waitForEvents)
        // The phrase, not the word: "tasks" was in the description before the heartbeat was (F6 T8).
        XCTAssertTrue(
            wait.contains("On timeout (timed_out: true), returns heartbeat tasks"),
            "wait_for_events returns heartbeat tasks on timeout and never names it: \(wait)")
        XCTAssertTrue(
            wait.contains("A review event carries round_summary"),
            "wait_for_events returns round_summary on a review event and never names it: \(wait)")

        let changes = description(ExternalAutovisorToolNames.taskChanges)
        for field in [
            "change_type", "total_pages", "has_more", "not_tracked", "old_path", "binary", "encoding",
            TaskSnapshotService.notUTF8Encoding,
            TaskSnapshotService.NotTrackedPath.embeddedRepository,
            TaskSnapshotService.NotTrackedPath.hiddenByRoundRules,
        ] {
            XCTAssertTrue(changes.contains(field), "task_changes returns \(field) and never names it")
        }
        XCTAssertTrue(
            changes.contains("with a trailing / and its contents not read"),
            "a directory hidden by a rule of the pass is one unread entry, and the agent must know it: \(changes)")
    }

    /// The rule that derives a pause's reason moved out of the feed's pause builder (now
    /// `standingPause`) so `task_status` answers the same question the same way — an agent that
    /// reconnects reads status rather than replaying the event. Two callers, one rule; the
    /// boundary worth pinning is the new one, a task that is not paused at all.
    func testPauseReasonResolvesToNothingWhenTheTaskIsNotPaused() {
        XCTAssertNil(AutovisorPauseReason.resolve(
            run: nil, taskStatus: .running, isPaused: false, liveIterationLimitPause: false))
        XCTAssertEqual(
            AutovisorPauseReason.resolve(
                run: nil, taskStatus: .running, isPaused: false, liveIterationLimitPause: true),
            .iterationLimit,
            "the engine's live flag stands on its own — the latch has not been armed yet")
        XCTAssertEqual(
            AutovisorPauseReason.resolve(
                run: nil, taskStatus: .paused, isPaused: true, liveIterationLimitPause: false),
            .recovered,
            "a run with no recorded cause falls to the latch")
    }

    // MARK: - A description says what the tool does; its inputs say what they take

    private func tool(_ name: String) throws -> HostedMCPCatalog.ToolDescriptor {
        try XCTUnwrap(HostedMCPCatalog.allTools.first { $0.name == name }, name)
    }

    private func property(_ name: String, of toolName: String) throws -> String {
        let schema = try tool(toolName).inputSchema
        return try XCTUnwrap(schema.properties?[name]?.description, "\(toolName).\(name)")
    }

    /// Every property text an agent reads: each input's own description and, for an array, its
    /// items'.
    private func propertyTexts() -> [(label: String, text: String)] {
        HostedMCPCatalog.allTools.flatMap { tool in
            (tool.inputSchema.properties ?? [:]).flatMap { name, property in
                [property.description, property.items?.description]
                    .compactMap { $0 }
                    .map { (label: "\(tool.name).\(name)", text: $0) }
            }
        }
    }

    /// A description that restates its inputs drifts from them: `create_managed_task` listed
    /// eight of its parameters and not the ninth, `folder_id` — the one that is required — and an
    /// agent reading the list wrote calls without it (2026-11-08). What an input takes is said
    /// once, on the input. Matched as a whole word, so `named` is not `name`.
    func testNoDescriptionNamesOneOfItsOwnInputs() throws {
        var checked = 0
        for tool in HostedMCPCatalog.allTools {
            let text = description(tool.name)
            for input in (tool.inputSchema.properties ?? [:]).keys.sorted() {
                checked += 1
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: input) + "\\b"
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNil(
                    regex.firstMatch(in: text, range: range),
                    "\(tool.name)'s description names its own input `\(input)` — say it on the property: \(text)")
            }
        }
        XCTAssertGreaterThan(checked, 40, "anti-vacuum: the schemas hold over 40 inputs")
    }

    /// The house rule for LLM-facing tool text: no default values. `timeout_seconds` and `limit`
    /// both said "default 50", a number the agent then plans around while the server is free to
    /// change it.
    func testNoPropertyTextGivesADefault() {
        let texts = propertyTexts()
        XCTAssertGreaterThan(texts.count, 40, "anti-vacuum")
        for (label, text) in texts {
            XCTAssertFalse(text.lowercased().contains("default"), "\(label) gives a default: \(text)")
        }
    }

    /// F6 D2, C10: "When omitted or true, context is included" gives the default of a boolean in
    /// words — the same thing "default" says, which the pin above could not see. The behaviour on
    /// ABSENCE stays where an agent needs it (which team, which pass); the value an omitted flag
    /// takes does not. RED before D2: `include_context`.
    func testNoPropertyTextSaysWhatAnOmittedFlagEquals() throws {
        let pattern = try NSRegularExpression(
            pattern: #"\b(when|if) omitted or (true|false)\b|\bomitted\W+(means|is|equals) (true|false)\b"#,
            options: [.caseInsensitive])
        let texts = propertyTexts()
        XCTAssertGreaterThan(texts.count, 40, "anti-vacuum")
        for (label, text) in texts {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(pattern.firstMatch(in: text, range: range), "\(label) says what an omitted flag equals: \(text)")
        }
        let include = try property("include_context", of: ExternalAutovisorToolNames.folderStatus)
        XCTAssertTrue(include.contains("false"), "the property still says how to leave the context out: \(include)")
    }

    /// F6 D2, C15: under Semi-automatic with nobody to ask, read-only commands, allow-rules and
    /// the commands a person saved as "always" (which is an allow-rule) run — the old value
    /// `allow_rules_unattended` named the second alone. And neither the availability values nor
    /// a server's `cross_server_transfer` were explained anywhere. RED before D2.
    func testFolderStatusExplainsTheApprovalAvailabilityValues() {
        let status = description(ExternalAutovisorToolNames.folderStatus)
        for value in ["available", "read_only_and_allow_rules", "read_only_unattended", "withheld"] {
            XCTAssertTrue(status.contains(value), "folder_status never says what availability \(value) means: \(status)")
        }
        XCTAssertFalse(status.contains("allow_rules_unattended"), status)
        XCTAssertTrue(status.contains("read-only"), "what runs besides the allow-rules: \(status)")
        XCTAssertTrue(status.contains("cross_server_transfer"), status)
        XCTAssertTrue(status.contains("auto") && status.contains(ToolErrorCode.approvalUnavailable.rawValue),
                      "both values of cross_server_transfer are named: \(status)")
    }

    /// Review R5: the description promises every withheld family `what_the_person_must_do`, and
    /// computer use sent none. RED before the fix: the computer_use object had mode, availability
    /// and reason only.
    func testEveryWithheldFamily_carriesWhatThePersonMustDo() throws {
        for (bash, computerUse) in [(BashExecutionMode.off, ComputerUseMode.off), (.manual, .manual)] {
            let approvals = ExternalAutovisorApprovals.evaluate(
                bashMode: bash, computerUseMode: computerUse, mcpServers: [])
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(approvals)) as? [String: Any])
            for family in ["bash", "computer_use"] {
                let entry = try XCTUnwrap(object[family] as? [String: Any], family)
                XCTAssertEqual(entry["availability"] as? String, "withheld", "premise: \(family) \(entry)")
                let remedy = entry["what_the_person_must_do"] as? String
                XCTAssertFalse(remedy?.isEmpty ?? true, "\(family) withheld (\(entry["reason"] ?? "")) says nothing")
            }
        }
        // And what refuses a call whatever the availability — a deny rule, the Auto judge — and
        // what keeps a read-only command from running unattended: an ask rule matching it.
        let status = description(ExternalAutovisorToolNames.folderStatus)
        XCTAssertTrue(status.contains("deny rule") && status.contains("Auto judge"), status)
        XCTAssertTrue(status.contains("ask rule"), status)
    }

    /// F6 D2, C7: `set_timeout` refuses a value at or below the elapsed time only for a run that
    /// is still going; the property says so, and says what happens to a finished one.
    func testTimeoutSecondsSaysWhichRunRefusesAValueBelowItsAge() throws {
        let timeout = try property("timeout_seconds", of: ExternalAutovisorToolNames.controlTask)
        XCTAssertTrue(timeout.contains("still going"), timeout)
        XCTAssertTrue(timeout.contains("review") && timeout.contains("failed"), timeout)
    }

    /// F6 D2, L2: one name for the moment a schedule next fires — the row's `next_run_at` — and
    /// the detail's schedule names its moments the same way.
    func testTaskStatusNamesTheScheduleMomentsLikeTheRow() {
        let task = description(ExternalAutovisorToolNames.taskStatus)
        XCTAssertTrue(task.contains("next_run_at"), task)
        XCTAssertTrue(task.contains("last_run_at"), task)
        XCTAssertFalse(task.contains("next_fire_at"), task)
        // A rule with no future occurrence disables itself and stays readable (`enabled: false`,
        // no `next_run_at`); the text said the whole `recurrence` went absent, which no path does.
        XCTAssertTrue(task.contains("enabled false"), task)
        XCTAssertFalse(task.contains("its absence"), task)
    }

    /// The sentences that named an input moved onto it rather than out of the catalog.
    func testTheSentencesThatNamedAnInputLiveOnThatInput() throws {
        let answer = try property("answer", of: ExternalAutovisorToolNames.answerTaskQuestion)
        XCTAssertTrue(answer.contains("Q1/Q2 grammar"), "a questionnaire's reply format: \(answer)")

        let waitingRole = try property("role_id", of: ExternalAutovisorToolNames.answerTaskQuestion)
        XCTAssertTrue(waitingRole.contains("multiple roles"), waitingRole)

        let verbs = try property("action", of: ExternalAutovisorToolNames.manageRole)
        for verb in RoleVerb.actionNames {
            XCTAssertTrue(verbs.contains(verb), "manage_role's action never says what `\(verb)` does: \(verbs)")
        }
        XCTAssertTrue(verbs.contains("paused"), "correct needs the task paused: \(verbs)")
        // `wait_for_events.after` is pinned by `testWaitForEventsCursorSaysHowASessionStartsAndResumes`.
    }

    // MARK: - Where a session's event stream starts

    /// `folder_status.event_cursor` is the feed's HEAD. A wait that starts from it scans only what
    /// is appended after it, and the conditions already standing are materialized only by a call
    /// WITHOUT a cursor — so a session that resumed from this cursor never heard of the question
    /// or review that was already waiting (2026-11-08). It was described as "current event
    /// cursor", which reads as "where to start". The text says what it is instead; the feed is
    /// unchanged, because re-snapshotting on it would reset what the agent was already told.
    func testFolderStatusSaysItsCursorSkipsWhatAlreadyStands() {
        let d = description(ExternalAutovisorToolNames.folderStatus)
        XCTAssertTrue(d.contains("event_cursor"), d)
        XCTAssertTrue(d.contains("only events after now"), "what a wait from it returns: \(d)")
        XCTAssertTrue(d.contains("already standing"), "what it does not: \(d)")
        XCTAssertFalse(d.contains("current event cursor"), "the wording that read as a starting point: \(d)")
    }

    /// How a session starts belongs to the input it is about, not to the tool's description.
    func testWaitForEventsCursorSaysHowASessionStartsAndResumes() throws {
        let cursor = try property("after", of: ExternalAutovisorToolNames.waitForEvents)
        XCTAssertTrue(cursor.contains("Omit it on a session's first call"), cursor)
        XCTAssertTrue(cursor.contains("then pass the cursor the previous call returned"), cursor)
        XCTAssertFalse(
            description(ExternalAutovisorToolNames.waitForEvents).contains("initial snapshot"),
            "the starting rule lives on `after` alone")
    }

    /// Whatever else these say, the house rule holds: a tool description never names a sibling
    /// tool. Pinned here as well as in `PromptFormatConventionsTests` because every edit above
    /// adds prose, and prose is where a sibling name slips in.
    func testNoDescriptionNamesASiblingTool() {
        for tool in ExternalAutovisorToolNames.all {
            let d = description(tool)
            for sibling in ExternalAutovisorToolNames.all where sibling != tool {
                XCTAssertFalse(
                    d.contains(sibling),
                    "\(tool)'s description names sibling `\(sibling)`")
            }
        }
    }

    // MARK: - Undeclared arguments (2026-11-09)

    /// An argument the published schema does not declare refuses the call by name — before
    /// 2026-11-09 each operation read the keys it knew and the rest vanished.
    func testAnUndeclaredArgument_isRefusedByName() throws {
        let refusal = try XCTUnwrap(HostedMCPCatalog.undeclaredArgumentsRefusal(
            toolName: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": "f", "brief": "b", "start": false]))
        XCTAssertTrue(refusal.isError)
        XCTAssertTrue(refusal.outputJSON.contains("INVALID_ARGS"), refusal.outputJSON)
        XCTAssertTrue(refusal.outputJSON.contains("no argument `start`"), refusal.outputJSON)
    }

    /// `folder_id` is accepted where the tool CHECKS it without publishing it (`list_teams`,
    /// `list_tasks`) and refused where nothing reads it — accepting it there would drop it.
    func testFolderID_isAcceptedWhereChecked_andRefusedWhereNothingReadsIt() {
        for tool in [ExternalAutovisorToolNames.listTasks, ExternalAutovisorToolNames.listTeams] {
            XCTAssertNil(HostedMCPCatalog.undeclaredArgumentsRefusal(toolName: tool, args: ["folder_id": "f"]), tool)
        }
        for tool in [ExternalAutovisorToolNames.waitForEvents, ExternalAutovisorToolNames.folderStatus] {
            XCTAssertNotNil(HostedMCPCatalog.undeclaredArgumentsRefusal(toolName: tool, args: ["folder_id": "f"]), tool)
        }
    }

    func testDeclaredArguments_aNullValue_andAnUnpublishedTool_passUntouched() {
        XCTAssertNil(HostedMCPCatalog.undeclaredArgumentsRefusal(
            toolName: ExternalAutovisorToolNames.messageTask,
            args: ["folder_id": "f", "task_id": 1, "message": "m", "role_id": NSNull(), "extra": NSNull()]))
        XCTAssertNil(HostedMCPCatalog.undeclaredArgumentsRefusal(toolName: "no_such_tool", args: ["x": 1]))
    }

    // MARK: - Wave W5 Catalog Tests

    func testListTeams_autonomousModeCorrectedForAutovisor() {
        let d = description(ExternalAutovisorToolNames.listTeams)
        XCTAssertTrue(d.contains("autonomous"), d)
        XCTAssertTrue(d.contains("in your place"), d)
        // Must clarify that under external autovisor, questions route to the agent and are not auto-answered
        XCTAssertTrue(d.contains("route") || d.contains("routes"), d)
        XCTAssertFalse(d.contains("so you never see it"), "list_teams must not claim autonomous mode hides questions: \(d)")
        XCTAssertFalse(d.contains("has a local model answer in your place"), "list_teams must not claim local model answers in agent's place: \(d)")
        XCTAssertTrue(d.contains("autonomous mode does not answer in your place"), "list_teams must state autonomous mode does not answer in agent's place: \(d)")
        XCTAssertTrue(d.contains("routing to you as well") || d.contains("routes questions to you"), "list_teams must state questions route to the agent: \(d)")
    }

    func testFolderStatus_inputSchemaDeclaresIncludeContext() {
        let schemaText = HostedMCPCatalog.inputSchemaText(for: ExternalAutovisorToolNames.folderStatus)
        XCTAssertTrue(schemaText.contains("include_context"), "folder_status input schema must declare include_context: \(schemaText)")
    }

    // MARK: - Wave W6 Catalog Tests

    func testControlTaskActionDescribesAllVerbs() throws {
        let actionDesc = try property("action", of: ExternalAutovisorToolNames.controlTask)
        for verb in ControlVerb.actionNames {
            XCTAssertTrue(actionDesc.contains(verb), "control_task action must describe `\(verb)`: \(actionDesc)")
        }
        XCTAssertTrue(actionDesc.contains("irreversible"), "must state delete is irreversible: \(actionDesc)")
        XCTAssertTrue(actionDesc.contains("cascades"), "must state stop cascades: \(actionDesc)")
        XCTAssertTrue(actionDesc.contains("timeout_seconds"), "must reference timeout_seconds: \(actionDesc)")
    }

    /// The person's Pause is refused to the verbs that would lift it (D-M18, 2026-11-12): the
    /// descriptions say which verbs and by which code, and `message_task` no longer claims it
    /// resumes every paused run — on the person's pause a message waits.
    func testThePersonsPause_isNamedWhereAVerbWouldLiftIt() throws {
        let control = description(ExternalAutovisorToolNames.controlTask)
        XCTAssertTrue(control.contains("by_person"), control)
        XCTAssertTrue(control.contains("PAUSED_BY_PERSON"), control)
        XCTAssertTrue(control.contains("resume and start refuse it"), control)

        let verbs = try property("action", of: ExternalAutovisorToolNames.manageRole)
        XCTAssertTrue(verbs.contains("refused while the pause is the person's (by_person)"), verbs)

        let message = description(ExternalAutovisorToolNames.messageTask)
        XCTAssertTrue(message.contains("except a pause the person made"), message)
    }

    func testManageRoleActionDescribesDiscardingOnRestart() throws {
        let actionDesc = try property("action", of: ExternalAutovisorToolNames.manageRole)
        XCTAssertTrue(actionDesc.contains("discarding"), "restart must mention discarding messages: \(actionDesc)")
        XCTAssertTrue(actionDesc.contains("surviving"), "restart must mention comment surviving: \(actionDesc)")
    }

    func testCreateManagedTaskPropertiesExplainDefaultsAndSourceWithoutForbiddenWords() throws {
        let teamIDDesc = try property("team_id", of: ExternalAutovisorToolNames.createManagedTask)
        XCTAssertFalse(teamIDDesc.contains("list_teams"), "team_id must not mention sibling tool list_teams: \(teamIDDesc)")
        XCTAssertTrue(teamIDDesc.contains("team catalog"), "team_id must mention team catalog source: \(teamIDDesc)")
        XCTAssertTrue(teamIDDesc.contains("active team"), "team_id must mention active team: \(teamIDDesc)")

        let titleDesc = try property("title", of: ExternalAutovisorToolNames.createManagedTask)
        XCTAssertTrue(titleDesc.contains("first line of the brief"), "title must mention brief first line derivation: \(titleDesc)")
    }

    func testInputSchemaText_unknownTool_returnsPlaceholder() {
        XCTAssertEqual(HostedMCPCatalog.inputSchemaText(for: "nonexistent_tool"), "(unknown tool)")
    }

    // MARK: - Wave F2: task_changes Description Truth (§3.6, §3.11)

    /// Whose changes the result holds and what `not_tracked` is (F6 N15): F2 dropped "including
    /// concurrent edits from other tasks or external processes", and an agent read every change as
    /// its own task's.
    func testTaskChangesDescription_saysWhoseChangesAndThatIgnoredFilesAreNotListed() {
        let d = description(ExternalAutovisorToolNames.taskChanges)
        XCTAssertTrue(
            d.contains("whoever made it — the task's file tools and bash, another task, the person or any other process"), d)
        XCTAssertTrue(d.contains("are excluded, and not listed,"), d)
        XCTAssertTrue(d.contains("not_tracked, each entry a path and a reason"), d)
        XCTAssertFalse(d.contains("files outside snapshot scope"), d)
    }

    /// E1 review R7, RED before 2026-11-12: the description promised "every change … whoever made
    /// it" and named three exclusion sources, while snapshot git also reads the person's global
    /// excludes file (`-c core.excludesFile=`, `TaskSnapshotService+GitProcess`) and never stages
    /// the places the resolver hides (`resolver.gitExcludePathspecs`, `+Staging`). A file either
    /// hides is in neither `files` nor `not_tracked`, so the agent read it as unchanged.
    func testTaskChangesDescription_namesEverySourceThatHidesAFile() {
        let d = description(ExternalAutovisorToolNames.taskChanges)
        XCTAssertTrue(d.contains("by the person's global git excludes file"), d)
        XCTAssertTrue(d.contains("the places NanoTeams hides from a team's tools"), d)
    }

    func testTaskChangesDescription_accuratelyDescribesNonIgnoredFilesAndSubmoduleExclusions() throws {
        let d = description(ExternalAutovisorToolNames.taskChanges)
        XCTAssertTrue(d.contains("ignored") || d.contains("exclude"), "task_changes description must mention that ignored files are excluded: \(d)")
        XCTAssertTrue(d.contains("embedded") || d.contains("submodule") || d.contains("repositories"), "task_changes description must note embedded repository / submodule exclusions: \(d)")
    }

    // MARK: - Wave F5: Universal Next Hint (§6.2, [B18])

    // The source pin that stood here read one file of the surface and passed a `next:` anywhere in
    // the 18 lines after a call — a neighbour's, or `next: nil` (F6 T2). Every refusal now gets its
    // next call at the exit seam: `ExternalNextCallTests`.

    func testExternalNextNeverReturnsNilForAnyFailureCode() {
        let failures: [AutovisorActionFailure?] = [.notWaiting, .taskNotFound, .roleNotFound, .limitReached, nil]
        for failure in failures {
            let hint = NTMSOrchestrator.externalNext(for: failure, taskID: 42)
            XCTAssertTrue(ExternalAutovisorToolNames.all.contains(hint.suggested_cmd ?? ""), "\(String(describing: failure))")
            // The task rides along where the named tool takes one; `list_tasks` takes none.
            XCTAssertEqual(
                hint.suggested_args?["task_id"],
                hint.suggested_cmd == ExternalAutovisorToolNames.listTasks ? nil : "42",
                "\(String(describing: failure))")
            XCTAssertFalse(hint.reason?.isEmpty ?? true, "reason must not be empty")
        }
    }
}
