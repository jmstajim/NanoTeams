import XCTest

@testable import NanoTeams

/// E2E tests for the full Supervisor acceptance flow:
/// acceptance modes → role transitions → closeTask → task done.
@MainActor
final class EndToEndSupervisorAcceptanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: finalOnly — all done → needsSupervisorAcceptance

    func testFinalOnly_allDone_needsSupervisorAcceptance() {
        let task = makeTaskWithAllRolesDone(acceptanceMode: .finalOnly)

        // Derived status should be needsSupervisorAcceptance when all roles done + closedAt nil
        XCTAssertNil(task.closedAt)
        // All steps should be done
        let allDone = task.runs.last?.steps.allSatisfy { $0.status == .done } ?? false
        XCTAssertTrue(allDone)
    }

    // MARK: - Test 2: closeTask transitions to done

    func testCloseTask_transitionsToDone() {
        var task = makeTaskWithAllRolesDone(acceptanceMode: .finalOnly)

        // Close the task
        task.closedAt = MonotonicClock.shared.now()
        task.status = .done

        XCTAssertNotNil(task.closedAt, "closedAt should be set")
        XCTAssertEqual(task.status, .done, "Task should be .done after close")
    }

    // MARK: - Test 3: afterEachRole — sequential acceptance check

    func testAfterEachRole_shouldRequestAcceptance() {
        // In afterEachRole mode, every role should request acceptance
        let shouldAcceptFirst = AcceptanceService.shouldRequestAcceptance(
            roleID: "pm-role",
            mode: .afterEachRole,
            checkpoints: []
        )
        XCTAssertTrue(shouldAcceptFirst, "afterEachRole: non-last role should need acceptance")

        let shouldAcceptLast = AcceptanceService.shouldRequestAcceptance(
            roleID: "tpm-role",
            mode: .afterEachRole,
            checkpoints: []
        )
        XCTAssertTrue(shouldAcceptLast, "afterEachRole: last role should also need acceptance")
    }

    // MARK: - Test 4: Revision preserves artifacts and sets revisionComment

    func testRevision_preservesArtifactsAndSetsRevisionComment() {
        var task = makeTaskWithDoneStep()
        let stepID = task.runs[0].steps[0].id

        // Add supervisor feedback
        task.runs[0].steps[0].messages.append(
            StepMessage(role: .supervisor, content: "Please add error handling")
        )

        // Simulate resetStepForRevision (preserves everything, sets revisionComment)
        let feedback = task.runs[0].steps[0].messages.last(where: { $0.role == .supervisor })?.content
            ?? "Revise"
        task.runs[0].steps[0].status = .pending
        task.runs[0].steps[0].completedAt = nil
        task.runs[0].steps[0].revisionComment = feedback
        task.runs[0].steps[0].updatedAt = MonotonicClock.shared.now()

        let revised = task.runs[0].steps[0]
        XCTAssertEqual(revised.status, .pending)
        XCTAssertFalse(revised.artifacts.isEmpty, "Artifacts should be preserved during revision")
        XCTAssertEqual(revised.revisionComment, "Please add error handling")
        XCTAssertNotNil(revised.artifacts.first(where: { $0.name == "Engineering Notes" }),
                        "Original artifact should be kept")
    }

    // MARK: - Test 5: Restart role clears closedAt

    func testRestartRole_clearsClosedAt() {
        var task = makeTaskWithAllRolesDone(acceptanceMode: .finalOnly)
        task.closedAt = MonotonicClock.shared.now()
        task.status = .done

        XCTAssertNotNil(task.closedAt)

        // Simulate restart role — clears closedAt
        task.closedAt = nil
        task.status = .running

        XCTAssertNil(task.closedAt, "closedAt should be cleared on restart")
        XCTAssertEqual(task.status, .running)
    }

    // MARK: - Test 6: customCheckpoints selective acceptance

    func testCustomCheckpoints_selectiveAcceptance() {
        let checkpoints: Set<String> = ["reviewer-role"]

        // Non-checkpoint, non-last role — should NOT need acceptance
        let pmNeedsAcceptance = AcceptanceService.shouldRequestAcceptance(
            roleID: "pm-role",
            mode: .customCheckpoints,
            checkpoints: checkpoints
        )
        XCTAssertFalse(pmNeedsAcceptance, "Non-checkpoint role should not need acceptance")

        // Checkpoint role — should need acceptance
        let reviewerNeedsAcceptance = AcceptanceService.shouldRequestAcceptance(
            roleID: "reviewer-role",
            mode: .customCheckpoints,
            checkpoints: checkpoints
        )
        XCTAssertTrue(reviewerNeedsAcceptance, "Checkpoint role should need acceptance")

        // Last role, not a checkpoint — NOT gated (only selected checkpoints gate; the
        // final deliverable is covered by the task-level final review)
        let lastNeedsAcceptance = AcceptanceService.shouldRequestAcceptance(
            roleID: "tpm-role",
            mode: .customCheckpoints,
            checkpoints: checkpoints
        )
        XCTAssertFalse(lastNeedsAcceptance, "Last role should NOT be auto-gated in customCheckpoints")
    }

    // MARK: - Test 7: finalOnly — non-last role should NOT need acceptance

    func testFinalOnly_nonLastRole_noAcceptance() {
        let shouldAccept = AcceptanceService.shouldRequestAcceptance(
            roleID: "pm-role",
            mode: .finalOnly,
            checkpoints: []
        )
        XCTAssertFalse(shouldAccept, "finalOnly: non-last role should not need acceptance")
    }

    // MARK: - Test 8: Validate acceptance — only needsAcceptance is valid

    func testValidateAcceptance_onlyNeedsAcceptanceIsValid() {
        let statuses: [String: RoleExecutionStatus] = [
            "role-1": .needsAcceptance,
            "role-2": .working,
            "role-3": .done,
        ]

        XCTAssertNil(AcceptanceService.validateAcceptance(roleID: "role-1", roleStatuses: statuses),
                     "needsAcceptance should be valid for acceptance")
        XCTAssertNotNil(AcceptanceService.validateAcceptance(roleID: "role-2", roleStatuses: statuses),
                        "working should not be valid for acceptance")
        XCTAssertNotNil(AcceptanceService.validateAcceptance(roleID: "role-3", roleStatuses: statuses),
                        "done should not be valid for acceptance")
    }

    // MARK: - Test 9: finalOnly all-roles-done surfaces ONLY the task-level final review

    /// Pins the user-facing symptom: in finalOnly, once every role is `.done` there must be
    /// NO per-role acceptance card (so the activity feed / Watchtower don't show "Review <role>"),
    /// and the task must derive to `.needsSupervisorAcceptance` so the final-review window shows.
    func testFinalOnly_allRolesDone_onlyFinalReviewSurfaces() {
        let task = makeTaskWithAllRolesDone(acceptanceMode: .finalOnly)

        // No role is `.needsAcceptance` → no per-role acceptance card on any surface.
        XCTAssertTrue(task.runs.last!.rolesNeedingAcceptance(definitions: []).isEmpty,
                      "finalOnly: no role should be awaiting per-role acceptance")
        // The final-review window IS available (all roles complete).
        XCTAssertTrue(task.isReadyForFinalAcceptance,
                      "finalOnly: task should be ready for the task-level final review")
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance,
                       "finalOnly: task derives to Review once all roles are done")
    }

    // MARK: - Test 10: derivation corner cases (Review vs Ready-for-final vs Working)

    /// All steps .done but ONE role still awaiting per-role acceptance (e.g. an afterEachRole
    /// intermediate) + the rest .done: the task DERIVES to Review (so the feed shows something),
    /// but it is NOT ready for the task-level final acceptance, and that one role surfaces as a
    /// per-role acceptance. This is the key distinction the fix preserves.
    func testDerivedStatus_oneRoleNeedsAcceptance_isReview_butNotReadyForFinal() {
        let task = makeTask(roleStatuses: ["a": .done, "b": .needsAcceptance, "c": .done])

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
        XCTAssertFalse(task.isReadyForFinalAcceptance,
                       "A pending per-role acceptance means NOT ready for task-level final review")
        let pending = task.runs.last!.rolesNeedingAcceptance(definitions: [])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.roleID, "b")
    }

    /// Degenerate: a run with all steps .done but EMPTY roleStatuses derives to Review (the
    /// "are all roles complete?" check is vacuously satisfied over an empty set).
    func testDerivedStatus_emptyRoleStatuses_allStepsDone_isReview() {
        let task = makeTask(roleStatuses: [:])

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
        XCTAssertTrue(task.isReadyForFinalAcceptance,
                      "No roles to wait on → vacuously ready for final review")
    }

    /// A Supervisor-closed task is terminal (.done) even if a role was left at .needsAcceptance
    /// and the step is .done — closing wins. It is no longer ready for final acceptance.
    func testDerivedStatus_closedTaskWithLeftoverNeedsAcceptance_isDone() {
        var task = makeTask(roleStatuses: ["a": .needsAcceptance])
        task.closedAt = MonotonicClock.shared.now()

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
        XCTAssertFalse(task.isReadyForFinalAcceptance, "A closed task is not awaiting final review")
    }

    /// All steps .done but a role status still lags at .working (the reconcile window): the task
    /// must read as Working, NOT prematurely as Review.
    func testDerivedStatus_allStepsDone_roleStillWorking_isRunning() {
        let task = makeTask(roleStatuses: ["a": .done, "b": .working])

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
        XCTAssertFalse(task.isReadyForFinalAcceptance)
    }

    /// Guard path: a task with no runs is never ready for final acceptance.
    func testIsReadyForFinalAcceptance_noRuns_false() {
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [])
        XCTAssertFalse(task.isReadyForFinalAcceptance)
    }

    // MARK: - Helpers

    /// Builds a non-chat task whose latest run has all-`.done` steps and the given role statuses.
    private func makeTask(roleStatuses: [String: RoleExecutionStatus]) -> NTMSTask {
        let step = StepExecution(
            id: "s0", role: .softwareEngineer, title: "S0",
            expectedArtifacts: [], status: .done, completedAt: MonotonicClock.shared.now(),
            artifacts: []
        )
        let run = Run(id: 0, steps: [step], roleStatuses: roleStatuses)
        return NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
    }

    private func makeTaskWithAllRolesDone(acceptanceMode: AcceptanceMode) -> NTMSTask {
        let step1 = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "Product Requirements",
            expectedArtifacts: ["Product Requirements"],
            status: .done, completedAt: MonotonicClock.shared.now(),
            artifacts: [Artifact(name: "Product Requirements")]
        )
        let step2 = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineering Notes",
            expectedArtifacts: ["Engineering Notes"],
            status: .done, completedAt: MonotonicClock.shared.now(),
            artifacts: [Artifact(name: "Engineering Notes")]
        )
        let run = Run(
            id: 0,
            steps: [step1, step2],
            roleStatuses: ["pm-role": .done, "swe-role": .done]
        )
        return NTMSTask(id: 0, title: "Test", supervisorTask: "Goal",
            runs: [run], acceptanceMode: acceptanceMode
        )
    }

    private func makeTaskWithDoneStep() -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineering Notes",
            expectedArtifacts: ["Engineering Notes"],
            status: .done, completedAt: MonotonicClock.shared.now(),
            artifacts: [Artifact(name: "Engineering Notes")]
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
    }
}
