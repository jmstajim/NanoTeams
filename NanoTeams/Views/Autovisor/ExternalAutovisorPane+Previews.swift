import SwiftUI

// MARK: - Preview data

/// Mocked facts for the External Autovisor pane: the states a design review needs to see
/// without a live agent — rendered through `./render_preview.sh` (Xcode's `RenderPreview`).
///
/// The "idle agent" sample reproduces the pane as it was photographed on 2026-11-07: one agent
/// that polled for three hours (`wait_for_events` 50 s at a time, `folder_status` between), two
/// closed tasks, and a handful of real actions buried under the polling.
// periphery:ignore - used in #Preview macros below
enum ExternalAutovisorPanePreview {

    static let agentID = UUID(uuidString: "A4C36525-0000-4000-8000-000000000001")!
    static let secondAgentID = UUID(uuidString: "B7D10000-0000-4000-8000-000000000002")!
    static let now = Date(timeIntervalSince1970: 1_794_200_000)

    static func agent(
        id: UUID = agentID, label: String = "Claude Code live", shortID: String = "a4c36525",
        lastSeenAgo: TimeInterval? = 2 * 3600
    ) -> HostedMCPAgentRecord {
        HostedMCPAgentRecord(
            id: id, shortID: shortID, label: label,
            createdAt: now.addingTimeInterval(-6 * 3600),
            lastSeenAt: lastSeenAgo.map { now.addingTimeInterval(-$0) },
            clientHint: "claude-code")
    }

    static func task(
        _ id: Int, _ title: String, status: TaskStatus, agent: HostedMCPAgentRecord = agent(),
        waiting: Int? = nil
    ) -> TaskSummary {
        TaskSummary(
            id: id, title: title, status: status, updatedAt: now.addingTimeInterval(-3 * 3600),
            hasPendingSupervisorInput: waiting.map { $0 > 0 },
            pendingSupervisorQuestionCount: waiting,
            origin: .externalAgent(agent.identity))
    }

    static func record(
        ago: TimeInterval, tool: String, agent: HostedMCPAgentRecord = agent(), taskID: Int? = nil,
        roleID: String? = nil, action: String? = nil, teamName: String? = nil, taskTitle: String? = nil,
        ok: Bool = true, errorCode: String? = nil, bytes: Int = 0, artifacts: [String] = [],
        events: Int? = nil, args: String = "", outcome: String = ""
    ) -> ExternalAutovisorActivityRecord {
        ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-ago), agentID: agent.id, agentLabel: agent.label,
            tool: tool, taskID: taskID, roleID: roleID, action: action, teamName: teamName,
            taskTitle: taskTitle, ok: ok, errorCode: errorCode, resultBytes: bytes,
            artifactNames: artifacts, eventCount: events, argumentsSummary: args,
            outcomeSummary: outcome)
    }

    /// The photographed session, oldest first (the log is append-order).
    static func idleSessionLog() -> [ExternalAutovisorActivityRecord] {
        var log: [ExternalAutovisorActivityRecord] = []
        var ago: TimeInterval = 5 * 3600 + 20 * 60
        func step(_ seconds: TimeInterval) { ago -= seconds }

        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.folderStatus, bytes: 1261, outcome: "ok (1261 B)"))
        step(4)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.listTeams, bytes: 2210, outcome: "ok (2210 B)"))
        step(6)
        log.append(record(
            ago: ago, tool: ExternalAutovisorToolNames.createManagedTask, taskID: 0, teamName: "Startup",
            taskTitle: "wordcount.py", bytes: 180, args: "team=Startup title=wordcount.py", outcome: "ok (180 B)"))
        step(50)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.waitForEvents, taskID: 0, events: 1, args: "timeout=50s", outcome: "1 event"))
        step(3)
        log.append(record(
            ago: ago, tool: ExternalAutovisorToolNames.answerTaskQuestion, taskID: 0, roleID: "Software Engineer",
            bytes: 96, args: "task=#0 role=Software Engineer", outcome: "ok (96 B)"))
        step(90)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.waitForEvents, taskID: 0, events: 1, args: "timeout=50s", outcome: "1 event"))
        step(2)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.taskResult, taskID: 0, bytes: 2048, artifacts: ["Engineering Notes"], outcome: "1 deliverable: Engineering Notes (2048 B)"))
        step(5)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.controlTask, taskID: 0, action: "close", args: "task=#0 action=close", outcome: "ok (64 B)"))
        step(20)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.scheduleTask, taskID: 0, args: "task=#0 repeat_daily_at=09:30", outcome: "ok (40 B)"))
        step(120 * 60)
        log.append(record(
            ago: ago, tool: ExternalAutovisorToolNames.createManagedTask, taskID: 1, teamName: "Startup",
            taskTitle: "linecount.py", bytes: 180, args: "team=Startup title=linecount.py", outcome: "ok (180 B)"))
        step(50)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.waitForEvents, taskID: 1, events: 1, args: "timeout=50s", outcome: "1 event"))
        step(3)
        log.append(record(
            ago: ago, tool: ExternalAutovisorToolNames.answerTaskQuestion, taskID: 1, roleID: "Software Engineer",
            bytes: 96, args: "task=#1 role=Software Engineer", outcome: "ok (96 B)"))
        step(40)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.waitForEvents, taskID: 1, events: 1, args: "timeout=50s", outcome: "1 event"))
        step(2)
        log.append(record(
            ago: ago, tool: ExternalAutovisorToolNames.answerTaskQuestion, taskID: 1, roleID: "Software Engineer",
            bytes: 96, args: "task=#1 role=Software Engineer", outcome: "ok (96 B)"))
        step(55)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.waitForEvents, taskID: 1, events: 1, args: "timeout=50s", outcome: "1 event"))
        step(2)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.taskLog, taskID: 1, bytes: 4632, outcome: "22 messages (4632 B)"))
        step(2)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.taskLog, taskID: 1, bytes: 4632, outcome: "22 messages (4632 B)"))
        step(4)
        log.append(record(ago: ago, tool: ExternalAutovisorToolNames.controlTask, taskID: 1, action: "close", args: "task=#1 action=close", outcome: "ok (64 B)"))
        step(3)
        log.append(record(
            ago: ago, tool: ExternalAutovisorToolNames.manageRole, taskID: 1, roleID: "Software Engineer", action: "accept",
            ok: false, errorCode: "TASK_CLOSED", args: "task=#1 role=Software Engineer action=accept",
            outcome: "TASK_CLOSED: the task is closed"))
        // Three idle hours: a 50 s wait that times out, then a folder_status, forever.
        for _ in 0..<20 {
            step(50)
            log.append(record(ago: ago, tool: ExternalAutovisorToolNames.waitForEvents, events: 0, args: "timeout=50s", outcome: "no events, timed out"))
            step(1)
            log.append(record(ago: ago, tool: ExternalAutovisorToolNames.folderStatus, bytes: 1261, outcome: "ok (1261 B)"))
        }
        return log
    }

    /// The pane is the destination only while the Autovisor is on (`AutovisorPolicy.detailPane`),
    /// so every preview of it is an enabled, ready folder.
    ///
    /// Every row opens its full call except the `recordedBeforeFullCalls` oldest — the rows an
    /// install already had when calls began to be kept (2026-11-08). A static render shows no
    /// hover, so the difference is in the presentation, not the picture.
    static func presentation(
        listenerState: HostedMCPListenerState = .listening(port: 47321),
        agents: [HostedMCPAgentRecord] = [agent()],
        present: Set<UUID> = [],
        waiting: Set<UUID> = [],
        tasks: [TaskSummary],
        log: [ExternalAutovisorActivityRecord],
        recordedBeforeFullCalls: Int = 2,
        activityTaskFilter: Int? = nil,
        activityClearedUpTo: Date? = nil
    ) -> ExternalAutovisorPanePresentation {
        ExternalAutovisorPanePresentation.build(
            listenerState: listenerState,
            externalAgentsEnabled: true,
            configuredPort: 47321,
            isAutovisorEnabled: true,
            readiness: .forState(.ready),
            agentRecords: agents,
            isAgentPresent: { present.contains($0) },
            hasActiveWait: { waiting.contains($0) },
            taskSummaries: tasks,
            loadedTask: { _ in nil },
            activityEntries: log,
            fullCallIDs: Set(log.dropFirst(recordedBeforeFullCalls).map(\.id)),
            activityTaskFilter: activityTaskFilter,
            activityClearedUpTo: activityClearedUpTo,
            now: now)
    }

    /// Screenshot 1: the agent went quiet two hours ago, both tasks are done.
    static func idleAgent() -> ExternalAutovisorPanePresentation {
        presentation(
            tasks: [task(1, "linecount.py", status: .done), task(0, "wordcount.py", status: .done)],
            log: idleSessionLog())
    }

    /// The agent is online and waiting; one task is parked on a question it will answer.
    static func liveAgent() -> ExternalAutovisorPanePresentation {
        presentation(
            agents: [agent(lastSeenAgo: 12)],
            present: [agentID], waiting: [agentID],
            tasks: [
                task(2, "Add --json output to linecount.py", status: .running, waiting: 1),
                task(1, "linecount.py", status: .done),
            ],
            log: Array(idleSessionLog().prefix(12)))
    }

    /// Two agents share the folder; the second is offline while its task waits on a question —
    /// the banner, and the agent tag on task rows, both appear.
    static func offlineAgentWithWaitingTask() -> ExternalAutovisorPanePresentation {
        let cursor = agent(id: secondAgentID, label: "Cursor", shortID: "b7d10000", lastSeenAgo: 25 * 60)
        return presentation(
            agents: [agent(lastSeenAgo: 30), cursor],
            present: [agentID],
            tasks: [
                task(3, "Refactor the parser into a package", status: .running, agent: cursor, waiting: 2),
                task(1, "linecount.py", status: .done),
            ],
            log: Array(idleSessionLog().prefix(8)))
    }

    /// The activity was hidden after the session: the header stays, every row before it is gone
    /// from view (not from disk).
    static func activityHidden() -> ExternalAutovisorPanePresentation {
        presentation(
            tasks: [task(1, "linecount.py", status: .done), task(0, "wordcount.py", status: .done)],
            log: idleSessionLog(),
            activityClearedUpTo: now)
    }

    /// The menu picked one task: only the calls about #1 are left.
    static func activityFilteredToTask() -> ExternalAutovisorPanePresentation {
        presentation(
            tasks: [task(1, "linecount.py", status: .done), task(0, "wordcount.py", status: .done)],
            log: idleSessionLog(),
            activityTaskFilter: 1)
    }

    /// The agent replaced the Work Folder Context, and a second agent nobody allowed to was refused:
    /// the one call that reaches every task, drawn as an action with its length, and the refusal.
    static func contextReplaced() -> ExternalAutovisorPanePresentation {
        let cursor = agent(id: secondAgentID, label: "Cursor", shortID: "b7d10000", lastSeenAgo: 25 * 60)
        var log = Array(idleSessionLog().prefix(4))
        log.append(record(
            ago: 3 * 3600, tool: ExternalAutovisorToolNames.setWorkFolderContext,
            bytes: 182, args: "characters=412", outcome: "ok (182 B)"))
        log.append(record(
            ago: 3 * 3600 - 40, tool: ExternalAutovisorToolNames.setWorkFolderContext, agent: cursor,
            ok: false, errorCode: ToolErrorCode.notAllowed.rawValue, bytes: 410, args: "characters=96",
            outcome: "\(ToolErrorCode.notAllowed.rawValue): \(NTMSOrchestrator.contextReplacementNotAllowedMessage)"))
        return presentation(
            agents: [agent(lastSeenAgo: 30), cursor],
            present: [agentID],
            tasks: [task(0, "wordcount.py", status: .done)],
            log: log)
    }

    /// External Agents is on, nothing has connected yet.
    static func nothingYet() -> ExternalAutovisorPanePresentation {
        presentation(agents: [], tasks: [], log: [])
    }
}

// periphery:ignore - used in #Preview macros below
private func externalAutovisorPreview(_ presentation: ExternalAutovisorPanePresentation) -> some View {
    ExternalAutovisorPaneContent(
        presentation: presentation,
        onToggleAutovisor: { _ in },
        onOpenTask: { _ in },
        onOpenExternalAgents: {},
        onOpenFullCall: { _ in },
        onSelectActivityTaskFilter: { _ in },
        onHideActivity: {}
    )
    .frame(width: 760, height: 1100)
}

#Preview("Idle agent — photographed session") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.idleAgent())
}

#Preview("Live agent — task waiting") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.liveAgent())
}

#Preview("Offline agent — banner") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.offlineAgentWithWaitingTask())
}

#Preview("Activity hidden") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.activityHidden())
}

#Preview("Activity filtered to #1") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.activityFilteredToTask())
}

#Preview("Work Folder Context replaced") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.contextReplaced())
}

#Preview("Nothing yet") {
    externalAutovisorPreview(ExternalAutovisorPanePreview.nothingYet())
}
