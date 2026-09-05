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

    // MARK: - Run.id == position (the invariant RunService.runIndex rests on)

    /// `createTeamRun` is the SOLE appender of `task.runs` (pinned tree-wide by
    /// `Ratchet/RunIDIsPositionPinTests`) and it stamps `id: task.runs.count` — so after any
    /// number of appends every run's id IS its array position. `RunService.runIndex(in:runID:)`
    /// and, through it, `NTMSOrchestrator.syncSelectedRunID` answer by-id questions in O(1)
    /// on that basis.
    ///
    /// RED: `id: task.runs.count` → `id: task.runs.count + 1` (or `id: 0`) → ids stop
    /// equalling positions.
    func testCreateTeamRun_runIDEqualsItsPosition_afterRepeatedAppends() {
        let team = makeTestTeam()
        var task = makeTask()
        for _ in 0..<5 { _ = RunService.createTeamRun(task: &task, team: team) }

        XCTAssertEqual(task.runs.map(\.id), Array(0..<5))
        XCTAssertTrue(task.runs.enumerated().allSatisfy { $0.offset == $0.element.id },
                      "every run's id must be its position")
    }

    /// RED: replace the body with `return runID` (drop the bounds guard) → `runID: 3` is
    /// non-nil; or drop `task.runs.indices.contains(runID)` alone → `runs[3]` traps.
    func testRunIndex_isTheIdentityInsideTheArray_andNilOutside() {
        let team = makeTestTeam()
        var task = makeTask()
        for _ in 0..<3 { _ = RunService.createTeamRun(task: &task, team: team) }

        for i in 0..<3 {
            XCTAssertEqual(RunService.runIndex(in: task, runID: i), i)
        }
        XCTAssertNil(RunService.runIndex(in: task, runID: 3), "one past the end is absent")
        XCTAssertNil(RunService.runIndex(in: task, runID: -1), "a negative id is absent, not a trap")
        XCTAssertNil(RunService.runIndex(in: task, runID: Int.max))
        XCTAssertEqual(RunService.selectedRunSnapshot(from: task, selectedRunID: 1)?.id, 1,
                       "the re-routed consumer still answers")
        XCTAssertEqual(RunService.selectedRunSnapshot(from: task, selectedRunID: 3)?.id, 2,
                       "an unknown id falls back to the newest run, as before")
    }

    func testRunIndex_emptyRuns_isNil() {
        let task = makeTask()
        XCTAssertNil(RunService.runIndex(in: task, runID: 0))
    }

    /// A relabelled legacy array (pre-sequential-ids data) can put a run whose id is 7 at
    /// position 0. A bare bounds check would answer "present" for `runID: 0` — a run that is
    /// not there. The `.id == runID` compare degrades to "absent" on both questions, which is
    /// the arm every caller already has for an unknown id (`selectedRunSnapshot` falls back
    /// to the newest run).
    ///
    /// RED: drop `task.runs[runID].id == runID` from the guard → `runID: 0` answers 0.
    func testRunIndex_malformedArray_neverAnswersPresentForAMissingRun() {
        var task = makeTask()
        task.runs = [Run(id: 7)]

        XCTAssertNil(RunService.runIndex(in: task, runID: 0),
                     "a bare bounds check would say present for a run that is not there")
        XCTAssertNil(RunService.runIndex(in: task, runID: 7),
                     "documented degradation: absent → callers fall back to the newest run")
        XCTAssertEqual(RunService.selectedRunSnapshot(from: task, selectedRunID: 7)?.id, 7,
                       "…and the fallback IS the newest run, so the caller still gets a run")
    }

    // MARK: - mutateActiveRun (the in-place edit that replaced four copy-out/write-back sites)

    /// Four orchestrator sites (`acceptRole`, `finishAdvisoryRoleAwaiting`, `closeTask`,
    /// `switchTeam`) used to copy the newest run out (`guard var run = task.runs.last`), edit
    /// the copy and store it with `task.runs[task.runs.count - 1] = run` — a whole-element
    /// write that `Run.id` being `let` does not police (a run read from another slot, or built
    /// elsewhere, would land with the wrong id and break `id == position` silently). The edit
    /// now happens IN PLACE through `inout`, so there is no copy to write back and the array's
    /// ids cannot change — which is what lets the source pin forbid the `runs[i] = run` shape
    /// tree-wide (`Ratchet/RunIDIsPositionPinTests`).
    ///
    /// RED: `task.runs.indices.last` → `task.runs.indices.first` → run 0 is edited, run 2 is
    /// not; or drop the in-place `&task.runs[i]` for a copy the body edits and discards → the
    /// status never lands.
    func testMutateActiveRun_editsTheNewestRunInPlace_andLeavesEveryIDWhereItWas() {
        let team = makeTestTeam()
        var task = makeTask()
        for _ in 0..<3 { _ = RunService.createTeamRun(task: &task, team: team) }
        let idsBefore = task.runs.map(\.id)

        let edited = RunService.mutateActiveRun(in: &task) { run in
            run.roleStatuses["pm-role-id"] = .accepted
        }

        XCTAssertTrue(edited, "a run existed to edit")
        XCTAssertEqual(task.runs[2].roleStatuses["pm-role-id"], .accepted, "the NEWEST run took the edit")
        XCTAssertEqual(task.runs[0].roleStatuses["pm-role-id"], .ready, "older runs are untouched")
        XCTAssertEqual(task.runs[1].roleStatuses["pm-role-id"], .ready)
        XCTAssertEqual(task.runs.count, 3, "no append, no removal")
        XCTAssertEqual(task.runs.map(\.id), idsBefore, "no id moved")
        XCTAssertTrue(task.runs.enumerated().allSatisfy { $0.offset == $0.element.id },
                      "`id == position` survives the edit")
    }

    /// The four call sites all guard `runs.last` before editing; with no run there is nothing
    /// to edit and the body must not run against a phantom.
    ///
    /// RED: replace the `indices.last` guard's `return false` with a trap or with `true` → the
    /// body-count or the return value trips.
    func testMutateActiveRun_noRuns_isANoOpThatSaysSo() {
        var task = makeTask()
        var bodyCalls = 0

        let edited = RunService.mutateActiveRun(in: &task) { _ in bodyCalls += 1 }

        XCTAssertFalse(edited)
        XCTAssertEqual(bodyCalls, 0, "the body must not run when there is no run to edit")
        XCTAssertTrue(task.runs.isEmpty, "and nothing was conjured")
    }
}
