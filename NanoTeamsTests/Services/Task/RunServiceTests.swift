import XCTest

@testable import NanoTeams

final class RunServiceTests: XCTestCase {
    // MARK: - Helpers

    override func setUp() {
        super.setUp()
        #if DEBUG
        MonotonicClock.shared.reset()
        #endif
    }

    /// Builds a minimal team with a Supervisor role, roles with no dependencies, and roles with dependencies.
    private func makeTestTeam() -> Team {
        let supervisorRole = TeamRoleDefinition(
            id: "supervisor-role-id",
            name: "Supervisor",
            prompt: "Supervisor prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )

        let independentRole = TeamRoleDefinition(
            id: "pm-role-id",
            name: "Product Manager",
            prompt: "PM prompt",
            toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Product Requirements"]
            )
        )

        let dependentRole = TeamRoleDefinition(
            id: "eng-role-id",
            name: "Software Engineer",
            prompt: "SWE prompt",
            toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Product Requirements"],
                producesArtifacts: ["Engineering Notes"]
            )
        )

        let supervisorTaskArtifact = TeamArtifact(
            id: "artifact-supervisor-task",
            name: "Supervisor Task",
            icon: "target",
            mimeType: "text/plain",
            description: "Supervisor's task"
        )

        let reqsArtifact = TeamArtifact(
            id: "artifact-reqs",
            name: "Product Requirements",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "Product requirements"
        )

        let notesArtifact = TeamArtifact(
            id: "artifact-notes",
            name: "Engineering Notes",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "Engineering notes"
        )

        return Team(
            name: "Test Team",
            roles: [supervisorRole, independentRole, dependentRole],
            artifacts: [supervisorTaskArtifact, reqsArtifact, notesArtifact],
            settings: .default,
            graphLayout: .default
        )
    }

    private func makeTask() -> NTMSTask {
        NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build something")
    }

    // MARK: - createTeamRun: Supervisor role status is done

    func testCreateTeamRun_supervisorRoleStatusIsDone() {
        let team = makeTestTeam()
        var task = makeTask()

        let run = RunService.createTeamRun(task: &task, team: team)

        XCTAssertEqual(run.roleStatuses["supervisor-role-id"], .done)
    }

    // MARK: - createTeamRun: no-dependency roles are ready

    func testCreateTeamRun_noDependencyRolesAreReady() {
        let team = makeTestTeam()
        var task = makeTask()

        let run = RunService.createTeamRun(task: &task, team: team)

        // PM has no requiredArtifacts -> ready
        XCTAssertEqual(run.roleStatuses["pm-role-id"], .ready)
    }

    // MARK: - createTeamRun: dependent roles are idle

    func testCreateTeamRun_dependentRolesAreIdle() {
        let team = makeTestTeam()
        var task = makeTask()

        let run = RunService.createTeamRun(task: &task, team: team)

        // SWE requires "Product Requirements" -> idle
        XCTAssertEqual(run.roleStatuses["eng-role-id"], .idle)
    }

    // MARK: - createTeamRun: appends run to task

    func testCreateTeamRun_appendsRunToTask() {
        let team = makeTestTeam()
        var task = makeTask()

        XCTAssertTrue(task.runs.isEmpty)

        let run = RunService.createTeamRun(task: &task, team: team)

        XCTAssertEqual(task.runs.count, 1)
        XCTAssertEqual(task.runs[0].id, run.id)
    }

    // MARK: - activeRunID

    func testActiveRunID_returnsLastRunID() {
        let team = makeTestTeam()
        var task = makeTask()

        let run1 = RunService.createTeamRun(task: &task, team: team)
        let run2 = RunService.createTeamRun(task: &task, team: team)

        let activeID = RunService.activeRunID(from: task)

        XCTAssertEqual(activeID, run2.id)
        XCTAssertNotEqual(activeID, run1.id)
    }

    func testActiveRunID_nilTask_returnsNil() {
        let result = RunService.activeRunID(from: nil)
        XCTAssertNil(result)
    }

    // MARK: - selectedRunSnapshot

    func testSelectedRunSnapshot_matchesSelectedID() {
        let team = makeTestTeam()
        var task = makeTask()

        let run1 = RunService.createTeamRun(task: &task, team: team)
        _ = RunService.createTeamRun(task: &task, team: team)

        // Explicitly select the first run
        let snapshot = RunService.selectedRunSnapshot(from: task, selectedRunID: run1.id)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.id, run1.id)
    }

    func testSelectedRunSnapshot_fallsBackToLastRun() {
        let team = makeTestTeam()
        var task = makeTask()

        _ = RunService.createTeamRun(task: &task, team: team)
        let run2 = RunService.createTeamRun(task: &task, team: team)

        // Pass nil for selectedRunID -> falls back to last run
        let snapshot = RunService.selectedRunSnapshot(from: task, selectedRunID: nil)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.id, run2.id)
    }

    func testSelectedRunSnapshot_nilTask_returnsNil() {
        let snapshot = RunService.selectedRunSnapshot(from: nil, selectedRunID: 99)
        XCTAssertNil(snapshot)
    }

    // MARK: - isSelectedRunActive

    func testIsSelectedRunActive_matchingID_returnsTrue() {
        let team = makeTestTeam()
        var task = makeTask()

        _ = RunService.createTeamRun(task: &task, team: team)
        let run2 = RunService.createTeamRun(task: &task, team: team)

        // run2 is the last (active) run; selecting it should return true
        let result = RunService.isSelectedRunActive(task: task, selectedRunID: run2.id)
        XCTAssertTrue(result)
    }

    func testIsSelectedRunActive_differentID_returnsFalse() {
        let team = makeTestTeam()
        var task = makeTask()

        let run1 = RunService.createTeamRun(task: &task, team: team)
        _ = RunService.createTeamRun(task: &task, team: team)

        // run1 is NOT the last (active) run; selecting it should return false
        let result = RunService.isSelectedRunActive(task: task, selectedRunID: run1.id)
        XCTAssertFalse(result)
    }

}
