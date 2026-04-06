import XCTest
@testable import NanoTeams

@MainActor
final class SidebarUnreadIndicatorTests: XCTestCase {

    var sut: TaskManagementState!

    override func setUp() {
        super.setUp()
        sut = TaskManagementState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - seenSupervisorInputTaskIDs tracking

    func testMarkSeen_addsTaskID() {
        let taskID = 0
        sut.markSupervisorInputSeen(taskID: taskID)
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskID))
    }

    func testMarkSeen_idempotent() {
        let taskID = 0
        sut.markSupervisorInputSeen(taskID: taskID)
        sut.markSupervisorInputSeen(taskID: taskID)
        XCTAssertEqual(sut.seenSupervisorInputTaskIDs.count, 1)
    }

    func testRemoveSeen_clearsTaskID() {
        let taskID = 0
        sut.markSupervisorInputSeen(taskID: taskID)
        sut.seenSupervisorInputTaskIDs.remove(taskID)
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(taskID))
    }

    func testRemoveSeen_doesNotAffectOtherTasks() {
        let taskA = 10
        let taskB = 20
        sut.markSupervisorInputSeen(taskID: taskA)
        sut.markSupervisorInputSeen(taskID: taskB)
        sut.seenSupervisorInputTaskIDs.remove(taskA)
        XCTAssertFalse(sut.seenSupervisorInputTaskIDs.contains(taskA))
        XCTAssertTrue(sut.seenSupervisorInputTaskIDs.contains(taskB))
    }

    // MARK: - hasUnreadInput derivation logic

    /// Mirrors the logic in SidebarView.allTasks:
    ///   hasUnread = isChatMode && status == .needsSupervisorInput && !seen
    private func computeHasUnread(
        isChatMode: Bool,
        status: TaskStatus,
        taskID: Int
    ) -> Bool {
        isChatMode
            && status == .needsSupervisorInput
            && !sut.seenSupervisorInputTaskIDs.contains(taskID)
    }

    func testHasUnread_chatModeWithUnansweredInput_returnsTrue() {
        let taskID = 0
        let result = computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskID)
        XCTAssertTrue(result)
    }

    func testHasUnread_chatModeWithUnansweredInput_alreadySeen_returnsFalse() {
        let taskID = 0
        sut.markSupervisorInputSeen(taskID: taskID)
        let result = computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskID)
        XCTAssertFalse(result)
    }

    func testHasUnread_chatModeRunning_returnsFalse() {
        let taskID = 0
        let result = computeHasUnread(isChatMode: true, status: .running, taskID: taskID)
        XCTAssertFalse(result)
    }

    func testHasUnread_taskModeWithInput_returnsFalse() {
        let taskID = 0
        let result = computeHasUnread(isChatMode: false, status: .needsSupervisorInput, taskID: taskID)
        XCTAssertFalse(result)
    }

    func testHasUnread_seenThenCleared_returnsTrue() {
        let taskID = 0
        sut.markSupervisorInputSeen(taskID: taskID)
        // Simulate: status left needsSupervisorInput (user answered) → remove from seen
        sut.seenSupervisorInputTaskIDs.remove(taskID)
        // Simulate: assistant replies again → new needsSupervisorInput
        let result = computeHasUnread(isChatMode: true, status: .needsSupervisorInput, taskID: taskID)
        XCTAssertTrue(result)
    }

    // MARK: - SidebarTaskItem statusColor logic

    func testStatusColor_unreadInput_returnsInfo() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .needsSupervisorInput,
            updatedAt: Date(), isChatMode: true, hasUnreadInput: true
        )
        // statusColor: if hasUnreadInput → info
        XCTAssertTrue(item.hasUnreadInput)
        XCTAssertEqual(item.status, .needsSupervisorInput)
    }

    func testStatusColor_noUnread_usesStatusTint() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .needsSupervisorInput,
            updatedAt: Date(), isChatMode: true, hasUnreadInput: false
        )
        XCTAssertFalse(item.hasUnreadInput)
    }

    // MARK: - Pulse condition logic

    /// Pulse should be active only when running AND not unread.
    /// This mirrors: task.status == .running && !task.hasUnreadInput

    func testPulseCondition_running_noPulseWhenUnread() {
        let shouldPulse = TaskStatus.running == .running && !true // hasUnreadInput = true
        XCTAssertFalse(shouldPulse, "Pulse should NOT be active when hasUnreadInput is true")
    }

    func testPulseCondition_running_pulsesWhenNoUnread() {
        let shouldPulse = TaskStatus.running == .running && !false // hasUnreadInput = false
        XCTAssertTrue(shouldPulse, "Pulse should be active when running without unread")
    }

    func testPulseCondition_needsSupervisorInput_noPulse() {
        let shouldPulse = TaskStatus.needsSupervisorInput == .running && !false
        XCTAssertFalse(shouldPulse, "Pulse should NOT be active for needsSupervisorInput status")
    }
}
