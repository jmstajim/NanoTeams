import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure logic extracted from `SidebarView`'s computed
/// properties. `@MainActor` (mirrors the established view-logic-helper test pattern, e.g.
/// `TeamActivityComposerRoutingTests`) because it touches view-adjacent types; every test
/// is value-in/value-out — no live view, store, or engine.
@MainActor
final class SidebarViewLogicTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    private func summary(
        _ id: Int,
        status: TaskStatus,
        isChatMode: Bool = false,
        recurring: Bool = false,
        waiting: Bool? = false
    ) -> TaskSummary {
        TaskSummary(
            id: id, title: "task\(id)", status: status, updatedAt: t0,
            isChatMode: isChatMode,
            nextRecurrenceFireAt: recurring ? t0 : nil,
            hasPendingSupervisorInput: waiting
        )
    }

    private func item(_ id: Int, status: TaskStatus, recurring: Bool = false) -> SidebarTaskItem {
        SidebarTaskItem(id: id, title: "t\(id)", status: status, updatedAt: t0, isRecurring: recurring)
    }

    // MARK: - buildSidebarTaskItems

    func testBuild_unreadLightsForUnseenChatModeSupervisorInput() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .needsSupervisorInput, isChatMode: true, waiting: true)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertTrue(items[0].hasUnreadInput)
    }

    func testBuild_unreadOffWhenSeen() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .needsSupervisorInput, isChatMode: true, waiting: true)],
            seenSupervisorInputTaskIDs: [1],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput, "Seen ⇒ no unread badge")
    }

    func testBuild_unreadRequiresChatMode() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .needsSupervisorInput, isChatMode: false, waiting: true)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput, "Non-chat tasks never show the unread badge")
    }

    func testBuild_unreadRequiresAPendingQuestion() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running, isChatMode: true, waiting: false)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput)
    }

    /// The restart shape: recovery parked the step, so the status says `.paused`, but
    /// the question is still standing. Keyed on status this went dark — which is what
    /// made an unanswered chat indistinguishable from an answered one after a relaunch.
    func testBuild_unreadLightsForAParkedButWaitingChat() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .paused, isChatMode: true, waiting: true)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertTrue(items[0].hasUnreadInput)
    }

    /// A legacy index row predating the field answers nothing, and "unknown" must not
    /// light an indicator on its own.
    func testBuild_unknownWaitState_doesNotLight() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .paused, isChatMode: true, waiting: nil)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput)
    }

    // MARK: - hasPendingBashApproval (cross-task held-command badge)

    func testBuild_bashApprovalFlag_litForMatchingTask() {
        // A background task (status .running, NOT .needsSupervisorInput — the in-loop
        // hold keeps it running) still gets the badge purely from the request set.
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running), summary(2, status: .running)],
            seenSupervisorInputTaskIDs: [],
            bashApprovalTaskIDs: [2],
            engineStates: [1: .running, 2: .running]
        )
        XCTAssertFalse(items[0].hasPendingBashApproval, "task 1 has no held command")
        XCTAssertTrue(items[1].hasPendingBashApproval, "task 2 is holding a command")
    }

    func testBuild_bashApprovalFlag_defaultsOffWhenSetEmpty() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running)],
            seenSupervisorInputTaskIDs: [],
            bashApprovalTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasPendingBashApproval)
    }

    func testBuild_bashApprovalFlag_unrelatedTaskIDsDoNotLeak() {
        // A held command on a child/other task id (e.g. 99) must not light any visible
        // top-level row.
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running)],
            seenSupervisorInputTaskIDs: [],
            bashApprovalTaskIDs: [99],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasPendingBashApproval)
    }

    func testBuild_engineRunningFlag() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running), summary(2, status: .running)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [1: .running, 2: .paused]
        )
        XCTAssertTrue(items[0].isEngineRunning)
        XCTAssertFalse(items[1].isEngineRunning, "paused engine is not running")
    }

    func testBuild_engineRunningFalseWhenAbsent() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].isEngineRunning, "no engine entry ⇒ not running")
    }

    func testBuild_recurringFlagAndFieldPassthrough() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(7, status: .done, isChatMode: true, recurring: true)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        let it = items[0]
        XCTAssertEqual(it.id, 7)
        XCTAssertEqual(it.title, "task7")
        XCTAssertEqual(it.status, .done)
        XCTAssertTrue(it.isChatMode)
        XCTAssertTrue(it.isRecurring)
    }

    func testBuild_emptySummaries_returnsEmpty() {
        XCTAssertTrue(SidebarViewLogic.buildSidebarTaskItems(
            summaries: [], seenSupervisorInputTaskIDs: [], engineStates: [:]).isEmpty)
    }

    func testBuild_mapsAllSummariesOneToOneInOrder() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(3, status: .running), summary(1, status: .done), summary(2, status: .paused)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertEqual(items.map(\.id), [3, 1, 2], "1:1 projection preserving input order")
    }

    // MARK: - filterCount

    func testFilterCount_allCategories() {
        let items = [
            item(1, status: .running),
            item(2, status: .done),
            item(3, status: .paused, recurring: true),
            item(4, status: .done),
        ]
        XCTAssertEqual(SidebarViewLogic.filterCount(.all, from: items), 4)
        XCTAssertEqual(SidebarViewLogic.filterCount(.running, from: items), 2, "running = not-done (running + paused)")
        XCTAssertEqual(SidebarViewLogic.filterCount(.done, from: items), 2)
        XCTAssertEqual(SidebarViewLogic.filterCount(.recurring, from: items), 1)
    }

    func testFilterCount_empty_isZeroForEveryFilter() {
        for f in TaskFilter.allCases {
            XCTAssertEqual(SidebarViewLogic.filterCount(f, from: []), 0, "\(f)")
        }
    }

    // MARK: - resolveCTALabel

    func testResolveCTALabel_searchPriorityOverFilter() {
        XCTAssertEqual(SidebarViewLogic.resolveCTALabel(searchText: "x", filter: .all), "Clear Search")
        XCTAssertEqual(SidebarViewLogic.resolveCTALabel(searchText: "x", filter: .running), "Clear Search",
                       "active search clears before filter resets")
    }

    func testResolveCTALabel_filterThenNewTask() {
        XCTAssertEqual(SidebarViewLogic.resolveCTALabel(searchText: "", filter: .running), "Show All")
        XCTAssertEqual(SidebarViewLogic.resolveCTALabel(searchText: "", filter: .all), "New Task")
    }

    // MARK: - resolveManagerRowInfo

    func testManagerRow_noFolder_isNil() {
        XCTAssertNil(SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: false, isManagerActive: false,
            engineState: nil, isIdleParked: false),
        "Default storage / no folder hides the row entirely — Autovisor is folder-scoped.")
    }

    func testManagerRow_noFolder_evenIfStaleActive_isNil() {
        XCTAssertNil(SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: false, isManagerActive: true,
            engineState: .running, isIdleParked: false),
        "No-folder gate dominates a stale active flag — paranoia against transition races.")
    }

    func testManagerRow_folder_unconfigured_showsSetupRow() {
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: false,
            engineState: nil, isIdleParked: false)
        XCTAssertEqual(info, .init(isEnabled: false, running: false, needsInput: false),
                       "Folder open but manager not yet created → row visible, quiet (drives setup pane).")
    }

    func testManagerRow_folder_unconfigured_ignoresStaleEngineState() {
        // A previously-deleted manager could leave a `taskEngineStates[id]` entry
        // if the engine cleanup raced settings. The row must NOT paint a status
        // badge over a setup row.
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: false,
            engineState: .running, isIdleParked: false)
        XCTAssertEqual(info, .init(isEnabled: false, running: false, needsInput: false))
    }

    func testManagerRow_running() {
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: true,
            engineState: .running, isIdleParked: false)
        XCTAssertEqual(info, .init(isEnabled: true, running: true, needsInput: false))
    }

    func testManagerRow_needsInput_whenNotParked() {
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: true,
            engineState: .needsSupervisorInput, isIdleParked: false)
        XCTAssertEqual(info, .init(isEnabled: true, running: false, needsInput: true))
    }

    func testManagerRow_idleParkSuppressesNeedsInput() {
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: true,
            engineState: .needsSupervisorInput, isIdleParked: true)
        XCTAssertEqual(info, .init(isEnabled: true, running: false, needsInput: false),
                       "wait_for_events idle park must not pulse the row")
    }

    func testManagerRow_nilState_shownButQuiet() {
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: true,
            engineState: nil, isIdleParked: false)
        XCTAssertEqual(info, .init(isEnabled: true, running: false, needsInput: false))
    }

    func testManagerRow_pausedState_shownButQuiet() {
        let info = SidebarViewLogic.resolveManagerRowInfo(
            hasWorkFolder: true, isManagerActive: true,
            engineState: .paused, isIdleParked: false)
        XCTAssertEqual(info, .init(isEnabled: true, running: false, needsInput: false))
    }

    // MARK: - The run-start spinner

    /// The sidebar spins for a run whose START is in flight, not only for one already
    /// running — otherwise the row goes still for exactly the seconds the user is asking
    /// about. The status LABEL stays whatever `TaskStatus` says: this column has no room
    /// for a caption, so the word lives only where there is (`RunInitializationDisplay`).
    ///
    /// RED: drop `initializingTaskIDs` from the builder → `isInitializing` is false and
    /// the first assertion fails.
    func testBuild_initializingTaskIsMarked_withoutTouchingTheStatusLabel() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .waiting)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:],
            initializingTaskIDs: [1]
        )

        XCTAssertTrue(items[0].isInitializing)
        XCTAssertFalse(items[0].isEngineRunning,
                       "Anti-vacuum: the engine is NOT running, so the spinner in this row "
                           + "can only be coming from the run-start claim")
        XCTAssertEqual(items[0].status, .waiting,
                       "The phase must not rewrite the task's status — the two answer "
                           + "different questions and the row shows both")
    }

    /// The two facts overlap by a tick, so a row must not lose its spinner as the claim
    /// is released and the engine comes up — nor gain one from an unrelated task's claim.
    func testBuild_initializingAndRunningAreIndependentPerTask() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running), summary(2, status: .waiting)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [1: .running],
            initializingTaskIDs: [1]
        )

        XCTAssertTrue(items[0].isEngineRunning)
        XCTAssertTrue(items[0].isInitializing, "Both may be true at once — that is why "
            + "they are two fields and not one enum")
        XCTAssertFalse(items[1].isInitializing,
                       "A claim is per task: task 2 must not borrow task 1's spinner")
    }

    func testBuild_noClaims_leavesEveryRowStill() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .waiting)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].isInitializing,
                       "The default must be silence — a row that always spins says nothing")
    }
}

/// Pins the single-pass pill counter that replaced four per-filter passes inside
/// `ForEach(TaskFilter.allCases)`, three of which materialized an intermediate
/// array of up to T items on every body pass — i.e. on every `mutateTask`.
@MainActor
final class SidebarFilterCountsTests: XCTestCase {

    private func item(id: Int, status: TaskStatus, recurring: Bool = false) -> SidebarTaskItem {
        SidebarTaskItem(
            id: id, title: "T\(id)", status: status,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(id)),
            isChatMode: false, hasUnreadInput: false,
            isEngineRunning: false, isRecurring: recurring,
            hasPendingBashApproval: false)
    }

    private var mixed: [SidebarTaskItem] {
        [item(id: 1, status: .running),
         item(id: 2, status: .done),
         item(id: 3, status: .paused, recurring: true),
         item(id: 4, status: .done, recurring: true),
         item(id: 5, status: .failed)]
    }

    /// Equivalence with the per-filter spelling it replaced, case by case.
    func testCountsAgreeWithThePerFilterSpelling() {
        let items = mixed
        let counts = SidebarViewLogic.filterCounts(from: items)
        for filter in TaskFilter.allCases {
            XCTAssertEqual(counts[filter],
                           SidebarViewLogic.filterCount(filter, from: items),
                           "single-pass count disagrees for \(filter)")
        }
    }

    /// Anti-vacuum: the fixture must actually distinguish the cases, or the
    /// equivalence above would hold for any pair of wrong implementations.
    func testFixtureDiscriminatesEveryFilter() {
        let counts = SidebarViewLogic.filterCounts(from: mixed)
        XCTAssertEqual(counts.all, 5)
        XCTAssertEqual(counts.running, 3, "`.running` is NOT-done, not status == .running")
        XCTAssertEqual(counts.done, 2)
        XCTAssertEqual(counts.recurring, 2)
        XCTAssertNotEqual(counts.running, counts.done)
        XCTAssertNotEqual(counts.recurring, counts.all)
    }

    func testEmptyInput_isAllZeroes() {
        XCTAssertEqual(SidebarViewLogic.filterCounts(from: []), SidebarViewLogic.FilterCounts())
    }

    /// The pill count and the row list must answer from the SAME predicate — a
    /// pill promising N rows while the list shows M is the drift this shares
    /// `matches(_:_:)` to prevent.
    func testPillCountEqualsTheRowCountTheListShows() {
        let items = mixed
        let state = TaskManagementState()
        for filter in TaskFilter.allCases {
            state.taskFilter = filter
            XCTAssertEqual(
                state.filteredTasks(from: items).count,
                SidebarViewLogic.filterCounts(from: items)[filter],
                "pill and list disagree for \(filter)")
        }
    }
}
