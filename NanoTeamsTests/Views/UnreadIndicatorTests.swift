import XCTest
@testable import NanoTeams

/// Tests for the unread supervisor input indicator in the sidebar.
///
/// Validates:
/// - `TaskManagementState.seenSupervisorInputTaskIDs` lifecycle (mark, clear, delete)
/// - `hasUnreadInput` computation logic (chat mode, status, seen set interaction)
/// - `SidebarTaskItem` default values
@MainActor
final class UnreadIndicatorTests: XCTestCase {

    var sut: TaskManagementState!

    override func setUp() async throws {
        try await super.setUp()
        sut = TaskManagementState()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private let taskA = 10
    private let taskB = 20

    /// Calls PRODUCTION. Both of this file's ancestors re-implemented the predicate
    /// here instead, which is why they stayed green through the change that moved the
    /// indicator off `TaskStatus` onto the durable waiting fact (CLAUDE.md #57).
    private func computeHasUnread(
        isChatMode: Bool,
        waiting: Bool,
        taskID: Int,
        status: TaskStatus = .running
    ) -> Bool {
        var summary = TaskSummary(id: taskID, title: "t\(taskID)", status: status, isChatMode: isChatMode)
        summary.hasPendingSupervisorInput = waiting
        return SidebarViewLogic.buildSidebarTaskItems(
            summaries: [summary],
            seenSupervisorInputTaskIDs: sut.seenSupervisorInputTaskIDs,
            engineStates: [:]
        )[0].hasUnreadInput
    }

    // MARK: - SeenSet: Mark Seen

    func testMarkSeen_insertsTaskID() {
        sut.markSupervisorInputSeen(taskID: taskA)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskA))
    }

    func testMarkSeen_idempotent() {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.markSupervisorInputSeen(taskID: taskA)
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs.count, 1)
    }

    func testMarkSeen_multipleTasksIndependent() {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.markSupervisorInputSeen(taskID: taskB)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskA))
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskB))
    }

    // MARK: - SeenSet: Removal

    func testRemove_clearsSingleTask() {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.markSupervisorInputSeen(taskID: taskB)
        sut.unmarkSupervisorInputSeen(taskID: taskA)
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(taskA))
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskB))
    }

    func testRemove_nonExistentID_noOp() {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.unmarkSupervisorInputSeen(taskID: taskB)
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs.count, 1)
    }

    // MARK: - SeenSet: Cleanup on Delete

    func testConfirmDelete_removesFromSeenSet() async {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.taskToDelete = taskA
        // confirmDelete calls store.removeTask which needs a real store,
        // but the seen set removal happens regardless
        _ = await sut.confirmDelete(store: TestOrchestrator.make())
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(taskA))
    }

    // MARK: - SeenSet: Empty on Init

    func testSeenSet_emptyByDefault() {
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
    }

    // MARK: - HasUnreadInput: Core Logic

    func testHasUnread_waitingAndNotSeen_returnsTrue() {
        let result = computeHasUnread(isChatMode: true, waiting: true, taskID: taskA)
        XCTAssertTrue(result)
    }

    func testHasUnread_waitingButSeen_returnsFalse() {
        sut.markSupervisorInputSeen(taskID: taskA)
        let result = computeHasUnread(isChatMode: true, waiting: true, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_nonChatMode_returnsFalse() {
        let result = computeHasUnread(isChatMode: false, waiting: true, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_notWaiting_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, waiting: false, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_notWaitingWhilePaused_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, waiting: false, taskID: taskA, status: .paused)
        XCTAssertFalse(result)
    }

    func testHasUnread_notWaitingWhileDone_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, waiting: false, taskID: taskA, status: .done)
        XCTAssertFalse(result)
    }

    func testHasUnread_notWaitingWhileFailed_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, waiting: false, taskID: taskA, status: .failed)
        XCTAssertFalse(result)
    }

    // MARK: - HasUnreadInput: Question Cycle (seen → status change → new question)

    func testQuestionCycle_seenThenStatusChange_reEnablesIndicator() {
        // 1. First question arrives, user sees it
        XCTAssertTrue(computeHasUnread(isChatMode: true, waiting: true, taskID: taskA))
        sut.markSupervisorInputSeen(taskID: taskA)
        XCTAssertFalse(computeHasUnread(isChatMode: true, waiting: true, taskID: taskA))

        // 2. User answers → status changes → clear seen set (simulates onChange handler)
        sut.unmarkSupervisorInputSeen(taskID: taskA)

        // 3. Second question arrives → indicator re-triggers
        XCTAssertTrue(computeHasUnread(isChatMode: true, waiting: true, taskID: taskA))
    }

    func testQuestionCycle_withoutClearing_indicatorStaysOff() {
        // If seen set is NOT cleared on status change, second question is suppressed
        sut.markSupervisorInputSeen(taskID: taskA)
        // Skip the remove step — simulates the bug the onChange handler fixes
        XCTAssertFalse(computeHasUnread(isChatMode: true, waiting: true, taskID: taskA))
    }

    // MARK: - HasUnreadInput: Multiple Tasks

    func testMultipleTasks_independentUnreadState() {
        // Task A seen, Task B not seen — both in needsSupervisorInput
        sut.markSupervisorInputSeen(taskID: taskA)
        XCTAssertFalse(computeHasUnread(isChatMode: true, waiting: true, taskID: taskA))
        XCTAssertTrue(computeHasUnread(isChatMode: true, waiting: true, taskID: taskB))
    }

    // MARK: - SidebarTaskItem Defaults

    func testSidebarTaskItem_hasUnreadInput_defaultsFalse() {
        let item = SidebarTaskItem(id: 0, title: "Test", status: .running, updatedAt: Date())
        XCTAssertFalse(item.hasUnreadInput)
    }

    func testSidebarTaskItem_isChatMode_defaultsFalse() {
        let item = SidebarTaskItem(id: 0, title: "Test", status: .running, updatedAt: Date())
        XCTAssertFalse(item.isChatMode)
    }

    func testSidebarTaskItem_hasUnreadInput_canBeSetTrue() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .needsSupervisorInput,
            updatedAt: Date(), isChatMode: true, hasUnreadInput: true
        )
        XCTAssertTrue(item.hasUnreadInput)
    }

    // MARK: - Edge Cases

    /// Inverted deliberately. This used to pin "unread ⟺ `status == .needsSupervisorInput`",
    /// which is the coupling that made the indicator go dark on exactly the chats that
    /// were still waiting: `StatusRecoveryService` parks every waiting step at launch,
    /// so after a restart their status reads `.paused`. The indicator now follows the
    /// durable fact and must be INDEPENDENT of the run-control status.
    func testUnreadIsIndependentOfTaskStatus() {
        for status in TaskStatus.allCases {
            XCTAssertTrue(
                computeHasUnread(isChatMode: true, waiting: true, taskID: taskA, status: status),
                "a waiting chat must light regardless of status (\(status))")
            XCTAssertFalse(
                computeHasUnread(isChatMode: true, waiting: false, taskID: taskA, status: status),
                "an answered chat must stay dark regardless of status (\(status))")
        }
    }

    /// The restart shape, stated once: parked by recovery, still owed an answer.
    func testParkedAfterRestart_stillLightsTheIndicator() {
        XCTAssertTrue(
            computeHasUnread(isChatMode: true, waiting: true, taskID: taskA, status: .paused))
    }
}
