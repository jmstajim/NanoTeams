import XCTest
@testable import NanoTeams

/// Tests for NTMSTask business logic (derivedStatus, toSummary)
final class NTMSTaskLogicTests: XCTestCase {

    // MARK: - derivedStatusFromActiveRun Tests

    func testDerivedStatusWithNoRuns() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .paused)

        // With no runs, should return the stored status
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusWithEmptySteps() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .done)
        task.runs = [Run(id: 0, steps: [])]

        // With empty steps, should return .running (the fallback)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusWithAllDoneSteps() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ])
        ]

        // Without closedAt, all done → .needsSupervisorAcceptance
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)

        // With closedAt, all done → .done
        task.closedAt = Date()
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    func testDerivedStatusWithFailedStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .failed),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // Failed takes highest priority
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusWithNeedsSupervisorInputStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .needsSupervisorInput),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorInput)
    }

    func testDerivedStatusWithPausedStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusWithRunningStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .running),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // Running and pending steps should result in .running overall
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusPriority_FailedOverNeedsSupervisor() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .needsSupervisorInput),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // Failed has highest priority
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusPriority_NeedsSupervisorOverPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .needsSupervisorInput),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // needsSupervisorInput has priority over paused
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorInput)
    }

    func testDerivedStatusUsesLastRun() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            // First run - all done
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
            ]),
            // Second (last) run - has failure
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed)
            ])
        ]

        // Should use the last run's status
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusWithNeedsApprovalAndRunningStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
            ])
        ]

        // When a role needs approval but another is still running, task should show .running
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusWithNeedsApprovalAndRunningStep_recoveredTask() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
            ])
        ]

        // .running base (has running steps) — recovery status doesn't override derivation
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    // MARK: - derivedStatus + roleStatuses Tests

    func testDerivedStatus_allStepsDone_rolesNotComplete_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .working   // Still working — task should NOT be needsSupervisorAcceptance
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatus_allStepsDone_rolesNeedAcceptance_returnsNeedsSupervisorAcceptance() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .needsAcceptance   // Waiting for Supervisor — task should show Review, not Working
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    func testDerivedStatus_allStepsDone_mixedAcceptanceAndWorking_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "pm": .needsAcceptance,
                "eng": .working   // Still working — task should be running
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatus_allStepsDone_allRolesComplete_returnsNeedsSupervisorAcceptance() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .done
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    /// The shape a pre-fix `StatusRecoveryService` manufactured at every launch: all
    /// steps `.done`, the finished role demoted to `.idle`. Pinned HERE, unchanged, to
    /// prove the fix belongs in recovery — `NTMSTask` is right to call an `.idle` role
    /// unfinished; it cannot see that the role's step already completed.
    func testDerivedStatus_allStepsDone_roleIdle_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "eng", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "eng": .idle
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
        XCTAssertFalse(task.isReadyForFinalAcceptance,
                       "every review affordance reduces to this — hence the invisible task")
    }

    /// The post-heal shape: recovery settled the role, so the task is reviewable.
    func testDerivedStatus_allStepsDone_roleSettledDone_isReadyForFinalAcceptance() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "eng", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "eng": .done
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
        XCTAssertTrue(task.isReadyForFinalAcceptance)
    }

    // MARK: - Recovery pause latch

    /// The latch exists so a recovered run whose remaining steps are all `.pending`
    /// reads "Paused" rather than "Working".
    func testRecoveryPauseLatch_armed_makesAllPendingRunReadPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "eng", role: .softwareEngineer, title: "Eng", status: .pending)
            ], roleStatuses: ["eng": .idle])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    /// …and clearing it on a transition back to live restores "Working". Without a
    /// clear the latch stayed armed for the task's whole life, so every LATER run
    /// rendered "Paused" at any moment when no step happened to be `.running`.
    func testClearRecoveryPauseLatch_restoresRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "eng", role: .softwareEngineer, title: "Eng", status: .pending)
            ], roleStatuses: ["eng": .idle])
        ]

        task.clearRecoveryPauseLatch()

        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testClearRecoveryPauseLatch_isNoOpForNonPausedStatus() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .done

        task.clearRecoveryPauseLatch()

        XCTAssertEqual(task.status, .done, "the clear must only ever retire the .paused latch")
    }

    func testDerivedStatus_emptyRoleStatuses_fallsThrough() {
        // Legacy runs have empty roleStatuses — should still work
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    // MARK: - derivedStatus + closedAt (Accept & Close) Tests

    /// Regression for the reported bug: "Accept & Close" on a paused non-chat
    /// task. `closeTask` finalizes the running/paused step to `.done` but leaves
    /// never-ran downstream roles as `.idle`/`.ready` (they have no step). The
    /// closed task must derive `.done`, not `.running` ("Working").
    func testDerivedStatus_closedWhilePaused_idleDownstreamRoles_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .done,
                "swe": .idle,    // downstream role that never ran
                "cr": .ready
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    /// `closeTask` deliberately preserves `.pending` steps (never-started roles).
    /// A leftover `.pending` step makes the step summary's base `.running`, so a
    /// closed task with one must still derive `.done` via the `!hasRunning` guard.
    func testDerivedStatus_closedWithPendingStep_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    /// A task closed before its run ever created a step still derives `.done`
    /// (the empty-steps guard honors `closedAt`).
    func testDerivedStatus_closedWithEmptyStepsRun_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [Run(id: 0, steps: [])]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    /// Defense (F1): `closedAt` is set but a step is actually `.running` (e.g.
    /// `resumeRun`, which has no `closedAt` guard, restarted it). The `!hasRunning`
    /// gate must NOT mask a live run as `.done` — surface its true status.
    func testDerivedStatus_closedWithRunningStep_doesNotMaskAsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
            ], roleStatuses: ["eng": .working])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    /// A closed task with a leftover failed step surfaces `.failed` (failures are
    /// preserved for diagnostics, mirroring `closeTask`'s failed-step preservation).
    func testDerivedStatus_closedWithFailedStep_returnsFailed() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .failed)
            ], roleStatuses: ["eng": .failed])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    /// A closed task with a leftover `.needsSupervisorInput` step must not resurface
    /// as "needs input" — closing is terminal. Distinct `stepStatusSummary` flag from
    /// the other closed tests (`closeTask` normally finalizes these, so this pins the
    /// guard's defensive coverage).
    func testDerivedStatus_closedWithNeedsSupervisorInputStep_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .needsSupervisorInput)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    /// A closed task with a leftover `.needsApproval` step → `.done`. `closeTask` does
    /// NOT finalize `.needsApproval` steps, so this shape is genuinely reachable — and
    /// it's the one explicitly named in the guard's comment.
    func testDerivedStatus_closedWithNeedsApprovalStep_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .needsApproval)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    /// Defense interaction: a closed task with BOTH a `.running` and a `.failed` step
    /// surfaces `.failed` — `!hasRunning` bypasses the closed-guard, and `.failed` wins
    /// the base priority. Distinguishes from the pure-running case (which yields `.running`).
    func testDerivedStatus_closedWithRunningAndFailedStep_returnsFailed() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .running),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .failed)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    /// A task closed before it ever created a run is still terminal → `.done`
    /// (the no-runs guard honors `closedAt`). Stored `status` is ignored when closed.
    func testDerivedStatus_closedWithNoRuns_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .paused)
        task.closedAt = Date()
        // runs intentionally left empty

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    // MARK: - derivedStatus additional corner cases

    /// The literal reported shape at the step level: closed + a still-`.paused` step
    /// (e.g. before closeTask's finalization ran, or as defense). `!hasRunning` holds
    /// for a paused step, so the closed-guard resolves it to `.done`, not "Working".
    func testDerivedStatus_closedWithPausedStep_returnsDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.closedAt = Date()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ], roleStatuses: ["eng": .working])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    /// Negative clause of the paused-override: stored `status == .paused` but a step is
    /// actually `.running` (`hasRunning` true → the `&& !s.hasRunning` guard fails), so
    /// the live work wins and the task reads `.running`, not a stale `.paused`.
    func testDerivedStatus_pausedStatus_withRunningStep_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .paused)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
            ], roleStatuses: ["eng": .working])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    /// All steps `.done` but a role is `.revisionRequested` (not complete, not awaiting
    /// acceptance) → `.running`. Distinct from the `.working` leftover case; pins that
    /// revision-in-progress keeps the task active rather than ready-for-acceptance.
    func testDerivedStatus_allStepsDone_roleRevisionRequested_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "pm": .done,
                "eng": .revisionRequested
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    /// All steps `.done` with roles `.accepted` + `.done` (both `isComplete`) → all roles
    /// complete → `.needsSupervisorAcceptance`. Pins that `.accepted` counts as complete,
    /// not just `.done`.
    func testDerivedStatus_allStepsDone_rolesAcceptedComplete_returnsNeedsSupervisorAcceptance() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "pm": .accepted,
                "eng": .done
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    /// A lone `.needsApproval` step (no running/paused) derives `.paused` at the task
    /// level — `derivedTaskStatus` maps `hasNeedsApproval && !hasRunning` → `.paused`,
    /// and the `default` arm passes it through. Pins the internal bridge state's surface.
    func testDerivedStatus_singleNeedsApprovalStep_returnsPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .needsApproval)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    /// All steps `.done` with a `.skipped` role (observer / error-recovery skip)
    /// alongside `.done` roles → all roles count as complete (`.skipped.isComplete`
    /// is true) → `.needsSupervisorAcceptance`. Pins that a skipped role does NOT
    /// block final acceptance — the only `RoleExecutionStatus` not otherwise covered.
    func testDerivedStatus_allStepsDone_roleSkipped_countsAsComplete() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "pm": .done,
                "observer": .skipped
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    /// A `.skipped` role does not RESCUE an otherwise-incomplete set: `.skipped`
    /// (complete) + `.working` (not complete, not acceptance) → `.running`. Guards
    /// against a bug that treats the mere presence of `.skipped` as "all complete".
    func testDerivedStatus_allStepsDone_skippedPlusWorking_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "observer": .skipped,
                "eng": .working
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    // MARK: - toSummary Tests

    func testToSummary() {
        let taskID = 0
        let updatedAt = Date()
        var task = NTMSTask(
            id: taskID,
            title: "Implement Login",
            supervisorTask: "Add login feature",
            status: .running,
            updatedAt: updatedAt
        )
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .done)
            ])
        ]

        let summary = task.toSummary()

        XCTAssertEqual(summary.id, taskID)
        XCTAssertEqual(summary.title, "Implement Login")
        XCTAssertEqual(summary.status, .needsSupervisorAcceptance) // Uses derived status (closedAt is nil)
        XCTAssertEqual(summary.updatedAt, updatedAt)
    }

    func testToSummaryWithFailedRun() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .failed)
            ])
        ]

        let summary = task.toSummary()

        // Summary should reflect derived failed status
        XCTAssertEqual(summary.status, .failed)
    }

    // MARK: - Run derivedStatus Tests

    func testRunDerivedStatusWithNoSteps() {
        let run = Run(id: 0, steps: [])
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testRunDerivedStatusAllDone() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
        ])
        XCTAssertEqual(run.derivedStatus(), .done)
    }

    func testRunDerivedStatusWithFailed() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .failed)
        ])
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testRunDerivedStatusWithNeedsSupervisorInput() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsSupervisorInput)
        ])
        XCTAssertEqual(run.derivedStatus(), .needsSupervisorInput)
    }

    func testRunDerivedStatusWithPaused() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused)
        ])
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    func testRunDerivedStatusWithMixedPendingAndDone() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
        ])
        // Not all done, no failure/needsSupervisor/paused -> running
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testRunDerivedStatusWithNeedsApproval() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .needsApproval)
        ])
        // needsApproval means waiting for Supervisor — maps to .paused at task level
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    // MARK: - Recovery Status Tests

    func testDerivedStatusReturnsPausedAfterRecovery() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // Paused steps → .paused (recovery and explicit pause produce same result)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusReturnsPausedWhenExplicitlyPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .running  // Normal running state (not recovered)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // With .running status and paused steps → .paused (explicit pause)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusWithNoPausedStepsAndPendingWork() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Recovered — no steps actually running
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .pending)
            ])
        ]

        // Base is .running (pending work) but no steps are actually running + task.status is .paused → .paused
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatus_emptySteps_ignoredStoredPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Set by recovery, but run has no steps yet
        task.runs = [Run(id: 0, steps: [])]

        // Empty steps → always .running, stored .paused is ignored
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusFailedOverridesPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused)
            ])
        ]

        // .failed still takes priority over .paused
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testToSummaryReflectsPausedStatus() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused)
            ])
        ]

        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .paused)
    }

    func testDerivedStatus_chatMode_recoveredTask_returnsPaused() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Goal", isChatMode: true)
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // Chat-mode recovered task derives .paused — display layer shows "Chat"
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .paused)
        XCTAssertTrue(summary.isChatMode)
        XCTAssertEqual(summary.status.displayLabel(isChatMode: summary.isChatMode), "Chat")
    }

    func testDerivedStatus_nonChatMode_recoveredTask_returnsPaused() {
        var task = NTMSTask(id: 0, title: "Task", supervisorTask: "Goal", isChatMode: false)
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // Non-chat recovered task derives .paused — display layer shows "Paused"
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .paused)
        XCTAssertFalse(summary.isChatMode)
        XCTAssertEqual(summary.status.displayLabel(isChatMode: summary.isChatMode), "Paused")
    }

    // MARK: - TaskSummary Tests

    func testTaskSummaryIdentifiable() {
        let id = 42
        let summary = TaskSummary(id: id, title: "Test", status: .running)
        XCTAssertEqual(summary.id, id)
    }

    func testTaskSummaryHashable() {
        let summary1 = TaskSummary(id: 0, title: "Test 1", status: .running)
        let summary2 = TaskSummary(id: 0, title: "Test 2", status: .done)

        var set = Set<TaskSummary>()
        set.insert(summary1)
        set.insert(summary2)
        set.insert(summary1) // duplicate

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - TasksIndex Tests

    func testTasksIndexDefaults() {
        let index = TasksIndex()
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertTrue(index.tasks.isEmpty)
    }

    func testTasksIndexWithTasks() {
        let tasks = [
            TaskSummary(id: 0, title: "Task 1", status: .running),
            TaskSummary(id: 0, title: "Task 2", status: .done)
        ]
        let index = TasksIndex(schemaVersion: 2, tasks: tasks)

        XCTAssertEqual(index.schemaVersion, 2)
        XCTAssertEqual(index.tasks.count, 2)
    }

    // MARK: - Initial Input

    func testHasInitialInput_falseWhenAllInputsEmpty() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "")

        XCTAssertFalse(task.hasInitialInput)
    }

    func testHasInitialInput_goalOnly() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Ship the feature")

        XCTAssertTrue(task.hasInitialInput)
    }

    func testHasInitialInput_clippedTextOnly() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "", clippedTexts: [Clip].minting(["Copied selection"]))

        XCTAssertTrue(task.hasInitialInput)
    }

    func testHasInitialInput_attachmentOnly() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "",
                            attachmentPaths: [".nanoteams/tasks/123/attachments/spec.pdf"]
        )

        XCTAssertTrue(task.hasInitialInput)
    }

    func testEffectiveSupervisorBrief_combinesGoalClipAndAttachments() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "Implement import flow",
                            clippedTexts: [Clip].minting(["Use the selected API response shape"]),
                            attachmentPaths: [
                                ".nanoteams/tasks/123/attachments/spec.pdf",
                                ".nanoteams/tasks/123/attachments/mock.png"
                            ]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            """
            Implement import flow
            
            ## Clipped Text
            Use the selected API response shape
            
            ## Attached Files
            - .nanoteams/tasks/123/attachments/spec.pdf
            - .nanoteams/tasks/123/attachments/mock.png
            """
        )
    }

    func testEffectiveSupervisorBrief_emptyGoalWithClippedTextOnly() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "",
                            clippedTexts: [Clip].minting(["Selected text from app"])
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            "## Clipped Text\nSelected text from app"
        )
    }

    func testEffectiveSupervisorBrief_emptyWhenAllInputsEmpty() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "")
        XCTAssertTrue(task.effectiveSupervisorBrief.isEmpty)
    }

    func testHasInitialInput_falseWithWhitespaceOnlyGoal() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "   \n\t")
        XCTAssertFalse(task.hasInitialInput)
    }

    func testHasInitialInput_trueWithAllInputs() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "Goal",
                            clippedTexts: [Clip].minting(["clip"]),
                            attachmentPaths: ["file.txt"]
        )
        XCTAssertTrue(task.hasInitialInput)
    }

    func testEffectiveSupervisorBrief_attachmentsOnly() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "",
                            attachmentPaths: [".nanoteams/tasks/1/attachments/spec.pdf"]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            "## Attached Files\n- .nanoteams/tasks/1/attachments/spec.pdf"
        )
    }

    func testEffectiveSupervisorBrief_goalAndAttachments_noClip() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "Build feature",
                            attachmentPaths: ["file.pdf"]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            "Build feature\n\n## Attached Files\n- file.pdf"
        )
    }

    func testEffectiveSupervisorBrief_whitespaceClippedText_ignored() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "Goal",
                            clippedTexts: [Clip].minting(["   \n\t"])
        )

        XCTAssertEqual(task.effectiveSupervisorBrief, "Goal")
    }

    func testDecodingMissingQuickCaptureFields_defaultsCleanly() throws {
        let json = """
        {
          "id": 0,
          "title": "Test",
          "supervisorTask": "Goal"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(NTMSTask.self, from: json)

        XCTAssertTrue(task.clippedTexts.isEmpty)
        XCTAssertTrue(task.attachmentPaths.isEmpty)
    }

    func testDecodingLegacyClippedText_migratesCorrectly() throws {
        let json = """
        {
          "id": 0,
          "title": "Test",
          "supervisorTask": "Goal",
          "clippedText": "legacy clip value"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(NTMSTask.self, from: json)

        XCTAssertEqual(task.clippedTexts.texts, ["legacy clip value"])
    }

    func testDecodingLegacyClippedTextNull_migratesEmpty() throws {
        let json = """
        {
          "id": 0,
          "title": "Test",
          "supervisorTask": "Goal",
          "clippedText": null
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(NTMSTask.self, from: json)

        XCTAssertTrue(task.clippedTexts.isEmpty)
    }

    func testEffectiveSupervisorBrief_multipleClips() {
        let task = NTMSTask(id: 0, title: "Test",
                            supervisorTask: "Goal",
                            clippedTexts: [Clip].minting(["First clip", "Second clip"])
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            """
            Goal
            
            ## Clipped Text \u{2014} 1 of 2
            First clip
            
            ## Clipped Text \u{2014} 2 of 2
            Second clip
            """
        )
    }

    // MARK: - TaskStatus Display Labels

    func testTaskStatusDisplayLabels() {
        XCTAssertEqual(TaskStatus.running.displayLabel, "Working")
        XCTAssertEqual(TaskStatus.done.displayLabel, "Done")
        XCTAssertEqual(TaskStatus.paused.displayLabel, "Paused")
        XCTAssertEqual(TaskStatus.waiting.displayLabel, "Waiting")
        XCTAssertEqual(TaskStatus.needsSupervisorInput.displayLabel, "Needs Supervisor")
        XCTAssertEqual(TaskStatus.needsSupervisorAcceptance.displayLabel, "Review")
        XCTAssertEqual(TaskStatus.failed.displayLabel, "Failed")
    }
}
