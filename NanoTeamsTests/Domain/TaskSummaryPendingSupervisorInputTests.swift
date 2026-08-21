import XCTest
@testable import NanoTeams

/// `TaskSummary.hasPendingSupervisorInput` is TRI-state, and these pin why.
///
/// A two-valued `Bool` defaulting to `false` would make every index row written
/// before the field existed read as "answered" — and the sweep that clears seen flags
/// for answered tasks would then wipe the entire persisted set on the first launch
/// after the upgrade, reproducing the exact bug the field is being added to fix.
final class TaskSummaryPendingSupervisorInputTests: XCTestCase {

    func testToSummary_stampsWaitingWhileStatusIsParked() {
        let task = makeTask(waiting: true, stepStatus: .paused)
        let summary = task.toSummary()
        XCTAssertTrue(summary.isWaitingForSupervisor)
        XCTAssertEqual(summary.status, .paused,
                       "the run-control status stays honest — no engine, so Resume")
    }

    func testToSummary_answeredTaskIsNotWaiting() {
        let summary = makeTask(waiting: false, stepStatus: .running).toSummary()
        XCTAssertFalse(summary.isWaitingForSupervisor)
        XCTAssertTrue(summary.supervisorInputStateIsKnown)
    }

    func testToSummary_closedTaskIsNotWaiting() {
        var task = makeTask(waiting: true, stepStatus: .paused)
        task.closedAt = Date()
        XCTAssertFalse(task.toSummary().isWaitingForSupervisor)
    }

    /// `.failed` outranks `.needsSupervisorInput` in `Run.derivedTaskStatus`, so the
    /// coarse status hides a waiting step entirely. The durable fact must not.
    func testToSummary_failedStepDoesNotMaskAWaitingSibling() {
        var run = Run(id: 0, teamID: "t")
        run.steps = [
            StepExecution(id: "a", role: .softwareEngineer, title: "s", status: .failed),
            waitingStep(id: "b", status: .needsSupervisorInput)
        ]
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [run])
        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .failed)
        XCTAssertTrue(summary.isWaitingForSupervisor)
    }

    // MARK: - Migration

    func testLegacyRowWithoutTheKey_decodesAsUnknownNotFalse() throws {
        let json = Data("""
        {"id":7,"title":"Legacy","status":"paused","isChatMode":true}
        """.utf8)
        let summary = try JSONDecoder().decode(TaskSummary.self, from: json)
        XCTAssertNil(summary.hasPendingSupervisorInput)
        XCTAssertFalse(summary.supervisorInputStateIsKnown,
                       "unknown must be distinguishable from answered")
        XCTAssertFalse(summary.isWaitingForSupervisor,
                       "unknown never lights an indicator on its own")
    }

    func testRoundTrip_preservesEachOfTheThreeStates() throws {
        for value in [true, false, nil] as [Bool?] {
            var summary = TaskSummary(id: 1, title: "T", status: .paused)
            summary.hasPendingSupervisorInput = value
            let data = try JSONEncoder().encode(summary)
            let decoded = try JSONDecoder().decode(TaskSummary.self, from: data)
            XCTAssertEqual(decoded.hasPendingSupervisorInput, value)
        }
    }

    func testDefaultInit_isUnknown() {
        XCTAssertNil(TaskSummary(id: 1, title: "T", status: .running).hasPendingSupervisorInput)
    }

    // MARK: - SupervisorWaitState projection

    func testWaitStateProjection_mapsAllThreeCases() {
        var waiting = TaskSummary(id: 1, title: "T", status: .paused)
        waiting.hasPendingSupervisorInput = true
        var answered = TaskSummary(id: 2, title: "T", status: .running)
        answered.hasPendingSupervisorInput = false
        let legacy = TaskSummary(id: 3, title: "T", status: .paused)

        XCTAssertEqual(SupervisorWaitState(waiting), .waiting)
        XCTAssertEqual(SupervisorWaitState(answered), .notWaiting)
        XCTAssertEqual(SupervisorWaitState(legacy), .unknown)
    }

    // MARK: - Fixtures

    private func waitingStep(id: String, status: StepStatus) -> StepExecution {
        StepExecution(
            id: id, role: .softwareEngineer, title: "s", status: status,
            toolCalls: [StepToolCall(name: ToolNames.askSupervisor,
                                     argumentsJSON: #"{"question":"Q"}"#)],
            needsSupervisorInput: true, supervisorQuestion: "Q"
        )
    }

    private func makeTask(waiting: Bool, stepStatus: StepStatus) -> NTMSTask {
        var run = Run(id: 0, teamID: "t")
        run.steps = waiting
            ? [waitingStep(id: "a", status: stepStatus)]
            : [StepExecution(id: "a", role: .softwareEngineer, title: "s", status: stepStatus)]
        return NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [run])
    }
}
