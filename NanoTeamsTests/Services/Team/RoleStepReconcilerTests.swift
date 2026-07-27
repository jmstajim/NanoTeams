import XCTest

@testable import NanoTeams

/// Pins the single role↔step reconciliation rule.
///
/// `RoleStepReconciler` is `nonisolated`, so this suite is a plain `XCTestCase`.
final class RoleStepReconcilerTests: XCTestCase {

    private let roleID = "software_engineer"

    private func outcome(
        role: RoleExecutionStatus?,
        step: StepStatus?,
        gate: AcceptanceService.Gate = .init(mode: .finalOnly)
    ) -> RoleStepReconciler.Outcome {
        RoleStepReconciler.outcome(roleStatus: role, stepStatus: step, gate: gate, roleID: roleID)
    }

    // MARK: - Live roles × terminal steps (the widened gate)

    func testWorkingRole_doneStep_finalOnly_settlesDone() {
        XCTAssertEqual(outcome(role: .working, step: .done), .settle(.done))
    }

    /// The headline case: the shape `StatusRecoveryService` used to manufacture and then
    /// never look at again.
    func testIdleRole_doneStep_finalOnly_settlesDone() {
        XCTAssertEqual(outcome(role: .idle, step: .done), .settle(.done))
    }

    func testReadyRole_doneStep_finalOnly_settlesDone() {
        XCTAssertEqual(outcome(role: .ready, step: .done), .settle(.done))
    }

    func testLiveRoles_doneStep_afterEachRole_settleNeedsAcceptance() {
        let gate = AcceptanceService.Gate(mode: .afterEachRole)
        for role in [RoleExecutionStatus.idle, .ready, .working] {
            XCTAssertEqual(
                outcome(role: role, step: .done, gate: gate),
                .settle(.needsAcceptance),
                "role \(role.rawValue)"
            )
        }
    }

    func testLiveRoles_doneStep_afterEachArtifact_settleNeedsAcceptance() {
        let gate = AcceptanceService.Gate(mode: .afterEachArtifact)
        XCTAssertEqual(outcome(role: .idle, step: .done, gate: gate), .settle(.needsAcceptance))
    }

    func testDoneStep_customCheckpoints_gatesOnMembership() {
        let inSet = AcceptanceService.Gate(mode: .customCheckpoints, checkpoints: [roleID])
        let outOfSet = AcceptanceService.Gate(mode: .customCheckpoints, checkpoints: ["someone_else"])

        XCTAssertEqual(outcome(role: .idle, step: .done, gate: inSet), .settle(.needsAcceptance))
        XCTAssertEqual(outcome(role: .idle, step: .done, gate: outOfSet), .settle(.done))
    }

    /// Variant 2 of the restart bug: the quit landed after `completeStepNeedsAcceptance`
    /// but before the role flip. The step itself already says a Supervisor must look, so
    /// the acceptance mode is irrelevant.
    func testLiveRoles_needsApprovalStep_settleNeedsAcceptance_regardlessOfMode() {
        for mode in [AcceptanceMode.finalOnly, .afterEachRole, .afterEachArtifact, .customCheckpoints] {
            let gate = AcceptanceService.Gate(mode: mode)
            XCTAssertEqual(
                outcome(role: .idle, step: .needsApproval, gate: gate),
                .settle(.needsAcceptance),
                "mode \(mode.rawValue)"
            )
        }
    }

    func testLiveRoles_failedStep_settleFailed() {
        for role in [RoleExecutionStatus.idle, .ready, .working] {
            XCTAssertEqual(outcome(role: role, step: .failed), .settle(.failed), "role \(role.rawValue)")
        }
    }

    // MARK: - Live roles × non-terminal steps

    func testLiveRoles_midFlightSteps_areInFlight() {
        let midFlight: [StepStatus?] = [.running, .paused, .pending, .needsSupervisorInput, nil]
        for role in [RoleExecutionStatus.idle, .ready, .working] {
            for step in midFlight {
                XCTAssertEqual(
                    outcome(role: role, step: step),
                    .inFlight,
                    "role \(role.rawValue) step \(step.map(\.rawValue) ?? "nil")"
                )
            }
        }
    }

    // MARK: - Never-touch set

    /// A live Supervisor gate must never be re-derived away. Under `.finalOnly` the naive
    /// derivation would rewrite it to `.done` — a silent acceptance that `acceptRole`
    /// then refuses to undo ("Role already completed").
    func testNeedsAcceptanceRole_doneStep_finalOnly_isNoAction() {
        XCTAssertEqual(outcome(role: .needsAcceptance, step: .done), .noAction)
    }

    func testNeedsAcceptanceRole_everyStepStatus_isNoAction() {
        for step in StepStatus.allCases {
            XCTAssertEqual(outcome(role: .needsAcceptance, step: step), .noAction, "step \(step.rawValue)")
        }
    }

    /// `resetStepForRevision` writes `.pending`, so between the request and the reset a
    /// `.revisionRequested` role legitimately sits next to a still-`.done` step.
    func testRevisionRequestedRole_doneStep_isNoAction() {
        XCTAssertEqual(outcome(role: .revisionRequested, step: .done), .noAction)
    }

    func testTerminalRoles_doneStep_areNoAction() {
        for role in [RoleExecutionStatus.done, .accepted, .skipped] {
            XCTAssertEqual(outcome(role: role, step: .done), .noAction, "role \(role.rawValue)")
        }
    }

    /// A recorded failure is never healed into a success — `resumeRun`'s revival branch
    /// owns that transition.
    func testFailedRole_doneStep_isNoAction() {
        XCTAssertEqual(outcome(role: .failed, step: .done), .noAction)
    }

    // MARK: - nil role status

    func testNilRoleStatus_isTreatedAsIdle() {
        XCTAssertEqual(outcome(role: nil, step: .done), .settle(.done))
        XCTAssertEqual(outcome(role: nil, step: .running), .inFlight)
    }

    // MARK: - Idempotence

    /// Feeding a settled result back in must be a no-op, or the engine's reconcile pass
    /// would rewrite the same role every 250 ms tick.
    func testSettleResultIsIdempotent() {
        for (mode, expected) in [(AcceptanceMode.finalOnly, RoleExecutionStatus.done),
                                 (.afterEachRole, .needsAcceptance)] {
            let gate = AcceptanceService.Gate(mode: mode)
            let first = outcome(role: .idle, step: .done, gate: gate)
            XCTAssertEqual(first, .settle(expected))
            XCTAssertEqual(outcome(role: expected, step: .done, gate: gate), .noAction)
        }
    }

    func testFailedSettleIsIdempotent() {
        XCTAssertEqual(outcome(role: .idle, step: .failed), .settle(.failed))
        XCTAssertEqual(outcome(role: .failed, step: .failed), .noAction)
    }

    // MARK: - Gate resolution

    func testGate_nilTeamSettings_fallsBackToVisibleAcceptance() {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "goal")
        let gate = AcceptanceService.Gate(task: task, teamSettings: nil)

        XCTAssertEqual(gate.mode, .afterEachRole, "unresolved team must fail VISIBLE, not silent")
        XCTAssertTrue(gate.requestsAcceptance(roleID: roleID))
    }

    func testGate_perTaskOverride_winsEvenWhenTeamUnresolved() {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "goal")
        task.acceptanceMode = .finalOnly

        let gate = AcceptanceService.Gate(task: task, teamSettings: nil)

        XCTAssertEqual(gate.mode, .finalOnly)
        XCTAssertFalse(gate.requestsAcceptance(roleID: roleID))
    }

    func testGate_usesTeamSettingsWhenNoPerTaskOverride() {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "goal")
        let settings = TeamSettings(defaultAcceptanceMode: .finalOnly)

        let gate = AcceptanceService.Gate(task: task, teamSettings: settings)

        XCTAssertEqual(gate.mode, .finalOnly)
    }

    func testGate_carriesCheckpointsFromTeamSettings() {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "goal")
        let settings = TeamSettings(
            defaultAcceptanceMode: .customCheckpoints,
            acceptanceCheckpoints: [roleID]
        )

        let gate = AcceptanceService.Gate(task: task, teamSettings: settings)

        XCTAssertTrue(gate.requestsAcceptance(roleID: roleID))
        XCTAssertFalse(gate.requestsAcceptance(roleID: "other"))
    }
}
