import XCTest
@testable import NanoTeams

/// The External Autovisor activity card's header — the hide cutoff it shares with the
/// Watchtower's Recent Activity, and its task filter (2026-11-08, «сделай чтобы активити можно
/// было очистить, синхронизируй с главным экраном»).
@MainActor
final class ExternalAutovisorActivitySelectionTests: XCTestCase {

    private var now: Date!
    private var agentID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        now = Date(timeIntervalSince1970: 1_749_946_000)
        agentID = UUID()
    }

    override func tearDown() async throws {
        now = nil
        agentID = nil
        try await super.tearDown()
    }

    private func record(
        _ secondsAgo: TimeInterval,
        taskID: Int? = nil,
        named: Set<Int>? = nil,
        tool: String = ExternalAutovisorToolNames.taskStatus
    ) -> ExternalAutovisorActivityRecord {
        ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-secondsAgo), agentID: agentID, agentLabel: "Claude Code",
            tool: tool, taskID: taskID, namedTaskIDs: named, ok: true, resultBytes: 2)
    }

    private func task(_ id: Int, _ title: String) -> ExternalAutovisorTaskRowItem {
        ExternalAutovisorTaskRowItem(
            id: id, title: title, status: .done,
            agentIdentity: AgentIdentity(id: agentID, label: "Claude Code"),
            isWaitingForAnswer: false, waitingQuestionCount: 0)
    }

    private func select(
        _ entries: [ExternalAutovisorActivityRecord],
        tasks: [ExternalAutovisorTaskRowItem] = [],
        filter: Int? = nil,
        clearedUpTo: Date? = nil
    ) -> ExternalAutovisorActivitySelection {
        ExternalAutovisorActivitySelection.make(
            entries: entries, fullCallIDs: [], tasks: tasks,
            taskFilter: filter, clearedUpTo: clearedUpTo, now: now)
    }

    // MARK: - Hide

    /// The Watchtower's rule, boundary included: a row AT the cutoff is hidden, one after it is
    /// shown, newest first.
    func testHide_aRowAtOrBeforeTheCutoffIsNotShown() async {
        let old = record(300)
        let atCutoff = record(120)
        let fresh = record(60)
        let selection = select([old, atCutoff, fresh], clearedUpTo: atCutoff.createdAt)
        XCTAssertEqual(selection.items.map(\.id), [fresh.id])
        XCTAssertTrue(selection.canHide)
    }

    /// No cutoff: everything, newest first, and the control is live.
    func testHide_noCutoffShowsEveryRow() async {
        let first = record(120)
        let second = record(60)
        let selection = select([first, second])
        XCTAssertEqual(selection.items.map(\.id), [second.id, first.id])
        XCTAssertTrue(selection.canHide)
    }

    /// Everything hidden: no row, the control goes dead, and the line says the log was hidden —
    /// not that the agent never called.
    func testHide_everythingHiddenSaysSo() async {
        let selection = select([record(120), record(60)], clearedUpTo: now)
        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertFalse(selection.canHide)
        XCTAssertEqual(selection.emptyText, ExternalAutovisorActivitySelection.allHiddenText)
    }

    /// An empty log is not a hidden one.
    func testHide_anEmptyLogSaysNoCallsYet() async {
        let selection = select([], clearedUpTo: now)
        XCTAssertFalse(selection.canHide)
        XCTAssertEqual(selection.emptyText, ExternalAutovisorActivitySelection.noCallsYetText)
    }

    // MARK: - Task filter

    /// The menu offers the agent's tasks, `#N title`, in the pane's order.
    func testFilter_optionsAreTheAgentsTasks() async {
        let selection = select([], tasks: [task(2, "wordcount"), task(1, "linecount")])
        XCTAssertEqual(selection.filterOptions, [
            ActivityFilterBar.Option(id: 2, title: "#2 wordcount"),
            ActivityFilterBar.Option(id: 1, title: "#1 linecount"),
        ])
    }

    /// A call about the task — its target, or a response that named it (an event, a list row) —
    /// stays; a call about another task, or about none, goes.
    func testFilter_keepsTheCallsAboutTheTask() async {
        let target = record(50, taskID: 2)
        let event = record(40, named: [2, 9], tool: ExternalAutovisorToolNames.waitForEvents)
        let other = record(30, taskID: 1)
        let none = record(20, tool: ExternalAutovisorToolNames.folderStatus)
        let selection = select([target, event, other, none], tasks: [task(2, "w"), task(1, "l")], filter: 2)
        XCTAssertEqual(selection.taskFilter, 2)
        XCTAssertEqual(selection.items.map(\.id), [event.id, target.id])
    }

    /// A replaced Work Folder Context names no task and reaches every one: the roles of the task
    /// chosen read it too, so it stays under the filter (2026-11-13). A refused one changed
    /// nothing and goes, as a call about no task does. Neither is ABOUT a task — deleting one
    /// keeps its full call (`concerns(taskID:)`).
    func testFilter_keepsAReplacedWorkFolderContext_andDropsARefusedOne() async {
        let replaced = record(40, tool: ExternalAutovisorToolNames.setWorkFolderContext)
        let refused = ExternalAutovisorActivityRecord(
            createdAt: now.addingTimeInterval(-30), agentID: agentID, agentLabel: "Claude Code",
            tool: ExternalAutovisorToolNames.setWorkFolderContext, ok: false, errorCode: "NOT_ALLOWED",
            resultBytes: 2)
        let other = record(20, taskID: 1)

        let selection = select([replaced, refused, other], tasks: [task(2, "w"), task(1, "l")], filter: 2)

        XCTAssertEqual(selection.items.map(\.id), [replaced.id])
        XCTAssertTrue(replaced.reachesEveryTask)
        XCTAssertFalse(refused.reachesEveryTask)
        XCTAssertFalse(replaced.concerns(taskID: 2), "about no task, so no task's deletion takes its call")
        XCTAssertEqual(
            select([replaced, refused, other], tasks: [task(2, "w")]).items.count, 3,
            "with no filter every row shows")
    }

    /// The filter and the cutoff apply together.
    func testFilter_andCutoffApplyTogether() async {
        let hidden = record(120, taskID: 2)
        let shown = record(30, taskID: 2)
        let selection = select(
            [hidden, record(20, taskID: 1), shown], tasks: [task(2, "w"), task(1, "l")],
            filter: 2, clearedUpTo: now.addingTimeInterval(-60))
        XCTAssertEqual(selection.items.map(\.id), [shown.id])
    }

    /// A filter on a task no longer offered (deleted) is not in effect: every row shows, and the
    /// menu reads "All" — an empty list under "All" would read as an empty log.
    func testFilter_onATaskNoLongerOfferedIsIgnored() async {
        let rows = [record(60, taskID: 7), record(30, taskID: 1)]
        let selection = select(rows, tasks: [task(1, "l")], filter: 7)
        XCTAssertNil(selection.taskFilter)
        XCTAssertEqual(selection.items.count, 2)
        XCTAssertEqual(
            ActivityFilterBar.label(for: selection.taskFilter, in: selection.filterOptions),
            ActivityFilterBar.allLabel)
    }

    /// A filter with nothing to show names the task, so the line is not mistaken for an empty log.
    func testFilter_withNothingToShowNamesTheTask() async {
        let selection = select([record(30, taskID: 1)], tasks: [task(2, "w"), task(1, "l")], filter: 2)
        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertFalse(selection.canHide)
        XCTAssertEqual(selection.emptyText, ExternalAutovisorActivitySelection.noCallsText(aboutTask: 2))
    }

    // MARK: - The presentation carries it

    /// The pane's presentation hands the card exactly this selection — the cutoff and filter it
    /// was built with, against the agent's own tasks.
    func testPresentation_buildsTheSelectionFromItsInputs() async {
        let identity = AgentIdentity(id: agentID, label: "Claude Code")
        let mine = NTMSTask(id: 2, title: "wordcount", supervisorTask: "x", origin: .externalAgent(identity))
        let hidden = record(120, taskID: 2)
        let shown = record(30, taskID: 2)
        let presentation = ExternalAutovisorPanePresentation.build(
            listenerState: .listening(port: 47321), externalAgentsEnabled: true, configuredPort: 47321,
            isAutovisorEnabled: true, readiness: .forState(.ready), agentRecords: [],
            isAgentPresent: { _ in false }, hasActiveWait: { _ in false },
            taskSummaries: [mine.toSummary()], loadedTask: { $0 == 2 ? mine : nil },
            activityEntries: [hidden, record(60, taskID: 5), shown], fullCallIDs: [shown.id],
            activityTaskFilter: 2, activityClearedUpTo: now.addingTimeInterval(-90), now: now)
        XCTAssertEqual(presentation.activity.items.map(\.id), [shown.id])
        XCTAssertTrue(presentation.activity.items[0].hasFullCall)
        XCTAssertEqual(presentation.activity.filterOptions.map(\.id), [2])
        XCTAssertEqual(presentation.activity.taskFilter, 2)
    }

    // MARK: - The shared header's menu title

    /// The menu reads the selected option's title, and "All" for no selection.
    func testFilterBarLabel_readsTheSelectionOrAll() async {
        let options = [ActivityFilterBar.Option(id: 3, title: "#3 parser")]
        XCTAssertEqual(ActivityFilterBar.label(for: nil, in: options), ActivityFilterBar.allLabel)
        XCTAssertEqual(ActivityFilterBar.label(for: 3, in: options), "#3 parser")
        XCTAssertEqual(ActivityFilterBar.label(for: 4, in: options), ActivityFilterBar.allLabel)
        XCTAssertEqual(ActivityFilterBar.allLabel, "All tasks & chats", "the Watchtower's own words")
    }
}
