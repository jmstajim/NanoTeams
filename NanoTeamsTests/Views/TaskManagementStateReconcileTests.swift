import XCTest
@testable import NanoTeams

/// Tests for `TaskManagementState.reconcileSeenSet(activeStatuses:)`.
///
/// Reconcile is the "clear stale seen flags for ALL tasks, not just the
/// active one" sweep. Without it, persisting the seen set across launches
/// (the bug fix) would leave a task that exited `.needsSupervisorInput`
/// while backgrounded permanently marked seen — the next question on the
/// same task would show no dot.
@MainActor
final class TaskManagementStateReconcileTests: XCTestCase {

    var sut: TaskManagementState!

    override func setUp() {
        super.setUp()
        sut = TaskManagementState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Pure function over input

    func testReconcile_clearsTasksNoLongerInNeedsSupervisorInput() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)
        sut.markSupervisorInputSeen(taskID: 3)

        sut.reconcileSeenSet(activeStatuses: [
            1: .needsSupervisorInput,  // still waiting → keep seen
            2: .running,                // answered, working → clear
            3: .done,                   // terminal → clear
        ])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1]))
    }

    func testReconcile_clearsTasksAbsentFromIndex() {
        // Simulates task deletion: the task ID is in the seen set but the
        // tasks index no longer mentions it. Must be cleared.
        sut.markSupervisorInputSeen(taskID: 5)
        sut.markSupervisorInputSeen(taskID: 6)

        sut.reconcileSeenSet(activeStatuses: [
            6: .needsSupervisorInput,
            // 5 is absent (deleted)
        ])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([6]))
    }

    /// Empty `activeStatuses` indicates snapshot teardown (folder close) or a
    /// not-yet-loaded snapshot — NOT that every task is gone. Reconcile must
    /// short-circuit so closing a folder doesn't destroy persisted state.
    func testReconcile_emptyInput_isNoOp() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(activeStatuses: [:])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    func testReconcile_emptySeenSet_isNoOp() {
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
        sut.reconcileSeenSet(activeStatuses: [
            1: .needsSupervisorInput,
            2: .done,
        ])
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
    }

    func testReconcile_allTasksStillWaiting_preservesSeenSet() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(activeStatuses: [
            1: .needsSupervisorInput,
            2: .needsSupervisorInput,
        ])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }
}
