import Foundation

// MARK: - Presentation Models (Pure & Testable)

/// Pure presentation model for the Watchtower Autovisor card when switching between
/// `.builtInModel` and `.externalAgent` (§11, Ш21).
struct WatchtowerAutovisorCardPresentation: Equatable {
    let driver: AutovisorDriver
    let isEnabled: Bool
    let agentLabel: String
    let lastSeenText: String
    let driverHeadline: String
    let showsExternalDriverRow: Bool
    let showsPowerToggle: Bool
    let showsGoalSection: Bool
    let showsMemorySection: Bool
    let showsMessageComposer: Bool

    static func build(
        driver: AutovisorDriver,
        isEnabled: Bool,
        agents: [HostedMCPAgentRecord],
        latestActivityAgentLabel: String? = nil,
        now: Date = Date()
    ) -> WatchtowerAutovisorCardPresentation {
        let mostRecentAgent = agents.max { ($0.lastSeenAt ?? $0.createdAt) < ($1.lastSeenAt ?? $1.createdAt) }
        let label = mostRecentAgent?.label ?? latestActivityAgentLabel ?? "External Agent"
        let lastSeen: String
        if let seenAt = mostRecentAgent?.lastSeenAt {
            lastSeen = ExternalAutovisorPanePresentation.formatRelativeTimestamp(seenAt, now: now)
        } else {
            lastSeen = "never"
        }
        let headline = "Driven by \(label) · last seen \(lastSeen)"
        let isExternal = (driver == .externalAgent)
        return WatchtowerAutovisorCardPresentation(
            driver: driver,
            isEnabled: isEnabled,
            agentLabel: label,
            lastSeenText: lastSeen,
            driverHeadline: headline,
            showsExternalDriverRow: isExternal,
            showsPowerToggle: isExternal,
            showsGoalSection: isEnabled,
            showsMemorySection: !isExternal && isEnabled,
            showsMessageComposer: !isExternal && isEnabled
        )
    }
}

/// Banner model shown when an external agent's task is parked on a Supervisor question while the
/// owning agent is offline (§11, Ш21).
struct ExternalAutovisorOfflineBanner: Equatable, Identifiable {
    let id: UUID
    let agentID: UUID
    let agentLabel: String
    let offlineSince: Date?
    let sinceText: String
    let waitingTaskIDs: [Int]
    let waitingQuestionCount: Int
    let headline: String
    let detail: String
}

/// Connected/registered agent row in the `ExternalAutovisorPane` header.
struct ExternalAutovisorAgentPresenceItem: Equatable, Identifiable {
    let id: UUID
    let label: String
    let shortID: String
    let isPresent: Bool
    let hasActiveWait: Bool
    let lastSeenAt: Date?
    let statusText: String
}

/// External-agent task row in `ExternalAutovisorPane`.
struct ExternalAutovisorTaskRowItem: Equatable, Identifiable {
    let id: Int
    let title: String
    let status: TaskStatus
    let agentIdentity: AgentIdentity
    let isWaitingForAnswer: Bool
    let waitingQuestionCount: Int
}

/// Formatted feed card model derived from `ExternalAutovisorActivityRecord` (§11, Ш21).
struct ExternalAutovisorFeedItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case createdTask
        case answeredQuestion
        case roleReview
        case taskControl
        case messaged
        case scheduled
        case folderContext
        case waitForEvents
        case error
        case other
    }

    let id: UUID
    let createdAt: Date
    let timestampText: String
    let kind: Kind
    let agentLabel: String
    let tool: String
    let title: String
    /// Whether the title already says what the arguments say — `read log of #1` carries
    /// `task=#1`; `wait_for_events` and `folder_status` carry nothing but their name.
    let titleNarratesArguments: Bool
    /// What came back, after the row's `→`: the outcome the service recorded, `ok` when it
    /// recorded nothing, and for a failure its message with the code stripped, since the title
    /// names the code. An answer's outcome is `ok (N B)` — the summary line keeps no answer
    /// text, by design (`ExternalAutovisorActivityRecord`); the answer in full is one tap away
    /// (`hasFullCall`).
    let resultText: String
    let argumentsSummary: String
    let taskID: Int?
    let taskBadgeText: String?
    let isError: Bool
    /// Whether the call in full — arguments and response — is on disk, so the row opens it
    /// (`detailWindow`). `false` for a row recorded before 2026-11-08, for one whose task was
    /// deleted, and in a preview of either.
    let hasFullCall: Bool

    /// Something the agent DID to a task or to the folder — create, answer, review, control,
    /// message, schedule, replace the Work Folder Context, or fail trying — as opposed to a poll
    /// or a read. The row draws an action in the primary ink; a plain call reads
    /// `$ tool args → result`, like `ToolCallItemView`.
    var isAgentAction: Bool {
        switch kind {
        case .createdTask, .answeredQuestion, .roleReview, .taskControl, .messaged, .scheduled, .folderContext,
             .error: true
        case .waitForEvents, .other: false
        }
    }

    /// The arguments on the row after the tool name (`wait_for_events timeout=50s`) — only
    /// where the title does not already say them. `read log of #1` followed by `task=#1` and
    /// then the `#1` link said the task three times (review, 2026-11-07).
    var inlineArgumentsText: String? {
        guard !titleNarratesArguments, !argumentsSummary.isEmpty else { return nil }
        return argumentsSummary
    }

    /// The title's tooltip: the title, and — where the title narrates the arguments only in
    /// part (a schedule's cadence, a create's team and title) — the arguments too. The chevron
    /// that showed them went on 2026-11-08, when a tap began opening the whole call; a row with
    /// no full call still has this.
    var titleHelpText: String {
        guard titleNarratesArguments, !argumentsSummary.isEmpty else { return title }
        return "\(title)\n\(argumentsSummary)"
    }

    /// The window a tap opens: the call in full, loaded there from
    /// `ExternalAutovisorActivityLog.fullCall(id:)`.
    var detailWindow: ActivityDetailWindow {
        .externalAgentCall(id: id, toolName: tool, isError: isError, createdAt: createdAt)
    }

    static func from(
        record: ExternalAutovisorActivityRecord,
        hasFullCall: Bool,
        now: Date = Date()
    ) -> ExternalAutovisorFeedItem {
        let timeText = ExternalAutovisorPanePresentation.formatRelativeTimestamp(record.createdAt, now: now)
        let taskBadge = record.taskID.map { "#\($0)" }
        let formatted = formatTitleAndKind(for: record)
        return ExternalAutovisorFeedItem(
            id: record.id,
            createdAt: record.createdAt,
            timestampText: timeText,
            kind: formatted.kind,
            agentLabel: record.agentLabel,
            tool: record.tool,
            title: formatted.title,
            titleNarratesArguments: formatted.narratesArguments,
            resultText: resultText(for: record, kind: formatted.kind),
            argumentsSummary: record.argumentsSummary,
            taskID: record.taskID,
            taskBadgeText: taskBadge,
            isError: !record.ok,
            hasFullCall: hasFullCall
        )
    }

    private static func resultText(for record: ExternalAutovisorActivityRecord, kind: Kind) -> String {
        let outcome = record.outcomeSummary.trimmingCharacters(in: .whitespaces)
        guard record.ok else {
            // `summarizeExternalOutcome` writes "CODE: message" or the bare code.
            if let code = record.errorCode, !code.isEmpty {
                if outcome == code { return "error" }
                let prefix = code + ":"
                if outcome.hasPrefix(prefix) {
                    let message = outcome.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return message.isEmpty ? "error" : message
                }
            }
            return outcome.isEmpty ? "error" : outcome
        }
        if kind == .waitForEvents, outcome.isEmpty, let count = record.eventCount {
            // A wait's result is its count even where nothing else was recorded.
            return count == 0 ? "no events" : (count == 1 ? "1 event" : "\(count) events")
        }
        return outcome.isEmpty ? "ok" : outcome
    }

    /// The row's title and kind, and whether that title already narrates the call's
    /// arguments. A failure's title names the tool and the task; a plain call's names the tool
    /// alone — the two shapes that leave the arguments to the row.
    private static func formatTitleAndKind(
        for record: ExternalAutovisorActivityRecord
    ) -> (title: String, kind: Kind, narratesArguments: Bool) {
        let narrated = narrate(record)
        // Three titles say nothing of the arguments: a failure's (tool and task only), a
        // wait's, and the default `<agent> → <tool>` of a read with no sentence of its own.
        let bare = narrated.kind == .error || narrated.kind == .waitForEvents || narrated.isDefaultTitle
        return (narrated.title, narrated.kind, !bare)
    }

    private static func narrate(
        _ record: ExternalAutovisorActivityRecord
    ) -> (title: String, kind: Kind, isDefaultTitle: Bool) {
        let taskPart = record.taskID.map { "#\($0)" } ?? "task"
        if !record.ok {
            let code = record.errorCode ?? "ERROR"
            let onTask = record.taskID.map { " on #\($0)" } ?? ""
            return ("\(record.agentLabel) → \(record.tool)\(onTask) failed (\(code))", .error, false)
        }

        switch record.tool {
        case ExternalAutovisorToolNames.createManagedTask:
            let teamPart = (record.teamName?.isEmpty == false) ? " on \(record.teamName!)" : ""
            let titlePart = (record.taskTitle?.isEmpty == false) ? ": \(record.taskTitle!)" : ""
            return ("\(record.agentLabel) → created \(taskPart)\(teamPart)\(titlePart)", .createdTask, false)

        case ExternalAutovisorToolNames.answerTaskQuestion:
            // The answer's text is the row's RESULT (`resultText`), where it truncates on its
            // own; in the title it pushed the task link and the time off the row.
            let rolePart = (record.roleID?.isEmpty == false) ? record.roleID! : "role"
            return ("\(rolePart) asked → \(record.agentLabel) answered", .answeredQuestion, false)

        case ExternalAutovisorToolNames.manageRole:
            let rolePart = (record.roleID?.isEmpty == false) ? record.roleID! : "role"
            switch record.action {
            case "accept":
                return ("\(record.agentLabel) → accepted \(rolePart) on \(taskPart)", .roleReview, false)
            case "request_changes":
                return ("\(record.agentLabel) → requested changes from \(rolePart) on \(taskPart)", .roleReview, false)
            default:
                let verb = record.action ?? "updated"
                return ("\(record.agentLabel) → \(verb) \(rolePart) on \(taskPart)", .roleReview, false)
            }

        case ExternalAutovisorToolNames.controlTask:
            switch record.action {
            case "close":
                return ("\(record.agentLabel) → closed \(taskPart)", .taskControl, false)
            case "pause":
                return ("\(record.agentLabel) → paused \(taskPart)", .taskControl, false)
            case "resume":
                return ("\(record.agentLabel) → resumed \(taskPart)", .taskControl, false)
            case "restart_role":
                let rolePart = (record.roleID?.isEmpty == false) ? " \(record.roleID!)" : ""
                return ("\(record.agentLabel) → restarted role\(rolePart) on \(taskPart)", .taskControl, false)
            default:
                let verb = record.action ?? "controlled"
                return ("\(record.agentLabel) → \(verb) \(taskPart)", .taskControl, false)
            }

        case ExternalAutovisorToolNames.waitForEvents:
            // The count is the result (`resultText`), not the name of what was done.
            return ("\(record.agentLabel) → wait_for_events", .waitForEvents, false)

        case ExternalAutovisorToolNames.messageTask:
            if let roleID = record.roleID, !roleID.isEmpty {
                return ("\(record.agentLabel) → messaged \(roleID) on \(taskPart)", .messaged, false)
            }
            return ("\(record.agentLabel) → messaged \(taskPart)", .messaged, false)

        case ExternalAutovisorToolNames.scheduleTask:
            return ("\(record.agentLabel) → scheduled \(taskPart)", .scheduled, false)

        case ExternalAutovisorToolNames.setWorkFolderContext:
            // A sentence, as a schedule's is: the length (`characters=N`) is in the title's
            // tooltip, and the text itself in the full call the row opens.
            return ("\(record.agentLabel) → replaced the Work Folder Context", .folderContext, false)

        case ExternalAutovisorToolNames.taskResult:
            return ("\(record.agentLabel) → read result of \(taskPart)", .other, false)

        case ExternalAutovisorToolNames.readArtifact:
            let artifact = record.artifactNames.first ?? "artifact"
            return ("\(record.agentLabel) → read artifact \(artifact) on \(taskPart)", .other, false)

        case ExternalAutovisorToolNames.taskLog:
            return ("\(record.agentLabel) → read log of \(taskPart)", .other, false)

        case ExternalAutovisorToolNames.taskStatus:
            return ("\(record.agentLabel) → checked \(taskPart)", .other, false)

        default:
            return ("\(record.agentLabel) → \(record.tool)", .other, true)
        }
    }
}

/// Complete pure presentation state for `ExternalAutovisorPane` (§11, Ш21).
struct ExternalAutovisorPanePresentation: Equatable {
    let listenerStatusText: String
    let isServerListening: Bool
    let isAutovisorEnabled: Bool
    let readiness: ExternalAutovisorReadiness
    let agents: [ExternalAutovisorAgentPresenceItem]
    let offlineBanners: [ExternalAutovisorOfflineBanner]
    /// The activity card: the rows shown, its filter and its empty line.
    let activity: ExternalAutovisorActivitySelection
    let externalTasks: [ExternalAutovisorTaskRowItem]

    /// A task row names its agent only when the name tells the agents apart. With one agent
    /// registered the tag repeated the header on every row (design review 2026-11-07).
    var showsAgentTagOnTaskRows: Bool { agents.count > 1 }

    static func build(
        listenerState: HostedMCPListenerState,
        externalAgentsEnabled: Bool,
        configuredPort: UInt16,
        isAutovisorEnabled: Bool,
        readiness: ExternalAutovisorReadiness,
        agentRecords: [HostedMCPAgentRecord],
        isAgentPresent: (UUID) -> Bool,
        hasActiveWait: (UUID) -> Bool,
        taskSummaries: [TaskSummary],
        loadedTask: (Int) -> NTMSTask?,
        activityEntries: [ExternalAutovisorActivityRecord],
        fullCallIDs: Set<UUID>,
        activityTaskFilter: Int?,
        activityClearedUpTo: Date?,
        now: Date = Date()
    ) -> ExternalAutovisorPanePresentation {
        let statusText = ExternalAgentsSettingsPresentation.formatListenerStatus(
            enabled: externalAgentsEnabled,
            configuredPort: configuredPort,
            state: listenerState
        )
        let isListening: Bool = {
            if case .listening = listenerState, externalAgentsEnabled { return true }
            return false
        }()

        let agentItems: [ExternalAutovisorAgentPresenceItem] = agentRecords.map { record in
            let present = isAgentPresent(record.id)
            let waiting = hasActiveWait(record.id)
            let status: String = {
                if present && waiting {
                    return "Online · listening (wait_for_events)"
                }
                if present {
                    if let seen = record.lastSeenAt {
                        return "Online · last seen \(formatRelativeTimestamp(seen, now: now))"
                    }
                    return "Online"
                }
                if let seen = record.lastSeenAt {
                    return "Offline · last seen \(formatRelativeTimestamp(seen, now: now))"
                }
                return "Offline · never connected"
            }()
            return ExternalAutovisorAgentPresenceItem(
                id: record.id,
                label: record.label,
                shortID: record.shortID,
                isPresent: present,
                hasActiveWait: waiting,
                lastSeenAt: record.lastSeenAt,
                statusText: status
            )
        }

        var externalTaskItems: [ExternalAutovisorTaskRowItem] = []
        var waitingByAgentID: [UUID: (identity: AgentIdentity, taskIDs: [Int], questionCount: Int)] = [:]

        for summary in taskSummaries {
            let hydrated = loadedTask(summary.id)
            let effectiveOrigin = hydrated?.origin ?? summary.origin
            guard case .externalAgent(let identity) = effectiveOrigin else { continue }

            let isClosed = (hydrated != nil) ? (hydrated?.closedAt != nil) : (summary.status == .done)
            let waitingCount: Int = {
                guard !isClosed else { return 0 }
                if let hydrated {
                    return hydrated.answerableSupervisorSteps.count
                }
                return summary.isWaitingForSupervisor ? max(1, summary.pendingSupervisorQuestionCount ?? 1) : 0
            }()
            let isWaiting = waitingCount > 0

            externalTaskItems.append(
                ExternalAutovisorTaskRowItem(
                    id: summary.id,
                    title: summary.title,
                    status: summary.status,
                    agentIdentity: identity,
                    isWaitingForAnswer: isWaiting,
                    waitingQuestionCount: waitingCount
                )
            )

            if isWaiting && !isAgentPresent(identity.id) {
                var entry = waitingByAgentID[identity.id] ?? (identity: identity, taskIDs: [], questionCount: 0)
                entry.taskIDs.append(summary.id)
                entry.questionCount += waitingCount
                waitingByAgentID[identity.id] = entry
            }
        }

        let agentRecordByID = Dictionary(uniqueKeysWithValues: agentRecords.map { ($0.id, $0) })
        let banners: [ExternalAutovisorOfflineBanner] = waitingByAgentID.values
            .sorted { $0.identity.label.localizedCaseInsensitiveCompare($1.identity.label) == .orderedAscending }
            .map { group in
                let record = agentRecordByID[group.identity.id]
                let lastSeen = record?.lastSeenAt
                let sinceText = lastSeen.map { formatRelativeTimestamp($0, now: now) } ?? "never"
                let taskList = group.taskIDs.map { "#\($0)" }.joined(separator: ", ")
                return ExternalAutovisorOfflineBanner(
                    id: group.identity.id,
                    agentID: group.identity.id,
                    agentLabel: group.identity.label,
                    offlineSince: lastSeen,
                    sinceText: sinceText,
                    waitingTaskIDs: group.taskIDs,
                    waitingQuestionCount: group.questionCount,
                    headline: "Agent offline since \(sinceText) — tasks are waiting",
                    detail: "\(group.identity.label) is offline while \(taskList) wait for a Supervisor answer."
                )
            }

        let activity = ExternalAutovisorActivitySelection.make(
            entries: activityEntries,
            fullCallIDs: fullCallIDs,
            tasks: externalTaskItems,
            taskFilter: activityTaskFilter,
            clearedUpTo: activityClearedUpTo,
            now: now
        )

        return ExternalAutovisorPanePresentation(
            listenerStatusText: statusText,
            isServerListening: isListening,
            isAutovisorEnabled: isAutovisorEnabled,
            readiness: readiness,
            agents: agentItems,
            offlineBanners: banners,
            activity: activity,
            externalTasks: externalTaskItems
        )
    }

    static func formatRelativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        let delta = max(0, Int(now.timeIntervalSince(date)))
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(delta)s ago" }
        let minutes = delta / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
