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

    // MARK: - The count mirror

    func testLegacyRow_knowsTheFlagButNotTheCount() throws {
        let json = Data("""
        {"id":7,"title":"Upgraded once","status":"paused","isChatMode":true,
         "hasPendingSupervisorInput":true}
        """.utf8)
        let summary = try JSONDecoder().decode(TaskSummary.self, from: json)
        XCTAssertTrue(summary.supervisorInputStateIsKnown)
        XCTAssertNil(summary.pendingSupervisorQuestionCount,
                     "a row can predate the second field while knowing the first")
        XCTAssertFalse(summary.waitingQuestionCountIsKnown)
        XCTAssertTrue(summary.supervisorWaitFactsPredateAField,
                      "…and the sweep's backfill filter must still select it")
    }

    func testCountRoundTrip_preservesUnknownDistinctFromZero() throws {
        for value in [nil, 0, 1, 4] as [Int?] {
            var summary = TaskSummary(id: 1, title: "T", status: .paused)
            summary.pendingSupervisorQuestionCount = value
            let data = try JSONEncoder().encode(summary)
            let decoded = try JSONDecoder().decode(TaskSummary.self, from: data)
            XCTAssertEqual(decoded.pendingSupervisorQuestionCount, value)
        }
    }

    func testDefaultInit_countIsUnknown() {
        let fresh = TaskSummary(id: 1, title: "T", status: .running)
        XCTAssertNil(fresh.pendingSupervisorQuestionCount)
        XCTAssertFalse(fresh.waitingQuestionCountIsKnown)
        XCTAssertTrue(fresh.supervisorWaitFactsPredateAField)
    }

    func testFullyStampedRow_predatesNothing() {
        var row = TaskSummary(id: 1, title: "T", status: .paused)
        row.hasPendingSupervisorInput = false
        row.pendingSupervisorQuestionCount = 0
        XCTAssertFalse(row.supervisorWaitFactsPredateAField,
                       "self-terminating: a converged row must drop out of the backfill filter")
    }

    func testToSummary_countsEveryParallelQuestion() {
        var run = Run(id: 0, teamID: "t")
        run.steps = [
            waitingStep(id: "a", status: .needsSupervisorInput),
            waitingStep(id: "b", status: .needsSupervisorInput),
            StepExecution(id: "c", role: .softwareEngineer, title: "s", status: .running)
        ]
        let summary = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [run]).toSummary()
        XCTAssertEqual(summary.pendingSupervisorQuestionCount, 2)
        XCTAssertTrue(summary.isWaitingForSupervisor)
    }

    /// `preserveSupervisorWaitFacts` moves BOTH fields or the row starts contradicting
    /// itself. RED: drop either assignment from `preserveSupervisorWaitFacts` → the
    /// assertion for the field it stopped carrying reads the recomputed value instead.
    func testPreserveSupervisorWaitFacts_movesBothFieldsTogether() {
        var row = TaskSummary(id: 1, title: "T", status: .paused)
        row.hasPendingSupervisorInput = true
        row.pendingSupervisorQuestionCount = 3

        var recomputed = TaskSummary(id: 1, title: "T", status: .paused)
        recomputed.hasPendingSupervisorInput = false
        recomputed.pendingSupervisorQuestionCount = 0
        recomputed.preserveSupervisorWaitFacts(from: row)

        XCTAssertEqual(recomputed.hasPendingSupervisorInput, true)
        XCTAssertEqual(recomputed.pendingSupervisorQuestionCount, 3)
    }

    func testPreserveSupervisorWaitFacts_carriesUnknownAsUnknown() {
        let legacy = TaskSummary(id: 1, title: "T", status: .paused)
        var recomputed = TaskSummary(id: 1, title: "T", status: .paused)
        recomputed.hasPendingSupervisorInput = false
        recomputed.pendingSupervisorQuestionCount = 0
        recomputed.preserveSupervisorWaitFacts(from: legacy)

        XCTAssertNil(recomputed.hasPendingSupervisorInput,
                     "the row's answer is 'don't know', and a patch must not upgrade that to 'no'")
        XCTAssertNil(recomputed.pendingSupervisorQuestionCount)
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
