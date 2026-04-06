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

    override func setUp() {
        super.setUp()
        sut = TaskManagementState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private let taskA = 10
    private let taskB = 20

    /// Replicates the `hasUnreadInput` computation from `SidebarView.allTasks`.
    private func computeHasUnread(
        isChatMode: Bool,
        status: TaskStatus,
        taskID: Int
    ) -> Bool {
        isChatMode
            && status == .needsSupervisorInput
            && !sut.seenSupervisorInputTaskIDs.contains(taskID)
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
        sut.seenSupervisorInputTaskIDs.remove(taskA)
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(taskA))
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskB))
    }

    func testRemove_nonExistentID_noOp() {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.seenSupervisorInputTaskIDs.remove(taskB)
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs.count, 1)
    }

    // MARK: - SeenSet: Cleanup on Delete

    func testConfirmDelete_removesFromSeenSet() async {
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.taskToDelete = taskA
        // confirmDelete calls store.removeTask which needs a real store,
        // but the seen set removal happens regardless
        _ = await sut.confirmDelete(store: NTMSOrchestrator(repository: NTMSRepository()))
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(taskA))
    }

    // MARK: - SeenSet: Empty on Init

    func testSeenSet_emptyByDefault() {
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.isEmpty)
    }

    // MARK: - HasUnreadInput: Core Logic

    func testHasUnread_chatMode_needsSupervisorInput_notSeen_returnsTrue() {
        let result = computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA)
        XCTAssertTrue(result)
    }

    func testHasUnread_chatMode_needsSupervisorInput_seen_returnsFalse() {
        sut.markSupervisorInputSeen(taskID: taskA)
        let result = computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_nonChatMode_needsSupervisorInput_returnsFalse() {
        let result = computeHasUnread(isChatMode: false, status: .needsSupervisorInput, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_chatMode_running_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, status: .running, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_chatMode_paused_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, status: .paused, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_chatMode_done_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, status: .done, taskID: taskA)
        XCTAssertFalse(result)
    }

    func testHasUnread_chatMode_failed_returnsFalse() {
        let result = computeHasUnread(isChatMode: true, status: .failed, taskID: taskA)
        XCTAssertFalse(result)
    }

    // MARK: - HasUnreadInput: Question Cycle (seen → status change → new question)

    func testQuestionCycle_seenThenStatusChange_reEnablesIndicator() {
        // 1. First question arrives, user sees it
        XCTAssertTrue(computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA))
        sut.markSupervisorInputSeen(taskID: taskA)
        XCTAssertFalse(computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA))

        // 2. User answers → status changes → clear seen set (simulates onChange handler)
        sut.seenSupervisorInputTaskIDs.remove(taskA)

        // 3. Second question arrives → indicator re-triggers
        XCTAssertTrue(computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA))
    }

    func testQuestionCycle_withoutClearing_indicatorStaysOff() {
        // If seen set is NOT cleared on status change, second question is suppressed
        sut.markSupervisorInputSeen(taskID: taskA)
        // Skip the remove step — simulates the bug the onChange handler fixes
        XCTAssertFalse(computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA))
    }

    // MARK: - HasUnreadInput: Multiple Tasks

    func testMultipleTasks_independentUnreadState() {
        // Task A seen, Task B not seen — both in needsSupervisorInput
        sut.markSupervisorInputSeen(taskID: taskA)
        XCTAssertFalse(computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskA))
        XCTAssertTrue(computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskB))
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

    func testAllTaskStatuses_onlySupervisorInputShowsUnread() {
        for status in TaskStatus.allCases {
            let result = computeHasUnread(isChatMode: true, status: status, taskID: taskA)
            if status == .needsSupervisorInput {
                XCTAssertTrue(result, "Expected unread for \(status)")
            } else {
                XCTAssertFalse(result, "Expected no unread for \(status)")
            }
        }
    }
}
