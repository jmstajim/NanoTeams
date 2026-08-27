import XCTest

@testable import NanoTeams

/// The roster guard on the two role verbs that write per-role state (D-13, 2026-08-25).
///
/// `restartRole` is the destructive one: it finds the step, `reset()`s it — destroying the
/// conversation, tool calls and artifacts — and then reported success for a role the engine can
/// never start again, because `findReadyRoles` iterates the roster. The post-mutation
/// verification it already carried catches a HALLUCINATED id, but a role that still HAS a step
/// sails past it, and deleting a role in the Team Editor while a task is pinned to that team
/// produces exactly that shape.
///
/// `requestRevision` is the quieter one: the orphan `roleStatuses` entry it wrote made the two
/// completion readers disagree — `TeamEngine.allRolesComplete` goes through
/// `Run.activeWorkRoleIDs`, which iterates definitions and never sees it, so the run retires
/// `.done`, while `derivedStatusFromActiveRun`'s `.done` arm reads `roleStatuses` raw and pins
/// the task at "Working" forever.
@MainActor
final class RoleControlRosterGuardTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Seeds a run whose step belongs to a role that is NOT on the task's pinned team — the
    /// shape a Team Editor deletion leaves behind on a live task.
    private func seedOffRosterStep(status: StepStatus = .done) async -> (id: Int, roleID: String)? {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "T", supervisorTask: "goal") else {
            XCTFail("createTask failed"); return nil
        }
        let roleID = "deleted_role"
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: roleID, role: .softwareEngineer, title: "Deleted Role", status: status,
                completedAt: MonotonicClock.shared.now(),
                messages: [StepMessage(role: .softwareEngineer, content: "work worth keeping")],
                toolCalls: [StepToolCall(name: "read_file", argumentsJSON: "{}", resultJSON: "{}")]
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [roleID: .needsAcceptance])]
        }
        // Premise: the role really is absent from the pinned team's roster.
        guard let task = sut.loadedTask(id), let snapshot = sut.snapshot,
              let team = TeamResolution.team(for: task, in: snapshot.projection)
        else { XCTFail("team must resolve"); return nil }
        XCTAssertNil(team.findRole(byIdentifier: roleID),
                     "premise: the role is off the roster")
        return (id, roleID)
    }

    /// RED: delete the roster guard from `restartRole` → the step is `reset()` (its messages and
    /// tool calls destroyed) for a role the engine can never start, and no error is surfaced.
    func testRestartRole_roleNotOnTheRoster_refusesAndLeavesTheStepIntact() async {
        guard let f = await seedOffRosterStep() else { return }
        let before = sut.errorSurfaceCount

        await sut.restartRole(taskID: f.id, roleID: f.roleID, comment: "try again")

        let step = sut.loadedTask(f.id)?.runs.last?.steps.first
        XCTAssertEqual(step?.messages.count, 1, "the step's work must survive a refused restart")
        XCTAssertEqual(step?.toolCalls.count, 1)
        let err = sut.errorSurfaced(since: before)
        XCTAssertNotNil(err, "the refusal must be reported, not swallowed")
        XCTAssertTrue(err?.contains(f.roleID) ?? false, "must name the role; got \(err ?? "nil")")
    }

    /// Success twin, so the refusal above cannot be satisfied by "restart always refuses".
    ///
    /// RED: widen the guard to refuse whenever the role has no STEP (a plausible-looking
    /// alternative) → a legitimate restart of a roster role is refused and this fails.
    func testRestartRole_roleOnTheRoster_stillResets() async {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "T", supervisorTask: "goal") else {
            return XCTFail("createTask failed")
        }
        guard let roleID = sut.snapshot?.projection.activeTeam?.nonSupervisorRoles.first?.id else {
            return XCTFail("active team has no role to restart")
        }
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: roleID, role: .codingAssistant, title: "Role", status: .done,
                messages: [StepMessage(role: .codingAssistant, content: "work")])
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [roleID: .done])]
        }
        let before = sut.errorSurfaceCount

        await sut.restartRole(taskID: id, roleID: roleID, comment: "try again")

        XCTAssertNil(sut.errorSurfaced(since: before), "a roster role must not be refused")
        // Asserted on the ROLE status, not on the step's messages: `restartRole` routes through
        // `resetStepForRevision`, which deliberately preserves conversation and artifacts, so
        // "messages are gone" would be asserting a mechanism this verb does not have.
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses[roleID], .idle,
                       "the restart must actually have reset the role")
        sut.stopEngine(for: id)
    }

    /// RED: delete the roster guard from `requestRevision` → `roleStatuses[deleted_role]`
    /// becomes `.revisionRequested`, invisible to `activeWorkRoleIDs`, and the task reads
    /// "Working" forever behind a run the engine has already retired.
    func testRequestRevision_roleNotOnTheRoster_refusesAndWritesNoOrphanStatus() async {
        guard let f = await seedOffRosterStep() else { return }
        let before = sut.errorSurfaceCount

        await sut.requestRevision(taskID: f.id, roleID: f.roleID, comment: "add tests")

        XCTAssertNotEqual(
            sut.loadedTask(f.id)?.runs.last?.roleStatuses[f.roleID], .revisionRequested,
            "an off-roster role must not gain a status no completion reader can see")
        XCTAssertNotNil(sut.errorSurfaced(since: before),
                        "the refusal must be reported, not swallowed")
    }

    // MARK: - The fixture helper the other suites depend on

    /// Anti-vacuum for `NTMSOrchestratorTestBase.registerRoles(_:onTeamOf:)`.
    ///
    /// Thirteen fixtures across five suites hand-build a `Run` and then call that helper so the
    /// role verbs see a roster role. If the helper ever silently became a no-op — a renamed
    /// field, a `firstIndex` that stops matching, a resolver that returns a different team —
    /// every one of those thirteen would go GREEN by refusal instead of by behaviour, and
    /// nothing else in the tree would notice. This pins the helper's effect directly, on the
    /// same off-roster fixture the refusal tests use, so the two readings cannot be confused.
    ///
    /// RED: make the helper's `register` return without mutating → the role stays off the
    /// roster, `restartRole` refuses, and both halves fail.
    func testRegisterRoles_putsTheRoleOnThePinnedRoster_andTheVerbThenAccepts() async {
        guard let f = await seedOffRosterStep() else { return }

        await registerRoles([f.roleID], onTeamOf: f.id)

        guard let task = sut.loadedTask(f.id), let snapshot = sut.snapshot,
              let team = TeamResolution.team(for: task, in: snapshot.projection)
        else { return XCTFail("team must resolve") }
        XCTAssertNotNil(team.findRole(byIdentifier: f.roleID),
                        "the helper must add the role to the team the TASK is pinned to")

        let before = sut.errorSurfaceCount
        await sut.restartRole(taskID: f.id, roleID: f.roleID, comment: "try again")
        XCTAssertNil(sut.errorSurfaced(since: before),
                     "after registration the verb must stop refusing — this is the exact "
                         + "property the converted fixtures rely on")
        sut.stopEngine(for: f.id)
    }
}
