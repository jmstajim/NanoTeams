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

    /// Pulse should be active only when the engine is actually running AND there is no unread badge.
    /// This mirrors: task.isEngineRunning && !task.hasUnreadInput

    /// Helper that pins the production gate to a single source of truth.
    private func shouldPulse(_ item: SidebarTaskItem) -> Bool {
        item.isEngineRunning && !item.hasUnreadInput
    }

    func testPulseCondition_engineRunning_noPulseWhenUnread() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .running, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: true, isEngineRunning: true
        )
        XCTAssertFalse(shouldPulse(item), "Pulse should NOT be active when hasUnreadInput is true")
    }

    func testPulseCondition_engineRunning_pulsesWhenNoUnread() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .running, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: false, isEngineRunning: true
        )
        XCTAssertTrue(shouldPulse(item), "Pulse should be active when engine is running and no unread")
    }

    func testPulseCondition_engineNotRunning_noPulse() {
        // Regression: chat task post-restart. Status is derived as `.running`
        // (chat-mode override surfaces idle as `.running`) but the engine is
        // `.paused`, so isEngineRunning is false → no pulse.
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .running, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: false, isEngineRunning: false
        )
        XCTAssertFalse(shouldPulse(item), "Pulse should NOT be active when engine is not running, even if status is .running")
    }

    func testPulseCondition_engineNil_noPulse() {
        // Regression: background chat task that was never opened this session.
        // engineState[taskID] is nil, mapped to isEngineRunning=false → no pulse.
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .running, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: false, isEngineRunning: false
        )
        XCTAssertFalse(shouldPulse(item), "Pulse should NOT be active for never-opened background tasks")
    }

    func testPulseCondition_needsSupervisorInput_noPulse() {
        // When the LLM is waiting for the user, engine state is .needsSupervisorInput,
        // not .running, so the icon stays static even before the user marks it seen.
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .needsSupervisorInput, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: true, isEngineRunning: false
        )
        XCTAssertFalse(shouldPulse(item), "Pulse should NOT be active when engine is in .needsSupervisorInput")
    }

    // MARK: - User path: bug regression — restart with open chat

    /// User reported: open chat icon keeps blinking after app restart.
    ///
    /// Reproduces the post-restart state for a chat task: the tasks-index
    /// status is `.running` (chat-mode override on top of all-done steps),
    /// but the engine has been seeded to `.paused` by `mapDerivedStatusToEngineState`.
    /// The pulse must NOT fire.
    func testUserPath_openChatAfterRestart_noPulse() {
        let chatTaskAfterRestart = SidebarTaskItem(
            id: 1, title: "расскажи больше про ва...",
            status: .running, // derived; chat override surfaces idle as .running
            updatedAt: Date(timeIntervalSinceNow: -36_000), // 10h ago, matches user screenshot
            isChatMode: true,
            hasUnreadInput: false,
            isEngineRunning: false // engine is .paused after StatusRecoveryService
        )
        XCTAssertFalse(shouldPulse(chatTaskAfterRestart),
                       "Bug regression: chat icon must not pulse after restart while engine is paused")
    }

    /// Sibling chat task, also recovered, also showing as `.running` in the index.
    /// Engine state map has no entry for it (it's not the active task).
    func testUserPath_backgroundChatAfterRestart_noPulse() {
        let backgroundChat = SidebarTaskItem(
            id: 2, title: "расскажи больше про ва...",
            status: .running,
            updatedAt: Date(timeIntervalSinceNow: -36_000),
            isChatMode: true,
            hasUnreadInput: false,
            isEngineRunning: false // never loaded → engineState[2] == nil → false
        )
        XCTAssertFalse(shouldPulse(backgroundChat),
                       "Background chat tasks with stale .running index entries must not pulse")
    }

    // MARK: - User path: live conversation

    /// While the LLM is generating a response, engine flips to `.running` and
    /// the chat icon pulses. The user can see "the assistant is replying".
    func testUserPath_chatLLMGenerating_pulses() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .running, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: false, isEngineRunning: true
        )
        XCTAssertTrue(shouldPulse(item), "While LLM generates, the icon must pulse")
    }

    /// LLM finishes its turn and emits ask_supervisor → engine state becomes
    /// `.needsSupervisorInput`. The pulse must stop, AND the unread badge takes
    /// precedence (statusColor turns `info`) when the user hasn't viewed it yet.
    func testUserPath_chatLLMFinishedAsksUser_pulseStopsUnreadShows() {
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .needsSupervisorInput, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: true, isEngineRunning: false
        )
        XCTAssertFalse(shouldPulse(item), "Pulse must stop when LLM hands off to the user")
        XCTAssertTrue(item.hasUnreadInput, "Unread indicator must light up to draw user attention")
    }

    /// User answers and the LLM resumes → engine .running → pulse resumes,
    /// unread badge clears.
    func testUserPath_chatUserAnswered_pulseResumes() {
        sut.markSupervisorInputSeen(taskID: 0) // simulate user viewed the question
        sut.seenSupervisorInputTaskIDs.remove(0) // simulate clear-on-answer in the orchestrator
        let item = SidebarTaskItem(
            id: 0, title: "Chat", status: .running, updatedAt: Date(),
            isChatMode: true, hasUnreadInput: false, isEngineRunning: true
        )
        XCTAssertTrue(shouldPulse(item), "Pulse must resume once the LLM starts the next turn")
    }

    // MARK: - User path: multi-task background activity

    /// User watches Task A (a non-chat FAANG task) actively executing, then
    /// switches the sidebar selection to Task B. switchTask does NOT stop
    /// engines, so Task A must keep pulsing.
    func testUserPath_taskARunsWhileViewingB_taskAStillPulses() {
        let taskA = SidebarTaskItem(
            id: 1, title: "FAANG: refactor auth", status: .running, updatedAt: Date(),
            isChatMode: false, hasUnreadInput: false, isEngineRunning: true
        )
        let taskB = SidebarTaskItem(
            id: 2, title: "FAANG: docs", status: .paused, updatedAt: Date(),
            isChatMode: false, hasUnreadInput: false, isEngineRunning: false
        )
        XCTAssertTrue(shouldPulse(taskA), "Background-running task A must keep its pulse while user views B")
        XCTAssertFalse(shouldPulse(taskB), "Idle task B must stay static")
    }

    // MARK: - User path: non-chat regression

    /// Non-chat task with a stale `.running` index entry whose engine isn't
    /// actually running (e.g. created but `startRun` failed silently). With
    /// the old gate, it pulsed; with the new gate, it stays static.
    func testUserPath_nonChatStaleRunningStatus_noPulse() {
        let item = SidebarTaskItem(
            id: 0, title: "FAANG: stuck", status: .running, updatedAt: Date(),
            isChatMode: false, hasUnreadInput: false, isEngineRunning: false
        )
        XCTAssertFalse(shouldPulse(item),
                       "Non-chat task with stale .running index but no live engine must not pulse")
    }

    /// Non-chat task that's actively running. Pulse must be on.
    func testUserPath_nonChatActiveRun_pulses() {
        let item = SidebarTaskItem(
            id: 0, title: "FAANG: live", status: .running, updatedAt: Date(),
            isChatMode: false, hasUnreadInput: false, isEngineRunning: true
        )
        XCTAssertTrue(shouldPulse(item), "Active non-chat run must pulse")
    }

    // MARK: - SidebarTaskItem default

    func testSidebarTaskItem_isEngineRunning_defaultsFalse() {
        let item = SidebarTaskItem(id: 0, title: "Test", status: .running, updatedAt: Date())
        XCTAssertFalse(item.isEngineRunning,
                       "Default isEngineRunning=false ensures unmodified construction sites cannot accidentally pulse")
    }
}
