import XCTest

@testable import NanoTeams

/// E2E tests for the full step lifecycle: create → setup → tool loop → completion.
/// Validates the integration between StepExecutionService, LLMExecutionService+StepCompletion,
/// and artifact completeness checking.
@MainActor
final class EndToEndStepLifecycleTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        mockDelegate = nil
        service = nil
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Basic happy path pending → running → done

    func testStepLifecycle_pendingToRunningToDone() async {
        // Create a task with a pending step
        var task = makeTaskWithStep(
            role: .softwareEngineer,
            expectedArtifacts: ["Engineering Notes"],
            status: .pending
        )
        let stepID = task.runs[0].steps[0].id
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Step 1: Prepare — should inject supervisor comment if prior step exists
        StepExecutionService.prepareStepForExecution(stepID: stepID, in: &task)
        XCTAssertEqual(task.runs[0].steps[0].status, .pending, "prepareStepForExecution doesn't change status")

        // Step 2: Mark running
        StepExecutionService.markStepRunning(stepID: stepID, in: &task)
        XCTAssertEqual(task.runs[0].steps[0].status, .running)

        // Step 3: Simulate artifact creation (the step gets artifact)
        task.runs[0].steps[0].artifacts = [Artifact(name: "Engineering Notes")]
        mockDelegate.taskToMutate = task

        // Step 4: Check completeness — should detect all artifacts present
        let stop = service.checkArtifactCompleteness(stepID: stepID)
        XCTAssertNotNil(stop, "Should detect artifact completeness")

        // Step 5: Complete step
        await service.completeStepSuccess(stepID: stepID)
        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, .done)
        XCTAssertNotNil(updated.completedAt)
    }

    // MARK: - Test 2: Producing role auto-completes when all artifacts present

    func testStepLifecycle_producingRole_autoCompletesWhenAllArtifacts() {
        var task = makeTaskWithStep(
            role: .productManager,
            expectedArtifacts: ["Product Requirements", "Acceptance Criteria"],
            status: .running
        )
        let stepID = task.runs[0].steps[0].id
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Only one artifact — not complete yet
        task.runs[0].steps[0].artifacts = [Artifact(name: "Product Requirements")]
        mockDelegate.taskToMutate = task

        XCTAssertNil(service.checkArtifactCompleteness(stepID: stepID),
                     "Should NOT complete with partial artifacts")

        // Add second artifact — now complete
        task.runs[0].steps[0].artifacts.append(Artifact(name: "Acceptance Criteria"))
        mockDelegate.taskToMutate = task

        XCTAssertNotNil(service.checkArtifactCompleteness(stepID: stepID),
                        "Should complete when all artifacts present")
    }

    // MARK: - Test 3: Producing role retries when artifacts missing (handleNoToolCalls)

    func testStepLifecycle_producingRole_retriesWhenArtifactsMissing() async {
        var task = makeTaskWithStep(
            role: .productManager,
            expectedArtifacts: ["Product Requirements"],
            status: .running
        )
        let stepID = task.runs[0].steps[0].id
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
        mockDelegate.taskToMutate = task

        // Verify that checkArtifactCompleteness returns nil when no artifacts present
        mockDelegate.taskToMutate = task
        let stop = service.checkArtifactCompleteness(stepID: stepID)
        XCTAssertNil(stop, "Should NOT complete when artifacts are missing")

        // The role has expected artifacts but none created — this triggers retry
        // in handleNoToolCalls. Verify the step is NOT artifact-complete.
        XCTAssertFalse(task.runs[0].steps[0].isArtifactComplete,
                       "Step should not be artifact-complete with missing artifacts")
    }

    // MARK: - Test 4: Advisory role never auto-completes

    func testStepLifecycle_advisoryRole_neverAutoCompletes() {
        // Advisory role: has required artifacts but no produced artifacts
        var task = makeTaskWithStep(
            role: .codeReviewer,
            expectedArtifacts: [], // Advisory — no expected artifacts
            status: .running
        )
        let stepID = task.runs[0].steps[0].id
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
        mockDelegate.taskToMutate = task

        // Even with no expected artifacts, isArtifactComplete returns false
        XCTAssertFalse(task.runs[0].steps[0].isArtifactComplete,
                       "Advisory step with no expected artifacts should not be artifact-complete")

        // checkArtifactCompleteness returns nil for advisory roles
        let stop = service.checkArtifactCompleteness(stepID: stepID)
        XCTAssertNil(stop, "Advisory role should never auto-complete via artifact check")
    }

    // MARK: - Test 5: Completion is idempotent

    func testStepLifecycle_completionIsIdempotent() async {
        var task = makeTaskWithStep(
            role: .softwareEngineer,
            expectedArtifacts: ["Engineering Notes"],
            status: .running
        )
        let stepID = task.runs[0].steps[0].id
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
        mockDelegate.taskToMutate = task

        // Complete once
        await service.completeStepSuccess(stepID: stepID)
        let firstCompletedAt = mockDelegate.taskToMutate!.runs[0].steps[0].completedAt
        XCTAssertNotNil(firstCompletedAt)

        // Complete again — status remains .done, completedAt unchanged
        await service.completeStepSuccess(stepID: stepID)
        let secondStatus = mockDelegate.taskToMutate!.runs[0].steps[0].status
        XCTAssertEqual(secondStatus, .done, "Status should remain .done after second completion")
    }

    // MARK: - Test 6: Revision blocks auto-completion on stale artifacts

    func testStepLifecycle_revisionBlocksAutoCompletion() {
        var task = makeTaskWithStep(
            role: .productManager,
            expectedArtifacts: ["Product Requirements"],
            status: .running
        )
        let stepID = task.runs[0].steps[0].id
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Add artifact (from prior execution)
        task.runs[0].steps[0].artifacts = [Artifact(name: "Product Requirements")]
        // Set revisionComment — indicates revision mode
        task.runs[0].steps[0].revisionComment = "Add more detail to section 3"
        mockDelegate.taskToMutate = task

        // checkArtifactCompleteness should return nil during revision
        // (old artifacts are stale, waiting for LLM to create updated ones)
        let stop = service.checkArtifactCompleteness(stepID: stepID)
        XCTAssertNil(stop, "Should NOT auto-complete during revision (stale artifacts)")

        // Clear revisionComment (simulates LLM creating a new artifact)
        task.runs[0].steps[0].revisionComment = nil
        mockDelegate.taskToMutate = task

        // Now completeness should work again
        let stopAfterClear = service.checkArtifactCompleteness(stepID: stepID)
        XCTAssertNotNil(stopAfterClear, "Should auto-complete after revisionComment cleared")
    }

    // MARK: - Helpers

    private func makeTaskWithStep(
        role: Role,
        expectedArtifacts: [String],
        status: StepStatus
    ) -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: role,
            title: expectedArtifacts.isEmpty ? "work" : expectedArtifacts.joined(separator: ", "),
            expectedArtifacts: expectedArtifacts,
            status: status
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build something", runs: [run])
    }
}
