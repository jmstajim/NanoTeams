import XCTest
@testable import NanoTeams

/// The Watchtower's dismissal garbage collector, which until now had NO production
/// coverage at all — every test that appeared to cover it re-implemented the sweep in
/// its own body and would have stayed green through any change to the real one.
///
/// The rule it gets wrong when scoped by "is anything loaded": `loadedTasks` is filled
/// lazily and the startup sweep evicts each task right after recovering it, so exactly
/// one task is resident at launch and every other task's dismissals were deleted.
@MainActor
final class WatchtowerInboxGCTests: XCTestCase {

    private let keyA1 = WatchtowerDismissKey(taskID: 1, typeID: "engineer::A")
    private let keyA2 = WatchtowerDismissKey(taskID: 1, typeID: "engineer::B")
    private let keyB1 = WatchtowerDismissKey(taskID: 2, typeID: "engineer::A")

    // MARK: - The bug

    /// Task 2 is dismissed but not resident. Nothing about that says the dismissal is
    /// stale — it says we cannot see task 2.
    func testDismissalForUnloadedTask_survives() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1, keyB1],
            active: [keyA1],
            loadedTaskIDs: [1],
            knownTaskIDs: [1, 2]
        )
        XCTAssertTrue(stale.isEmpty, "an unloaded task's dismissal must never be expired")
    }

    /// Two tasks on the same team share `stepID`, so before task-scoping, task 1 going
    /// quiet expired task 2's identically-named dismissal too.
    func testSameTeamSiblings_doNotShareExpiry() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1, keyB1],
            active: [],
            loadedTaskIDs: [1],
            knownTaskIDs: [1, 2]
        )
        XCTAssertEqual(stale, [keyA1], "only the loaded, now-quiet task's key expires")
    }

    // MARK: - The legitimate sweep

    func testLoadedTaskNoLongerProducingTheNotification_expires() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1, keyA2], active: [keyA2], loadedTaskIDs: [1], knownTaskIDs: [1])
        XCTAssertEqual(stale, [keyA1])
    }

    func testLoadedTaskStillProducingIt_survives() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1], active: [keyA1], loadedTaskIDs: [1], knownTaskIDs: [1])
        XCTAssertTrue(stale.isEmpty)
    }

    /// A deleted task can never match anything again, so its keys are reclaimed even
    /// though it is (necessarily) not loaded.
    func testDismissalForDeletedTask_isReclaimed() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1, keyB1], active: [keyA1], loadedTaskIDs: [1], knownTaskIDs: [1])
        XCTAssertEqual(stale, [keyB1])
    }

    // MARK: - Degenerate inputs

    /// Snapshot teardown / pre-bootstrap. Every key would otherwise look like it
    /// belonged to a deleted task.
    func testEmptyIndex_isTotalNoOp() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1, keyB1], active: [], loadedTaskIDs: [], knownTaskIDs: [])
        XCTAssertTrue(stale.isEmpty)
    }

    /// Folder switch: the index swaps to a disjoint id set while nothing is loaded yet.
    func testFolderSwitch_nothingLoaded_expiresNothingFromTheOldFolder() {
        let stale = WatchtowerInboxBuilder.staleDismissals(
            dismissed: [keyA1], active: [], loadedTaskIDs: [], knownTaskIDs: [77, 78])
        XCTAssertEqual(stale, [keyA1],
                       "keys are folder-namespaced in storage, so a cross-folder key never reaches here")
    }

    func testNothingDismissed_isEmpty() {
        XCTAssertTrue(WatchtowerInboxBuilder.staleDismissals(
            dismissed: [], active: [keyA1], loadedTaskIDs: [1], knownTaskIDs: [1]).isEmpty)
    }

    // MARK: - build / visible

    func testBuild_stampsTaskScopedIdentity() {
        let notifications = WatchtowerInboxBuilder.build([.init(task: waitingTask(id: 5), teamRoles: [])])
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications[0].dismissKey.taskID, 5)
        XCTAssertEqual(notifications[0].id, notifications[0].dismissKey.storageKey)
    }

    /// Two tasks, same team, byte-identical question text: the per-call UUID keeps
    /// their banners independently dismissible.
    func testBuild_identicalQuestionsAcrossTasks_getDistinctKeys() {
        let a = WatchtowerInboxBuilder.build([.init(task: waitingTask(id: 5), teamRoles: [])])
        let b = WatchtowerInboxBuilder.build([.init(task: waitingTask(id: 9), teamRoles: [])])
        XCTAssertNotEqual(a[0].dismissKey, b[0].dismissKey)
    }

    func testBuild_taskWithNoRuns_producesNothing() {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [])
        XCTAssertTrue(WatchtowerInboxBuilder.build([.init(task: task, teamRoles: [])]).isEmpty)
    }

    /// Closing is the Supervisor's explicit "done": a chat closed mid-question
    /// must not keep producing "<Role> replied" off its last run forever. The
    /// per-step scan cannot know the task, so the gate lives here.
    func testBuild_closedTask_producesNothing() {
        var task = waitingTask(id: 5)
        task.closedAt = Date()
        XCTAssertTrue(WatchtowerInboxBuilder.build([.init(task: task, teamRoles: [])]).isEmpty)
    }

    func testVisible_filtersDismissed() {
        let all = WatchtowerInboxBuilder.build([.init(task: waitingTask(id: 5), teamRoles: [])])
        XCTAssertTrue(WatchtowerInboxBuilder.visible(all, dismissed: [all[0].dismissKey]).isEmpty)
        XCTAssertEqual(WatchtowerInboxBuilder.visible(all, dismissed: []).count, 1)
    }

    // MARK: - Fixtures

    /// A chat-mode task whose assistant has replied via `ask_supervisor` — the shape
    /// every chat turn produces.
    private func waitingTask(id: Int) -> NTMSTask {
        let call = StepToolCall(
            name: ToolNames.askSupervisor, argumentsJSON: #"{"question":"Here is your answer."}"#)
        let step = StepExecution(
            id: "assistant", role: .softwareEngineer, title: "s",
            status: .needsSupervisorInput, toolCalls: [call],
            needsSupervisorInput: true, supervisorQuestion: "Here is your answer."
        )
        var run = Run(id: 0, teamID: "t")
        run.steps = [step]
        return NTMSTask(id: id, title: "Chat", supervisorTask: "hi", runs: [run])
    }
}
