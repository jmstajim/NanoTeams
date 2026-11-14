import Foundation

// MARK: - Orchestrator External Read & Detail Operations (§8.1)

extension NTMSOrchestrator {

    /// What the LOCAL team reads that the brief did not tell it. The Work Folder Context — the
    /// person's text, or an agent's they allowed — rides the system prompt of every role on a
    /// team whose template carries it, under
    /// `## Work folder`, and the built-in manager's own prompt orders it to check that the
    /// context will serve a new team BEFORE creating the task — "afterwards is too late for that
    /// task". An external agent could make no such judgement: it either repeated the project's
    /// durable facts in the brief, spending the small local window on text already in the
    /// prompt, or left them out assuming the team had them. `nil` when nobody has written one.
    ///
    /// `stale` carried a `what_the_person_must_do` beside it until 2026-11-13, sending the agent
    /// to ask the person for an update: an agent the person allows may now replace the text
    /// itself (`set_work_folder_context`), and one they do not is told so by that tool.
    nonisolated struct WorkFolderContextInfo: Codable, Sendable {
        var text: String?
        /// Names the stored text `text` shows (`ProjectSettings.contextRevision`) — what
        /// `set_work_folder_context` requires back as `expected_revision`. Published with the text
        /// and never without it: a revision read with no text is a write permit for a text nobody
        /// read, so `include_context: false` drops both.
        var revision: String?
        var updated_at: String?
        var stale: Bool?
        /// The files whose FULL text is pasted into every role's prompt, versus the ones a
        /// role only sees listed and may read for itself. The person promotes and demotes
        /// them by hand, so "the team has the same conventions I do" is an assumption the
        /// agent could not check.
        var injected_instruction_files: [String]
        var listed_instruction_files: [String]
    }
    /// The inactivity deadline. Under this driver the Autovisor's auto-off counts from the END
    /// of the agent's last call and a wait in progress holds it off
    /// (`evaluateAutovisorAutoDisable`); when it fires every write is refused until a person
    /// turns the Autovisor back on by hand. Turning it on, or handing it to the agent, starts the
    /// count afresh (`restartExternalInactivityCount`) — a base no agent reads here, since the
    /// read is itself a call and moves the base to its own end, which is why the description
    /// names only the call. The app tells the PERSON both halves; this field is how the agent
    /// learns them. `nil` when the person switched auto-off off.
    nonisolated struct AutoOffInfo: Codable, Sendable {
        var after_seconds: Int
        var at: String?
    }

    nonisolated struct ExternalOriginDTO: Codable, Hashable, Sendable {
        var kind: String
        var label: String?
    }

    nonisolated static func externalOriginDTO(
        for origin: TaskOrigin?,
        agentID: UUID
    ) -> (dto: ExternalOriginDTO, mine: Bool) {
        switch origin {
        case nil:
            return (ExternalOriginDTO(kind: "human", label: nil), false)
        case .builtInAutovisor?:
            return (ExternalOriginDTO(kind: "autovisor", label: nil), false)
        case .externalAgent(let identity)?:
            return (
                ExternalOriginDTO(
                    kind: "agent",
                    label: MCPTextSanitizer.singleLine(identity.label)
                ),
                identity.id == agentID
            )
        }
    }

    // MARK: - folder_status helpers

    /// The prompt slot the agent SHARES with the team but could not read. Sanitized like every
    /// other person-authored field that crosses this seam.
    private func workFolderContextInfo(
        snapshot snap: WorkFolderContext?,
        includeContext: Bool = true
    ) -> WorkFolderContextInfo? {
        let raw = (snap?.workFolder.settings.context ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = agentInstructions ?? .empty
        let injected = instructions.injectedFiles.map(\.relativePath)
        let listed = instructions.items.map(\.relativePath).filter { !injected.contains($0) }
        let settings = snap?.workFolder.settings
        let updatedAt = settings?.contextUpdatedAt
        // Against the folder's OWN files: what a team writes under `.nanoteams/` is no project
        // fact the context could have missed (`SearchIndex.maxProjectFileMTime`).
        let isStale: Bool?
        if let maxMTime = searchIndexCoordinator?.maxProjectFileMTime, let updatedAt {
            isStale = maxMTime > updatedAt
        } else {
            // Nothing to compare — no index, an index not built yet, or a context that predates
            // its update time — is not "fresh" (F6 C12): `stale` is absent.
            isStale = nil
        }
        // With the text asked for, the object is there for an empty context too: its revision is
        // what the first write of one sends back.
        guard let stored = settings else { return nil }
        guard includeContext || !raw.isEmpty || !injected.isEmpty || !listed.isEmpty || updatedAt != nil
        else { return nil }
        return .init(
            // As a role reads it (`PromptBuilder.buildWorkFolderContextMessage`): the agent edits
            // the text the roles get, with nothing in it its own write would be refused for.
            text: includeContext ? MCPTextSanitizer.sanitizeDisplayedData(raw) : nil,
            revision: includeContext ? stored.contextRevision : nil,
            updated_at: stored.contextUpdatedAtStamp,
            stale: isStale,
            injected_instruction_files: injected.map(MCPTextSanitizer.singleLine),
            listed_instruction_files: listed.map(MCPTextSanitizer.singleLine))
    }

    /// The deadline only when one is actually armed: auto-off on AND the Autovisor running.
    private func autoOffInfo(
        snapshot snap: WorkFolderContext?
    ) -> AutoOffInfo? {
        let activation = snap?.workFolder.settings.autovisorActivation
        guard let activation, activation.autoDisableEnabled else { return nil }
        return .init(
            after_seconds: Int(activation.autoDisableAfterSeconds),
            at: autovisorAutoDisableAt.map { JSONCoderFactory.iso8601Formatter.string(from: $0) })
    }

    // MARK: - 1. folder_status

    func handleExternalFolderStatus(
        args: [String: Any],
        agent: AgentIdentity,
        actor: AutovisorActor,
        now: Date
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.folderStatus
        let includeContext = optionalBool(args, "include_context", default: true)
        let snap = (hasRealWorkFolder && !isFolderTransitionInProgress) ? snapshot : nil
        let folderID = snap?.projection.id.uuidString ?? ""
        // A folder another NanoTeams process holds still names its path: it is the fact the agent
        // checks its project against, and the refusal is about that folder.
        let path = (snap != nil || workFolderHeldByAnotherProcess != nil) ? workFolderURL?.path : nil
        let name = snap.map { MCPTextSanitizer.singleLine($0.projection.name) }
        let readiness = externalAutovisorReadiness
        let driver = (snap?.workFolder.settings.autovisorDriver ?? .builtInModel).rawValue

        let rawGoal = (snap?.workFolder.settings.autovisorGoal ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let goal: String? = (rawGoal.isEmpty || AutovisorPolicy.goalIsUnset(rawGoal))
            ? nil
            : MCPTextSanitizer.sanitizeData(rawGoal)

        let rawMemory = (snap?.workFolder.settings.autovisorMemory ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultMem = AutovisorConstants.defaultMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        let memory: String? = (rawMemory.isEmpty || rawMemory == defaultMem)
            ? nil
            : MCPTextSanitizer.sanitizeData(rawMemory)

        let tuning = snap?.workFolder.settings.autovisorTuning ?? .default
        let runningCount = runningTopLevelTaskCount(for: actor)
        let openCount = openExternalTaskCount(for: agent.id)
        let windowCount = autovisorCreationLedger.externalWindowCount(
            for: agent.id,
            windowMinutes: tuning.externalCreationWindowMinutes,
            now: now
        )

        let approvals = ExternalAutovisorApprovals.evaluate(
            bashMode: bashPolicy.mode,
            bashAllowRules: bashPolicy.allowRules,
            computerUseMode: computerUsePolicy.mode,
            mcpServers: mcpServerManager?.grantCatalogue.servers ?? []
        )

        struct AgentInfo: Codable {
            var id: String
            var label: String
        }
        struct LLMInfo: Codable {
            var provider: String
            var model: String
            /// The status monitor's last probe; absent until it has probed once.
            var reachable: Bool?
            var checked_at: String?
        }
        struct LimitsInfo: Codable {
            var max_running: Int
            var running: Int
            var max_open: Int
            var open: Int
            var created_in_window: Int
            var window_minutes: Int
            var max_per_window: Int
        }
        struct FolderStatusData: Codable {
            var folder_id: String
            var path: String?
            var name: String?
            var readiness: ExternalAutovisorReadiness
            var driver: String
            var agent: AgentInfo
            var llm: LLMInfo
            var goal: String?
            var memory: String?
            var work_folder_context: WorkFolderContextInfo?
            var auto_off: AutoOffInfo?
            /// `nil` when the person has picked no Xcode scheme, which strips `run_xcodebuild`
            /// and `run_xcodetests` from EVERY role — so "the build passes" is an acceptance
            /// criterion no role could meet, and only `bash` (see `approvals`) can build at all.
            var xcode_scheme: String?
            var limits: LimitsInfo
            var approvals: ExternalAutovisorApprovals
            var event_cursor: String?
            var server_version: String
            var agent_text_version: String
        }

        let lifecycle = currentFolderLifecycle
        let llmStatus = await llmReachability()
        guard isCurrentFolderLifecycle(lifecycle) else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }
        let data = FolderStatusData(
            folder_id: folderID,
            path: path,
            name: name,
            readiness: readiness,
            driver: driver,
            agent: AgentInfo(
                id: agent.id.uuidString,
                label: MCPTextSanitizer.singleLine(agent.label)
            ),
            llm: LLMInfo(
                provider: globalLLMConfig.provider.rawValue,
                model: globalLLMConfig.modelName,
                reachable: llmStatus.reachable,
                checked_at: llmStatus.checkedAt.map { ISO8601DateFormatter().string(from: $0) }
            ),
            goal: goal,
            memory: memory,
            work_folder_context: workFolderContextInfo(snapshot: snap, includeContext: includeContext),
            auto_off: autoOffInfo(snapshot: snap),
            xcode_scheme: snap?.workFolder.settings.selectedScheme
                .flatMap { $0.isEmpty ? nil : MCPTextSanitizer.singleLine($0) },
            limits: LimitsInfo(
                max_running: tuning.maxConcurrentManagedTasks,
                running: runningCount,
                max_open: tuning.maxOpenExternalTasks,
                open: openCount,
                created_in_window: windowCount,
                window_minutes: tuning.externalCreationWindowMinutes,
                max_per_window: tuning.maxExternalCreationsPerWindow
            ),
            approvals: approvals,
            event_cursor: autovisorEventFeed.currentCursor,
            server_version: AppVersion.current,
            agent_text_version: RuntimePromptFingerprint.externalAgent
        )
        return makeSuccessResult(toolName: toolName, args: args, data: data)
    }

    // MARK: - 2. list_teams

    func handleExternalListTeams(
        args: [String: Any],
        within lifecycle: WorkFolderLifecycle
    ) -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.listTeams
        let folderID: String
        let snap: WorkFolderContext
        switch validateActiveFolderID(from: args, required: false, within: lifecycle) {
        case .failure(let refusal):
            return refusal.errorResult(toolName: toolName, args: args)
        case .success(let validated):
            folderID = validated.folderID
            snap = validated.snapshot
        }

        let policy = AutovisorTeamPolicy(settings: snap.workFolder.settings)
        let selectable = policy.selectableTeams(from: snap.workFolder.teams)

        struct RoleItem: Codable {
            var id: String
            var name: String
            var kind: String
            var model: String?
            var tools: [String]
        }
        struct TeamItem: Codable {
            var id: String
            var name: String
            var description: String
            var chat_mode: Bool
            var deliverables: [String]
            var model: String
            var roles: [RoleItem]
            var supervisor_mode: String
            var acceptance_mode: String
            var delegates: Bool
            var reads_work_folder_context: Bool
        }
        struct ListTeamsData: Codable {
            var folder_id: String
            var teams: [TeamItem]
            var generation_allowed: Bool
        }

        let approvalAvailability = ToolApprovalAvailability(
            bashMode: bashPolicy.mode,
            computerUseMode: computerUsePolicy.mode,
            humanPresent: false
        )
        let mcpTools = mcpServerManager?.grantCatalogue.resolvedTools(humanPresent: false) ?? .empty
        let teamModel = effectiveModel(of: nil)

        var textChunksToScan: [String] = []
        let items: [TeamItem] = selectable.map { team in
            let cleanName = MCPTextSanitizer.singleLine(team.name)
            let cleanDesc = MCPTextSanitizer.sanitizeData(team.description)
            textChunksToScan.append(cleanName)
            if !cleanDesc.isEmpty { textChunksToScan.append(cleanDesc) }

            var hasDelegation = false
            let roles = team.nonSupervisorRoles.map { role -> RoleItem in
                if role.hasDelegationConfigured {
                    hasDelegation = true
                }
                let roleName = MCPTextSanitizer.singleLine(role.name)
                textChunksToScan.append(roleName)
                let roleModel = effectiveModel(of: role)
                let schemas = LLMExecutionService.resolveToolSchemas(
                    forDefinition: role,
                    team: team,
                    allTeams: snap.workFolder.teams,
                    selectedScheme: snap.workFolder.settings.selectedScheme,
                    isVisionConfigured: visionLLMConfig != nil,
                    approval: approvalAvailability,
                    autovisorTeamPolicy: policy,
                    mcpTools: mcpTools
                )
                let toolNames = schemas.map(\.name)
                return RoleItem(
                    id: role.id,
                    name: roleName,
                    kind: role.completionType.rawValue,
                    model: (roleModel != teamModel) ? roleModel : nil,
                    tools: toolNames
                )
            }
            return TeamItem(
                id: team.id,
                name: cleanName,
                description: cleanDesc,
                chat_mode: team.isChatMode,
                deliverables: team.supervisorRequiredArtifacts.map(MCPTextSanitizer.singleLine),
                model: teamModel,
                roles: roles,
                supervisor_mode: team.settings.supervisorMode.rawValue,
                acceptance_mode: team.settings.defaultAcceptanceMode.rawValue,
                delegates: hasDelegation,
                reads_work_folder_context: team.readsWorkFolderContext
            )
        }

        let warnings = MCPToolResultMapper.injectionScan(in: textChunksToScan)
        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: ListTeamsData(
                folder_id: folderID,
                teams: items,
                generation_allowed: policy.allowGeneration
            ),
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    // MARK: - 3. list_tasks

    func handleExternalListTasks(
        args: [String: Any],
        agent: AgentIdentity,
        now: Date,
        within lifecycle: WorkFolderLifecycle
    ) -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.listTasks
        let folderID: String
        let snap: WorkFolderContext
        switch validateActiveFolderID(from: args, required: false, within: lifecycle) {
        case .failure(let refusal):
            return refusal.errorResult(toolName: toolName, args: args)
        case .success(let validated):
            folderID = validated.folderID
            snap = validated.snapshot
        }

        let managerID = snap.workFolder.state.autovisorTaskID
        let summaries = snap.tasksIndex.tasks
            .filter { $0.parentTaskID == nil && $0.id != managerID }
            .sorted { $0.updatedAt > $1.updatedAt }

        struct ExternalTaskRow: Codable {
            var id: Int
            var title: String
            var status: String
            var chat_mode: Bool
            var updated_seconds_ago: Int
            var waiting_for_supervisor: Bool?
            var pending_question_count: Int?
            var roles_awaiting_acceptance: Bool?
            var origin: ExternalOriginDTO
            var mine: Bool
            /// The `request_key` the task was created with — what a retried create is matched on.
            /// The owner's own string: absent on another's task.
            var request_key: String?
            /// Present only while a schedule is armed. A rule that resolves to no future
            /// occurrence disables itself (`TaskRecurrence.reschedule`), so its absence here is
            /// the only report that a schedule the agent set has stopped.
            var next_run_at: String?
        }
        struct ListTasksData: Codable {
            var folder_id: String
            var tasks: [ExternalTaskRow]
        }

        var textChunks: [String] = []
        let rows = summaries.map { summary -> ExternalTaskRow in
            let task = statusBearingTask(for: summary)
            let resolvedOrigin = task?.origin ?? summary.origin
            let (originDTO, mine) = Self.externalOriginDTO(for: resolvedOrigin, agentID: agent.id)
            let cleanTitle = MCPTextSanitizer.singleLine(summary.title)
            textChunks.append(cleanTitle)
            let rowStatus = externalTaskStatus(for: summary, task: task).rawValue
            return ExternalTaskRow(
                id: summary.id,
                title: cleanTitle,
                status: rowStatus,
                chat_mode: summary.isChatMode,
                updated_seconds_ago: max(0, Int(now.timeIntervalSince(summary.updatedAt))),
                waiting_for_supervisor: summary.isWaitingForSupervisor ? true : nil,
                pending_question_count: summary.pendingSupervisorQuestionCount.flatMap { $0 > 0 ? $0 : nil },
                roles_awaiting_acceptance: summary.hasRoleAtAcceptanceGate ? true : nil,
                origin: originDTO,
                mine: mine,
                request_key: mine ? summary.requestKey : nil,
                next_run_at: summary.nextRecurrenceFireAt
                    .map { JSONCoderFactory.iso8601Formatter.string(from: $0) }
            )
        }
        let warnings = MCPToolResultMapper.injectionScan(in: textChunks)
        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: ListTasksData(folder_id: folderID, tasks: rows),
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    private func validateExternalFolderAndTaskID(
        toolName: String,
        args: [String: Any],
        within lifecycle: WorkFolderLifecycle
    ) -> Result<(folderID: String, taskID: Int, snapshot: WorkFolderContext), ToolExecutionResult> {
        switch validateActiveFolderID(from: args, required: true, within: lifecycle) {
        case .failure(let refusal):
            return .failure(refusal.errorResult(toolName: toolName, args: args))
        case .success(let validated):
            guard let taskID = try? requiredInt(args, "task_id") else {
                return .failure(makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: "Missing required parameter: task_id",
                    next: ExternalNextCall.taskIDs.hint()
                ))
            }
            return .success((validated.folderID, taskID, validated.snapshot))
        }
    }

    private func validateAndLoadOwnedExternalTask(
        toolName: String,
        args: [String: Any],
        agent: AgentIdentity,
        within lifecycle: WorkFolderLifecycle
    ) async -> Result<(folderID: String, taskID: Int, task: NTMSTask), ToolExecutionResult> {
        let folderID: String
        let taskID: Int
        switch validateExternalFolderAndTaskID(toolName: toolName, args: args, within: lifecycle) {
        case .failure(let errorResult):
            return .failure(errorResult)
        case .success(let validated):
            folderID = validated.folderID
            taskID = validated.taskID
        }
        switch await loadAndVerifyOwnedTask(
            taskID: taskID,
            folderID: folderID,
            agent: agent,
            within: lifecycle
        ) {
        case .failure(let err):
            return .failure(err.errorResult(toolName: toolName, args: args))
        case .success(let loaded):
            return .success((folderID, taskID, loaded))
        }
    }

    /// The task a status of `summary` is read from: the loaded one, or — for the one row whose
    /// index fields cannot tell its status — the task hydrated from disk. A row paused with a role
    /// at its acceptance gate is a gate when nobody paused it and a pause when someone did, and
    /// only the task's run says which (`autovisorPauseReason`). Every other row reads right from
    /// the index, so nothing else is loaded. One rule for `list_tasks` and the `wait_for_events`
    /// heartbeat: until 2026-11-12 (F6 C4) the heartbeat did not hydrate, and a gate the person
    /// paused read `acceptance_gate` there and `paused` in `list_tasks`. The read is quiet: a
    /// task.json that cannot be read leaves the row `paused` and surfaces no error (review R2).
    func statusBearingTask(for summary: TaskSummary) -> NTMSTask? {
        if let loaded = loadedTask(summary.id) { return loaded }
        guard summary.status == .paused && summary.hasRoleAtAcceptanceGate else { return nil }
        _ = ensureTaskLoadedSync(summary.id, reportsLoadFailure: false)
        return loadedTask(summary.id)
    }

    /// The status the external agent reads: the event names (`question`, `review`, `closed`,
    /// `acceptance_gate`) over the domain's derived status.
    ///
    /// `waiting` — a scheduled task that has not run yet — is this mapper's word alone, read off
    /// the index row (`hasRuns == false` beside an armed schedule) or the loaded task; the domain
    /// answers with the task's stored status there (F6 C6). A row at the gate whose task could not
    /// be read is `paused`: whose pause it is, if anyone's, only the run says, and `paused` is the
    /// status that tells the agent to touch nothing (F6 C4).
    func externalTaskStatus(for summary: TaskSummary, task: NTMSTask?) -> ExternalTaskStatus {
        let neverRan = task.map { $0.runs.isEmpty } ?? (summary.hasRuns == false)
        let scheduleArmed = task.map { $0.recurrence?.armedNextFireAt != nil } ?? (summary.nextRecurrenceFireAt != nil)
        let closed = task.map { $0.closedAt != nil } ?? (summary.status == .done)
        if neverRan && scheduleArmed && !closed {
            return .waiting
        }
        if let task {
            let derived = task.derivedStatusFromActiveRun()
            if derived == .paused && autovisorPauseReason(of: task) == nil,
               task.runs.last?.everyRoleIsCompleteOrAwaitingAcceptance == true {
                return .acceptanceGate
            }
            return ExternalTaskStatus(derived)
        }
        return ExternalTaskStatus(summary.status)
    }

    func externalTaskStatus(for task: NTMSTask) -> ExternalTaskStatus {
        externalTaskStatus(for: task.toSummary(), task: task)
    }

    // MARK: - 4. task_status

    func handleExternalTaskStatus(
        args: [String: Any],
        agent: AgentIdentity,
        now: Date,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.taskStatus
        let folderID: String
        let taskID: Int
        let snap: WorkFolderContext
        switch validateExternalFolderAndTaskID(toolName: toolName, args: args, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
            taskID = validated.taskID
            snap = validated.snapshot
        }
        if taskID == autovisorTaskID {
            return ExternalAutovisorError.taskNotFound(taskID).errorResult(toolName: toolName, args: args)
        }

        await ensureTaskLoaded(taskID)
        guard hasRealWorkFolder,
              !isFolderTransitionInProgress,
              isCurrentFolderLifecycle(lifecycle),
              snapshot?.projection.id.uuidString.caseInsensitiveCompare(folderID) == .orderedSame
        else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }

        guard let task = loadedTask(taskID), task.parentTaskID == nil else {
            return ExternalAutovisorError.taskNotFound(taskID).errorResult(toolName: toolName, args: args)
        }

        let tuning = snap.workFolder.settings.autovisorTuning
        let team = resolvedTeam(for: task)
        let rawLastError = lastErrorMessageForTask(taskID)
        let paths = workFolderURL.map(NTMSPaths.init(workFolderRoot:))
        let (originDTO, mine) = Self.externalOriginDTO(for: task.origin, agentID: agent.id)

        struct StuckRow: Codable { var kind: String; var detail: String? }
        /// A card waiting for a person to Allow or Deny: the step stands still until they do.
        struct ApprovalRow: Codable { var kind: String; var detail: String? }
        struct StepRow: Codable {
            var role_id: String
            var status: String
            var resumable: Bool?
            var role_kind: String?
            /// `planning` or `implementation`, for a role that plans first; absent otherwise.
            var phase: String?
            /// The model the role runs on: its own override, else the folder's.
            var model: String
            var elapsed_seconds: Int
            var idle_seconds: Int?
            var message_count: Int
            var tool_call_count: Int
            var running_tool: String?
            /// The child task this role is synchronously waiting on. A delegating role emits
            /// nothing while the child works and `AutovisorStuckEvaluator` calls it `.notStuck`
            /// on purpose, so without this it is a role that has been silent for half an hour
            /// with no verdict explaining why.
            var delegated_task_id: Int?
            /// What the model server last failed with, while the role retries the request.
            var llm_retry: String?
            var awaiting_approval: ApprovalRow?
            var stuck: StuckRow?
        }
        struct ArtifactRow: Codable {
            var name: String
            var role_id: String
            var path: String?
        }
        struct PendingQuestionRow: Codable {
            var role_id: String
            var question: String
        }
        struct ExternalStatusData: Codable {
            var folder_id: String
            var task_id: Int
            var title: String
            var status: String
            var origin: ExternalOriginDTO
            var mine: Bool
            var chat_mode: Bool
            var elapsed_seconds: Int?
            var run_timeout_seconds: Int?
            var timed_out: Bool
            var steps: [StepRow]
            var artifacts: [ArtifactRow]
            var pending_question: String?
            var pending_questions: [PendingQuestionRow]?
            var last_error: String?
            var roles_needing_acceptance: [String]?
            /// Which run this whole payload describes, and how many there are. Every read here
            /// is `runs.last`, and a recurrence fire appends a run — so on the second fire the
            /// deliverables and the transcript reviewed on the first silently become another
            /// run's, with nothing saying they ever existed.
            var run_id: Int?
            var run_count: Int
            /// Why the task is paused, for an agent that reconnected and reads status instead of
            /// replaying the event that carried it. The four values need four different
            /// remedies; resuming an `iteration_limit` pause re-enters the same loop.
            var pause_reason: String?
            /// The schedule was write-only: two tools set it and none read it back, while the
            /// app's own refusal told the agent to "re-read it with task_status". A rule that
            /// resolves to no future occurrence disables ITSELF, which nothing reported.
            var recurrence: RecurrenceRow?
            var stuck: StuckRow?
            /// The `request_key` the task was created with, on the agent's own task.
            var request_key: String?
            /// Supervisor messages queued for the task, not yet delivered to a role.
            var queued_messages: Int?
            /// Round execution metrics and bash history for the active round.
            var round_summary: RoundSummaryDTO?
        }
        /// The moments named like `list_tasks.next_run_at` (F6 L2): one moment, one name.
        struct RecurrenceRow: Codable {
            var rule: String
            var enabled: Bool
            /// Present only while the schedule is armed — the same value as the row's.
            var next_run_at: String?
            /// When the schedule last started a run.
            var last_run_at: String?
        }

        var steps: [StepRow] = []
        var artifacts: [ArtifactRow] = []
        var taskStuck: StuckRow?
        var textChunksToScan: [String] = [task.title]
        let run = task.runs.last
        // `resumable` promises a resume that runs; on the person's Pause the agent's is refused (D-M18).
        let pausedByThePerson = isPausedInTheApp(task)
        let roleKindByID = Dictionary(
            team.roles.map { ($0.id, $0.completionType.rawValue) },
            uniquingKeysWith: { first, _ in first }
        )
        if let run {
            for step in run.steps {
                let live = streamLastActivityAt(stepID: step.id, taskID: task.id)
                let verdict = AutovisorStuckEvaluator.evaluate(
                    step: step,
                    now: now,
                    lastStreamActivityAt: live,
                    liveStreamText: streamLiveText(stepID: step.id, taskID: task.id),
                    processingStatus: streamProcessingStatus(stepID: step.id, taskID: task.id),
                    hangSeconds: tuning.stuckHangSeconds,
                    prefillHangSeconds: tuning.stuckPrefillHangSeconds,
                    loopRecencySeconds: tuning.stuckLoopRecencySeconds
                )
                let stuckRow = verdict.wireRow.map { StuckRow(kind: $0.kind, detail: $0.detail) }
                if taskStuck == nil, let stuckRow { taskStuck = stuckRow }
                let runningTool = (step.status == .running && AutovisorStatus.hasToolInFlight(step: step))
                    ? step.toolCalls.last?.name : nil

                // The definition the step runs under, found as the runtime finds it.
                let role = team.findRole(byIdentifier: step.effectiveRoleID)
                let awaiting = awaitingApproval(taskID: task.id, stepID: step.id)
                // Only text the result carries is scanned: another's held command is withheld, and a
                // warning about it told the agent one bit about a command it was not shown (F6 S6).
                if let awaiting, mine { textChunksToScan.append(awaiting.detail) }
                let retry = Self.llmRetryNotice(of: step)
                if let retry { textChunksToScan.append(retry) }
                steps.append(StepRow(
                    role_id: step.effectiveRoleID,
                    status: step.status.externalName,
                    resumable: AutovisorStatus.isResumable(
                        step: step,
                        roleStatus: run.roleStatuses[step.effectiveRoleID],
                        taskIsClosed: task.closedAt != nil,
                        pausedByThePerson: pausedByThePerson
                    ) ? true : nil,
                    role_kind: roleKindByID[step.effectiveRoleID],
                    phase: Self.planningPhase(of: step, role: role),
                    model: effectiveModel(of: role),
                    elapsed_seconds: AutovisorStatus.roleElapsedSeconds(step: step, now: now),
                    idle_seconds: step.status == .running
                        ? AutovisorStatus.idleSeconds(step: step, now: now, lastStreamActivityAt: live)
                        : nil,
                    message_count: step.messages.count,
                    tool_call_count: step.toolCalls.count,
                    running_tool: runningTool,
                    delegated_task_id: step.activeDelegationChildID,
                    llm_retry: retry,
                    awaiting_approval: awaiting.map { ApprovalRow(kind: $0.kind, detail: mine ? $0.detail : nil) },
                    stuck: stuckRow
                ))
                for art in step.artifacts {
                    let cleanName = MCPTextSanitizer.singleLine(art.name)
                    textChunksToScan.append(cleanName)
                    let absPath: String? = art.relativePath.flatMap { rel -> String? in
                        guard !rel.isEmpty, let paths else { return nil }
                        return paths.nanoteamsDir.appendingPathComponent(rel, isDirectory: false)
                            .standardizedFileURL.path
                    }
                    artifacts.append(ArtifactRow(
                        name: cleanName,
                        role_id: step.effectiveRoleID,
                        path: absPath
                    ))
                }
            }
        }

        let answerableRows: [PendingQuestionRow] = task.answerableSupervisorSteps.compactMap { step in
            guard let question = step.formattedSupervisorQuestion else { return nil }
            let cleanQuestion = MCPTextSanitizer.sanitizeData(question)
            textChunksToScan.append(cleanQuestion)
            return PendingQuestionRow(role_id: step.effectiveRoleID, question: cleanQuestion)
        }
        let pendingQuestion = answerableRows.first?.question
        let pendingQuestions: [PendingQuestionRow]? = answerableRows.isEmpty ? nil : answerableRows

        let cleanLastError = rawLastError.map(MCPTextSanitizer.sanitizeData)
        if let cleanLastError { textChunksToScan.append(cleanLastError) }

        var rolesNeedingAcceptance: [String]?
        if let run {
            let ids = AcceptanceService.actionableAcceptanceGates(run: run)
            if !ids.isEmpty { rolesNeedingAcceptance = ids }
        }

        // Only the owner can close it: another's task in Review is not this agent's to close, and
        // the hint sent it into the refusal it was about to get (`NOT_OWNER`).
        let next: NextHint? = mine && task.isReadyForFinalAcceptance
            ? AutovisorStatus.closeTaskHint(taskID: task.id, reason: LLMExecutionService.reviewReadyCloseReason)
            : nil

        let roundSummary: RoundSummaryDTO? = run.map {
            let full = RoundSummaryDTO.build(for: $0)
            return mine ? full : full.redactedForForeignTask()
        }
        if mine, let summary = roundSummary {
            for br in summary.bash_runs {
                textChunksToScan.append(br.command)
                textChunksToScan.append(br.outcome)
            }
        }
        let warnings = MCPToolResultMapper.injectionScan(in: textChunksToScan)
        let queuedMessages = messageQueue.queuedMessageCount(for: task.id)

        let data = ExternalStatusData(
            folder_id: folderID,
            task_id: task.id,
            title: MCPTextSanitizer.singleLine(task.title),
            status: externalTaskStatus(for: task).rawValue,
            origin: originDTO,
            mine: mine,
            chat_mode: task.isChatMode,
            elapsed_seconds: AutovisorStatus.taskElapsedSeconds(run: run, closedAt: task.closedAt, now: now),
            run_timeout_seconds: task.runTimeoutSeconds.map { Int($0) },
            timed_out: autovisorPauseReason(of: task) == .timedOut,
            steps: steps,
            artifacts: artifacts,
            pending_question: pendingQuestion,
            pending_questions: pendingQuestions,
            last_error: cleanLastError,
            roles_needing_acceptance: rolesNeedingAcceptance,
            run_id: run?.id,
            run_count: task.runs.count,
            pause_reason: autovisorPauseReason(of: task)?.rawValue,
            recurrence: task.recurrence.map { rec in
                RecurrenceRow(
                    rule: MCPTextSanitizer.singleLine(rec.rule.summary),
                    enabled: rec.isEnabled,
                    next_run_at: rec.armedNextFireAt.map { JSONCoderFactory.iso8601Formatter.string(from: $0) },
                    last_run_at: rec.lastFiredAt.map { JSONCoderFactory.iso8601Formatter.string(from: $0) })
            },
            stuck: taskStuck,
            request_key: mine ? task.requestKey : nil,
            queued_messages: queuedMessages > 0 ? queuedMessages : nil,
            round_summary: roundSummary
        )
        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: data,
            next: next,
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    // MARK: - 5. wait_for_events

    /// The word an event's `by` names its actor with: `agent` for an external agent, `person` for
    /// the person — and for the built-in Autovisor, which acts in the app on the person's behalf.
    nonisolated static func wireActor(_ actor: ControlActor) -> String {
        switch actor {
        case .externalAgent: "agent"
        case .person, .builtInAutovisor: "person"
        }
    }

    func handleExternalWaitForEvents(
        args: [String: Any],
        agent: AgentIdentity,
        sessionID: String?
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.waitForEvents
        let after = extractString(args, "after")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var taskIDs: Set<Int>?
        if let rawTaskIDs = args["task_ids"] {
            guard let array = rawTaskIDs as? [Any] else {
                return makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: "Invalid parameter 'task_ids': expected an array of integers.",
                    next: ExternalNextCall.fixArgument.hint(after: toolName, call: args, correcting: ["task_ids"])
                )
            }
            var parsed: Set<Int> = []
            for item in array {
                // Task ids are a per-folder counter that starts at 0, so 0 is the folder's first task.
                guard let id = optionalInt(["v": item], "v"), id >= 0 else {
                    return makeErrorResult(
                        toolName: toolName,
                        args: args,
                        code: .invalidArgs,
                        message: "Invalid parameter 'task_ids': task IDs must be non-negative integers.",
                        next: ExternalNextCall.taskIDs.hint()
                    )
                }
                parsed.insert(id)
            }
            taskIDs = parsed
        }

        let timeoutSeconds: TimeInterval
        if let rawTimeout = args["timeout_seconds"] {
            guard let sec = optionalInt(["v": rawTimeout], "v"),
                  (0...HostedMCPConstants.maxWaitSeconds).contains(sec) else {
                return makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: "Invalid parameter 'timeout_seconds': must be an integer between 0 and \(HostedMCPConstants.maxWaitSeconds).",
                    next: ExternalNextCall.waitTimeout.hint(call: args)
                )
            }
            timeoutSeconds = TimeInterval(sec)
        } else {
            timeoutSeconds = TimeInterval(HostedMCPConstants.defaultWaitSeconds)
        }

        // A wait begun while the folder cannot be supervised from here ends at once and says why
        // (`AutovisorWaitStopReason.immediate`), shaped as any stopped wait is.
        let waitResult: AutovisorWaitResult
        if let stop = AutovisorWaitStopReason.immediate(for: externalAutovisorReadiness.state) {
            waitResult = .stopped(stop, keeping: after, waitedSeconds: 0)
        } else {
            waitResult = await autovisorEventFeed.waitForEvents(
                agentID: agent.id,
                sessionID: sessionID,
                after: after,
                taskIDs: taskIDs,
                timeoutSeconds: timeoutSeconds
            )
        }

        struct EventDTO: Codable {
            var seq: Int?
            var task_id: Int
            var kind: String
            var title: String
            var role_id: String?
            var question: String?
            var pause_reason: String?
            var by: String?
            var error_message: String?
            var round_summary: RoundSummaryDTO?
        }
        struct WaitData: Codable {
            var folder_id: String
            var events: [EventDTO]
            var cursor: String?
            var waited_seconds: Int
            var timed_out: Bool
            var cursor_reset_reason: String?
            var stop_reason: String?
            var tasks: [TaskHeartbeatSummary]?
        }

        var textChunksToScan: [String] = []
        let eventDTOs = waitResult.events.map { ev -> EventDTO in
            let cleanTitle = MCPTextSanitizer.singleLine(ev.title)
            let cleanQuestion = ev.question.map(MCPTextSanitizer.sanitizeData)
            let cleanError = ev.errorMessage.map(MCPTextSanitizer.sanitizeData)
            textChunksToScan.append(cleanTitle)
            if let cleanQuestion { textChunksToScan.append(cleanQuestion) }
            if let cleanError { textChunksToScan.append(cleanError) }

            // The feed delivers only this agent's own tasks (`AutovisorEventFeed` checks the
            // owner before it materializes an event), so a summary here is always the agent's
            // own, in full. A foreign-task branch stood here until 2026-11-12 that no event could
            // reach (S7d); `task_status` is where a foreign task's summary is redacted.
            let summary = ev.roundSummary
            if let rs = ev.roundSummary {
                for br in rs.bash_runs {
                    textChunksToScan.append(br.command)
                    textChunksToScan.append(br.outcome)
                }
            }

            return EventDTO(
                seq: ev.seq,
                task_id: ev.taskID,
                kind: ev.kind.rawValue,
                title: cleanTitle,
                role_id: ev.roleID,
                question: cleanQuestion,
                pause_reason: ev.pauseReason?.rawValue,
                by: ev.by.map(Self.wireActor),
                error_message: cleanError,
                round_summary: summary
            )
        }

        let folderID = (hasRealWorkFolder && !isFolderTransitionInProgress)
            ? (snapshot?.projection.id.uuidString ?? "")
            : ""
        var heartbeatTasks: [TaskHeartbeatSummary]? = nil
        if waitResult.timedOut && eventDTOs.isEmpty {
            heartbeatTasks = buildHeartbeatTasks(agent: agent, taskIDs: taskIDs)
            for hb in heartbeatTasks ?? [] {
                if let detail = hb.awaiting_approval?.detail {
                    textChunksToScan.append(detail)
                }
            }
        }
        let warnings = MCPToolResultMapper.injectionScan(in: textChunksToScan)
        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: WaitData(
                folder_id: folderID,
                events: eventDTOs,
                cursor: waitResult.cursor,
                waited_seconds: max(0, Int(waitResult.waitedSeconds.rounded())),
                timed_out: waitResult.timedOut,
                cursor_reset_reason: waitResult.cursorResetReason?.rawValue,
                stop_reason: waitResult.stopReason?.rawValue,
                tasks: heartbeatTasks
            ),
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    private func buildHeartbeatTasks(
        agent: AgentIdentity,
        taskIDs: Set<Int>?,
        now: Date = MonotonicClock.shared.now()
    ) -> [TaskHeartbeatSummary] {
        guard let summaries = snapshot?.tasksIndex.tasks else { return [] }
        let managerID = autovisorTaskID
        var results: [TaskHeartbeatSummary] = []

        for summary in summaries where summary.parentTaskID == nil && summary.id != managerID {
            if let taskIDs, !taskIDs.contains(summary.id) { continue }

            // Whose row it is the row says — an origin is written with its task and never changes
            // — so another's row is skipped before anything is read for it. Until 2026-11-12
            // (review R2) ownership was read off the hydrated task, and every poll loaded another
            // agent's or the person's task at its gate, recovery included, to learn it.
            guard Self.externalOriginDTO(for: summary.origin, agentID: agent.id).mine else { continue }
            let task = statusBearingTask(for: summary)

            if taskIDs == nil {
                let isClosed = (task?.closedAt != nil) || summary.status == .done
                if isClosed { continue }
            }

            let status = externalTaskStatus(for: summary, task: task).rawValue
            let run = task?.runs.last

            let team = task.map { resolvedTeam(for: $0) }
            var runningStep: StepExecution? = nil
            var toolCallCount = 0
            var latestActivity: Date? = nil
            var awaitingApprovalDTO: HeartbeatApprovalDTO? = nil

            if let steps = run?.steps {
                for step in steps {
                    toolCallCount += step.toolCalls.count
                    if runningStep == nil && step.status == .running {
                        runningStep = step
                    }
                    let live = streamLastActivityAt(stepID: step.id, taskID: summary.id)
                    let act = AutovisorStatus.lastActivity(step: step, lastStreamActivityAt: live)
                    if latestActivity == nil || act > latestActivity! {
                        latestActivity = act
                    }
                    if awaitingApprovalDTO == nil, let awaiting = awaitingApproval(taskID: summary.id, stepID: step.id) {
                        awaitingApprovalDTO = HeartbeatApprovalDTO(kind: awaiting.kind, detail: awaiting.detail)
                    }
                }
            }

            let role: TeamRoleDefinition?
            if let roleID = runningStep?.effectiveRoleID {
                role = team?.findRole(byIdentifier: roleID)
            } else {
                role = nil
            }
            let phase = runningStep.flatMap { Self.planningPhase(of: $0, role: role) }
            let elapsedSeconds: Int? = (task != nil)
                ? (AutovisorStatus.taskElapsedSeconds(run: run, closedAt: task?.closedAt, now: now) ?? 0)
                : nil
            let toolCalls: Int? = (task != nil) ? toolCallCount : nil

            if latestActivity == nil {
                latestActivity = task?.updatedAt ?? summary.updatedAt
            }
            let lastActivityAt = latestActivity.map { JSONCoderFactory.iso8601Formatter.string(from: $0) }

            results.append(TaskHeartbeatSummary(
                task_id: summary.id,
                status: status,
                phase: phase,
                elapsed_seconds: elapsedSeconds,
                tool_call_count: toolCalls,
                last_activity_at: lastActivityAt,
                awaiting_approval: awaitingApprovalDTO
            ))
        }

        return results
    }

    // MARK: - 6. task_result

    func handleExternalTaskResult(
        args: [String: Any],
        agent: AgentIdentity,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.taskResult
        let folderID: String
        let taskID: Int
        let task: NTMSTask
        switch await validateAndLoadOwnedExternalTask(toolName: toolName, args: args, agent: agent, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
            taskID = validated.taskID
            task = validated.task
        }

        let team = resolvedTeam(for: task)
        let requiredNames = team.supervisorRequiredArtifacts
        let requiredSet = Set(requiredNames)
        guard let rootURL = workFolderURL else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }
        let paths = NTMSPaths(workFolderRoot: rootURL)
        let expectedTaskDir = paths.taskDir(taskID: taskID).resolvingSymlinksInPath().standardizedFileURL

        struct IndexRow: Codable {
            var name: String
            var role_id: String
            var path: String
            var bytes: Int
        }
        struct DeliverableRow: Codable {
            var name: String
            var role_id: String
            var path: String
            var bytes: Int
            var content: String
        }
        struct ChangedFileRow: Codable {
            var path: String
            var tool: String
            var count: Int
        }
        /// A turn of the conversation, as `task_log` lists it (`AutovisorTaskTranscript`).
        struct RecentMessageRow: Codable {
            var at: String
            var from: String
            var kind: String
            var text: String
        }

        var indexRows: [IndexRow] = []
        var deliverableRows: [DeliverableRow] = []
        var otherArtifactRows: [IndexRow] = []
        var producedNames: Set<String> = []
        var changedCounts: [String: Int] = [:]
        var changedOrder: [(path: String, tool: String)] = []
        var textChunksToScan: [String] = [task.title]

        struct PendingArtifactRead: Sendable {
            var rawName: String
            var cleanName: String
            var roleID: String
            var relativePath: String?
            var isDeliverable: Bool
        }
        struct ResolvedArtifactRead: Sendable {
            var rawName: String
            var cleanName: String
            var roleID: String
            var resolvedPath: String
            var byteCount: Int
            var textContent: String?
            var isDeliverable: Bool
        }

        var pendingReads: [PendingArtifactRead] = []
        if let run = task.runs.last {
            for step in run.steps {
                let roleID = step.effectiveRoleID
                for art in step.artifacts {
                    let cleanName = MCPTextSanitizer.singleLine(art.name)
                    textChunksToScan.append(cleanName)
                    producedNames.insert(art.name)
                    pendingReads.append(PendingArtifactRead(
                        rawName: art.name,
                        cleanName: cleanName,
                        roleID: roleID,
                        relativePath: art.relativePath,
                        isDeliverable: requiredSet.isEmpty || requiredSet.contains(art.name)
                    ))
                }
            }
        }

        let nanoteamsDir = paths.nanoteamsDir
        let resolvedArtifacts: [ResolvedArtifactRead] = if pendingReads.isEmpty {
            []
        } else {
            await Task.detached(priority: .userInitiated) {
                pendingReads.map { item in
                    var resolvedPath = ""
                    var byteCount = 0
                    var textContent: String?
                    if let rel = item.relativePath, !rel.isEmpty,
                       !rel.split(separator: "/").contains("..") {
                        let candidate = nanoteamsDir.appendingPathComponent(rel, isDirectory: false)
                        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                        if SandboxPathResolver.isWithin(candidate: resolved, container: expectedTaskDir),
                           resolved != expectedTaskDir {
                            resolvedPath = resolved.path
                            if let data = try? Data(contentsOf: resolved) {
                                byteCount = data.count
                                if !data.contains(0x00), let str = String(data: data, encoding: .utf8) {
                                    textContent = MCPTextSanitizer.sanitizeData(str)
                                }
                            }
                        }
                    }
                    return ResolvedArtifactRead(
                        rawName: item.rawName,
                        cleanName: item.cleanName,
                        roleID: item.roleID,
                        resolvedPath: resolvedPath,
                        byteCount: byteCount,
                        textContent: textContent,
                        isDeliverable: item.isDeliverable
                    )
                }
            }.value
        }

        guard hasRealWorkFolder,
              !isFolderTransitionInProgress,
              isCurrentFolderLifecycle(lifecycle),
              snapshot?.projection.id.uuidString.caseInsensitiveCompare(folderID) == .orderedSame
        else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }

        for item in resolvedArtifacts {
            if let textContent = item.textContent {
                textChunksToScan.append(textContent)
            }
            let idxRow = IndexRow(
                name: item.cleanName,
                role_id: item.roleID,
                path: item.resolvedPath,
                bytes: item.byteCount
            )
            indexRows.append(idxRow)
            if item.isDeliverable {
                deliverableRows.append(DeliverableRow(
                    name: item.cleanName,
                    role_id: item.roleID,
                    path: item.resolvedPath,
                    bytes: item.byteCount,
                    content: item.textContent ?? ""
                ))
            } else {
                otherArtifactRows.append(idxRow)
            }
        }

        if let run = task.runs.last {
            for step in run.steps {
                for call in step.toolCalls where call.isError != true && ToolHandlerRegistry.fileWriteTools.contains(call.name) {
                    // Under the tool's own names (`ToolCallArguments.displayArguments`): an executed
                    // call is stored as its handler received it, but one stored as the model wrote
                    // it may say `file_path` — the same write either way.
                    guard let raw = JSONUtilities.parseJSONDictionary(call.argumentsJSON) else { continue }
                    let dict = ToolCallArguments.displayArguments(raw, toolName: call.name)
                    guard let path = (dict["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !path.isEmpty
                    else { continue }
                    let key = "\(call.name)\u{00}\(path)"
                    if changedCounts[key] == nil {
                        changedOrder.append((path: path, tool: call.name))
                        changedCounts[key] = 1
                    } else {
                        changedCounts[key, default: 0] += 1
                    }
                }
            }
        }

        // The latest ten turns of the conversation, by when they were said and with who said
        // them — the same entries `task_log` lists. Until 2026-11-09 these were the last ten
        // step messages in STEP order, each under its step's role: a Supervisor's revision read
        // as the role's own words, and an early role's last note outranked a later one's.
        let recentMessages = AutovisorTaskTranscript.entries(of: task)
            .filter(\.kind.isConversational)
            .suffix(10)
            .map { entry -> RecentMessageRow in
                textChunksToScan.append(entry.text)
                return RecentMessageRow(
                    at: JSONCoderFactory.iso8601Formatter.string(from: entry.at),
                    from: entry.from,
                    kind: entry.kind.rawValue,
                    text: entry.text)
            }
        let missing = requiredNames.filter { !producedNames.contains($0) }
        let changedFiles: [ChangedFileRow] = changedOrder.map { entry in
            let key = "\(entry.tool)\u{00}\(entry.path)"
            return ChangedFileRow(
                path: entry.path,
                tool: entry.tool,
                count: changedCounts[key] ?? 1
            )
        }

        let next: NextHint? = task.isReadyForFinalAcceptance
            ? AutovisorStatus.closeTaskHint(taskID: task.id, reason: LLMExecutionService.reviewReadyCloseReason)
            : nil
        let warnings = MCPToolResultMapper.injectionScan(in: textChunksToScan)
        let meta = ToolResultMeta(warnings: warnings)

        // Serialize `data` with `"index"` first, before `"deliverables"` and `"changed_files"`,
        // so clients that truncate large tool outputs from the tail always keep the path index (§8.1).
        let encoder = JSONCoderFactory.makeWireEncoder()
        func encodeFragment<T: Encodable>(_ value: T) -> String {
            guard let data = try? encoder.encode(value),
                  let str = String(data: data, encoding: .utf8)
            else { return "null" }
            return str
        }

        let orderedDataPairs: [(String, String)] = [
            ("folder_id", encodeFragment(folderID)),
            ("task_id", encodeFragment(task.id)),
            ("title", encodeFragment(MCPTextSanitizer.singleLine(task.title))),
            ("status", encodeFragment(externalTaskStatus(for: task).rawValue)),
            ("index", encodeFragment(indexRows)),
            ("deliverables", encodeFragment(deliverableRows)),
            ("missing", encodeFragment(missing)),
            ("other_artifacts", encodeFragment(otherArtifactRows)),
            ("changed_files", encodeFragment(changedFiles)),
            ("changed_files_note", encodeFragment(Self.changedFilesBashNote)),
            ("recent_messages", encodeFragment(recentMessages)),
        ]
        let dataObjectJSON = "{" + orderedDataPairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        let envelopeJSON = "{"
            + "\"data\":\(dataObjectJSON),"
            + "\"error\":null,"
            + "\"meta\":\(encodeFragment(meta)),"
            + "\"next\":\(encodeFragment(next)),"
            + "\"ok\":true"
            + "}"

        return ToolExecutionResult(
            toolName: toolName,
            argumentsJSON: encodeArgsToJSON(args),
            outputJSON: envelopeJSON,
            isError: false
        )
    }

    // MARK: - 7. read_artifact

    func handleExternalReadArtifact(
        args: [String: Any],
        agent: AgentIdentity,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.readArtifact
        guard let artifactName = (try? requiredNonEmptyString(args, "name"))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !artifactName.isEmpty
        else {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .invalidArgs,
                message: "Missing required parameter: name",
                next: ExternalNextCall.artifacts.hint(taskID: optionalInt(args, "task_id"))
            )
        }
        let targetRoleID = extractString(args, "role_id")?.trimmingCharacters(in: .whitespacesAndNewlines)

        let folderID: String
        let taskID: Int
        let task: NTMSTask
        switch await validateAndLoadOwnedExternalTask(toolName: toolName, args: args, agent: agent, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
            taskID = validated.taskID
            task = validated.task
        }

        // A task that never ran has no artifact to read: the same refusal as a wrong name, with
        // nothing in `available`.
        let steps = task.runs.last?.steps ?? []
        if let targetRoleID, !targetRoleID.isEmpty,
           !steps.contains(where: { $0.effectiveRoleID == targetRoleID }) {
            // A wrong role id is its own mistake: answering "no such artifact, none available" would
            // send the agent hunting for a name when the role was what it got wrong.
            let roles = Self.uniqueInOrder(steps.filter { !$0.artifacts.isEmpty }.map(\.effectiveRoleID))
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .roleNotFound,
                message: "Task #\(taskID) has no role '\(targetRoleID)' in its latest run.",
                details: ["roles_with_artifacts": roles.isEmpty ? "(none)" : roles.joined(separator: ", ")],
                next: ExternalNextCall.roles.hint(taskID: taskID)
            )
        }

        let searched = steps.filter { step in
            guard let targetRoleID, !targetRoleID.isEmpty else { return true }
            return step.effectiveRoleID == targetRoleID
        }
        var matchedStepRoleID: String?
        var matchedArtifact: Artifact?
        stepSearch: for step in searched.reversed() {
            for candidate in step.artifacts.reversed() where Self.artifact(candidate, isNamed: artifactName) {
                matchedStepRoleID = step.effectiveRoleID
                matchedArtifact = candidate
                break stepSearch
            }
        }
        guard let artifact = matchedArtifact, let roleID = matchedStepRoleID else {
            let available = Self.uniqueInOrder(searched.flatMap { $0.artifacts.map { MCPTextSanitizer.singleLine($0.name) } })
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .artifactNotFound,
                message: "Artifact '\(artifactName)' not found on task #\(taskID).",
                details: ["available": available.isEmpty ? "(none)" : available.joined(separator: ", ")],
                next: ExternalNextCall.artifacts.hint(taskID: taskID)
            )
        }

        guard let relPath = artifact.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relPath.isEmpty,
              !relPath.hasPrefix("/"),
              !relPath.hasPrefix("~"),
              !relPath.split(separator: "/").contains("..")
        else {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .commandFailed,
                message: "Artifact '\(artifactName)' path is invalid or outside the task directory.",
                next: ExternalNextCall.artifacts.hint(taskID: taskID)
            )
        }

        guard let rootURL = workFolderURL else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }
        let paths = NTMSPaths(workFolderRoot: rootURL)
        let expectedTaskDir = paths.taskDir(taskID: taskID).resolvingSymlinksInPath().standardizedFileURL
        let candidateURL = paths.nanoteamsDir.appendingPathComponent(relPath, isDirectory: false)
        let resolvedFileURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL

        guard resolvedFileURL != expectedTaskDir,
              SandboxPathResolver.isWithin(candidate: resolvedFileURL, container: expectedTaskDir)
        else {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .commandFailed,
                message: "Artifact '\(artifactName)' resolves outside task #\(taskID)'s directory.",
                next: ExternalNextCall.artifacts.hint(taskID: taskID)
            )
        }

        // Read file off MainActor, then re-verify folder lifecycle (§8.1).
        let readResult: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Data(contentsOf: resolvedFileURL) }
        }.value

        guard hasRealWorkFolder,
              !isFolderTransitionInProgress,
              isCurrentFolderLifecycle(lifecycle),
              snapshot?.projection.id.uuidString.caseInsensitiveCompare(folderID) == .orderedSame
        else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }

        let fileData: Data
        switch readResult {
        case .failure(let error):
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .commandFailed,
                message: "Could not read artifact '\(artifactName)' at \(resolvedFileURL.path): \(error.localizedDescription)",
                next: ExternalNextCall.deliverableLog.hint(taskID: taskID)
            )
        case .success(let data):
            fileData = data
        }

        guard artifact.mimeType != "application/octet-stream",
              !fileData.contains(0x00),
              let rawText = String(data: fileData, encoding: .utf8)
        else {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .commandFailed,
                message: "Artifact '\(artifactName)' is a binary file (\(fileData.count) bytes) at \(resolvedFileURL.path). Inspect it directly from disk.",
                next: ExternalNextCall.artifacts.hint(taskID: taskID)
            )
        }

        let cleanContent = MCPTextSanitizer.sanitizeData(rawText)
        let cleanName = MCPTextSanitizer.singleLine(artifact.name)
        let warnings = MCPToolResultMapper.injectionScan(in: [cleanName, cleanContent])

        struct ReadArtifactData: Codable {
            var folder_id: String
            var task_id: Int
            var name: String
            var role_id: String
            var path: String
            var bytes: Int
            var content: String
        }

        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: ReadArtifactData(
                folder_id: folderID,
                task_id: taskID,
                name: cleanName,
                role_id: roleID,
                path: resolvedFileURL.path,
                bytes: fileData.count,
                content: cleanContent
            ),
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    // MARK: - 8. task_log

    func handleExternalTaskLog(
        args: [String: Any],
        agent: AgentIdentity,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.taskLog
        let filterRoleID = extractString(args, "role_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let page: TaskLogPage
        switch Self.taskLogPage(from: args) {
        case .failure(let refusal):
            return refusal.errorResult(toolName: toolName, args: args)
        case .success(let parsed):
            page = parsed
        }

        let folderID: String
        let taskID: Int
        let task: NTMSTask
        switch await validateAndLoadOwnedExternalTask(toolName: toolName, args: args, agent: agent, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
            taskID = validated.taskID
            task = validated.task
        }

        let entries = AutovisorTaskTranscript.entries(of: task, role: filterRoleID)
        let slice = page.slice(of: entries.map(\.cursor))

        struct LogMessageDTO: Codable {
            var at: String
            var from: String
            var kind: String
            var text: String
        }
        struct TaskLogData: Codable {
            var folder_id: String
            var task_id: Int
            var messages: [LogMessageDTO]
            /// Pass as `before` for the entries older than this page; absent at the start.
            var next_before: Int?
            /// Pass as `after` for the entries newer than this page — present on every page, so
            /// an agent reads on from where it stopped. Both are moments (`TaskLogPage`).
            var next_after: Int
        }

        let pageEntries = entries[slice.range]
        let warnings = MCPToolResultMapper.injectionScan(in: pageEntries.map(\.text))
        return makeSuccessResult(
            toolName: toolName,
            args: args,
            data: TaskLogData(
                folder_id: folderID,
                task_id: taskID,
                messages: pageEntries.map {
                    LogMessageDTO(
                        at: JSONCoderFactory.iso8601Formatter.string(from: $0.at),
                        from: $0.from,
                        kind: $0.kind.rawValue,
                        text: $0.text)
                },
                next_before: slice.nextBefore,
                next_after: slice.nextAfter
            ),
            meta: ToolResultMeta(warnings: warnings)
        )
    }

    // MARK: - 9. task_changes

    func handleExternalTaskChanges(
        args: [String: Any],
        agent: AgentIdentity,
        within lifecycle: WorkFolderLifecycle
    ) async -> ToolExecutionResult {
        let toolName = ExternalAutovisorToolNames.taskChanges
        let folderID: String
        let taskID: Int
        let task: NTMSTask
        switch await validateAndLoadOwnedExternalTask(toolName: toolName, args: args, agent: agent, within: lifecycle) {
        case .failure(let errorResult):
            return errorResult
        case .success(let validated):
            folderID = validated.folderID
            taskID = validated.taskID
            task = validated.task
        }

        let currentRun = task.runs.last

        guard let rootURL = workFolderURL else {
            return Self.folderChangedReply(toolName: toolName, args: args)
        }

        var round: Int? = nil
        if let roundRaw = args["round"], !(roundRaw is NSNull) {
            guard let r = optionalInt(args, "round"), r >= 1 else {
                return makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: TaskChangesRefusal.invalidRoundArgument,
                    next: ExternalNextCall.currentRound.hint(taskID: taskID, call: args)
                )
            }
            round = r
        }
        // The run's own round count says which rounds exist, and an omitted round is the run's
        // CURRENT round — not the latest one that has a snapshot, which after a failed start
        // was the round before (N2).
        if let r = round, let currentRun, r > currentRun.round {
            return TaskSnapshotService.roundDoesNotExist(round: r, taskID: taskID)
                .errorResult(toolName: toolName, args: args)
        }
        let targetRound = round ?? currentRun?.round
        let roundIsOpen = taskChangesRoundIsOpen(task: task, round: targetRound)

        var page: Int? = nil
        if let pageRaw = args["page"], !(pageRaw is NSNull) {
            guard let p = optionalInt(args, "page"), p >= 1 else {
                return makeErrorResult(
                    toolName: toolName,
                    args: args,
                    code: .invalidArgs,
                    message: TaskChangesRefusal.invalidPageArgument,
                    next: ExternalNextCall.firstPage.hint(taskID: taskID, call: args)
                )
            }
            page = p
        }

        let filePath = extractString(args, "file_path")?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refused here, where the call's own arguments are, so the hint keeps the round it asked
        // for; `diffChanges` refuses the same shape for its other callers, with none to keep.
        if let filePath, !filePath.isEmpty, TaskChangesRefusal.refuses(filePath: filePath) {
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .invalidArgs,
                message: TaskChangesRefusal.invalidFilePath(filePath),
                next: ExternalNextCall.fixArgument.hint(
                    after: toolName, taskID: taskID, call: args, correcting: ["file_path"])
            )
        }

        do {
            let changes = try await taskSnapshotService.diffChanges(
                workFolder: rootURL,
                folderID: folderID,
                taskID: taskID,
                runID: currentRun?.id,
                round: targetRound,
                roundIsOpen: roundIsOpen,
                page: page,
                pageSize: 5,
                filePath: (filePath?.isEmpty == false) ? filePath : nil
            )
            guard isCurrentFolderLifecycle(lifecycle) else {
                return Self.folderChangedReply(toolName: toolName, args: args)
            }
            let presented = TaskChangesPresentation.present(changes)
            var warnings = TaskChangesWarnings.snapshotFailures(
                currentRun?.snapshotFailures ?? [], round: changes.round, roundIsOpen: roundIsOpen)
            warnings.append(contentsOf: presented.warnings)
            warnings.append(contentsOf: MCPToolResultMapper.injectionScan(in: presented.scanTargets))
            let cleanChanges = presented.result

            return makeSuccessResult(
                toolName: toolName,
                args: args,
                data: cleanChanges,
                meta: ToolResultMeta(warnings: warnings)
            )
        } catch let err as ExternalAutovisorError {
            // An error after a folder transition is the transition's, not the old folder's (N16).
            guard isCurrentFolderLifecycle(lifecycle) else {
                return Self.folderChangedReply(toolName: toolName, args: args)
            }
            if let missingRound = err.missingRoundStart, currentRun != nil {
                return Self.roundStartUnavailable(
                    round: missingRound, failures: currentRun?.snapshotFailures ?? [],
                    taskID: taskID
                ).errorResult(toolName: toolName, args: args)
            }
            // A git failure the snapshot service named no call for (F6 L1).
            return err.namingNext(ExternalNextCall.passLog.hint(taskID: taskID)).errorResult(toolName: toolName, args: args)
        } catch {
            guard isCurrentFolderLifecycle(lifecycle) else {
                return Self.folderChangedReply(toolName: toolName, args: args)
            }
            return makeErrorResult(
                toolName: toolName,
                args: args,
                code: .commandFailed,
                message: error.localizedDescription,
                next: ExternalNextCall.passLog.hint(taskID: taskID)
            )
        }
    }

    /// The folder changed while a read ran: `FOLDER_CHANGED`, and `folder_status` next.
    nonisolated static func folderChangedReply(toolName: String, args: [String: Any]) -> ToolExecutionResult {
        makeErrorResult(
            toolName: toolName,
            args: args,
            code: .folderChanged,
            message: DeferredCallReplies.folderChanged,
            next: ExternalNextCall.folderChanged.hint()
        )
    }

    /// A round of the current run with no start snapshot: `SNAPSHOTS_UNAVAILABLE` with what the
    /// run recorded about it — `timed_out` (still running in the background), `failed` with the
    /// error — or `none_taken`, and the round in `details`, so the refusal says WHICH round.
    nonisolated static func roundStartUnavailable(
        round: Int, failures: [RunSnapshotFailure], taskID: Int
    ) -> ExternalAutovisorError {
        let record = failures.last { $0.round == round && $0.phase == .start && $0.reason != .completedLate }
        var details = ["reason": record?.reason.rawValue ?? "none_taken", "round": "\(round)"]
        if let detail = record?.detail { details["error"] = detail }
        return ExternalAutovisorError(
            TaskChangesRefusal.snapshotsUnavailable(taskID: taskID),
            code: .snapshotsUnavailable,
            details: details,
            next: ExternalNextCall.passLog.hint(taskID: taskID)
        )
    }

    /// Which entries a `task_log` call asks for: the newest `limit` (no cursor), the `limit`
    /// recorded before a moment, or the `limit` recorded after one. A cursor is a MOMENT
    /// (`AutovisorTaskTranscript.Entry.cursor`), not a position: a restart clears the restarted
    /// role's entries and a schedule fire starts a new run, and a position read past either
    /// skipped what came after it or read it twice.
    nonisolated struct TaskLogPage: Equatable {
        enum Anchor: Equatable { case newest, before(Int), after(Int) }
        let anchor: Anchor
        let limit: Int

        static let defaultLimit = 50
        static let maxLimit = 200

        /// The entries a page holds, and the cursors that read on from it either way.
        struct Slice: Equatable {
            let range: Range<Int>
            /// `before` for the entries older than the page; `nil` when there are none.
            let nextBefore: Int?
            /// `after` for the entries newer than the page.
            let nextAfter: Int
        }

        /// The page of a transcript whose entries were recorded at `moments`, oldest first.
        /// It never splits one millisecond: a cursor names a moment and could not say which of
        /// that moment's entries a page had reached, so it takes them all — the one way a page
        /// holds more than `limit`.
        func slice(of moments: [Int]) -> Slice {
            let count = moments.count
            var start: Int
            var end: Int
            switch anchor {
            case .newest:
                end = count
                start = max(0, end - limit)
            case .before(let moment):
                end = moments.firstIndex { $0 >= moment } ?? count
                start = max(0, end - limit)
            case .after(let moment):
                start = moments.firstIndex { $0 > moment } ?? count
                end = min(count, start + limit)
            }
            switch anchor {
            case .newest, .before:
                while start > 0, start < end, moments[start - 1] == moments[start] { start -= 1 }
            case .after:
                while end < count, end > start, moments[end] == moments[end - 1] { end += 1 }
            }

            let nextBefore: Int? = if start == 0 {
                nil
            } else if start < count {
                moments[start]
            } else {
                // An empty page past the newest entry: everything recorded so far is older.
                moments[count - 1] + 1
            }
            let nextAfter: Int = if end > start {
                moments[end - 1]
            } else {
                switch anchor {
                case .newest: 0
                case .after(let moment): moment
                case .before(let moment): max(0, moment - 1)
                }
            }
            return Slice(range: start..<end, nextBefore: nextBefore, nextAfter: nextAfter)
        }
    }

    /// The page `args` ask for, or why they ask for none. An argument the schema bounds and the
    /// call broke is refused, not replaced: until 2026-11-09 a `limit` of 500 was read as 200, a
    /// `before` the parser could not read as no cursor at all — and the agent read the wrong page
    /// believing it had asked for it.
    nonisolated static func taskLogPage(from args: [String: Any]) -> Result<TaskLogPage, ExternalAutovisorError> {
        // The same call with the argument fixed — its cursor kept unless the cursor is the fault.
        func fix(_ correcting: Set<String>) -> NextHint {
            ExternalNextCall.fixArgument.hint(
                after: ExternalAutovisorToolNames.taskLog, taskID: optionalInt(args, "task_id"),
                call: args, correcting: correcting)
        }
        func refused(_ message: String, correcting: Set<String>) -> Result<TaskLogPage, ExternalAutovisorError> {
            .failure(ExternalAutovisorError(message, code: .invalidArgs, next: fix(correcting)))
        }
        func integer(_ key: String) -> Result<Int?, ExternalAutovisorError> {
            guard let raw = args[key], !(raw is NSNull) else { return .success(nil) }
            guard let value = optionalInt([key: raw], key) else {
                return .failure(ExternalAutovisorError(
                    "Invalid parameter '\(key)': expected an integer.", code: .invalidArgs, next: fix([key])))
            }
            return .success(value)
        }
        let before: Int?, after: Int?, limit: Int?
        switch (integer("before"), integer("after"), integer("limit")) {
        case (.failure(let refusal), _, _), (_, .failure(let refusal), _), (_, _, .failure(let refusal)):
            return .failure(refusal)
        case (.success(let b), .success(let a), .success(let l)):
            (before, after, limit) = (b, a, l)
        }
        if let limit, !(1...TaskLogPage.maxLimit).contains(limit) {
            return refused(
                "Invalid parameter 'limit': must be an integer between 1 and \(TaskLogPage.maxLimit).", correcting: ["limit"])
        }
        if let before, before < 1 {
            return refused(
                "Invalid parameter 'before': must be a next_before from an earlier page (1 or more).", correcting: ["before"])
        }
        if let after, after < 0 {
            return refused(
                "Invalid parameter 'after': must be a next_after from an earlier page (0 or more).", correcting: ["after"])
        }
        let anchor: TaskLogPage.Anchor
        switch (before, after) {
        case (.some, .some):
            return refused(
                "Pass either 'before' or 'after', not both: 'before' pages back, 'after' reads on.",
                correcting: ["before", "after"])
        case (let before?, nil): anchor = .before(before)
        case (nil, let after?): anchor = .after(after)
        case (nil, nil): anchor = .newest
        }
        return .success(TaskLogPage(anchor: anchor, limit: limit ?? TaskLogPage.defaultLimit))
    }

    /// Whether `candidate` is the artifact `requested` names: its name, its file's name
    /// (`artifact_<slug>.md`, what `task_result` lists under `path`), or its slug. Until
    /// 2026-11-09 only the exact name matched, and the agent that asked by the file name it had
    /// just read in `task_result` was told the artifact did not exist.
    nonisolated static func artifact(_ candidate: Artifact, isNamed requested: String) -> Bool {
        if candidate.name == requested { return true }
        if let fileName = candidate.relativePath.map({ ($0 as NSString).lastPathComponent }),
           fileName == requested {
            return true
        }
        // Two names that are all punctuation both slug to "" — that is not a match.
        let slug = Artifact.slugify(requested)
        return !slug.isEmpty && slug == Artifact.slugify(candidate.name)
    }

    /// `items` without repeats, first occurrence first.
    nonisolated static func uniqueInOrder(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - task_status per step

    /// `planning` or `implementation` for a step of a role that plans first, `nil` otherwise and
    /// before the step starts. The planning phase ends by recording its notes in the scratchpad,
    /// so a step with notes is implementing.
    nonisolated static func planningPhase(of step: StepExecution, role: TeamRoleDefinition?) -> String? {
        guard role?.usePlanningPhase == true, step.status != .pending else { return nil }
        return step.scratchpad == nil ? "planning" : "implementation"
    }

    /// The model `role` runs on, resolved as a step resolves it (`buildEffectiveConfig`): its
    /// override's model when it names one, else the folder's. `list_teams` and `task_status`
    /// both answer through it, so the two cannot name different models for one role.
    func effectiveModel(of role: TeamRoleDefinition?) -> String {
        LLMExecutionService.buildEffectiveConfig(
            globalConfig: globalLLMConfig, roleOverride: role?.llmOverride
        ).modelName
    }

    /// What the model server last failed with, while the step retries the request: its latest
    /// turn is the retry notice (`TaskMutationService.appendOrReplaceRetryNotice`, one live notice
    /// per burst) — behind the empty placeholder an attempt in flight puts after it. `nil` once
    /// the model replies, in words or with a tool call, and for a step that is not running.
    nonisolated static func llmRetryNotice(of step: StepExecution) -> String? {
        guard step.status == .running else { return nil }
        let msgs = step.llmConversation
        guard let last = msgs.last else { return nil }
        let candidate = last.isStreamingPlaceholder ? (msgs.count >= 2 ? msgs[msgs.count - 2] : nil) : last
        guard let candidate,
              candidate.sourceContext == .serverError,
              step.toolCalls.last.map({ $0.createdAt <= candidate.createdAt }) ?? true
        else { return nil }
        return MCPTextSanitizer.sanitizeData(candidate.content)
    }

    /// The approval card a step is held on, if any: a `bash` command, a computer-use action or an
    /// MCP tool call waiting for a person's Allow or Deny. Nothing an agent can answer — the step
    /// stands still until the person does, and the agent learns why only from here.
    func awaitingApproval(taskID: Int, stepID: String) -> (kind: String, detail: String)? {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if let request = bashApprovalRequests[key] {
            return ("bash", MCPTextSanitizer.singleLine(request.command))
        }
        if let request = computerUseApprovalRequests[key] {
            return ("computer_use", MCPTextSanitizer.singleLine(request.actionSummary))
        }
        if let request = mcpApprovalRequests[key] {
            return ("mcp", MCPTextSanitizer.singleLine(request.toolName))
        }
        return nil
    }
}
