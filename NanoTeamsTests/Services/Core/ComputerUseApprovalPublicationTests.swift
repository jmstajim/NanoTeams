import XCTest

@testable import NanoTeams

/// Publication of computer-use approval cards on the orchestrator.
///
/// This is the surface that decides whether the human is *shown* a held action. It sat at 13%
/// coverage, and the interesting rule in it is the one that is easy to get wrong by
/// simplification: `computerUseApprovalDidEnd` clears the card only when the end matches the
/// SAME hold instance. A gate resolving hold #1 late — Pause races the human tapping Allow —
/// must not wipe the card for hold #2, which would leave the model blocked on a decision the
/// user can no longer make.
@MainActor
final class ComputerUseApprovalPublicationTests: XCTestCase, @unchecked Sendable {

    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        sut = TestOrchestrator.make()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    private func request(
        taskID: Int = 1, stepID: String = "role-1",
        actionKey: String = "click:10:10",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ComputerUseApprovalRequest {
        ComputerUseApprovalRequest(
            taskID: taskID, stepID: stepID, actionKey: actionKey,
            actionSummary: "Click at (10, 10)", targetApp: "Safari", offerAlways: true,
            screenshotBase64: nil, targetX: 10, targetY: 10, createdAt: createdAt)
    }

    private func key(taskID: Int = 1, stepID: String = "role-1") -> TaskStepKey {
        TaskStepKey(taskID: taskID, stepID: stepID)
    }

    // MARK: - Publication

    func testDidBegin_publishesTheCard() {
        let held = request()

        sut.computerUseApprovalDidBegin(held)

        XCTAssertEqual(sut.computerUseApprovalRequests[key()], held)
    }

    func testDidEnd_matchingHold_clearsTheCard() {
        let held = request()
        sut.computerUseApprovalDidBegin(held)

        sut.computerUseApprovalDidEnd(
            taskID: 1, stepID: "role-1", actionKey: held.actionKey, createdAt: held.createdAt)

        XCTAssertNil(sut.computerUseApprovalRequests[key()])
    }

    // MARK: - Late-end discrimination

    /// Same step, different action: the gate holds one action at a time per step, so a card that
    /// was republished for a NEW action must survive the previous action's end.
    func testDidEnd_differentActionKey_leavesTheCurrentCardStanding() {
        let current = request(actionKey: "type:hello")
        sut.computerUseApprovalDidBegin(current)

        sut.computerUseApprovalDidEnd(
            taskID: 1, stepID: "role-1", actionKey: "click:10:10", createdAt: current.createdAt)

        XCTAssertEqual(sut.computerUseApprovalRequests[key()], current)
    }

    /// Same action key, different hold: the model retries the identical click, so `actionKey`
    /// alone cannot discriminate — `createdAt` is what separates the two holds.
    func testDidEnd_sameActionKeyButOlderHold_leavesTheFreshCardStanding() {
        let fresh = request(createdAt: Date(timeIntervalSince1970: 2_000))
        sut.computerUseApprovalDidBegin(fresh)

        sut.computerUseApprovalDidEnd(
            taskID: 1, stepID: "role-1", actionKey: fresh.actionKey,
            createdAt: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(sut.computerUseApprovalRequests[key()], fresh,
                       "a stale end must not wipe a republished card")
    }

    func testDidEnd_unknownStep_isANoOp() {
        sut.computerUseApprovalDidBegin(request())

        sut.computerUseApprovalDidEnd(
            taskID: 99, stepID: "other", actionKey: "click:10:10",
            createdAt: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(sut.computerUseApprovalRequests.count, 1)
    }

    // MARK: - Per-step isolation

    /// Cards are keyed by `TaskStepKey`, not `stepID`: `StepExecution.id` IS the role id, so two
    /// concurrent tasks on the same team share step ids by construction (CLAUDE.md §5). Keying
    /// on the step alone would let one task's approval card replace the other's.
    func testTwoTasksSharingAStepID_holdIndependentCards() {
        let a = request(taskID: 1, actionKey: "click:1:1")
        let b = request(taskID: 2, actionKey: "click:2:2")

        sut.computerUseApprovalDidBegin(a)
        sut.computerUseApprovalDidBegin(b)

        XCTAssertEqual(sut.computerUseApprovalRequests[key(taskID: 1)], a)
        XCTAssertEqual(sut.computerUseApprovalRequests[key(taskID: 2)], b)
    }

    func testDidEnd_onOneTask_leavesTheOtherTasksCard() {
        let a = request(taskID: 1, actionKey: "click:1:1")
        let b = request(taskID: 2, actionKey: "click:2:2")
        sut.computerUseApprovalDidBegin(a)
        sut.computerUseApprovalDidBegin(b)

        sut.computerUseApprovalDidEnd(
            taskID: 1, stepID: "role-1", actionKey: a.actionKey, createdAt: a.createdAt)

        XCTAssertNil(sut.computerUseApprovalRequests[key(taskID: 1)])
        XCTAssertEqual(sut.computerUseApprovalRequests[key(taskID: 2)], b)
    }

    // MARK: - Teardown

    /// Full teardown (work-folder switch, app quit path) must leave no card behind: a stranded
    /// card offers Allow for an action whose waiter is gone, so tapping it does nothing.
    func testClearAll_dropsEveryCard() {
        sut.computerUseApprovalDidBegin(request(taskID: 1, actionKey: "a"))
        sut.computerUseApprovalDidBegin(request(taskID: 2, actionKey: "b"))

        sut.clearAllComputerUseApprovalRequests()

        XCTAssertTrue(sut.computerUseApprovalRequests.isEmpty)
    }

    func testClearAll_withNoCards_isANoOp() {
        sut.clearAllComputerUseApprovalRequests()

        XCTAssertTrue(sut.computerUseApprovalRequests.isEmpty)
    }

    // MARK: - Resolution routing

    /// The button surface resolves the hold DIRECTLY on the execution service, bypassing the
    /// model. Nothing is waiting here, so the assertion is that it neither traps nor mutates the
    /// published card — clearing is `didEnd`'s job, driven by the gate that actually unblocked.
    func testResolve_withNoWaiter_doesNotTrapOrClearTheCard() {
        let held = request()
        sut.computerUseApprovalDidBegin(held)

        for choice in [ComputerUseApprovalChoice.allow, .deny, .alwaysAllowApp] {
            sut.resolveComputerUseApproval(
                taskID: 1, stepID: "role-1", actionKey: held.actionKey, choice: choice)
        }

        XCTAssertEqual(sut.computerUseApprovalRequests[key()], held)
    }
}
