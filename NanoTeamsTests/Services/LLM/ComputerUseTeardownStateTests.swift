import XCTest

@testable import NanoTeams

/// Regression pins for the computer-use per-run session state lifecycle:
///  - the "always allow in this app" grant is PER-TASK (survives a step completing) — it must
///    NOT be wiped by per-step teardown (`clearBashState`), only by per-task teardown.
///  - the first-capture-per-run counter is likewise per-task (survives step/pause boundaries).
///  - full teardown (`cancelAllExecutions`, e.g. work-folder switch) drops every computer-use
///    grant/counter AND clears the orchestrator's published cards — so nothing leaks into a
///    newly-opened folder where task IDs are reused.
///
/// `@MainActor` + `async` per the documented sync-test abort gotcha (building the `@MainActor`
/// `LLMExecutionService` from a sync test aborts on CI).
@MainActor
final class ComputerUseTeardownStateTests: XCTestCase {

    var service: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - #5 — the per-run app grant survives a step completing

    func testSessionGrant_survivesPerStepTeardown() {
        service.allowComputerUseAppForRun(taskID: 1, bundleOrName: "Safari")
        XCTAssertEqual(service.computerUseSessionAllowedApps[1], ["safari"])

        // A step of task 1 completes → per-step teardown. The grant is per-RUN, so it must
        // still be there for the next role/step in the same run.
        service.clearBashState(stepID: "roleA", taskID: 1)
        XCTAssertEqual(
            service.computerUseSessionAllowedApps[1], ["safari"],
            "an 'always allow for the rest of the run' grant must NOT be wiped when a step finishes")
    }

    // MARK: - #5/#6 — per-task teardown clears grants + capture count

    func testClearComputerUseTaskState_dropsGrantAndCaptureCount() {
        service.allowComputerUseAppForRun(taskID: 1, bundleOrName: "Safari")
        service.computerUseCaptureCountByTask[1] = 3

        service.clearComputerUseTaskState(taskID: 1)
        XCTAssertNil(service.computerUseSessionAllowedApps[1])
        XCTAssertNil(service.computerUseCaptureCountByTask[1])
    }

    func testCancelExecutionsForTask_dropsPerTaskComputerUseState() {
        service.allowComputerUseAppForRun(taskID: 7, bundleOrName: "Mail")
        service.computerUseCaptureCountByTask[7] = 1

        service.cancelExecutions(forTaskID: 7)
        XCTAssertNil(service.computerUseSessionAllowedApps[7], "task run ended → grant cleared")
        XCTAssertNil(service.computerUseCaptureCountByTask[7])
    }

    // MARK: - #6 — capture count is per-task (survives a step teardown)

    func testCaptureCount_survivesPerStepTeardown() {
        service.computerUseCaptureCountByTask[2] = 1
        service.clearBashState(stepID: "roleA", taskID: 2)
        XCTAssertEqual(
            service.computerUseCaptureCountByTask[2], 1,
            "first-capture-per-run counter must survive a step finishing")
    }

    // MARK: - #4 — full teardown drops all computer-use state + clears published cards

    func testCancelAllExecutions_clearsAllComputerUseState() {
        service.allowComputerUseAppForRun(taskID: 1, bundleOrName: "Safari")
        service.allowComputerUseAppForRun(taskID: 2, bundleOrName: "Mail")
        service.computerUseCaptureCountByTask[1] = 2
        service.computerUseCaptureCountByTask[2] = 5

        service.cancelAllExecutions()

        XCTAssertTrue(service.computerUseSessionAllowedApps.isEmpty,
                      "no per-run app grant may survive a full teardown / folder switch")
        XCTAssertTrue(service.computerUseCaptureCountByTask.isEmpty)
        XCTAssertEqual(
            delegate.clearAllComputerUseApprovalRequestsCallCount, 1,
            "full teardown must clear the orchestrator's published computer-use cards directly")
    }
}
