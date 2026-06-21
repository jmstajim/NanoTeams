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
        recurring: Bool = false
    ) -> TaskSummary {
        TaskSummary(
            id: id, title: "task\(id)", status: status, updatedAt: t0,
            isChatMode: isChatMode,
            nextRecurrenceFireAt: recurring ? t0 : nil
        )
    }

    private func item(_ id: Int, status: TaskStatus, recurring: Bool = false) -> SidebarTaskItem {
        SidebarTaskItem(id: id, title: "t\(id)", status: status, updatedAt: t0, isRecurring: recurring)
    }

    // MARK: - buildSidebarTaskItems

    func testBuild_unreadLightsForUnseenChatModeSupervisorInput() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .needsSupervisorInput, isChatMode: true)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertTrue(items[0].hasUnreadInput)
    }

    func testBuild_unreadOffWhenSeen() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .needsSupervisorInput, isChatMode: true)],
            seenSupervisorInputTaskIDs: [1],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput, "Seen ⇒ no unread badge")
    }

    func testBuild_unreadRequiresChatMode() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .needsSupervisorInput, isChatMode: false)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput, "Non-chat tasks never show the unread badge")
    }

    func testBuild_unreadRequiresNeedsSupervisorInputStatus() {
        let items = SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary(1, status: .running, isChatMode: true)],
            seenSupervisorInputTaskIDs: [],
            engineStates: [:]
        )
        XCTAssertFalse(items[0].hasUnreadInput)
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
}
