import XCTest
@testable import NanoTeams

/// Tests for `TaskManagementState.reconcileSeenSet(waitStates:)`.
///
/// Reconcile is the "clear stale seen flags for ALL tasks, not just the
/// active one" sweep. Without it, persisting the seen set across launches
/// (the bug fix) would leave a task that exited `.needsSupervisorInput`
/// while backgrounded permanently marked seen — the next question on the
/// same task would show no dot.
@MainActor
final class TaskManagementStateReconcileTests: XCTestCase {

    var sut: TaskManagementState!

    override func setUp() async throws {
        try await super.setUp()
        sut = TaskManagementState()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Pure function over input

    func testReconcile_clearsTasksNoLongerInNeedsSupervisorInput() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)
        sut.markSupervisorInputSeen(taskID: 3)

        sut.reconcileSeenSet(waitStates: [
            1: .waiting,     // still waiting → keep seen
            2: .notWaiting,  // answered, working → clear
            3: .notWaiting,  // terminal → clear
        ])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1]))
    }

    func testReconcile_clearsTasksAbsentFromIndex() {
        // Simulates task deletion: the task ID is in the seen set but the
        // tasks index no longer mentions it. Must be cleared.
        sut.markSupervisorInputSeen(taskID: 5)
        sut.markSupervisorInputSeen(taskID: 6)

        sut.reconcileSeenSet(waitStates: [
            6: .waiting,
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

        sut.reconcileSeenSet(waitStates: [:])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }

    func testReconcile_emptySeenSet_isNoOp() {
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
        sut.reconcileSeenSet(waitStates: [
            1: .waiting,
            2: .notWaiting,
        ])
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
    }

    /// The restart shape. `StatusRecoveryService` parks every waiting step to
    /// `.paused` at launch while leaving the question intact, so the coarse task
    /// status says "not waiting" for a task that IS waiting. Keyed on status, this
    /// sweep deleted the persisted flag on every single launch — the fixtures that
    /// existed here only ever used `.running` and `.done`, so nothing caught it.
    func testReconcile_parkedButStillWaiting_preservesSeenFlag() {
        sut.markSupervisorInputSeen(taskID: 1)

        sut.reconcileSeenSet(waitStates: [1: .waiting])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1]),
                       "a parked task that is still owed an answer must keep its seen flag")
    }

    /// A legacy index row predating `hasPendingSupervisorInput` answers nothing.
    /// Reading unknown as "answered" would wipe the whole persisted set on the first
    /// launch after the upgrade — the very failure this sweep is being fixed for.
    func testReconcile_unknownState_leavesFlagAlone() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(waitStates: [1: .unknown, 2: .notWaiting])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1]),
                       "unknown is not a licence to delete; only a known .notWaiting clears")
    }

    func testReconcile_allTasksStillWaiting_preservesSeenSet() {
        sut.markSupervisorInputSeen(taskID: 1)
        sut.markSupervisorInputSeen(taskID: 2)

        sut.reconcileSeenSet(waitStates: [
            1: .waiting,
            2: .waiting,
        ])

        XCTAssertEqual(sut.seenSupervisorInputTaskIDs, Set([1, 2]))
    }
}
