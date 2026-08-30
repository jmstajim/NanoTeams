import XCTest

@testable import NanoTeams

/// The durable "a role is parked on an acceptance decision" fact, and the one predicate
/// behind it.
///
/// A task can be fully STALLED on a mid-pipeline gate while deriving `.running`: the role
/// settles to `.needsAcceptance`, the engine's run loop transitions and RETURNS, and the
/// downstream roles are still `.ready` so `derivedStatusFromActiveRun` never reaches its
/// `.done` arm. The status is not wrong — downstream work genuinely is still to come — so
/// the missing thing is a SECOND fact, not a different status. These pin that fact, and pin
/// that its two forms (the id list three surfaces render, and the allocation-free predicate
/// `toSummary()` calls on every mutation) cannot disagree.
final class AcceptanceGateFactTests: XCTestCase {

    private func step(_ roleID: String, _ status: StepStatus = .done) -> StepExecution {
        StepExecution(id: roleID, role: .softwareEngineer, title: roleID, status: status)
    }

    private func task(
        run: Run, closedAt: Date? = nil
    ) -> NTMSTask {
        NTMSTask(id: 1, title: "t", supervisorTask: "s", runs: [run], closedAt: closedAt)
    }

    // MARK: - the predicate

    func testGate_holdsForAStepBackedRoleAwaitingAcceptance() {
        let run = Run(id: 0, steps: [step("a")], roleStatuses: ["a": .needsAcceptance])
        XCTAssertEqual(AcceptanceService.actionableAcceptanceGates(run: run), ["a"])
        XCTAssertTrue(AcceptanceService.hasAcceptanceGate(run: run))
        XCTAssertTrue(task(run: run).hasRolesAwaitingAcceptance)
    }

    func testGate_requiresAStepBackedRole() {
        // `roleStatuses` can hold an entry for a role deleted from the roster while the task
        // was live, and `manage_role accept` resolves a STEP — so an id with no step row is
        // un-actionable. Surfacing it would be a banner nobody can clear and a manager pass
        // with nothing to do, whose level therefore never goes quiet.
        let run = Run(id: 0, steps: [step("a", .running)],
                      roleStatuses: ["a": .working, "orphan": .needsAcceptance])
        XCTAssertEqual(AcceptanceService.actionableAcceptanceGates(run: run), [],
                       "an orphan `.needsAcceptance` with no step is not an actionable gate")
        XCTAssertFalse(AcceptanceService.hasAcceptanceGate(run: run))
        XCTAssertFalse(task(run: run).hasRolesAwaitingAcceptance)
    }

    func testGate_falseForClosedTask() {
        let run = Run(id: 0, steps: [step("a")], roleStatuses: ["a": .needsAcceptance])
        XCTAssertFalse(task(run: run, closedAt: Date()).hasRolesAwaitingAcceptance,
                       "a closed task is parked on nothing")
    }

    func testGate_falseForAnAcceptedRole() {
        // Predicted-GREEN control (CLAUDE.md #56): the RED mutations above (dropping the step
        // intersection, dropping the `closedAt` guard) all leave this case alone, so a
        // predicate over-fitted to either of them still has to answer for the ordinary
        // "already accepted" shape.
        let run = Run(id: 0, steps: [step("a")], roleStatuses: ["a": .accepted])
        XCTAssertFalse(AcceptanceService.hasAcceptanceGate(run: run))
        XCTAssertFalse(task(run: run).hasRolesAwaitingAcceptance)
    }

    func testGate_falseForATaskWithNoRuns() {
        XCTAssertFalse(NTMSTask(id: 1, title: "t", supervisorTask: "s").hasRolesAwaitingAcceptance)
    }

    // MARK: - the two forms agree

    func testTheListAndThePredicateAgree_acrossShapes() {
        // The predicate exists ONLY because the list allocates a `Set` and two arrays on a
        // path that runs on every `mutateTask`. Two spellings of one rule is exactly the
        // drift class the extraction was for (CLAUDE.md #51), so they are compared directly.
        let shapes: [Run] = [
            Run(id: 0, steps: [], roleStatuses: [:]),
            Run(id: 0, steps: [step("a")], roleStatuses: ["a": .needsAcceptance]),
            Run(id: 0, steps: [step("a")], roleStatuses: ["a": .accepted]),
            Run(id: 0, steps: [step("a")], roleStatuses: ["a": .working, "orphan": .needsAcceptance]),
            Run(id: 0, steps: [step("a"), step("b", .running)],
                roleStatuses: ["a": .needsAcceptance, "b": .working]),
            Run(id: 0, steps: [step("a"), step("b")],
                roleStatuses: ["a": .accepted, "b": .needsAcceptance]),
        ]
        for run in shapes {
            XCTAssertEqual(AcceptanceService.hasAcceptanceGate(run: run),
                           !AcceptanceService.actionableAcceptanceGates(run: run).isEmpty,
                           "the predicate and the id list must decide the same runs")
        }
    }

    // MARK: - the fact reaches the index row

    func testSummary_mirrorsTheFact() {
        let gated = task(run: Run(id: 0, steps: [step("a")], roleStatuses: ["a": .needsAcceptance]))
        XCTAssertEqual(gated.toSummary().hasRolesAwaitingAcceptance, true)
        XCTAssertTrue(gated.toSummary().hasRoleAtAcceptanceGate)

        let clear = task(run: Run(id: 0, steps: [step("a")], roleStatuses: ["a": .accepted]))
        XCTAssertEqual(clear.toSummary().hasRolesAwaitingAcceptance, false,
                       "a known-clear row writes `false`, not `nil` — `nil` means "
                           + "\"row predates the field\", and the two must stay distinguishable")
        XCTAssertFalse(clear.toSummary().hasRoleAtAcceptanceGate)
    }

    func testLegacyRow_readsUnknownNotFalse() {
        // Tri-state contract (CLAUDE.md #91), same as `hasPendingSupervisorInput`: a row
        // written before the field existed must be distinguishable from a known "no gate",
        // or a consumer that needs the distinction has no way to ask for it.
        let legacy = TaskSummary(id: 1, title: "t", status: .running)
        XCTAssertNil(legacy.hasRolesAwaitingAcceptance)
        XCTAssertFalse(legacy.hasRoleAtAcceptanceGate, "unknown never reads as a gate")
        XCTAssertFalse(legacy.acceptanceGateStateIsKnown)

        var known = legacy
        known.hasRolesAwaitingAcceptance = false
        XCTAssertTrue(known.acceptanceGateStateIsKnown, "…and a known `false` is not unknown")
    }
}
