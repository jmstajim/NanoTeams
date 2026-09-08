import XCTest

@testable import NanoTeams

/// The observable the composer's fill indicator reads.
///
/// Its whole reason for existing is observation scope: a view reading the orchestrator's
/// `snapshot` re-evaluates on every `mutateTask`, i.e. on every LLM delta, to render a number
/// that changes once per request. So the assertions here are about identity (never key by
/// stepID alone) and about not notifying when nothing changed.
@MainActor
final class ContextFillProjectionTests: XCTestCase {

    var sut: ContextFillProjection!

    override func setUp() async throws {
        try await super.setUp()
        sut = ContextFillProjection()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    private func fill(_ tokens: Int) -> ContextFill {
        ContextFill(
            promptTokens: tokens, window: 8192, budget: 2048, isEstimate: false,
            measuredAt: Date(timeIntervalSince1970: 0))
    }

    func testUpdateAndRead() {
        sut.update(stepID: "engineer", taskID: 1, fill: fill(100))
        XCTAssertEqual(sut.fill(stepID: "engineer", taskID: 1)?.promptTokens, 100)
        XCTAssertNil(sut.fill(stepID: "engineer", taskID: 2))
        XCTAssertNil(sut.fill(stepID: "reviewer", taskID: 1))
    }

    /// `StepExecution.id` IS the role id, so two concurrent tasks on the same team share step
    /// ids. A stepID-keyed map would have them overwrite each other's occupancy — the exact
    /// defect multi-task invariant #5 exists for.
    func testTwoTasksSharingAStepID_keepSeparateFills() {
        sut.update(stepID: "engineer", taskID: 1, fill: fill(100))
        sut.update(stepID: "engineer", taskID: 2, fill: fill(900))
        XCTAssertEqual(sut.fill(stepID: "engineer", taskID: 1)?.promptTokens, 100)
        XCTAssertEqual(sut.fill(stepID: "engineer", taskID: 2)?.promptTokens, 900)
    }

    /// An identical assignment still notifies every observer of the property, and this one is
    /// written on every response of every running step.
    func testUpdate_withAnIdenticalValue_doesNotRewrite() {
        let value = fill(100)
        sut.update(stepID: "engineer", taskID: 1, fill: value)
        let before = sut.fillByStep
        sut.update(stepID: "engineer", taskID: 1, fill: value)
        XCTAssertEqual(before, sut.fillByStep)
    }

    func testSetCompacting_isIdempotentInBothDirections() {
        XCTAssertFalse(sut.isCompacting(stepID: "engineer", taskID: 1))
        sut.setCompacting(stepID: "engineer", taskID: 1, true)
        sut.setCompacting(stepID: "engineer", taskID: 1, true)
        XCTAssertTrue(sut.isCompacting(stepID: "engineer", taskID: 1))
        XCTAssertEqual(sut.compactingKeys.count, 1)
        sut.setCompacting(stepID: "engineer", taskID: 1, false)
        sut.setCompacting(stepID: "engineer", taskID: 1, false)
        XCTAssertFalse(sut.isCompacting(stepID: "engineer", taskID: 1))
        XCTAssertTrue(sut.compactingKeys.isEmpty)
    }

    // MARK: - Seeding

    /// A step that is merely LOADED — parked, paused, not running — still shows its last known
    /// fill, because the number was persisted with the transcript it measures.
    func testSeed_readsTheLatestRunsPersistedFills() {
        var step = StepExecution(id: "engineer", role: .softwareEngineer, title: "work")
        step.contextFill = fill(4200)
        var other = StepExecution(id: "reviewer", role: .codeReviewer, title: "review")
        other.contextFill = nil
        var run = Run(id: 1, teamID: NTMSID.from(name: "Team"))
        run.steps = [step, other]
        var task = NTMSTask(id: 7, title: "T", supervisorTask: "b")
        task.runs = [run]

        sut.seed(from: task)
        XCTAssertEqual(sut.fill(stepID: "engineer", taskID: 7)?.promptTokens, 4200)
        XCTAssertNil(sut.fill(stepID: "reviewer", taskID: 7),
                     "a step that never measured must show nothing, not zero")
    }

    /// Earlier runs are history: their fills describe conversations that no longer drive
    /// anything, and a step id repeats across runs.
    func testSeed_ignoresEarlierRuns() {
        var oldStep = StepExecution(id: "engineer", role: .softwareEngineer, title: "work")
        oldStep.contextFill = fill(9999)
        var oldRun = Run(id: 0, teamID: NTMSID.from(name: "Team"))
        oldRun.steps = [oldStep]

        var newStep = StepExecution(id: "engineer", role: .softwareEngineer, title: "work")
        newStep.contextFill = fill(10)
        var newRun = Run(id: 1, teamID: NTMSID.from(name: "Team"))
        newRun.steps = [newStep]

        var task = NTMSTask(id: 7, title: "T", supervisorTask: "b")
        task.runs = [oldRun, newRun]
        sut.seed(from: task)
        XCTAssertEqual(sut.fill(stepID: "engineer", taskID: 7)?.promptTokens, 10)
    }

    func testSeed_withNoRuns_isANoOp() {
        sut.seed(from: NTMSTask(id: 7, title: "T", supervisorTask: "b"))
        XCTAssertTrue(sut.fillByStep.isEmpty)
    }

    // MARK: - Invalidation

    func testRemoveTask_dropsOnlyThatTask() {
        sut.update(stepID: "engineer", taskID: 1, fill: fill(100))
        sut.update(stepID: "engineer", taskID: 2, fill: fill(200))
        sut.setCompacting(stepID: "engineer", taskID: 1, true)
        sut.setCompacting(stepID: "engineer", taskID: 2, true)

        sut.removeTask(1)
        XCTAssertNil(sut.fill(stepID: "engineer", taskID: 1))
        XCTAssertFalse(sut.isCompacting(stepID: "engineer", taskID: 1))
        XCTAssertEqual(sut.fill(stepID: "engineer", taskID: 2)?.promptTokens, 200)
        XCTAssertTrue(sut.isCompacting(stepID: "engineer", taskID: 2))
    }

    func testRemoveStep_dropsOnlyThatStep() {
        sut.update(stepID: "engineer", taskID: 1, fill: fill(100))
        sut.update(stepID: "reviewer", taskID: 1, fill: fill(200))
        sut.removeStep(stepID: "engineer", taskID: 1)
        XCTAssertNil(sut.fill(stepID: "engineer", taskID: 1))
        XCTAssertEqual(sut.fill(stepID: "reviewer", taskID: 1)?.promptTokens, 200)
    }

    func testClear_dropsEverything() {
        sut.update(stepID: "engineer", taskID: 1, fill: fill(100))
        sut.setCompacting(stepID: "engineer", taskID: 1, true)
        sut.clear()
        XCTAssertTrue(sut.fillByStep.isEmpty)
        XCTAssertTrue(sut.compactingKeys.isEmpty)
    }
}
