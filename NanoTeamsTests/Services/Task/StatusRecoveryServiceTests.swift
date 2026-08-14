import XCTest

@testable import NanoTeams

@MainActor
final class StatusRecoveryServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    private func makeTask(
        stepStatuses: [StepStatus],
        roleStatuses: [String: RoleExecutionStatus] = [:]
    ) -> NTMSTask {
        let steps = stepStatuses.map { status in
            StepExecution(
                id: "test_step",
                role: .softwareEngineer,
                title: "Step",
                status: status
            )
        }
        let run = Run(
            id: 0,
            steps: steps,
            roleStatuses: roleStatuses
        )
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [run]
        return task
    }

    /// Builds a task whose step id MATCHES the role id, so `stepsByRoleBaseID()` actually
    /// pairs them. `makeTask` above deliberately does not (its steps are all `test_step`),
    /// which is why its roles only ever exercise the "no step" path.
    private func makePairedTask(
        roleID: String = "software_engineer",
        stepStatus: StepStatus,
        roleStatus: RoleExecutionStatus,
        otherRoles: [String: RoleExecutionStatus] = ["supervisor": .done]
    ) -> NTMSTask {
        let step = StepExecution(id: roleID, role: .softwareEngineer, title: "Step", status: stepStatus)
        var statuses = otherRoles
        statuses[roleID] = roleStatus
        let run = Run(id: 0, steps: [step], roleStatuses: statuses)
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [run]
        return task
    }

    private static let finalOnly = TeamSettings(defaultAcceptanceMode: .finalOnly)
    private static let afterEachRole = TeamSettings(defaultAcceptanceMode: .afterEachRole)

    // MARK: - Torn-pair Settling (the restart-review bug)

    /// The exact shape the app quits into: the step finished, the engine never got to
    /// write the role. Before the fix the role was demoted to `.idle` and the task read
    /// "Working" forever with every review affordance hidden.
    func testRecoverWorkingRoleWithDoneStep_settlesToDone() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .working)

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .done)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
        XCTAssertTrue(task.isReadyForFinalAcceptance)
    }

    /// Self-heal: a `task.json` ALREADY demoted by an older build must recover on the
    /// next launch, with no migration and no user action.
    func testRecoverIdleRoleWithDoneStep_settlesToDone_finalOnly() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .idle)

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .done)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    func testRecoverIdleRoleWithDoneStep_settlesToNeedsAcceptance_afterEachRole() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .idle)

        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.afterEachRole)

        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .needsAcceptance)
        // A role awaiting acceptance surfaces the per-role Accept card, not final review.
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
        XCTAssertFalse(task.isReadyForFinalAcceptance)
    }

    /// Variant 2: the quit landed after `completeStepNeedsAcceptance` but before the
    /// role flip. Recovery leaves the `.needsApproval` step alone, so the role must be
    /// the thing that surfaces the acceptance card.
    func testRecoverIdleRoleWithNeedsApprovalStep_settlesToNeedsAcceptance() {
        var task = makePairedTask(stepStatus: .needsApproval, roleStatus: .idle)

        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .needsAcceptance)
        XCTAssertEqual(task.runs[0].steps[0].status, .needsApproval, "step must not be rewritten")
        XCTAssertFalse(
            task.runs[0].rolesNeedingAcceptance(definitions: []).isEmpty,
            "the acceptance card must have something to render"
        )
    }

    func testRecoverIdleRoleWithFailedStep_settlesToFailed() {
        var task = makePairedTask(stepStatus: .failed, roleStatus: .idle)

        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .failed)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed, "a failure must read as failed, not Working")
    }

    /// An unresolvable team must fail VISIBLE (one extra Accept click) rather than
    /// silently accepting the work on the Supervisor's behalf.
    func testRecoverNilTeamSettings_defaultsToVisibleGate() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .working)

        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: nil)

        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .needsAcceptance)
    }

    // MARK: - Never-touch set

    func testRecoverRevisionRequestedRoleWithDoneStep_untouched() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .revisionRequested)

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .revisionRequested)
    }

    /// Re-deriving a live Supervisor gate under `.finalOnly` would rewrite it to `.done`
    /// — a silent acceptance `acceptRole` then refuses to undo.
    func testRecoverNeedsAcceptanceRoleWithDoneStep_untouched_evenInFinalOnly() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .needsAcceptance)

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .needsAcceptance)
    }

    // MARK: - The paused latch

    /// A pass that only settled a torn TERMINAL pair interrupted nothing, so it must not
    /// arm the `.paused` latch — which is durable and permanently arms the guard in
    /// `derivedStatusFromActiveRun`.
    func testSettleOnlyPass_doesNotArmPausedLatch() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .working)
        task.status = .running

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.status, .running, "settling a finished pair is not a park")
    }

    func testParkingPass_stillArmsPausedLatch() {
        var task = makePairedTask(stepStatus: .running, roleStatus: .working)
        task.status = .running

        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly)

        XCTAssertEqual(task.status, .paused)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .idle)
    }

    // MARK: - Historical runs

    /// A historical run must still lose its stale `.working` (the run-history graph
    /// renders `displayedRun`'s role pills), but must NEVER gain `.needsAcceptance`:
    /// the activity feed renders acceptance cards from `displayedRun` un-gated on
    /// `isReadOnly`, while `acceptRole` writes to `runs.last` — a card there would
    /// mutate a different run. A superseded run collapses to `.done` instead.
    func testHistoricalRun_settlesToDone_neverToNeedsAcceptance() {
        let oldStep = StepExecution(id: "r", role: .softwareEngineer, title: "Old", status: .done)
        let newStep = StepExecution(id: "r", role: .softwareEngineer, title: "New", status: .running)
        let oldRun = Run(id: 0, steps: [oldStep], roleStatuses: ["r": .working])
        let newRun = Run(id: 1, steps: [newStep], roleStatuses: ["r": .working])
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [oldRun, newRun]

        // `.afterEachRole` is the mode that WOULD settle to `.needsAcceptance`.
        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.afterEachRole)

        XCTAssertEqual(task.runs[0].roleStatuses["r"], .done, "historical run settles, but not to a gate")
        XCTAssertTrue(
            task.runs[0].rolesNeedingAcceptance(definitions: []).isEmpty,
            "a historical run must never mint an Accept card — it would mutate runs.last"
        )
        XCTAssertEqual(task.runs[1].roleStatuses["r"], .idle, "active run's step is mid-flight → demote")
    }

    /// The active run keeps the real gate — only history collapses it.
    func testActiveRun_stillSettlesToNeedsAcceptance() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .working)

        StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.afterEachRole)

        XCTAssertEqual(task.runs[0].roleStatuses["software_engineer"], .needsAcceptance)
    }

    // MARK: - Idempotence

    func testRecoveryIsIdempotent() {
        var task = makePairedTask(stepStatus: .done, roleStatus: .working)

        XCTAssertTrue(StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly))
        let afterFirst = task.updatedAt

        XCTAssertFalse(
            StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: Self.finalOnly),
            "a second launch must not churn the task"
        )
        XCTAssertEqual(task.updatedAt, afterFirst)
    }

    // MARK: - Step Recovery Tests

    func testRecoverRunningStepsToPaused() {
        var task = makeTask(stepStatuses: [.running, .done, .pending])

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].steps[1].status, .done)
        XCTAssertEqual(task.runs[0].steps[2].status, .pending)
        XCTAssertEqual(task.status, .paused)
    }

    func testRecoverNeedsSupervisorInputStepsToPaused() {
        var task = makeTask(stepStatuses: [.needsSupervisorInput, .done])

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].steps[1].status, .done)
        XCTAssertEqual(task.status, .paused)
    }

    func testRecoverMultipleStaleSteps() {
        var task = makeTask(stepStatuses: [.running, .needsSupervisorInput, .running])

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].steps[1].status, .paused)
        XCTAssertEqual(task.runs[0].steps[2].status, .paused)
    }

    // MARK: - Role Recovery Tests

    func testRecoverWorkingRolesToIdle() {
        var task = makeTask(
            stepStatuses: [.running],
            roleStatuses: [
                "softwareEngineer": .working,
                "productManager": .done,
                "sre": .idle,
            ]
        )

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].roleStatuses["softwareEngineer"], .idle)
        XCTAssertEqual(task.runs[0].roleStatuses["productManager"], .done)
        XCTAssertEqual(task.runs[0].roleStatuses["sre"], .idle)
        XCTAssertEqual(task.status, .paused)
    }

    // MARK: - No-op Tests

    func testNoChangeWhenAllStatusesSafe() {
        var task = makeTask(
            stepStatuses: [.done, .pending, .paused],
            roleStatuses: [
                "softwareEngineer": .done,
                "productManager": .accepted,
                "sre": .idle,
            ]
        )
        let originalStatus = task.status

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.status, originalStatus, "task.status should not change when no recovery needed")
    }

    func testReturnsFalseWhenNoRuns() {
        var task = NTMSTask(id: 0, title: "Empty", supervisorTask: "Goal")
        task.runs = []

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertFalse(changed)
    }

    // MARK: - Chat Mode Recovery Tests

    func testRecoverChatModeTask_setsPaused() {
        var task = makeTask(stepStatuses: [.running])
        task.setStoredChatMode(true)

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.status, .paused)
        XCTAssertTrue(task.isChatMode, "isChatMode should be preserved after recovery")
    }

    // MARK: - Preserved Status Tests

    func testPreservesCompletedStatuses() {
        var task = makeTask(
            stepStatuses: [.done, .failed, .needsApproval],
            roleStatuses: [
                "softwareEngineer": .done,
                "productManager": .accepted,
                "uxDesigner": .failed,
                "sre": .needsAcceptance,
                "tpm": .revisionRequested,
                "supervisor": .skipped,
            ]
        )

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
        XCTAssertEqual(task.runs[0].steps[1].status, .failed)
        XCTAssertEqual(task.runs[0].steps[2].status, .needsApproval)
        XCTAssertEqual(task.runs[0].roleStatuses["softwareEngineer"], .done)
        XCTAssertEqual(task.runs[0].roleStatuses["productManager"], .accepted)
        XCTAssertEqual(task.runs[0].roleStatuses["uxDesigner"], .failed)
        XCTAssertEqual(task.runs[0].roleStatuses["sre"], .needsAcceptance)
        XCTAssertEqual(task.runs[0].roleStatuses["tpm"], .revisionRequested)
        XCTAssertEqual(task.runs[0].roleStatuses["supervisor"], .skipped)
    }

    // MARK: - Timestamp Tests

    func testUpdatesTimestampsOnChange() {
        var task = makeTask(stepStatuses: [.running])
        let originalTaskUpdatedAt = task.updatedAt
        let originalStepUpdatedAt = task.runs[0].steps[0].updatedAt

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertGreaterThan(task.updatedAt, originalTaskUpdatedAt)
        XCTAssertGreaterThan(task.runs[0].steps[0].updatedAt, originalStepUpdatedAt)
        XCTAssertGreaterThan(task.runs[0].updatedAt, originalTaskUpdatedAt)
    }

    func testDoesNotUpdateTimestampsWhenNoChange() {
        var task = makeTask(stepStatuses: [.done, .pending])
        let originalUpdatedAt = task.updatedAt

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertFalse(changed)
        XCTAssertEqual(task.updatedAt, originalUpdatedAt)
    }

    // MARK: - Multiple Runs Tests

    func testRecoverMultipleRuns() {
        let step1 = StepExecution(id: "test_step", role: .productManager, title: "Step1", status: .running)
        let step2 = StepExecution(id: "test_step", role: .softwareEngineer, title: "Step2", status: .needsSupervisorInput)

        let run1 = Run(id: 0, steps: [step1], roleStatuses: ["productManager": .working])
        let run2 = Run(id: 0, steps: [step2], roleStatuses: ["softwareEngineer": .working])

        var task = NTMSTask(id: 0, title: "Multi-run", supervisorTask: "Goal")
        task.runs = [run1, run2]

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.runs[0].roleStatuses["productManager"], .idle)
        XCTAssertEqual(task.runs[1].steps[0].status, .paused)
        XCTAssertEqual(task.runs[1].roleStatuses["softwareEngineer"], .idle)
    }

    // MARK: - Destroyed team-generation records

    private static let generationStepID = "\(StepExecution.teamGenerationIDPrefix)ABC"

    /// The observed production wedge: `restartRole` reset the synthetic generation step,
    /// leaving it `.pending` with an empty `toolCalls` and a phantom `roleStatuses` key.
    private func makeWedgedGenerationTask(
        stepStatus: StepStatus = .pending,
        generatedTeam: Team? = nil,
        phantomRoleStatus: RoleExecutionStatus? = .idle
    ) -> NTMSTask {
        let step = StepExecution(
            id: Self.generationStepID, role: .supervisor, title: "Generate Team",
            status: stepStatus)
        var roleStatuses: [String: RoleExecutionStatus] = ["supervisor": .done]
        if let phantomRoleStatus { roleStatuses[Self.generationStepID] = phantomRoleStatus }
        var task = NTMSTask(id: 0, title: "Gen", supervisorTask: "build it")
        task.runs = [Run(id: 0, steps: [step], roleStatuses: roleStatuses)]
        if let generatedTeam { task.adoptGeneratedTeam(generatedTeam) }
        return task
    }

    func testDestroyedGenerationRecord_withNoTeam_settlesToPaused() {
        var task = makeWedgedGenerationTask()
        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(
            task.runs[0].steps[0].status, .paused,
            ".paused, not .failed: resumeRun re-enters generation for it, so it is genuinely "
                + "resumable — and .failed would hide the toolbar control entirely")
        XCTAssertNotNil(task.runs[0].steps[0].completedAt)
    }

    /// The whole point of settling it. A `.pending` step makes `derivedTaskStatus()` fall
    /// through to `.running` forever with a dead engine — invisible to the Autovisor's
    /// triage, which has no `running` bullet, and blocking every milestone behind it
    /// under the manager's ONE-TASK-IN-FLIGHT rule.
    func testDestroyedGenerationRecord_taskStopsDerivingRunning() {
        var task = makeWedgedGenerationTask()
        XCTAssertEqual(
            task.derivedStatusFromActiveRun(), .running, "precondition: the wedge")

        _ = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    /// With a team already adopted there is nothing left to generate, so the record
    /// settles `.done` — otherwise `allDone` can never be true and the task never
    /// reaches Review.
    func testDestroyedGenerationRecord_afterAdoption_settlesToDone() {
        var task = makeWedgedGenerationTask(generatedTeam: TeamTemplateFactory.startup())
        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .done)
        XCTAssertNotEqual(task.derivedStatusFromActiveRun(), .running)
    }

    /// Removing the phantom key is not cosmetic: left in place, the role pass below
    /// reconciles it against the step and settles it, after which `resumeRun`'s
    /// failed-step revival would call `runStep` on a step belonging to no roster.
    func testPhantomGenerationRoleKey_isRemovedFromEveryRun() {
        let older = Run(
            id: 0,
            steps: [StepExecution(id: Self.generationStepID, role: .supervisor, title: "G", status: .failed)],
            roleStatuses: ["supervisor": .done, Self.generationStepID: .failed])
        var task = makeWedgedGenerationTask()
        task.runs.insert(older, at: 0)

        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)

        XCTAssertTrue(changed)
        for (index, run) in task.runs.enumerated() {
            XCTAssertNil(
                run.roleStatuses[Self.generationStepID],
                "phantom key survived in run \(index)")
        }
    }

    /// Nothing was interrupted, so the durable latch must stay disarmed — the step's own
    /// `.paused` already drives the derived status.
    func testDestroyedGenerationRecord_doesNotArmTheRecoveryPauseLatch() {
        var task = makeWedgedGenerationTask(phantomRoleStatus: nil)
        _ = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)
        XCTAssertNotEqual(task.status, .paused)
    }

    /// `.paused` is HONEST for a generation cancelled by `pauseRun` or parked here after
    /// an app quit — and it carries the "was cancelled" envelope the pane renders. Only
    /// `.pending` (which has exactly one writer, `StepExecution.reset()`) is a wedge.
    func testHonestGenerationStepStatuses_areLeftAlone() {
        for status in [StepStatus.paused, .failed, .done] {
            var task = makeWedgedGenerationTask(stepStatus: status, phantomRoleStatus: nil)
            _ = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)
            XCTAssertEqual(task.runs[0].steps[0].status, status, "status \(status) was rewritten")
        }
    }

    /// A `.running` generation step belongs to the ordinary parking pass, which writes
    /// `.paused` AND arms the latch — the settle must not intercept it.
    func testRunningGenerationStep_isParkedByTheOrdinaryPass_andArmsTheLatch() {
        var task = makeWedgedGenerationTask(stepStatus: .running, phantomRoleStatus: nil)
        _ = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)
        XCTAssertEqual(task.runs[0].steps[0].status, .paused)
        XCTAssertEqual(task.status, .paused, "genuinely interrupted work arms the latch")
    }

    /// A REAL role's `.pending` step is the ordinary "hasn't started yet" state and must
    /// never be settled — only the synthetic generation prefix qualifies.
    func testPendingStepOfARealRole_isUntouched() {
        var task = makePairedTask(stepStatus: .pending, roleStatus: .idle)
        let changed = StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default)
        XCTAssertFalse(changed)
        XCTAssertEqual(task.runs[0].steps[0].status, .pending)
    }

    func testDestroyedGenerationRecord_isIdempotent() {
        var task = makeWedgedGenerationTask()
        XCTAssertTrue(StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default))
        XCTAssertFalse(
            StatusRecoveryService.recoverStaleStatuses(in: &task, teamSettings: .default),
            "a second pass has nothing left to do")
    }
}
