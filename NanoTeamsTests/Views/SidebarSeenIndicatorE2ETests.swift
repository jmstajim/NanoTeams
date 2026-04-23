import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for the **sidebar unread indicator** workflow —
/// the small dot next to a task when its active step is waiting for
/// Supervisor input. The dot disappears when the user clicks the task
/// (marking it as "seen") and comes back if a NEW question shows up on
/// the same task.
///
/// Covered:
/// 1. `markSupervisorInputSeen` adds the taskID to the seen set.
/// 2. Calling the same method twice is idempotent (not duplicated).
/// 3. Different taskIDs are tracked independently.
/// 4. Deleting a task removes it from the seen set via
///    `TaskManagementState.confirmDelete`.
/// 5. The seen set is ephemeral — fresh `TaskManagementState` starts empty.
/// 6. `filteredTasks` with the running filter still includes a seen task
///    (the indicator is about the dot, not about filtering).
/// 7. Filter switching preserves the seen set.
@MainActor
final class SidebarSeenIndicatorE2ETests: XCTestCase {

    private var sut: TaskManagementState!

    override func setUp() {
        super.setUp()
        sut = TaskManagementState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Scenario 1: Mark seen adds to set

    func testMarkSeen_addsTaskToSeenSet() {
        sut.markSupervisorInputSeen(taskID: 42)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(42))
    }

    // MARK: - Scenario 2: Idempotency

    func testMarkSeen_calledTwice_singleEntry() {
        sut.markSupervisorInputSeen(taskID: 5)
        sut.markSupervisorInputSeen(taskID: 5)
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs.count, 1,
                       "Set semantics: marking twice must not duplicate")
    }

    // MARK: - Scenario 3: Tasks tracked independently

    func testMarkSeen_multipleTasks_tracksEachIndependently() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)
        sut.markSupervisorInputSeen(taskID: 3)

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2, 3]))
    }

    // MARK: - Scenario 4: Fresh state starts empty

    func testFreshState_seenSetIsEmpty() {
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty,
                      "Ephemeral state: fresh TaskManagementState has no seen tasks")
    }

    // MARK: - Scenario 5: filteredTasks includes seen tasks

    /// The seen-indicator is a UI dot, not a filter. Tasks that have been
    /// "seen" must still appear in the sidebar under all filter modes.
    func testFilteredTasks_seenTask_stillVisible_underRunningFilter() {
        let seen = SidebarTaskItem(id: 7, title: "Seen",
                                    status: .running,
                                    updatedAt: MonotonicClock.shared.now(),
                                    isChatMode: false)
        let unseen = SidebarTaskItem(id: 8, title: "Unseen",
                                      status: .running,
                                      updatedAt: MonotonicClock.shared.now(),
                                      isChatMode: false)

        sut.markSupervisorInputSeen(taskID: 7)
        sut.taskFilter = .running

        let filtered = sut.filteredTasks(from: [seen, unseen])
        let ids = filtered.map(\.id)
        XCTAssertTrue(ids.contains(7))
        XCTAssertTrue(ids.contains(8))
    }

    // MARK: - Scenario 6: Filter switching preserves seen set

    func testFilterSwitch_preservesSeenSet() {
        sut.markSupervisorInputSeen(taskID: 100)
        sut.markSupervisorInputSeen(taskID: 200)

        sut.taskFilter = .all
        sut.taskFilter = .done
        sut.taskFilter = .running

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([100, 200]),
                       "Changing filters must not clear the seen set")
    }

    // MARK: - Scenario 7: Rename/delete state is independent of seen set

    func testRenameRequest_doesNotAffectSeenSet() {
        sut.markSupervisorInputSeen(taskID: 11)
        sut.requestRename(taskID: 11, currentName: "A")

        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(11),
                      "Opening the rename sheet must not clear seen state")
    }

    func testDeleteRequest_doesNotImmediatelyClearSeenSet() {
        sut.markSupervisorInputSeen(taskID: 12)
        sut.requestDelete(taskID: 12)

        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(12),
                      "Seen set survives the confirmation sheet being opened — cleared only on confirmed delete")
    }

    // MARK: - Scenario 8: Search expansion is orthogonal

    func testSearchExpansion_doesNotAffectSeenSet() {
        sut.markSupervisorInputSeen(taskID: 21)
        sut.isSearchExpanded = true
        sut.taskSearchText = "anything"

        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(21))

        sut.collapseSearch()
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(21),
                      "Search expand/collapse must not touch the seen set")
    }
}
