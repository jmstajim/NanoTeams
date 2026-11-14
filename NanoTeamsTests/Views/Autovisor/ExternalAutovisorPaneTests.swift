import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

@MainActor
final class ExternalAutovisorPaneTests: XCTestCase {

    // MARK: - Header & Offline Waiting Banner

    func testOfflineWaitingBanner_shownWhenOwnedTaskHasPendingQuestionAndAgentIsOffline() {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        let agentID = UUID()
        let identity = AgentIdentity(id: agentID, label: "Claude Code")
        let agentRecord = HostedMCPAgentRecord(
            id: agentID,
            shortID: "a1b2c3d4e5f6",
            label: "Claude Code",
            createdAt: now.addingTimeInterval(-3600),
            lastSeenAt: now.addingTimeInterval(-300),
            clientHint: nil
        )

        var step = StepExecution(
            id: "architect",
            role: .softwareEngineer,
            title: "Architecture",
            status: .needsSupervisorInput
        )
        step.needsSupervisorInput = true
        step.supervisorQuestion = "Which database schema should we use?"
        let run = Run(id: 1, steps: [step], teamID: UUID().uuidString)
        let task = NTMSTask(
            id: 12,
            title: "Design database layer",
            supervisorTask: "Build the persistence schema",
            status: .needsSupervisorInput,
            runs: [run],
            origin: .externalAgent(identity)
        )
        let summary = task.toSummary()

        // 1. Agent is offline (!isAgentPresent) and task has answerableSupervisorSteps
        let offlinePresentation = ExternalAutovisorPanePresentation.build(
            listenerState: .listening(port: 47321),
            externalAgentsEnabled: true,
            configuredPort: 47321,
            isAutovisorEnabled: true,
            readiness: .forState(.ready),
            agentRecords: [agentRecord],
            isAgentPresent: { _ in false },
            hasActiveWait: { _ in false },
            taskSummaries: [summary],
            loadedTask: { id in id == 12 ? task : nil },
            activityEntries: [],
            fullCallIDs: [],
            activityTaskFilter: nil,
            activityClearedUpTo: nil,
            now: now
        )

        XCTAssertTrue(offlinePresentation.isServerListening)
        XCTAssertEqual(offlinePresentation.offlineBanners.count, 1)
        let banner = offlinePresentation.offlineBanners[0]
        XCTAssertEqual(banner.agentID, agentID)
        XCTAssertEqual(banner.agentLabel, "Claude Code")
        XCTAssertEqual(banner.waitingTaskIDs, [12])
        XCTAssertEqual(banner.waitingQuestionCount, 1)
        XCTAssertEqual(banner.headline, "Agent offline since 5m ago — tasks are waiting")
        XCTAssertTrue(banner.detail.contains("#12"))

        // 2. When the owning agent reconnects (isAgentPresent == true), banner disappears
        let onlinePresentation = ExternalAutovisorPanePresentation.build(
            listenerState: .listening(port: 47321),
            externalAgentsEnabled: true,
            configuredPort: 47321,
            isAutovisorEnabled: true,
            readiness: .forState(.ready),
            agentRecords: [agentRecord],
            isAgentPresent: { _ in true },
            hasActiveWait: { _ in true },
            taskSummaries: [summary],
            loadedTask: { id in id == 12 ? task : nil },
            activityEntries: [],
            fullCallIDs: [],
            activityTaskFilter: nil,
            activityClearedUpTo: nil,
            now: now
        )
        XCTAssertTrue(onlinePresentation.offlineBanners.isEmpty)
        XCTAssertEqual(
            onlinePresentation.agents.first?.statusText,
            "Online · listening (wait_for_events)"
        )
    }

    // MARK: - Live Conversation Feed Formatting

    func testFeedItems_formatsCreateAnswerManageRoleControlTaskWaitAndError() {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        let agentID = UUID()

        let createRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-60),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.createManagedTask,
            taskID: 7,
            teamName: "Startup",
            taskTitle: "Implement OAuth",
            ok: true,
            resultBytes: 128,
            argumentsSummary: "team=Startup title=Implement OAuth",
            outcomeSummary: "Created task #7"
        )
        let answerRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-45),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.answerTaskQuestion,
            taskID: 7,
            roleID: "architect",
            ok: true,
            resultBytes: 96,
            argumentsSummary: "task_id=7 role_id=architect",
            outcomeSummary: "ok (96 B)"
        )
        let acceptRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-30),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.manageRole,
            taskID: 7,
            roleID: "engineer",
            action: "accept",
            ok: true,
            resultBytes: 64
        )
        let requestChangesRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-25),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.manageRole,
            taskID: 7,
            roleID: "engineer",
            action: "request_changes",
            ok: true,
            resultBytes: 64,
            outcomeSummary: "Add PKCE state verification tests"
        )
        let closeRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-15),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.controlTask,
            taskID: 7,
            action: "close",
            ok: true,
            resultBytes: 48
        )
        let waitRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-10),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.waitForEvents,
            ok: true,
            resultBytes: 256,
            eventCount: 3
        )
        let errorRecord = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-5),
            agentID: agentID,
            agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.controlTask,
            taskID: 99,
            action: "close",
            ok: false,
            errorCode: "TASK_NOT_OWNED",
            resultBytes: 80,
            outcomeSummary: "Task #99 belongs to another supervisor"
        )

        let createItem = ExternalAutovisorFeedItem.from(record: createRecord, hasFullCall: false, now: now)
        XCTAssertEqual(createItem.kind, .createdTask)
        XCTAssertEqual(createItem.title, "Claude Code → created #7 on Startup: Implement OAuth")
        XCTAssertEqual(createItem.taskID, 7)
        XCTAssertEqual(createItem.taskBadgeText, "#7")
        XCTAssertFalse(createItem.hasFullCall, "built with no full call on disk")

        let answerItem = ExternalAutovisorFeedItem.from(record: answerRecord, hasFullCall: false, now: now)
        XCTAssertEqual(answerItem.kind, .answeredQuestion)
        XCTAssertEqual(answerItem.title, "architect asked → Claude Code answered")
        XCTAssertEqual(answerItem.resultText, "ok (96 B)", "the summary keeps no answer text; the answer opens with the full call")
        XCTAssertEqual(answerItem.taskID, 7)

        let acceptItem = ExternalAutovisorFeedItem.from(record: acceptRecord, hasFullCall: false, now: now)
        XCTAssertEqual(acceptItem.kind, .roleReview)
        XCTAssertEqual(acceptItem.title, "Claude Code → accepted engineer on #7")

        let requestChangesItem = ExternalAutovisorFeedItem.from(record: requestChangesRecord, hasFullCall: false, now: now)
        XCTAssertEqual(requestChangesItem.kind, .roleReview)
        XCTAssertEqual(requestChangesItem.title, "Claude Code → requested changes from engineer on #7")
        XCTAssertEqual(requestChangesItem.resultText, "Add PKCE state verification tests")

        let closeItem = ExternalAutovisorFeedItem.from(record: closeRecord, hasFullCall: false, now: now)
        XCTAssertEqual(closeItem.kind, .taskControl)
        XCTAssertEqual(closeItem.title, "Claude Code → closed #7")

        // The count is the RESULT of the wait, not its name: the row reads
        // `Claude Code → wait_for_events → 3 events`, said once (the title carried the count
        // and the subtitle repeated it until the 2026-11-07 design review).
        let waitItem = ExternalAutovisorFeedItem.from(record: waitRecord, hasFullCall: false, now: now)
        XCTAssertEqual(waitItem.kind, .waitForEvents)
        XCTAssertEqual(waitItem.title, "Claude Code → wait_for_events")
        XCTAssertEqual(waitItem.resultText, "3 events")

        let singleWaitItem = ExternalAutovisorFeedItem.from(
            record: ExternalAutovisorActivityRecord(
                createdAt: now.addingTimeInterval(-9),
                agentID: agentID,
                agentLabel: "Claude Code",
                tool: ExternalAutovisorToolNames.waitForEvents,
                ok: true,
                resultBytes: 128,
                eventCount: 1,
                outcomeSummary: "1 event"
            ),
            hasFullCall: false,
            now: now
        )
        XCTAssertEqual(singleWaitItem.title, "Claude Code → wait_for_events")
        XCTAssertEqual(singleWaitItem.resultText, "1 event")

        let errorItem = ExternalAutovisorFeedItem.from(record: errorRecord, hasFullCall: false, now: now)
        XCTAssertEqual(errorItem.kind, .error)
        XCTAssertTrue(errorItem.isError)
        XCTAssertEqual(errorItem.title, "Claude Code → control_task on #99 failed (TASK_NOT_OWNED)")
        XCTAssertEqual(errorItem.taskID, 99)
    }

    // MARK: - One-line feed rows (design review 2026-11-07)

    /// Every record is one line: `title → resultText`. The result is the outcome the service
    /// recorded, `ok` when it recorded nothing, and for an answer — whose outcome the title
    /// already quotes — `ok` as well. A failure shows its message, not its code again.
    func testFeedRows_resultTextSaysTheOutcomeOnce() {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        let agentID = UUID()
        func record(
            _ tool: String, ok: Bool = true, errorCode: String? = nil, roleID: String? = nil,
            events: Int? = nil, args: String = "", outcome: String = "", artifacts: [String] = []
        ) -> ExternalAutovisorFeedItem {
            ExternalAutovisorFeedItem.from(
                record: ExternalAutovisorActivityRecord(
                    createdAt: now, agentID: agentID, agentLabel: "Claude Code", tool: tool,
                    taskID: 4, roleID: roleID, ok: ok, errorCode: errorCode, resultBytes: 10,
                    artifactNames: artifacts, eventCount: events, argumentsSummary: args,
                    outcomeSummary: outcome),
                hasFullCall: false,
                now: now)
        }

        // A read says what it read.
        XCTAssertEqual(record(ExternalAutovisorToolNames.folderStatus, outcome: "ok (1261 B)").resultText, "ok (1261 B)")
        XCTAssertEqual(record(ExternalAutovisorToolNames.taskLog, outcome: "22 messages (4632 B)").resultText, "22 messages (4632 B)")
        // Nothing recorded → plain ok.
        XCTAssertEqual(record(ExternalAutovisorToolNames.controlTask).resultText, "ok")
        // An answer's outcome is what the service writes — `ok (N B)`, never the answer's text
        // (the summary line keeps no bodies; the full call does, one tap away). The row says
        // that and nothing more.
        let answer = record(ExternalAutovisorToolNames.answerTaskQuestion, roleID: "engineer", outcome: "ok (96 B)")
        XCTAssertEqual(answer.title, "engineer asked → Claude Code answered")
        XCTAssertEqual(answer.resultText, "ok (96 B)")
        XCTAssertEqual(record(ExternalAutovisorToolNames.answerTaskQuestion, roleID: "engineer").resultText, "ok")
        // A wait with no events, timed out — as the service now writes it.
        XCTAssertEqual(record(ExternalAutovisorToolNames.waitForEvents, events: 0, outcome: "no events, timed out").resultText, "no events, timed out")
        // A failure: the title names the code, the result carries the message without it.
        let failed = record(ExternalAutovisorToolNames.manageRole, ok: false, errorCode: "TASK_CLOSED", outcome: "TASK_CLOSED: the task is closed")
        XCTAssertEqual(failed.title, "Claude Code → manage_role on #4 failed (TASK_CLOSED)")
        XCTAssertEqual(failed.resultText, "the task is closed")
        // A failure that recorded only its code reads `error`, not the code a third time.
        XCTAssertEqual(record(ExternalAutovisorToolNames.listTasks, ok: false, errorCode: "ERR", outcome: "ERR").resultText, "error")
        XCTAssertEqual(record(ExternalAutovisorToolNames.listTasks, ok: false, errorCode: nil, outcome: "").resultText, "error")

        // A call whose title is just its name puts its arguments on the row
        // (`wait_for_events timeout=50s`, `folder_status`); a title that narrates them
        // (`read log of #1`, `closed #4`) does not repeat them — they are in its tooltip and in
        // the full call a tap opens.
        let poll = record(ExternalAutovisorToolNames.waitForEvents, events: 0, args: "timeout=50s", outcome: "no events, timed out")
        XCTAssertFalse(poll.isAgentAction)
        XCTAssertFalse(poll.titleNarratesArguments)
        XCTAssertEqual(poll.inlineArgumentsText, "timeout=50s")
        XCTAssertEqual(poll.titleHelpText, poll.title, "the arguments are on the row, not in the tooltip again")
        XCTAssertNil(record(ExternalAutovisorToolNames.folderStatus).inlineArgumentsText)
        let readLog = record(ExternalAutovisorToolNames.taskLog, args: "task=#4", outcome: "22 messages (4632 B)")
        XCTAssertFalse(readLog.isAgentAction, "a read is drawn dim")
        XCTAssertTrue(readLog.titleNarratesArguments)
        XCTAssertNil(readLog.inlineArgumentsText, "`read log of #4` already says `task=#4`")
        let close = record(ExternalAutovisorToolNames.controlTask, args: "task=#4 action=close")
        XCTAssertTrue(close.isAgentAction)
        XCTAssertNil(close.inlineArgumentsText)
        XCTAssertTrue(failed.isAgentAction, "a failure is something that happened to a task, drawn as one")

        // Messaging a role and scheduling a task are things the agent DID, drawn as actions.
        let messaged = record(ExternalAutovisorToolNames.messageTask, roleID: "engineer", args: "task=#4 role=engineer")
        XCTAssertEqual(messaged.kind, .messaged)
        XCTAssertEqual(messaged.title, "Claude Code → messaged engineer on #4")
        XCTAssertTrue(messaged.isAgentAction)
        let scheduled = record(ExternalAutovisorToolNames.scheduleTask, args: "task=#4 repeat_daily_at=09:30")
        XCTAssertEqual(scheduled.kind, .scheduled)
        XCTAssertEqual(scheduled.title, "Claude Code → scheduled #4")
        XCTAssertTrue(scheduled.isAgentAction)
        XCTAssertNil(scheduled.inlineArgumentsText)
        // The chevron that showed a narrated title's arguments is gone; a row with no full call
        // (recorded before calls were kept) still says its cadence — in the title's tooltip.
        XCTAssertEqual(scheduled.titleHelpText, "Claude Code → scheduled #4\ntask=#4 repeat_daily_at=09:30")
        XCTAssertFalse(scheduled.hasFullCall)
        XCTAssertEqual(record(ExternalAutovisorToolNames.scheduleTask).titleHelpText, "Claude Code → scheduled #4",
                       "no arguments recorded → the title alone")
    }

    // MARK: - A replaced Work Folder Context (2026-11-13)

    /// The one call that reaches past the agent's tasks is drawn as an action — a sentence, its
    /// length in the title's tooltip as a schedule's cadence is, and never its text; a refusal is
    /// drawn as an error, like any other.
    func testAContextWrite_isAnActionRow_withItsLength_andARefusalIsAnError() {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        let agentID = UUID()
        func item(ok: Bool, errorCode: String? = nil, outcome: String = "") -> ExternalAutovisorFeedItem {
            ExternalAutovisorFeedItem.from(
                record: ExternalAutovisorActivityRecord(
                    createdAt: now, agentID: agentID, agentLabel: "Claude Code",
                    tool: ExternalAutovisorToolNames.setWorkFolderContext,
                    ok: ok, errorCode: errorCode, resultBytes: 10,
                    argumentsSummary: "characters=412", outcomeSummary: outcome),
                hasFullCall: true,
                now: now)
        }

        let written = item(ok: true)
        XCTAssertEqual(written.kind, .folderContext)
        XCTAssertEqual(written.title, "Claude Code → replaced the Work Folder Context")
        XCTAssertTrue(written.isAgentAction)
        XCTAssertFalse(written.isError)
        XCTAssertNil(written.inlineArgumentsText, "an action's title is a sentence, not `$ tool args`")
        XCTAssertEqual(written.titleHelpText, "Claude Code → replaced the Work Folder Context\ncharacters=412")
        XCTAssertEqual(written.resultText, "ok")
        XCTAssertNil(written.taskBadgeText, "it is about no one task")
        XCTAssertEqual(ExternalAutovisorActivityRow.glyph(for: written.kind), TerminalGlyph.revision)

        let refused = item(
            ok: false, errorCode: "NOT_ALLOWED",
            outcome: "NOT_ALLOWED: \(NTMSOrchestrator.contextReplacementNotAllowedMessage)")
        XCTAssertEqual(refused.kind, .error)
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(refused.title, "Claude Code → set_work_folder_context failed (NOT_ALLOWED)")
        XCTAssertEqual(refused.resultText, NTMSOrchestrator.contextReplacementNotAllowedMessage)
    }

    // MARK: - Full calls (2026-11-08)

    /// A row opens its call in full exactly when the log holds that call on disk — the set the
    /// pane reads (`ExternalAutovisorActivityLog.fullCallIDs`) — and the window it opens names
    /// the row's own record, tool, outcome and time.
    func testFullCall_aRowOpensOnlyACallThatIsOnDisk() throws {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        let agentID = UUID()
        let legacy = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-120), agentID: agentID, agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.folderStatus, ok: true, resultBytes: 1371,
            outcomeSummary: "ok (1371 B)")
        let kept = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-60), agentID: agentID, agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.createManagedTask, ok: false, errorCode: "INVALID_ARGS",
            resultBytes: 220, outcomeSummary: "INVALID_ARGS: Missing required parameter: brief")
        let presentation = ExternalAutovisorPanePresentation.build(
            listenerState: .listening(port: 47321), externalAgentsEnabled: true, configuredPort: 47321,
            isAutovisorEnabled: true, readiness: .forState(.ready), agentRecords: [],
            isAgentPresent: { _ in false }, hasActiveWait: { _ in false },
            taskSummaries: [], loadedTask: { _ in nil }, activityEntries: [legacy, kept],
            fullCallIDs: [kept.id, UUID()], activityTaskFilter: nil, activityClearedUpTo: nil, now: now)

        XCTAssertEqual(presentation.activity.items.map(\.id), [kept.id, legacy.id], "newest first")
        let keptItem = presentation.activity.items[0]
        let legacyItem = presentation.activity.items[1]
        XCTAssertTrue(keptItem.hasFullCall)
        XCTAssertFalse(legacyItem.hasFullCall, "recorded before calls were kept — nothing to open")

        guard case .externalAgentCall(let id, let toolName, let isError, let createdAt) = keptItem.detailWindow else {
            return XCTFail("a row opens the external-call window, got \(keptItem.detailWindow)")
        }
        XCTAssertEqual(id, kept.id)
        XCTAssertEqual(toolName, ExternalAutovisorToolNames.createManagedTask)
        XCTAssertTrue(isError, "a failed call opens with the error tint")
        XCTAssertEqual(createdAt, kept.createdAt)
        XCTAssertEqual(keptItem.detailWindow.dedupKey, "external-call:\(kept.id)")
    }

    /// The agent's label on a task row says WHICH agent — a fact only when there is more than one.
    func testShowsAgentTagOnTaskRows_onlyWhenSeveralAgentsAreRegistered() {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        func presentation(agents: [HostedMCPAgentRecord]) -> ExternalAutovisorPanePresentation {
            ExternalAutovisorPanePresentation.build(
                listenerState: .listening(port: 47321), externalAgentsEnabled: true, configuredPort: 47321,
                isAutovisorEnabled: true, readiness: .forState(.ready), agentRecords: agents,
                isAgentPresent: { _ in false }, hasActiveWait: { _ in false },
                taskSummaries: [], loadedTask: { _ in nil }, activityEntries: [], fullCallIDs: [],
                activityTaskFilter: nil, activityClearedUpTo: nil, now: now)
        }
        func agent(_ label: String) -> HostedMCPAgentRecord {
            HostedMCPAgentRecord(id: UUID(), shortID: "abcd1234", label: label, createdAt: now, lastSeenAt: nil, clientHint: nil)
        }
        XCTAssertFalse(presentation(agents: []).showsAgentTagOnTaskRows)
        XCTAssertFalse(presentation(agents: [agent("Claude Code")]).showsAgentTagOnTaskRows)
        XCTAssertTrue(presentation(agents: [agent("Claude Code"), agent("Cursor")]).showsAgentTagOnTaskRows)
    }

    /// The readiness badge spells the state for a person — never the wire's `snake_case`.
    func testReadinessStateDisplayLabels_areWordsForEveryState() {
        let expected: [ExternalAutovisorReadiness.State: String] = [
            .ready: "Ready",
            .folderTransition: "Opening folder",
            .folderInUse: "Open in another NanoTeams",
            .noWorkFolder: "No work folder",
            .autovisorDisabled: "Autovisor off",
            .builtInDriver: "Built-in driver",
        ]
        for state in ExternalAutovisorReadiness.State.allCases {
            XCTAssertEqual(state.displayLabel, expected[state], "\(state)")
            XCTAssertFalse(state.displayLabel.contains("_"), "\(state) leaks its raw value")
        }
    }

    // MARK: - External Tasks Filtering & Watchtower Card Presentation

    func testExternalTasksAndWatchtowerCardPresentation() {
        let now = Date(timeIntervalSince1970: 1_749_946_000)
        let agentID = UUID()
        let identity = AgentIdentity(id: agentID, label: "Cursor Agent")

        let humanTask = NTMSTask(id: 1, title: "Human Task", supervisorTask: "Brief", origin: nil)
        let builtInTask = NTMSTask(id: 2, title: "Built-in Task", supervisorTask: "Brief", origin: .builtInAutovisor)
        let externalTask = NTMSTask(id: 3, title: "External Task", supervisorTask: "Brief", origin: .externalAgent(identity))

        let allTasks = [humanTask, builtInTask, externalTask]
        let byID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })

        let panePresentation = ExternalAutovisorPanePresentation.build(
            listenerState: .listening(port: 47321),
            externalAgentsEnabled: true,
            configuredPort: 47321,
            isAutovisorEnabled: true,
            readiness: .forState(.ready),
            agentRecords: [],
            isAgentPresent: { _ in true },
            hasActiveWait: { _ in false },
            taskSummaries: allTasks.map { $0.toSummary() },
            loadedTask: { byID[$0] },
            activityEntries: [],
            fullCallIDs: [],
            activityTaskFilter: nil,
            activityClearedUpTo: nil,
            now: now
        )
        XCTAssertEqual(panePresentation.externalTasks.map { $0.id }, [3])
        XCTAssertEqual(panePresentation.externalTasks.first?.agentIdentity, identity)

        let agentRecord = HostedMCPAgentRecord(
            id: agentID,
            shortID: "112233445566",
            label: "Cursor Agent",
            createdAt: now.addingTimeInterval(-600),
            lastSeenAt: now.addingTimeInterval(-120),
            clientHint: nil
        )

        let builtInWatchtower = WatchtowerAutovisorCardPresentation.build(
            driver: .builtInModel,
            isEnabled: true,
            agents: [agentRecord],
            now: now
        )
        XCTAssertFalse(builtInWatchtower.showsExternalDriverRow)
        XCTAssertFalse(builtInWatchtower.showsPowerToggle)
        XCTAssertTrue(builtInWatchtower.showsGoalSection)
        XCTAssertTrue(builtInWatchtower.showsMemorySection)
        XCTAssertTrue(builtInWatchtower.showsMessageComposer)

        let externalWatchtower = WatchtowerAutovisorCardPresentation.build(
            driver: .externalAgent,
            isEnabled: true,
            agents: [agentRecord],
            now: now
        )
        XCTAssertTrue(externalWatchtower.showsExternalDriverRow)
        XCTAssertTrue(externalWatchtower.showsPowerToggle)
        XCTAssertTrue(externalWatchtower.showsGoalSection)
        XCTAssertFalse(externalWatchtower.showsMemorySection)
        XCTAssertFalse(externalWatchtower.showsMessageComposer)
        XCTAssertEqual(externalWatchtower.driverHeadline, "Driven by Cursor Agent · last seen 2m ago")
    }

    // MARK: - View Hosting Smoke Check

    func testExternalAutovisorPane_mountsInHostingView() {
        let store = TestOrchestrator.make()
        var selection: MainLayoutView.NavigationItem? = .autovisor
        let binding = Binding<MainLayoutView.NavigationItem?>(
            get: { selection },
            set: { selection = $0 }
        )
        let view = ExternalAutovisorPane(selectedItem: binding)
            .environment(store)
            .environment(store.configuration)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.width, 800)
    }

    func testHostedMCPAgentsRevision_incrementsWhenActiveWaiterRegistersAndCancels() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMS-ExtAutovisorPane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = TestOrchestrator.make(repository: NTMSRepository())
        await store.openWorkFolder(tempDir)
        let cursor = try XCTUnwrap(store.autovisorEventFeed.currentCursor)

        let agentID = UUID()
        let revBefore = store.hostedMCPAgentsRevision
        XCTAssertFalse(store.hasActiveHostedMCPWait(forAgent: agentID))

        let waitTask = Task { @MainActor in
            await store.autovisorEventFeed.waitForEvents(
                agentID: agentID,
                after: cursor,
                timeoutSeconds: 30
            )
        }

        await Task.yield()
        await Task.yield()

        XCTAssertTrue(store.hasActiveHostedMCPWait(forAgent: agentID))
        let revDuringWait = store.hostedMCPAgentsRevision
        XCTAssertGreaterThan(revDuringWait, revBefore)

        store.autovisorEventFeed.cancelWaiters(forAgentID: agentID)
        _ = await waitTask.value

        XCTAssertFalse(store.hasActiveHostedMCPWait(forAgent: agentID))
        XCTAssertGreaterThan(store.hostedMCPAgentsRevision, revDuringWait)
    }
}
