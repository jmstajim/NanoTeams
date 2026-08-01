import XCTest

@testable import NanoTeams

/// Pins `TeamBusyScan` — the guard that refuses a Team Editor artifact rename
/// while a run is still in flight on that team.
///
/// Why the guard exists: `StepExecution.expectedArtifacts` is a creation-time
/// snapshot (`reset()` preserves it, `findOrCreateStep` never refreshes it), so
/// a rename landing mid-run leaves the live step waiting on an artifact name no
/// role produces any more, with no healing path.
final class TeamBusyScanTests: XCTestCase {

    private let teamID = NTMSID.from(name: "busy-scan-team")
    private let otherTeamID = NTMSID.from(name: "some-other-team")

    private func makeTask(
        id: Int,
        runTeamID: NTMSID?,
        stepStatus: StepStatus,
        closed: Bool = false
    ) -> NTMSTask {
        var task = NTMSTask(id: id, title: "T\(id)", supervisorTask: "do it")
        var run = Run(id: 0)
        run.teamID = runTeamID
        var step = StepExecution(id: "worker", role: .softwareEngineer, title: "Work")
        step.status = stepStatus
        run.steps = [step]
        task.runs = [run]
        if closed { task.closedAt = MonotonicClock.shared.now() }
        return task
    }

    // MARK: - In flight

    func testRunningTaskOnThisTeam_isInFlight() {
        let task = makeTask(id: 1, runTeamID: teamID, stepStatus: .running)
        XCTAssertTrue(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
    }

    func testPausedTaskOnThisTeam_isInFlight() {
        // A paused run resumes into the same StepExecution, so its stale
        // expectedArtifacts snapshot is just as wedgeable as a running one.
        let task = makeTask(id: 1, runTeamID: teamID, stepStatus: .paused)
        XCTAssertTrue(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
    }

    func testTaskAwaitingSupervisor_isInFlight() {
        var task = makeTask(id: 1, runTeamID: teamID, stepStatus: .running)
        task.runs[0].steps[0].needsSupervisorInput = true
        XCTAssertTrue(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
    }

    // MARK: - Not in flight

    func testRunPinnedToAnotherTeam_isIgnored() {
        let task = makeTask(id: 1, runTeamID: otherTeamID, stepStatus: .running)
        XCTAssertFalse(
            TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]),
            "A run on a different team must not lock this team's editor.")
    }

    func testRunWithNoTeamID_isIgnored() {
        let task = makeTask(id: 1, runTeamID: nil, stepStatus: .running)
        XCTAssertFalse(
            TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]),
            "A legacy run with no pin must not block renames on every team.")
    }

    func testClosedTask_isIgnored() {
        let task = makeTask(id: 1, runTeamID: teamID, stepStatus: .running, closed: true)
        XCTAssertFalse(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
    }

    func testFailedTask_isIgnored() {
        let task = makeTask(id: 1, runTeamID: teamID, stepStatus: .failed)
        XCTAssertFalse(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
    }

    /// Steps have all finished, so a rename cannot wedge execution.
    func testTaskAwaitingAcceptance_isNotInFlight() {
        let task = makeTask(id: 1, runTeamID: teamID, stepStatus: .done)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
        XCTAssertFalse(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
    }

    func testNoTasks_isNotInFlight() {
        XCTAssertFalse(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: []))
    }

    // MARK: - Mixed

    func testAnyInFlightTaskLocksTheTeam() {
        let idle = makeTask(id: 1, runTeamID: teamID, stepStatus: .done)
        let live = makeTask(id: 2, runTeamID: teamID, stepStatus: .running)
        XCTAssertTrue(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [idle, live]))
    }

    /// Only the LATEST run pins the team — historical runs of a task that has
    /// since been switched to another team must not lock the old one.
    func testOnlyTheLatestRunIsConsulted() {
        var task = makeTask(id: 1, runTeamID: otherTeamID, stepStatus: .running)
        var historical = Run(id: 0)
        historical.teamID = teamID
        task.runs.insert(historical, at: 0)
        task.runs[1].id = 1

        XCTAssertFalse(TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: [task]))
        XCTAssertTrue(TeamBusyScan.hasInFlightRun(teamID: otherTeamID, tasks: [task]))
    }
}
