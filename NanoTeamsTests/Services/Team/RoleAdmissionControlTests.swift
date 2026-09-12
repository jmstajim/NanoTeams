import XCTest

@testable import NanoTeams

/// The concurrency rule, tested where it is a pure function — no engine, no store.
///
/// Half of these are the four counterexamples that killed the obvious measure ("count the
/// `.working` roles"). Each is a state the app reaches on its own, and each is pinned so the
/// next reader who reaches for `.working` finds out why it is wrong before shipping it.
final class RoleAdmissionControlTests: XCTestCase {

    // MARK: - Fixtures

    private func worker(_ id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id.capitalized,
            prompt: "You are \(id).",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["\(id) Notes"]))
    }

    private func supervisor() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor-role",
            name: "Supervisor",
            prompt: "You are the Supervisor.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final Deliverable"],
                producesArtifacts: ["Supervisor Task"]),
            isSystemRole: true,
            systemRoleID: "supervisor")
    }

    private func observer(_ id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id.capitalized,
            prompt: "You observe.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []))
    }

    private func step(
        _ roleID: String,
        _ status: StepStatus,
        delegatingTo childID: Int? = nil
    ) -> StepExecution {
        StepExecution(
            id: roleID,
            role: .custom(id: roleID),
            title: roleID,
            status: status,
            activeDelegationChildID: childID)
    }

    // MARK: - admit: the arithmetic

    func testAdmit_noLimit_admitsEveryCandidate() {
        let admitted = RoleAdmissionControl.admit(
            candidates: ["a", "b", "c"], occupied: [], limit: nil)
        XCTAssertEqual(admitted, ["a", "b", "c"])
    }

    func testAdmit_capOfOne_withNothingRunning_admitsExactlyTheFirst() {
        let admitted = RoleAdmissionControl.admit(
            candidates: ["a", "b", "c"], occupied: [], limit: 1)
        XCTAssertEqual(admitted, ["a"], "and the FIRST — candidate order is the priority order")
    }

    func testAdmit_capReached_admitsNothing() {
        let admitted = RoleAdmissionControl.admit(
            candidates: ["b"], occupied: ["a"], limit: 1)
        XCTAssertTrue(admitted.isEmpty)
    }

    func testAdmit_partialRoom_admitsUpToTheRemainder() {
        let admitted = RoleAdmissionControl.admit(
            candidates: ["b", "c", "d"], occupied: ["a"], limit: 3)
        XCTAssertEqual(admitted, ["b", "c"])
    }

    /// A stored `0` is reachable through team import and hand-edited defaults. Read as "one",
    /// never as "none": a cap of zero admits nothing forever, and the run loop would wait for
    /// a slot that can never open — a hang with no message.
    func testAdmit_nonPositiveCap_isReadAsOne() {
        XCTAssertEqual(
            RoleAdmissionControl.admit(candidates: ["a", "b"], occupied: [], limit: 0), ["a"])
        XCTAssertEqual(
            RoleAdmissionControl.admit(candidates: ["a", "b"], occupied: [], limit: -5), ["a"])
    }

    /// Over-subscription (more holders than the cap — reachable after lowering the setting
    /// mid-run) admits nobody new rather than going negative.
    func testAdmit_occupiedExceedsCap_admitsNothing() {
        XCTAssertTrue(
            RoleAdmissionControl.admit(candidates: ["c"], occupied: ["a", "b"], limit: 1).isEmpty)
    }

    /// A candidate that already holds a slot is admitted WITHOUT spending one — it is not
    /// asking for a new slot, it is being re-entered on the one it already counts against.
    /// The commonest shape is a `.revisionRequested` role whose step is still `.running` after
    /// an app restart; refusing it here would refuse the very restart this exists for.
    /// ("Is somebody already executing this role" is the other question, and the engine
    /// answers it with `hasLiveRoleTask` at each dispatch site.)
    func testAdmit_candidateThatAlreadyHoldsASlot_costsNoSlot() {
        XCTAssertEqual(
            RoleAdmissionControl.admit(candidates: ["a", "b"], occupied: ["a"], limit: 1),
            ["a"],
            "`a` re-enters its own slot; `b` still has to wait for one")
        XCTAssertEqual(
            RoleAdmissionControl.admit(candidates: ["a", "b"], occupied: ["a"], limit: 2),
            ["a", "b"])
    }

    func testAdmit_preservesCandidateOrder() {
        let admitted = RoleAdmissionControl.admit(
            candidates: ["z", "y", "x"], occupied: [], limit: nil)
        XCTAssertEqual(admitted, ["z", "y", "x"])
    }

    // MARK: - occupancy: what actually holds a slot

    func testOccupancy_runningStep_holdsASlot() {
        let run = Run(id: 0, steps: [step("a", .running)], roleStatuses: ["a": .working])
        XCTAssertEqual(
            RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]), ["a"])
    }

    /// Counterexample 1. `holdDownstreamForRevision` flags the role that asked for the changes
    /// `.revisionRequested` and deliberately leaves its own step running. Measured by
    /// `.working` it is invisible, and a cap of one would hand out a second stream beside it.
    func testOccupancy_changeRequesterIsRevisionRequestedButStillRunning_holdsASlot() {
        let run = Run(
            id: 0, steps: [step("a", .running)], roleStatuses: ["a": .revisionRequested])
        XCTAssertEqual(
            RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]), ["a"],
            "the measure is the STEP, not the role's flag")
    }

    /// Counterexample 2. A role deleted from the team mid-run keeps its `.working` entry —
    /// `StatusRecoveryService` preserves it on purpose — and would eat the only slot forever.
    /// The walk is over the ROSTER, so it is not even looked at.
    func testOccupancy_orphanedWorkingEntryOutsideTheRoster_isIgnored() {
        let run = Run(
            id: 0,
            steps: [step("ghost", .running)],
            roleStatuses: ["ghost": .working, "a": .idle])
        XCTAssertTrue(RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]).isEmpty)
    }

    /// Counterexample 3. Parked on a question, or paused: `.working`, holding nothing.
    func testOccupancy_workingRoleWithAParkedStep_holdsNothing() {
        for parked in [StepStatus.paused, .needsSupervisorInput, .needsApproval, .pending] {
            let run = Run(id: 0, steps: [step("a", parked)], roleStatuses: ["a": .working])
            XCTAssertTrue(
                RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]).isEmpty,
                "a \(parked) step is not touching the server")
        }
    }

    /// Counterexample 4. A parent suspended in `delegate_to_team` is `.working` with a
    /// `.running` step for up to thirty minutes and is not touching the server. Counting it
    /// would deadlock the one bundled template that delegates by design.
    func testOccupancy_roleWaitingOnADelegatedChild_holdsNothing() {
        let run = Run(
            id: 0, steps: [step("a", .running, delegatingTo: 7)], roleStatuses: ["a": .working])
        XCTAssertTrue(RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]).isEmpty)
    }

    /// The window between `updateRoleStatus(.working)` and `findOrCreateStep`: no step exists
    /// yet, and the role is on its way to one.
    func testOccupancy_workingRoleWithNoStepYet_holdsASlot() {
        let run = Run(id: 0, roleStatuses: ["a": .working])
        XCTAssertEqual(
            RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]), ["a"])
    }

    func testOccupancy_idleOrReadyRoleWithNoStep_holdsNothing() {
        let run = Run(id: 0, roleStatuses: ["a": .idle, "b": .ready])
        XCTAssertTrue(
            RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a"), worker("b")])
                .isEmpty)
    }

    func testOccupancy_terminalRoles_holdNothing() {
        let run = Run(
            id: 0,
            steps: [step("a", .done), step("b", .failed)],
            roleStatuses: ["a": .done, "b": .failed])
        XCTAssertTrue(
            RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a"), worker("b")])
                .isEmpty)
    }

    /// A DECISION, pinned so it is not "fixed" blind: a role waiting on a `bash` or
    /// computer-use approval card keeps its slot. Its step is `.running`, a human answers one
    /// question at a time anyway, and freeing the slot would let a second role start a call the
    /// same human then has to arbitrate.
    func testOccupancy_roleWaitingOnAnApprovalCard_keepsItsSlot_deliberately() {
        let run = Run(id: 0, steps: [step("a", .running)], roleStatuses: ["a": .working])
        XCTAssertEqual(
            RoleAdmissionControl.occupiedRoleIDs(run: run, roles: [worker("a")]), ["a"])
    }

    /// The Supervisor is the human and never executes a step; observers never get one either.
    func testOccupancy_supervisorAndObservers_areNotCounted() {
        let run = Run(
            id: 0,
            steps: [step("supervisor-role", .running), step("obs", .running)],
            roleStatuses: ["supervisor-role": .working, "obs": .working])
        XCTAssertTrue(
            RoleAdmissionControl.occupiedRoleIDs(
                run: run, roles: [supervisor(), observer("obs")]).isEmpty)
    }

    func testOccupancy_emptyRun_isEmpty() {
        XCTAssertTrue(
            RoleAdmissionControl.occupiedRoleIDs(run: Run(id: 0), roles: []).isEmpty)
        XCTAssertTrue(
            RoleAdmissionControl.occupiedRoleIDs(run: Run(id: 0), roles: [worker("a")]).isEmpty)
    }
}
