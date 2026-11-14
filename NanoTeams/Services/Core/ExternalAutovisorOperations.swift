import Foundation

/// Names of every MCP tool NanoTeams exposes to external Autovisor agents (§8.1).
/// Shared tools keep the exact names used by the in-app manager so `NextHint` suggestions
/// remain valid across both surfaces.
nonisolated enum ExternalAutovisorToolNames {
    static let folderStatus = "folder_status"
    static let listTeams = "list_teams"
    static let listTasks = ToolNames.listTasks
    static let taskStatus = ToolNames.taskStatus
    static let createManagedTask = ToolNames.createManagedTask
    static let controlTask = ToolNames.controlTask
    static let manageRole = ToolNames.manageRole
    static let answerTaskQuestion = ToolNames.answerTaskQuestion
    static let messageTask = ToolNames.messageTask
    static let scheduleTask = ToolNames.scheduleTask
    /// Published since 2026-11-13 (decision A3, revised): the person allows it per agent.
    static let setWorkFolderContext = ToolNames.setWorkFolderContext
    static let waitForEvents = ToolNames.waitForEvents
    static let taskResult = "task_result"
    static let readArtifact = "read_artifact"
    static let taskLog = "task_log"
    static let taskChanges = "task_changes"

    static let all: [String] = [
        folderStatus,
        listTeams,
        listTasks,
        taskStatus,
        createManagedTask,
        controlTask,
        manageRole,
        answerTaskQuestion,
        messageTask,
        scheduleTask,
        setWorkFolderContext,
        waitForEvents,
        taskResult,
        readArtifact,
        taskLog,
        taskChanges,
    ]
}

/// Namespace for external Autovisor operation constants and warnings (§8.1).
nonisolated enum ExternalAutovisorOperations {
    /// runtime-prompt
    static let llmUnreachableWarning = "LLM server is unreachable. Tasks may not execute until the server is online."

    /// The warning on a `set_timeout` reply when the task's last run is not going and began longer
    /// ago than the new value: the watchdog measures a continuation of that run from its start
    /// (`NTMSOrchestrator.evaluateRunTimeouts`), so continuing it pauses at the next tick (review R4).
    /// runtime-prompt
    static let continuationPausesAtOnceWarning =
        "This task's last run is not going and began longer ago than the new timeout. Continuing it (request_changes or restart) is measured from that start, so the watchdog pauses it at its next tick; a new run counts from its own start."
}

/// A refusal of an external Autovisor call, with the code an agent branches on and the call to
/// make next. The validation helpers return it; `errorResult` is the envelope.
nonisolated struct ExternalAutovisorError: Error, Sendable {
    let code: ToolErrorCode
    let message: String
    let details: [String: String]?
    let next: NextHint?
    /// The round whose start snapshot `task_changes` found missing — for the handler, which may
    /// hold the reason (`Run.snapshotFailures`). Never on the wire.
    var missingRoundStart: Int?

    init(_ message: String, code: ToolErrorCode = .commandFailed, details: [String: String]? = nil, next: NextHint? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.next = next
        self.missingRoundStart = nil
    }

    func errorResult(toolName: String, args: [String: Any]) -> ToolExecutionResult {
        makeErrorResult(toolName: toolName, args: args, code: code, message: message, details: details, next: next)
    }

    /// No top-level task with this id in the open folder — `list_tasks` lists the ones there are.
    static func taskNotFound(_ taskID: Int) -> ExternalAutovisorError {
        ExternalAutovisorError(
            LLMExecutionService.taskStatusNotFoundMessage(taskID: taskID),
            code: .taskNotFound,
            next: ExternalNextCall.taskIDs.hint())
    }

    /// The task is somebody else's. Nothing this agent may change there, but `task_status` answers
    /// for any task in the folder — with what is not this agent's left out. Until 2026-11-12 this
    /// named no next call at all (F6 L1), against the instructions' "refused calls carry a next
    /// suggestion".
    static func notOwner(_ taskID: Int) -> ExternalAutovisorError {
        ExternalAutovisorError(
            NTMSOrchestrator.foreignTaskRefusalMessage(taskID: taskID),
            code: .notOwner,
            next: ExternalNextCall.foreignTask.hint(taskID: taskID))
    }

    /// The folder changed while the call ran — `FOLDER_CHANGED`, the one code the external surface
    /// gives this case (N16 of the F6 acceptance: seven sites said `COMMAND_FAILED`, two said
    /// `FOLDER_CHANGED`, for the same sentence), and `folder_status` next (F6 L1).
    static var folderChanged: ExternalAutovisorError {
        ExternalAutovisorError(
            DeferredCallReplies.folderChanged, code: .folderChanged, next: ExternalNextCall.folderChanged.hint())
    }

    /// The folder changed after `create_managed_task` had CREATED its task: `FOLDER_CHANGED`, with
    /// the task in the message and in `details.task_id`. Until 2026-11-12 (E1 review R2) this was
    /// the plain folder-changed refusal, whose next call said "nothing was done in the one this
    /// call named" — and an agent without a `request_key` that believed it created the task again.
    static func folderChangedAfterCreation(taskID: Int) -> ExternalAutovisorError {
        ExternalAutovisorError(
            NTMSOrchestrator.createdBeforeFolderChangedMessage(taskID: taskID),
            code: .folderChanged,
            details: ["task_id": "\(taskID)"],
            next: ExternalNextCall.folderChanged.hint())
    }

    /// This refusal, with `hint` as its next call when it names none.
    func namingNext(_ hint: NextHint) -> ExternalAutovisorError {
        guard next == nil else { return self }
        var named = ExternalAutovisorError(message, code: code, details: details, next: hint)
        named.missingRoundStart = missingRoundStart
        return named
    }
}

extension BashExecutionMode {
    nonisolated var wireMode: String {
        switch self {
        case .off: "off"
        case .manual: "manual"
        case .semiAutomatic: "semi_automatic"
        case .auto: "auto"
        }
    }
}

extension ComputerUseMode {
    nonisolated var wireMode: String {
        switch self {
        case .off: "off"
        case .manual: "manual"
        case .semiAutomatic: "semi_automatic"
        case .auto: "auto"
        }
    }
}

extension MCPApprovalMode {
    nonisolated var wireMode: String {
        switch self {
        case .manual: "manual"
        case .semiAutomatic: "semi_automatic"
        case .auto: "auto"
        }
    }
}

/// Per-family approval availability for tasks running under the external Autovisor (§10.3).
/// Computed directly from `ApprovalGatedAvailability` and `MCPPermissionService.runsUnattended`
/// with `humanPresent: false`.
nonisolated struct ExternalAutovisorApprovals: Codable, Hashable, Sendable {
    struct BashApproval: Codable, Hashable, Sendable {
        var mode: String
        var availability: String
        var reason: String?
        var allow_rules: [String]
        var what_the_person_must_do: String?
    }

    struct FamilyApproval: Codable, Hashable, Sendable {
        var mode: String
        var availability: String
        var reason: String?
        var what_the_person_must_do: String?
    }

    struct MCPServerApproval: Codable, Hashable, Sendable {
        var slug: String
        var name: String
        var status: String
        var approval_mode: String
        var trusted: Bool
        var unattended_tools: [String]
        var withheld_tools: [String]
        var cross_server_transfer: String
    }

    struct MCPApprovals: Codable, Hashable, Sendable {
        var servers: [MCPServerApproval]
    }

    var bash: BashApproval
    var computer_use: FamilyApproval
    var mcp: MCPApprovals

    static func evaluate(
        bashMode: BashExecutionMode,
        bashAllowRules: [String] = [],
        computerUseMode: ComputerUseMode,
        mcpServers: [MCPGrantCatalogue.Server]
    ) -> ExternalAutovisorApprovals {
        let bashAvail = ApprovalGatedAvailability.forBash(mode: bashMode, humanPresent: false)
        let cuAvail = ApprovalGatedAvailability.forComputerUse(mode: computerUseMode, humanPresent: false)

        let servers = mcpServers.map { server -> MCPServerApproval in
            var unattended: [String] = []
            var withheld: [String] = []
            for tool in server.reviewedTools {
                if tool.runsUnattended {
                    unattended.append(tool.modelFacingName)
                } else {
                    withheld.append(tool.modelFacingName)
                }
            }
            let serverCrossTransfer = server.approvalMode == .auto
                ? "auto"
                : ToolErrorCode.approvalUnavailable.rawValue
            return MCPServerApproval(
                slug: server.slug.rawValue,
                name: MCPTextSanitizer.singleLine(server.displayName),
                status: server.status.displayLabel,
                approval_mode: server.approvalMode.wireMode,
                trusted: server.isTrusted,
                unattended_tools: unattended,
                withheld_tools: withheld,
                cross_server_transfer: serverCrossTransfer
            )
        }

        return ExternalAutovisorApprovals(
            bash: mapBash(mode: bashMode, availability: bashAvail, allowRules: bashAllowRules),
            computer_use: mapFamily(mode: computerUseMode.wireMode, availability: cuAvail),
            mcp: MCPApprovals(servers: servers)
        )
    }

    private static func mapBash(
        mode: BashExecutionMode,
        availability: ApprovalGatedAvailability,
        allowRules: [String]
    ) -> BashApproval {
        switch availability {
        case .available:
            return BashApproval(
                mode: mode.wireMode,
                availability: "available",
                reason: nil,
                allow_rules: allowRules,
                what_the_person_must_do: nil
            )
        case .readOnlyUnattended:
            return BashApproval(
                mode: mode.wireMode,
                availability: "read_only_and_allow_rules",
                reason: nil,
                allow_rules: allowRules,
                what_the_person_must_do: nil
            )
        case .withheld(.switchedOff):
            return BashApproval(
                mode: mode.wireMode,
                availability: "withheld",
                reason: "switched_off",
                allow_rules: allowRules,
                what_the_person_must_do: bashWhatThePersonMustDo(for: .switchedOff)
            )
        case .withheld(.noApprover):
            return BashApproval(
                mode: mode.wireMode,
                availability: "withheld",
                reason: "no_approver",
                allow_rules: allowRules,
                what_the_person_must_do: bashWhatThePersonMustDo(for: .noApprover)
            )
        }
    }

    /// What the person must do for bash to run with nobody to approve it. Unmarked until
    /// 2026-11-12 (F6 T3), under a registry row named for no builder.
    /// runtime-prompt
    static func bashWhatThePersonMustDo(for reason: ApprovalGatedAvailability.Reason) -> String {
        switch reason {
        case .switchedOff:
            return "Enable the bash tool in NanoTeams with Semi-automatic or Auto execution mode."
        case .noApprover:
            return "Change the bash execution mode in NanoTeams to Auto (or Semi-automatic with allow-rules for needed commands) so commands can run without interactive confirmation."
        }
    }

    /// What the person must do for computer use to run with nobody to approve it — the same
    /// field bash's withheld availability carries, which the `folder_status` description promises
    /// for every withheld family (review R5, 2026-11-12).
    /// runtime-prompt
    static func computerUseWhatThePersonMustDo(for reason: ApprovalGatedAvailability.Reason) -> String {
        switch reason {
        case .switchedOff:
            return "Enable computer use in NanoTeams with Semi-automatic or Auto mode."
        case .noApprover:
            return "Change the computer use mode in NanoTeams to Auto (or Semi-automatic for read-only actions) so actions can run without interactive confirmation."
        }
    }

    private static func mapFamily(
        mode: String,
        availability: ApprovalGatedAvailability
    ) -> FamilyApproval {
        switch availability {
        case .available:
            return FamilyApproval(mode: mode, availability: "available", reason: nil, what_the_person_must_do: nil)
        case .readOnlyUnattended:
            return FamilyApproval(
                mode: mode, availability: "read_only_unattended", reason: nil, what_the_person_must_do: nil)
        case .withheld(.switchedOff):
            return FamilyApproval(
                mode: mode, availability: "withheld", reason: "switched_off",
                what_the_person_must_do: computerUseWhatThePersonMustDo(for: .switchedOff))
        case .withheld(.noApprover):
            return FamilyApproval(
                mode: mode, availability: "withheld", reason: "no_approver",
                what_the_person_must_do: computerUseWhatThePersonMustDo(for: .noApprover))
        }
    }
}

// MARK: - Orchestrator External Operations (§8.1)

extension NTMSOrchestrator {

    /// Whether a run in this derived status is still going — the runs `set_timeout` measures a
    /// new value against (F6 C7).
    nonisolated static func runIsStillGoing(_ status: TaskStatus) -> Bool {
        switch status {
        case .running, .paused, .needsSupervisorInput: true
        case .waiting, .needsSupervisorAcceptance, .failed, .done: false
        }
    }

    /// The refusal of a `set_timeout` value at or below the elapsed time of a run still going.
    /// runtime-prompt
    nonisolated static func timeoutNotPastElapsedMessage(elapsedSeconds: Int) -> String {
        "New timeout must exceed elapsed run time (\(elapsedSeconds)s)."
    }

    /// runtime-prompt
    nonisolated static func foreignTaskRefusalMessage(taskID: Int) -> String {
        "Task #\(taskID) was not created by this agent. Only tasks created by this agent can be modified or inspected in detail."
    }

    /// What `set_work_folder_context` answers an agent the person has not allowed to replace the
    /// Work Folder Context: the fact, with the remedy beside it in `details.what_the_person_must_do`
    /// — the shape of a readiness refusal (`contextReplacementNotAllowedRemedy`).
    /// runtime-prompt
    nonisolated static let contextReplacementNotAllowedMessage =
        "This agent may not replace the work folder context: the person has not allowed it, and only they can. Nothing was changed."

    /// runtime-prompt
    nonisolated static let contextReplacementNotAllowedRemedy =
        "Allow this agent to replace the Work Folder Context in NanoTeams."

    /// The refusal of a `set_work_folder_context` whose text carries characters that change how it
    /// displays (`hiddenScalars`), after "Argument 'content' ". Refused, not cleaned: the person
    /// reads this text in Settings and a reading role reads it in its prompt, and an override or a
    /// directional mark stored in it would show the one a line the other does not read.
    /// runtime-prompt
    nonisolated static func contextHiddenCharactersDetail(count: Int, first: Unicode.Scalar, position: Int) -> String {
        let code = String(format: "U+%04X", first.value)
        let noun = count == 1 ? "character" : "characters"
        return "carries \(count) \(noun) that change how text displays — bidi controls, directional marks, tag characters or control characters, "
            + "the first \(code) at position \(position); nothing was written. Remove them and send the text again."
    }

    /// The refusal of an `expected_revision` that is not a string, after "Argument
    /// 'expected_revision' ".
    /// runtime-prompt
    nonisolated static let contextRevisionNotARevisionDetail =
        "must be the revision the work folder context was read with, as a string."

    /// What the prompt seam would remove from `text` (`MCPTextSanitizer.sanitizeDisplayedData`) —
    /// how many scalars, the first, and its 1-based position among the text's scalars — or `nil`
    /// when it removes nothing. The sanitizer only removes, so the kept text is a subsequence of
    /// the original and the first scalar where the two part is the first one removed.
    nonisolated static func hiddenScalars(in text: String) -> (count: Int, first: Unicode.Scalar, position: Int)? {
        let clean = MCPTextSanitizer.sanitizeDisplayedData(text)
        guard clean != text else { return nil }
        let original = Array(text.unicodeScalars)
        let kept = Array(clean.unicodeScalars)
        var index = 0
        while index < kept.count, original[index] == kept[index] { index += 1 }
        guard index < original.count else { return nil }
        return (original.count - kept.count, original[index], index + 1)
    }

    /// The argument `set_work_folder_context` carries the agent's read of the context in
    /// (`ProjectSettings.contextRevision`). Required: without it no write could tell a text the
    /// agent read from one the person typed since.
    nonisolated static let expectedRevisionKey = "expected_revision"

    /// The task `agentID` created with `requestKey`, read off the folder's index rows — the key is
    /// stored on the task, so it outlives the process and a folder switch. A deleted task frees
    /// its key; another agent's key is not this one's.
    nonisolated static func taskCreated(forRequestKey requestKey: String, by agentID: UUID, in rows: [TaskSummary]) -> Int? {
        rows.first { row in
            guard row.requestKey == requestKey, case .externalAgent(let identity)? = row.origin else { return false }
            return identity.id == agentID
        }?.id
    }

    /// runtime-prompt
    nonisolated static func requestInProgressMessage(requestKey: String) -> String {
        "A create with request_key '\(requestKey)' is still under way; its task appears in list_tasks with this request_key once it is created."
    }

    /// The reply to a create the folder change overtook after the task existed: which task, that
    /// what came after the creation may be missing, and that creating it again makes a second.
    /// runtime-prompt
    nonisolated static func createdBeforeFolderChangedMessage(taskID: Int) -> String {
        "Task #\(taskID) was created in the folder this call named, which closed before the call finished: "
            + "what the call asked for after the creation (attachments, a timeout, a schedule, the start) "
            + "may not have been done. The task stays in that folder; task_status reads it there once that "
            + "folder is open again, and creating it again makes a second task."
    }

    /// runtime-prompt
    nonisolated static func alreadyCreatedIdempotentMessage(taskID: Int, requestKey: String) -> String {
        "Task #\(taskID) was already created for request_key '\(requestKey)'."
    }

    /// The note beside `task_result`'s `changed_files`. Until 2026-11-12 (F6 T11) it sent the agent
    /// to `git status` / `git diff` — useless in a folder without git, and against the instructions,
    /// which send it to `task_changes`, the snapshot of every change in the pass.
    /// runtime-prompt
    nonisolated static let changedFilesBashNote =
        "Only files written with the team's file tools are listed. Changes made through bash are not: "
            + "task_changes shows every change to the work folder during a pass, bash included."

    /// Executes one external Autovisor MCP tool call on `@MainActor`, keeping the error/info
    /// banners the CALL raises off the person's screen, so all its refusals are delivered
    /// exclusively via the returned NanoTeams JSON envelope (§8.1, Ш13). Scoped to the call's own
    /// task tree (`suppressingBanners`): a banner any other task raises while the call is in
    /// flight — an agent in `wait_for_events` always has one — is the person's, and stays.
    func executeExternalAutovisorTool(
        name: String,
        args: [String: Any],
        agent: AgentIdentity,
        sessionID: String? = nil,
        now: Date = MonotonicClock.shared.now(),
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) async -> ToolExecutionResult {
        noteExternalAutovisorActivity(now: now)
        return await suppressingBanners {
            await executeExternalAutovisorToolSuppressed(
                name: name, args: args, agent: agent, sessionID: sessionID, now: now, isCancelled: isCancelled)
        }
    }

    private func executeExternalAutovisorToolSuppressed(
        name: String,
        args: [String: Any],
        agent: AgentIdentity,
        sessionID: String?,
        now: Date,
        isCancelled: @Sendable () -> Bool
    ) async -> ToolExecutionResult {
        let lifecycle = currentFolderLifecycle
        let actor = AutovisorActor.externalAgent(agent, session: sessionID)
        let startedAt = ContinuousClock.now

        let preCallWaitingRoleID: String? = {
            guard name == ExternalAutovisorToolNames.answerTaskQuestion,
                  let taskID = try? requiredInt(args, "task_id")
            else {
                return nil
            }
            if let explicit = extractString(args, "role_id")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty
            {
                return explicit
            }
            return loadedTask(taskID)?.answerableSupervisorSteps.first?.effectiveRoleID
        }()

        let result: ToolExecutionResult
        // An argument the published schema does not declare refuses the call before any
        // operation reads the rest (`HostedMCPCatalog.undeclaredArgumentsRefusal`).
        if let refusal = HostedMCPCatalog.undeclaredArgumentsRefusal(toolName: name, args: args) {
            result = refusal
        } else {
            switch name {
            case ExternalAutovisorToolNames.folderStatus:
                result = await handleExternalFolderStatus(args: args, agent: agent, actor: actor, now: now)

            case ExternalAutovisorToolNames.listTeams:
                result = handleExternalListTeams(args: args, within: lifecycle)

            case ExternalAutovisorToolNames.listTasks:
                result = handleExternalListTasks(args: args, agent: agent, now: now, within: lifecycle)

            case ExternalAutovisorToolNames.taskStatus:
                result = await handleExternalTaskStatus(args: args, agent: agent, now: now, within: lifecycle)

            case ExternalAutovisorToolNames.createManagedTask:
                result = await handleExternalCreateManagedTask(
                    args: args,
                    agent: agent,
                    actor: actor,
                    now: now,
                    within: lifecycle,
                    isCancelled: isCancelled
                )

            case ExternalAutovisorToolNames.setWorkFolderContext:
                result = await handleExternalSetWorkFolderContext(
                    args: args,
                    agent: agent,
                    actor: actor,
                    within: lifecycle,
                    isCancelled: isCancelled
                )

            case ExternalAutovisorToolNames.controlTask,
                 ExternalAutovisorToolNames.manageRole,
                 ExternalAutovisorToolNames.answerTaskQuestion,
                 ExternalAutovisorToolNames.messageTask:
                result = await handleExternalSharedWriteTool(
                    name: name,
                    args: args,
                    agent: agent,
                    actor: actor,
                    within: lifecycle
                )

            case ExternalAutovisorToolNames.scheduleTask:
                result = await handleExternalScheduleTask(
                    args: args,
                    agent: agent,
                    actor: actor,
                    within: lifecycle
                )

            case ExternalAutovisorToolNames.waitForEvents:
                result = await handleExternalWaitForEvents(
                    args: args,
                    agent: agent,
                    sessionID: sessionID
                )

            case ExternalAutovisorToolNames.taskResult:
                result = await handleExternalTaskResult(
                    args: args,
                    agent: agent,
                    within: lifecycle
                )

            case ExternalAutovisorToolNames.readArtifact:
                result = await handleExternalReadArtifact(
                    args: args,
                    agent: agent,
                    within: lifecycle
                )

            case ExternalAutovisorToolNames.taskLog:
                result = await handleExternalTaskLog(
                    args: args,
                    agent: agent,
                    within: lifecycle
                )

            case ExternalAutovisorToolNames.taskChanges:
                result = await handleExternalTaskChanges(
                    args: args,
                    agent: agent,
                    within: lifecycle
                )

            default:
                result = makeErrorResult(
                    toolName: name,
                    args: args,
                    code: .invalidArgs,
                    message: "Unknown external Autovisor tool '\(name)'.",
                    next: ExternalNextCall.unknownTool.hint()
                )
            }
        }

        let delivered = deliveredToExternalAgent(result, toolName: name, args: args, within: lifecycle)
        let elapsed = ContinuousClock.now - startedAt
        let durationMs = Double(elapsed.components.seconds) * 1_000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        recordExternalAutovisorActivity(
            tool: name,
            args: args,
            agent: agent,
            preCallRoleID: preCallWaitingRoleID,
            result: delivered,
            durationMs: durationMs,
            now: now,
            cancelled: isCancelled(),
            within: lifecycle
        )
        // Activity again at the END, on the clock the call began on, so a long call — a wait above
        // all — counts from when the agent got its answer, not from when it asked. Only in the
        // folder the call was for: a call that outlived its folder is no activity in the next.
        if isCurrentFolderLifecycle(lifecycle) {
            noteExternalAutovisorActivity(now: now.addingTimeInterval(durationMs / 1_000))
        }
        return delivered
    }

    /// The envelope as it leaves for the agent: a refusal that names no next call given the one its
    /// code answers (`ExternalNextCall.ensuringNext`, F6 L1), then its `next` hint fitted to the
    /// hosted tool it names (`HostedMCPNextHintCompletion`). The `folder_id` filled in is the one this call carried and
    /// PROVED — checked again here by the `validateActiveFolderID` its handler ran, in the lifecycle
    /// the call began in, so an id the call omitted or failed, or a folder that changed under it, is
    /// never supplied for it. Every hint-bearing handler ran that same check first, so the two agree.
    private func deliveredToExternalAgent(
        _ handled: ToolExecutionResult,
        toolName: String,
        args: [String: Any],
        within lifecycle: WorkFolderLifecycle
    ) -> ToolExecutionResult {
        let result = ExternalNextCall.ensuringNext(handled, toolName: toolName, args: args)
        let proven = try? validateActiveFolderID(from: args, required: true, within: lifecycle).get().folderID
        let completed = HostedMCPNextHintCompletion.completing(result.outputJSON, provenFolderID: proven)
        guard completed != result.outputJSON else { return result }
        var delivered = result
        delivered.outputJSON = completed
        return delivered
    }

    // MARK: - Validation Helpers

    /// The call's `folder_id` against the folder NanoTeams has open, in the lifecycle the call
    /// began in. The refusal is typed (`ExternalFolderRefusal`), so its code, message and next
    /// call are chosen by case and not read back out of a string.
    func validateActiveFolderID(
        from args: [String: Any],
        required: Bool,
        within lifecycle: WorkFolderLifecycle
    ) -> Result<(folderID: String, snapshot: WorkFolderContext), ExternalFolderRefusal> {
        let snap = snapshot
        if let refusal = ExternalFolderRefusal.classify(
            providedFolderID: extractString(args, "folder_id"),
            required: required,
            isFolderTransitionInProgress: isFolderTransitionInProgress,
            isLifecycleCurrent: isCurrentFolderLifecycle(lifecycle),
            isFolderInUseByAnotherProcess: workFolderHeldByAnotherProcess != nil,
            hasRealWorkFolder: hasRealWorkFolder,
            openFolderID: snap?.projection.id.uuidString
        ) {
            return .failure(refusal)
        }
        // `classify` refuses a missing snapshot as `.noWorkFolder`; this only unwraps it.
        guard let snap else { return .failure(.noWorkFolder) }
        return .success((snap.projection.id.uuidString, snap))
    }

    func loadAndVerifyOwnedTask(
        taskID: Int,
        folderID: String,
        agent: AgentIdentity,
        within lifecycle: WorkFolderLifecycle
    ) async -> Result<NTMSTask, ExternalAutovisorError> {
        if taskID == autovisorTaskID {
            return .failure(.taskNotFound(taskID))
        }
        await ensureTaskLoaded(taskID)
        guard hasRealWorkFolder,
              !isFolderTransitionInProgress,
              isCurrentFolderLifecycle(lifecycle),
              snapshot?.projection.id.uuidString.caseInsensitiveCompare(folderID) == .orderedSame
        else {
            return .failure(.folderChanged)
        }
        guard let task = loadedTask(taskID), task.parentTaskID == nil else {
            return .failure(.taskNotFound(taskID))
        }
        guard case .externalAgent(let owner) = task.origin, owner.id == agent.id else {
            return .failure(.notOwner(taskID))
        }
        return .success(task)
    }

    private func folderChangedToolError(toolName: String, args: [String: Any]) -> ToolExecutionResult {
        ExternalAutovisorError.folderChanged.errorResult(toolName: toolName, args: args)
    }

    /// The answer to a call the decoder read as another tool's command: `AutovisorToolDecoding` and
    /// the handler that asked it drifted apart. Unreachable while the two agree — loud in DEBUG, and
    /// in release an error that names what happened rather than a folder change that did not.
    private func decodedAsAnotherCommandError(
        toolName: String,
        args: [String: Any],
        command: AutovisorCommand
    ) -> ToolExecutionResult {
        assertionFailure("\(toolName) decoded as \(command)")
        return makeErrorResult(
            toolName: toolName,
            args: args,
            code: .commandFailed,
            message: "Internal error: the server decoded this \(toolName) call as a different command, "
                + "so nothing was done. Retrying the same call will not help."
        )
    }

    /// A write refused by readiness. The Autovisor off — or driven by the built-in model — is
    /// `AUTOVISOR_OFF`, with the state in `details.readiness` and `folder_status` next, which says
    /// who switched it and when; a folder that is opening or absent stays `COMMAND_FAILED`, the
    /// code `ExternalFolderRefusal` answers the same states with.
    nonisolated static func readinessRefusalResult(
        state: ExternalAutovisorReadiness.State,
        refusal: ExternalAutovisorReadiness.Refusal,
        toolName: String,
        args: [String: Any]
    ) -> ToolExecutionResult {
        switch refusal {
        case .autovisorDisabled, .builtInDriver:
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .autovisorOff,
                message: refusal.message,
                details: ["readiness": state.rawValue],
                next: ExternalNextCall.autovisorOff.hint())
        case .folderTransition, .folderInUse, .noWorkFolder:
            return makeErrorResult(
                toolName: toolName, args: args, code: .commandFailed, message: refusal.message,
                next: ExternalNextCall.folderNotReady.hint())
        }
    }

    private func validateExternalWritePreconditions(
        toolName: String,
        args: [String: Any],
        within lifecycle: WorkFolderLifecycle
    ) -> Result<(folderID: String, snapshot: WorkFolderContext), ToolExecutionResult> {
        // A state that refuses is a state with a `Refusal` (`ExternalAutovisorReadiness.State.refusal`,
        // `nil` for `.ready` alone — which is what `allowsWrites` says), so the gate reads the
        // refusal itself. The fact AND the fix: every refusing state carries both, and this path
        // once sent only the fact — the agent could tell its user that something was off but not
        // which switch ends it, while the app held the sentence one field away. The instructions
        // promise "a refused call says why; follow its next suggestion"; without the remedy there
        // is no suggestion to follow. Until 2026-11-08 the message was read as an optional with a
        // fallback no refusing state could produce.
        let state = externalAutovisorReadiness.state
        if let refusal = state.refusal {
            return .failure(Self.readinessRefusalResult(state: state, refusal: refusal, toolName: toolName, args: args))
        }
        switch validateActiveFolderID(from: args, required: true, within: lifecycle) {
        case .failure(let refusal):
            return .failure(refusal.errorResult(toolName: toolName, args: args))
        case .success(let validated):
            return .success(validated)
        }
    }

    // MARK: - Write Operations

    private func handleExternalCreateManagedTask(
        args: [String: Any],
        agent: AgentIdentity,
        actor: AutovisorActor,
        now: Date,
        within lifecycle: WorkFolderLifecycle,
        isCancelled: @Sendable () -> Bool
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.createManagedTask
        let folderID: String
        let snap: WorkFolderContext
        switch validateExternalWritePreconditions(toolName: toolName, args: args, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
            snap = validated.snapshot
        }

        let command: AutovisorCommand
        switch AutovisorToolDecoding.decode(tool: toolName, args: args, surface: .externalMCP) {
        case .failure(let failure):
            return failure.result
        case .success(let decoded):
            command = decoded
        }
        guard case .createManagedTask(let title, let brief, let teamID) = command else {
            return decodedAsAnotherCommandError(toolName: toolName, args: args, command: command)
        }

        let requestKey: String? = {
            guard let raw = (args["request_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            return raw
        }()

        // Idempotent retry check BEFORE reserving a slot or creating a duplicate task. The key is
        // read off the index rows: it is stored on the task, so a retry after a relaunch or a
        // folder switch still finds it — until 2026-11-09 only an in-memory map was read, and a
        // retry after either created a second task. A creation still under way has no row yet:
        // the ledger holds its key from the slot's reservation to the commit.
        if let requestKey,
           autovisorCreationLedger.isRequestInFlight(requestKey, for: agent.id) {
            return makeErrorResult(
                toolName: toolName, args: args, code: .requestInProgress,
                message: Self.requestInProgressMessage(requestKey: requestKey),
                next: ExternalNextCall.requestInProgress.hint())
        }
        if let requestKey,
           let existingID = Self.taskCreated(forRequestKey: requestKey, by: agent.id, in: snap.tasksIndex.tasks)
        {
            struct CreateResponse: Codable {
                var folder_id: String
                var status: String
                var task_id: Int
                var message: String
            }
            return makeSuccessResult(
                toolName: toolName,
                args: args,
                data: CreateResponse(
                    folder_id: folderID,
                    status: "already_created",
                    task_id: existingID,
                    message: Self.alreadyCreatedIdempotentMessage(taskID: existingID, requestKey: requestKey)
                )
            )
        }

        // Validate optional `run_timeout_seconds`.
        var runTimeoutSeconds: TimeInterval?
        if let rawTimeout = args["run_timeout_seconds"] {
            guard let seconds = optionalInt(["v": rawTimeout], "v"), seconds >= 0 else {
                return makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: "Invalid parameter 'run_timeout_seconds': must be an integer >= 0."
                )
            }
            runTimeoutSeconds = seconds > 0 ? TimeInterval(seconds) : nil
        }

        // Validate optional flat schedule fields.
        let parsedRecurrence: TaskRecurrence?
        switch Self.parseFlatSchedule(from: args, allowClearFlag: false) {
        case .failure(let err):
            return makeErrorResult(toolName: toolName, args: args, code: .invalidArgs, message: err.message)
        case .success(let scheduleOp):
            if case .set(let rec) = scheduleOp {
                parsedRecurrence = rec
            } else {
                parsedRecurrence = nil
            }
        }

        // Validate optional `attachments` (must stay inside workFolderRoot and outside .nanoteams/).
        guard let rootURL = workFolderURL else { return folderChangedToolError(toolName: toolName, args: args) }
        let validatedAttachments: [String]
        switch validateExternalAttachmentPaths(from: args, workFolderRoot: rootURL) {
        case .failure(let err):
            return makeErrorResult(toolName: toolName, args: args, code: .invalidArgs, message: err.message)
        case .success(let relPaths):
            validatedAttachments = relPaths
        }

        // Synchronous slot reservation BEFORE the first `await` (§10.4, M5).
        let tuning = snap.workFolder.settings.autovisorTuning
        let reservation: AutovisorCreationLedger.Reservation
        switch autovisorCreationLedger.tryReserveSlot(
            for: actor,
            tuning: tuning,
            runningCount: runningTopLevelTaskCount(for: actor),
            openExternalCount: openExternalTaskCount(for: agent.id),
            requestKey: requestKey,
            now: now
        ) {
        case .success(let reserved):
            reservation = reserved
        case .failure(let rejection):
            // `LIMIT_REACHED`, and in `details` which limit, its value, and — for the sliding
            // window, which closing a task never refills — when it next admits a creation.
            let reply: AutovisorReply
            var details: [String: String]
            switch rejection {
            case .tooManyRunning(let count, let limit):
                reply = .tooManyRunning(count: count)
                details = ["limit": "running", "count": "\(count)", "max": "\(limit)"]
            case .tooManyOpenTasks(let count, let limit):
                reply = .openTaskLimitReached(count: count, limit: limit)
                details = ["limit": "open", "count": "\(count)", "max": "\(limit)"]
            case .windowCreationLimitReached(let limit, let windowMinutes):
                reply = .creationWindowLimitReached(limit: limit, windowMinutes: windowMinutes)
                details = ["limit": "window", "max": "\(limit)", "window_minutes": "\(windowMinutes)"]
                if let reopensAt = autovisorCreationLedger.externalWindowReopensAt(
                    for: agent.id, windowMinutes: windowMinutes, now: now) {
                    details["retry_at"] = JSONCoderFactory.iso8601Formatter.string(from: reopensAt)
                }
            // Built-in-only: the ledger raises the per-review cap on the `.builtInManager` arm
            // alone. Kept exhaustive rather than defaulted so adding a rejection breaks here.
            case .reviewCreationLimitReached(let limit):
                reply = .creationLimitReached(limit: limit)
                details = ["limit": "review", "max": "\(limit)"]
            }
            return makeErrorResult(
                toolName: toolName, args: args, code: .limitReached, message: reply.text, details: details,
                next: ExternalNextCall.limitReached.hint())
        }
        var slotCommitted = false
        defer {
            if !slotCommitted {
                autovisorCreationLedger.rollback(reservation)
            }
        }

        // Validate team selection policy.
        let allTeams = snap.workFolder.teams
        let activeTeam = snap.workFolder.activeTeam
        let teamPolicy = AutovisorTeamPolicy(settings: snap.workFolder.settings)
        let resolution = teamPolicy.classify(teamID: teamID, allTeams: allTeams, activeTeam: activeTeam)
        let omitPathIsViable = activeTeam.map {
            !$0.isChatMode && !$0.isHiddenFromPickers && !teamPolicy.blocks(id: $0.id)
        } ?? false
        if let message = teamPolicy.failureMessage(
            for: resolution,
            allTeams: allTeams,
            omitPathIsViable: omitPathIsViable,
            surface: .externalMCP
        ) {
            return makeErrorResult(
                toolName: toolName, args: args, code: .teamRefused, message: message,
                next: ExternalNextCall.teams.hint())
        }

        // Pre-commit cancellation check: rolls back the reserved slot via `defer`.
        if isCancelled() {
            return makeCancelledResult(toolName: toolName, argumentsJSON: encodeArgsToJSON(args))
        }

        let resolvedTeamID: NTMSID?
        switch resolution {
        case .generated:
            resolvedTeamID = await ensureGeneratedTeamID()
            guard isCurrentFolderLifecycle(lifecycle) else { return folderChangedToolError(toolName: toolName, args: args) }
            if isCancelled() {
                return makeCancelledResult(toolName: toolName, argumentsJSON: encodeArgsToJSON(args))
            }
        case .team(let id):
            resolvedTeamID = id
        default:
            resolvedTeamID = nil
        }

        let (creation, creationError) = await surfacingError {
            await createTask(
                title: title,
                supervisorTask: brief,
                preferredTeamID: resolvedTeamID,
                makeActive: false,
                origin: .externalAgent(agent),
                requestKey: requestKey,
                within: lifecycle
            )
        }
        let createdID: Int
        switch creation {
        case .created(let id):
            createdID = id
        case .folderChanged:
            return folderChangedToolError(toolName: toolName, args: args)
        case .notCreated:
            let err = creationError ?? AutovisorReply.creationFailed.text
            return makeErrorResult(toolName: toolName, args: args, code: .commandFailed, message: err)
        }

        // Commit point passed: the slot counts against the window, and the request_key is the
        // task's own (on its index row), so the ledger stops holding it.
        slotCommitted = true
        commitCreation(reservation, now: now)
        autovisorSeenTaskIDs.insert(createdID)
        // From here a folder change is reported with the task it leaves behind.
        func createdThenFolderChanged() -> ToolExecutionResult {
            ExternalAutovisorError.folderChangedAfterCreation(taskID: createdID).errorResult(toolName: toolName, args: args)
        }

        await ensureTaskLoaded(createdID)
        guard isCurrentFolderLifecycle(lifecycle) else { return createdThenFolderChanged() }

        if !validatedAttachments.isEmpty || runTimeoutSeconds != nil || parsedRecurrence != nil {
            await mutateTask(taskID: createdID) { task in
                if !validatedAttachments.isEmpty {
                    task.attachmentPaths = validatedAttachments
                }
                if let runTimeoutSeconds {
                    task.runTimeoutSeconds = runTimeoutSeconds
                }
                if var rec = parsedRecurrence {
                    rec.reschedule(after: Date())
                    task.recurrence = rec
                }
            }
            guard isCurrentFolderLifecycle(lifecycle) else { return createdThenFolderChanged() }
        }

        let isOneShotScheduled: Bool = {
            if let rec = parsedRecurrence, case .once = rec.rule { return true }
            return false
        }()

        let status: String
        let messageText: String

        if isOneShotScheduled {
            status = "created_scheduled"
            let runAt: Date?
            if case let .once(date)? = parsedRecurrence?.rule {
                runAt = date
            } else {
                runAt = nil
            }
            messageText = AutovisorReply.createdScheduled(taskID: createdID, title: title, runAt: runAt).text
        } else if let refusal = externalAutovisorReadiness.state.refusal {
            // Readiness is asked again here, after the create and before the start: the gate at
            // the top passed before every suspension above, and a task started into a folder whose
            // Autovisor went off, or to the built-in driver, in between runs with nobody but a
            // person to approve it — what 8 November's task 3 did (F6 C1). The task stays, its
            // slot spent; the reason says what the person must do, and the reply tells the agent to
            // start it with `control_task start` — refused by the same gate until the folder is ready.
            status = "created_not_started"
            messageText = AutovisorReply.createdNotStarted(
                taskID: createdID, title: title, reason: refusal.message).text
        } else {
            let startError = await surfacingError { await startRun(taskID: createdID) }.error
            guard isCurrentFolderLifecycle(lifecycle) else { return createdThenFolderChanged() }

            let started = (loadedTask(createdID)?.runs.isEmpty == false) || isGeneratingTeam(taskID: createdID)
            status = started ? "created_and_started" : "created_not_started"
            let reply: AutovisorReply = started
                ? .createdAndStarted(taskID: createdID, title: title)
                : .createdNotStarted(taskID: createdID, title: title, reason: startError)
            messageText = reply.text
        }

        var warnings: [String] = []
        let reachability = await llmReachability()
        if reachability.reachable == false {
            warnings.append(ExternalAutovisorOperations.llmUnreachableWarning)
        }

        struct CreateResponse: Codable {
            var folder_id: String
            var status: String
            var task_id: Int
            var message: String
        }
        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: CreateResponse(
                folder_id: folderID,
                status: status,
                task_id: createdID,
                message: messageText
            ),
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    private func validateExternalAttachmentPaths(
        from args: [String: Any],
        workFolderRoot: URL
    ) -> Result<[String], ExternalAutovisorError> {
        guard let rawValue = args["attachments"] else { return .success([]) }
        guard let rawList = rawValue as? [Any] else {
            return .failure(.init("Invalid parameter 'attachments': expected an array of relative file paths."))
        }
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let resolver = SandboxPathResolver(workFolderRoot: workFolderRoot, internalDir: paths.nanoteamsDir)
        let resolvedRoot = workFolderRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedNanoteams = paths.nanoteamsDir.resolvingSymlinksInPath().standardizedFileURL

        var result: [String] = []
        for item in rawList {
            guard let rawPath = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty
            else {
                return .failure(.init("Invalid parameter 'attachments': every attachment path must be a non-empty string."))
            }
            if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
                return .failure(.init(SandboxPathError.absolutePathNotAllowed(rawPath).message))
            }
            let candidateURL: URL
            do {
                candidateURL = try resolver.resolveFileURL(relativePath: rawPath)
            } catch let error as SandboxPathError {
                return .failure(.init(error.message))
            } catch {
                return .failure(.init(error.localizedDescription))
            }
            let symlinkResolved = candidateURL.resolvingSymlinksInPath().standardizedFileURL
            let rel = paths.relativePathFromProjectRoot(for: symlinkResolved)
            guard symlinkResolved != resolvedRoot,
                  !rel.isEmpty,
                  SandboxPathResolver.isWithin(candidate: symlinkResolved, container: resolvedRoot),
                  !SandboxPathResolver.isWithin(candidate: symlinkResolved, container: resolvedNanoteams)
            else {
                return .failure(.init(SandboxPathError.outsideSandbox(rawPath).message))
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: symlinkResolved.path, isDirectory: &isDir),
                  !isDir.boolValue
            else {
                return .failure(.init("Attachment file not found: \(rawPath)"))
            }
            result.append(rel)
        }
        return .success(result)
    }

    private func handleExternalSharedWriteTool(
        name: String,
        args: [String: Any],
        agent: AgentIdentity,
        actor: AutovisorActor,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let folderID: String
        switch validateExternalWritePreconditions(toolName: name, args: args, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
        }

        var argsForDecode = args
        argsForDecode.removeValue(forKey: "folder_id")
        let command: AutovisorCommand
        switch AutovisorToolDecoding.decode(tool: name, args: argsForDecode, surface: .externalMCP) {
        case .failure(let failure):
            return failure.result
        case .success(let decoded):
            command = decoded
        }
        guard let action = command.autovisorAction, let targetTaskID = action.targetTaskID else {
            return decodedAsAnotherCommandError(toolName: name, args: args, command: command)
        }

        switch await loadAndVerifyOwnedTask(
            taskID: targetTaskID,
            folderID: folderID,
            agent: agent,
            within: lifecycle
        ) {
        case .failure(let err):
            return err.errorResult(toolName: name, args: args)
        case .success:
            break
        }

        // A value at or below the elapsed time would pause the run at the watchdog's next tick —
        // for a run still going: running, waiting for an answer, or paused (resume continues it).
        // A run in review or failed, or a task that has not run, takes any value: it is the next
        // run's, or the one a continuation (request_changes, restart) carries on with — measured
        // from that run's start, as the property says (F6 C7). Until 2026-11-12 the age of a run
        // that had finished hours ago refused every value below it.
        if case .controlTask(let tID, .setTimeout(let seconds)) = action, let seconds, seconds > 0,
           let task = loadedTask(tID), task.closedAt == nil, let run = task.runs.last,
           Self.runIsStillGoing(task.derivedStatusFromActiveRun()) {
            let elapsed = Int(MonotonicClock.shared.now().timeIntervalSince(run.createdAt))
            if seconds <= TimeInterval(elapsed) {
                return makeErrorResult(
                    toolName: name,
                    args: args,
                    code: .invalidArgs,
                    message: Self.timeoutNotPastElapsedMessage(elapsedSeconds: elapsed),
                    details: ["elapsed": String(elapsed)],
                    next: ExternalNextCall.timeout.hint(taskID: tID)
                )
            }
        }

        let result = await performAutovisorAction(action, as: actor, within: lifecycle)
        if result.ok {
            struct TimeoutInfo: Codable {
                var value: Int
                var deadline_at: String?
                var remaining: Int?
            }

            struct WriteOKData: Codable {
                var folder_id: String
                var status: String
                var message: String
                var task_id: Int?
                var timeout: TimeoutInfo?
            }

            var timeoutInfo: TimeoutInfo?
            var warnings: [String] = []

            if case .controlTask(let tID, .setTimeout(let seconds)) = action {
                let val = seconds.map { Int($0) } ?? 0
                var deadlineStr: String?
                var remainingSec: Int?

                // A deadline and a countdown are facts about a run the watchdog is watching — one
                // still going. A run in review or failed has neither: the value is a new run's,
                // or a continuation's, and a continuation is measured from this run's start — so
                // when that start is already past the value, continuing pauses at once, and the
                // reply says so (review R4). Until 2026-11-12 it sent a deadline in the past and
                // `remaining` 0 for such a run, with nothing to say what they meant.
                if let seconds, seconds > 0, let task = loadedTask(tID), let run = task.runs.last,
                   task.closedAt == nil {
                    let now = MonotonicClock.shared.now()
                    let deadline = run.createdAt.addingTimeInterval(seconds)
                    if Self.runIsStillGoing(task.derivedStatusFromActiveRun()) {
                        deadlineStr = ISO8601DateFormatter().string(from: deadline)
                        remainingSec = max(0, Int(ceil(deadline.timeIntervalSince(now))))
                    } else if deadline <= now {
                        warnings.append(ExternalAutovisorOperations.continuationPausesAtOnceWarning)
                    }
                }
                timeoutInfo = TimeoutInfo(
                    value: val,
                    deadline_at: deadlineStr,
                    remaining: remainingSec
                )
            }

            return makeSuccessResult(
                toolName: name,
                args: args,
                data: WriteOKData(
                    folder_id: folderID,
                    status: result.outcome?.rawValue ?? "ok",
                    message: result.message,
                    task_id: result.createdTaskID ?? targetTaskID,
                    timeout: timeoutInfo
                ),
                next: result.next,
                meta: ToolResultMeta(warnings: warnings)
            )
        }
        return makeErrorResult(
            toolName: name,
            args: args,
            code: Self.externalCode(for: result.failure),
            message: result.message,
            details: Self.externalDetails(for: result.failure),
            next: result.next ?? Self.externalNext(for: result.failure, taskID: targetTaskID, call: args)
        )
    }

    /// The code a refused action carries to an external agent: its cause where the action named
    /// one, `COMMAND_FAILED` for every other refusal.
    nonisolated static func externalCode(for failure: AutovisorActionFailure?) -> ToolErrorCode {
        switch failure {
        case .taskNotFound?: .taskNotFound
        case .roleNotFound?: .roleNotFound
        case .notWaiting?: .notWaiting
        case .limitReached?: .limitReached
        case .pausedByPerson?: .pausedByPerson
        case .contextChanged?: .conflict
        case nil: .commandFailed
        }
    }

    /// What a refused action's code says beside its message: the pause that stands, for a verb
    /// the person's Pause refused — the reason `task_status` and the `paused` event give.
    nonisolated static func externalDetails(for failure: AutovisorActionFailure?) -> [String: String]? {
        switch failure {
        case .pausedByPerson?: ["pause_reason": AutovisorPauseReason.byPerson.rawValue]
        case .taskNotFound?, .roleNotFound?, .notWaiting?, .limitReached?, .contextChanged?, nil: nil
        }
    }

    /// The call after a refusal the action gave no next call for: whoever got to a question first
    /// is in `task_log`'s `from`; a task id that names nothing is answered by `list_tasks`.
    ///
    /// `call` is the refused call's own arguments: the hint sends again what its case carries
    /// (`ExternalNextCall.carriedArguments`) and the tool it names declares.
    nonisolated static func externalNext(
        for failure: AutovisorActionFailure?, taskID: Int, call: [String: Any] = [:]
    ) -> NextHint {
        let next: ExternalNextCall = switch failure {
        case .notWaiting?: .whoSpoke
        case .taskNotFound?: .taskIDs
        case .roleNotFound?: .roles
        case .limitReached?: .limitReached
        case .pausedByPerson?: .personsResume
        case .contextChanged?: .currentContext
        case nil: .taskState
        }
        return next.hint(taskID: taskID, call: call)
    }

    /// `set_work_folder_context` from an external agent: the action the built-in manager's tool
    /// performs (`performAutovisorAction(.setWorkFolderContext)`), behind the checks a writer from
    /// outside needs for a text the person's own tasks read too (decision A3, revised 2026-11-13).
    /// Before this handler runs, the dispatcher has refused an undeclared argument by name
    /// (`HostedMCPCatalog.undeclaredArgumentsRefusal`), ahead of readiness and the switch, as for
    /// every tool. Then, in order, each refusing with nothing written:
    /// 1. readiness and `folder_id`, as for every write (`validateExternalWritePreconditions`);
    /// 2. the person's switch for this agent (`NOT_ALLOWED`), before anything else it sent is read;
    /// 3. the shared decoder: `content` a string, not empty;
    /// 4. characters that change how text displays (`hiddenScalars`);
    /// 5. an `expected_revision` that is missing or no string;
    /// 6. a call the agent withdrew while it waited for the main actor (`CANCELLED`).
    /// The revision itself is compared inside the write (`updateWorkFolderContext`) — `CONFLICT`
    /// when the text moved — and a folder that changed under the call is `FOLDER_CHANGED`.
    private func handleExternalSetWorkFolderContext(
        args: [String: Any],
        agent: AgentIdentity,
        actor: AutovisorActor,
        within lifecycle: WorkFolderLifecycle,
        isCancelled: @Sendable () -> Bool
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.setWorkFolderContext
        let folderID: String
        switch validateExternalWritePreconditions(toolName: toolName, args: args, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
        }
        guard externalAgentMayReplaceWorkFolderContext(agent) else {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .notAllowed,
                message: Self.contextReplacementNotAllowedMessage,
                details: ["what_the_person_must_do": Self.contextReplacementNotAllowedRemedy])
        }

        var argsForDecode = args
        argsForDecode.removeValue(forKey: "folder_id")
        let expectedRaw = argsForDecode.removeValue(forKey: Self.expectedRevisionKey)
        let command: AutovisorCommand
        switch AutovisorToolDecoding.decode(tool: toolName, args: argsForDecode, surface: .externalMCP) {
        case .failure(let failure):
            return failure.result
        case .success(let decoded):
            command = decoded
        }
        guard case .setWorkFolderContext(let content) = command else {
            return decodedAsAnotherCommandError(toolName: toolName, args: args, command: command)
        }
        if let hidden = Self.hiddenScalars(in: content) {
            return ToolErrorHandler.envelope(
                for: ToolArgumentError.invalidValue(
                    key: "content",
                    detail: Self.contextHiddenCharactersDetail(
                        count: hidden.count, first: hidden.first, position: hidden.position)),
                toolName: toolName,
                args: args)
        }
        // Missing, null or blank is one fault with one remedy: read the context, which publishes
        // the revision beside the text it names.
        let expectedRevision: String
        switch expectedRaw {
        case let raw as String where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            expectedRevision = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        case nil, is NSNull, is String:
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .invalidArgs,
                message: ToolArgumentError.missingRequired(Self.expectedRevisionKey).localizedDescription,
                next: ExternalNextCall.currentContext.hint())
        default:
            return ToolErrorHandler.envelope(
                for: ToolArgumentError.invalidValue(
                    key: Self.expectedRevisionKey, detail: Self.contextRevisionNotARevisionDetail),
                toolName: toolName,
                args: args)
        }
        // The last moment the call can still be withdrawn: past it the text is replaced.
        if isCancelled() {
            return makeCancelledResult(toolName: toolName, argumentsJSON: encodeArgsToJSON(args))
        }

        let result = await performAutovisorAction(
            .setWorkFolderContext(content: content, expectedRevision: expectedRevision),
            as: actor,
            within: lifecycle)
        guard isCurrentFolderLifecycle(lifecycle) else {
            return folderChangedToolError(toolName: toolName, args: args)
        }
        if result.ok {
            struct ContextWriteData: Codable {
                var folder_id: String
                var status: String
                var message: String
            }
            return makeSuccessResult(
                toolName: toolName,
                args: args,
                data: ContextWriteData(folder_id: folderID, status: "ok", message: result.message))
        }
        return makeErrorResult(
            toolName: toolName,
            args: args,
            code: Self.externalCode(for: result.failure),
            message: result.message,
            details: Self.externalDetails(for: result.failure),
            next: result.failure == .contextChanged ? ExternalNextCall.currentContext.hint() : result.next)
    }

    private func handleExternalScheduleTask(
        args: [String: Any],
        agent: AgentIdentity,
        actor: AutovisorActor,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.scheduleTask
        let folderID: String
        switch validateExternalWritePreconditions(toolName: toolName, args: args, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
        }
        guard let taskID = try? requiredInt(args, "task_id") else {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .invalidArgs,
                message: "Missing required parameter: task_id",
                next: ExternalNextCall.taskIDs.hint()
            )
        }

        // A schedule refused for its fields points at the schedule the task has now (F6 L1: four
        // live refusals carried no next call).
        let scheduleNext = ExternalNextCall.schedule.hint(taskID: taskID)
        let scheduleOp: FlatScheduleOperation
        switch Self.parseFlatSchedule(from: args, allowClearFlag: true) {
        case .failure(let err):
            return makeErrorResult(
                toolName: toolName, args: args, code: .invalidArgs, message: err.message, next: scheduleNext)
        case .success(let parsed):
            if case .none = parsed {
                return makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: "Specify a schedule (repeat_every_minutes, repeat_daily_at, repeat_monthly_day, run_once_at) or clear: true.",
                    next: scheduleNext
                )
            }
            scheduleOp = parsed
        }

        switch await loadAndVerifyOwnedTask(
            taskID: taskID,
            folderID: folderID,
            agent: agent,
            within: lifecycle
        ) {
        case .failure(let err):
            return err.errorResult(toolName: toolName, args: args)
        case .success:
            break
        }

        struct ScheduleData: Codable {
            var folder_id: String
            var status: String
            var task_id: Int
            var message: String
        }

        switch Self.scheduleApplication(for: scheduleOp) {
        case .refuse(let message):
            return makeErrorResult(
                toolName: toolName, args: args, code: .invalidArgs, message: message, next: scheduleNext)
        case .setInterval(let intervalMinutes):
            let res = await performAutovisorAction(
                .scheduleTask(taskID: taskID, intervalMinutes: intervalMinutes),
                as: actor,
                within: lifecycle
            )
            guard res.ok else {
                return makeErrorResult(
                    toolName: toolName, args: args, code: .commandFailed, message: res.message, next: scheduleNext)
            }
            return makeSuccessResult(
                toolName: toolName,
                args: args,
                data: ScheduleData(folder_id: folderID, status: "ok", task_id: taskID, message: res.message)
            )
        case .setRecurrence(let recurrence):
            await setTaskRecurrence(taskID: taskID, recurrence: recurrence)
            guard isCurrentFolderLifecycle(lifecycle) else { return folderChangedToolError(toolName: toolName, args: args) }
            if let persisted = loadedTask(taskID)?.recurrence {
                return makeSuccessResult(
                    toolName: toolName,
                    args: args,
                    data: ScheduleData(
                        folder_id: folderID,
                        status: "ok",
                        task_id: taskID,
                        message: "Task #\(taskID) scheduled (\(persisted.rule.summary))."
                    )
                )
            }
        }
        return makeErrorResult(
            toolName: toolName,
            args: args,
            code: .commandFailed,
            message: AutovisorReply.scheduleNotStored(taskID: taskID).text,
            next: scheduleNext
        )
    }

    // MARK: - Flat Schedule Parsing

    enum FlatScheduleOperation {
        case none
        case clear
        case set(TaskRecurrence)
    }

    /// What `schedule_task` applies for a parsed schedule: an interval in minutes through the
    /// shared action (`0` clears the schedule), any other recurrence directly, or a refusal.
    nonisolated enum ScheduleApplication: Equatable {
        case setInterval(minutes: Int)
        case setRecurrence(TaskRecurrence)
        case refuse(message: String)
    }

    /// `.none` — a call that names no schedule — is refused by the argument check before the
    /// ownership check, and refused here again, so that no reordering of the two lets such a call
    /// clear the schedule in place (it did, as `case .none, .clear: intervalMinutes = 0`, until
    /// 2026-11-07). A pure function so that this second refusal, unreachable through the tool
    /// today, is tested directly.
    nonisolated static func scheduleApplication(for operation: FlatScheduleOperation) -> ScheduleApplication {
        switch operation {
        case .none:
            return .refuse(message: "No schedule specified.")
        case .clear:
            return .setInterval(minutes: 0)
        case .set(let recurrence):
            if case .interval(let seconds) = recurrence.rule {
                return .setInterval(minutes: max(1, Int(seconds / 60)))
            }
            return .setRecurrence(recurrence)
        }
    }

    nonisolated static func parseFlatSchedule(
        from args: [String: Any],
        allowClearFlag: Bool
    ) -> Result<FlatScheduleOperation, ExternalAutovisorError> {
        let hasClearFlag = allowClearFlag && optionalBool(args, "clear")

        if let rawMinutes = optionalInt(args, "repeat_every_minutes") {
            guard rawMinutes >= 1 else {
                return .failure(.init("Schedule interval must be >= 1 minute.", code: .invalidArgs))
            }
        }

        let hasInterval = optionalInt(args, "repeat_every_minutes") != nil
        let hasMonthly = optionalInt(args, "repeat_monthly_day") != nil
        let hasDaily = extractString(args, "repeat_daily_at") != nil && !hasMonthly
        let hasOnce = extractString(args, "run_once_at") != nil
        let hasWeekdays = args["repeat_weekdays"] != nil && !(args["repeat_weekdays"] is NSNull)

        // Clear flag cannot be combined with positive schedule fields.
        if hasClearFlag {
            if hasInterval || hasMonthly || hasDaily || hasOnce || hasWeekdays {
                return .failure(.init("Conflict: 'clear' cannot be combined with schedule fields.", code: .invalidArgs))
            }
            return .success(.clear)
        }

        // repeat_weekdays applies strictly to repeat_daily_at (not monthly, interval, or once).
        if hasWeekdays {
            if hasMonthly {
                return .failure(.init("Invalid 'repeat_weekdays': weekdays can only be specified for daily recurrence, not monthly.", code: .invalidArgs))
            }
            if extractString(args, "repeat_daily_at") == nil {
                return .failure(.init("Invalid 'repeat_weekdays': weekdays can only be specified together with 'repeat_daily_at'.", code: .invalidArgs))
            }
        }

        // Multiple schedule kinds check.
        let kindCount = (hasInterval ? 1 : 0) + (hasMonthly ? 1 : 0) + (hasDaily ? 1 : 0) + (hasOnce ? 1 : 0)
        if kindCount > 1 {
            return .failure(.init("Multiple schedule kinds specified: specify only one recurrence type (interval, daily, monthly, or once) or clear: true.", code: .invalidArgs))
        }

        if let minutes = optionalInt(args, "repeat_every_minutes") {
            return .success(.set(TaskRecurrence(rule: .interval(seconds: TimeInterval(minutes * 60)))))
        }

        if let monthlyDay = optionalInt(args, "repeat_monthly_day") {
            guard (1...31).contains(monthlyDay) else {
                return .failure(.init("Invalid 'repeat_monthly_day': must be in 1...31.", code: .invalidArgs))
            }
            let timeStr = extractString(args, "repeat_daily_at") ?? "09:00"
            guard let (hour, minute) = parseHourMinute(timeStr) else {
                return .failure(.init("Invalid 'repeat_daily_at': expected HH:mm in 24-hour format.", code: .invalidArgs))
            }
            return .success(.set(TaskRecurrence(rule: .monthlyAt(day: monthlyDay, hour: hour, minute: minute))))
        }

        if let dailyAt = extractString(args, "repeat_daily_at") {
            guard let (hour, minute) = parseHourMinute(dailyAt) else {
                return .failure(.init("Invalid 'repeat_daily_at': expected HH:mm in 24-hour format.", code: .invalidArgs))
            }
            var calendarWeekdays: Set<Int> = []
            if let rawWeekdays = args["repeat_weekdays"] {
                guard let array = rawWeekdays as? [Any] else {
                    return .failure(.init("Invalid 'repeat_weekdays': expected an array of integers in 1...7.", code: .invalidArgs))
                }
                guard !array.isEmpty else {
                    return .failure(.init("Invalid 'repeat_weekdays': weekday array must not be empty.", code: .invalidArgs))
                }
                for item in array {
                    guard let isoDay = optionalInt(["v": item], "v"), (1...7).contains(isoDay) else {
                        return .failure(.init("Invalid 'repeat_weekdays': weekday values must be integers in 1...7.", code: .invalidArgs))
                    }
                    // ISO weekday: 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat, 7=Sun
                    // Apple Calendar weekday: 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri, 7=Sat
                    let calDay = (isoDay % 7) + 1
                    calendarWeekdays.insert(calDay)
                }
            }
            return .success(.set(TaskRecurrence(rule: .dailyAt(hour: hour, minute: minute, weekdays: calendarWeekdays))))
        }

        if let onceAt = extractString(args, "run_once_at") {
            guard let date = parseRunOnceDate(onceAt) else {
                return .failure(.init("Invalid 'run_once_at': expected an ISO-8601 timestamp.", code: .invalidArgs))
            }
            guard date > Date() else {
                return .failure(.init("Invalid 'run_once_at': timestamp is in the past.", code: .invalidArgs))
            }
            return .success(.set(TaskRecurrence(rule: .once(date: date))))
        }

        return .success(.none)
    }

    nonisolated private static func parseRunOnceDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let localIso = ISO8601DateFormatter()
        localIso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        localIso.timeZone = TimeZone.current
        if let date = localIso.date(from: trimmed) { return date }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            df.dateFormat = fmt
            if let date = df.date(from: trimmed) { return date }
        }
        return nil
    }

    nonisolated private static func parseHourMinute(_ raw: String) -> (Int, Int)? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }
}
