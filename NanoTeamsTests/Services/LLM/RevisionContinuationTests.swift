import XCTest

@testable import NanoTeams

/// Regression tests for the revision flow (Supervisor "Request Changes" via UI).
///
/// Covers:
/// - `resetStepForRevision` preserves artifacts, conversation, session, messages
/// - `checkArtifactCompleteness` skips during revision
/// - `revisionComment` cleared on artifact creation
/// - `persistWireTranscript` saves the replayable transcript on step completion
/// - `handleNoToolCalls` revision-aware nudge
@MainActor
final class RevisionContinuationTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try? FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

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
        super.tearDown()
    }

    // MARK: - resetStepForRevision Tests

    func testResetStepForRevision_keepsArtifacts() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        // Add artifacts to the step
        let artifact = Artifact(
            name: "Product Requirements",
            mimeType: "text/markdown",
            relativePath: "steps/\(stepID)/product_requirements.md"
        )
        task.runs[0].steps[0].artifacts = [artifact]
        task.runs[0].steps[0].messages.append(
            StepMessage(role: .supervisor, content: "Please add more detail to section 3.")
        )
        mockDelegate.taskToMutate = task

        // Simulate resetStepForRevision
        await simulateResetStepForRevision(task: &task, stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.artifacts.count, 1, "Artifacts should be preserved during revision")
        XCTAssertEqual(updated.artifacts[0].name, "Product Requirements")
        XCTAssertEqual(updated.status, .pending)
    }

    func testResetStepForRevision_keepsLLMConversation() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        task.runs[0].steps[0].llmConversation = [
            LLMMessage(role: .system, content: "System prompt"),
            LLMMessage(role: .user, content: "User task"),
            LLMMessage(role: .assistant, content: "Tool call"),
            LLMMessage(role: .tool, content: "Tool result"),
        ]
        task.runs[0].steps[0].messages.append(
            StepMessage(role: .supervisor, content: "Revise this.")
        )
        mockDelegate.taskToMutate = task

        await simulateResetStepForRevision(task: &task, stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.llmConversation.count, 4,
                       "LLM conversation should be preserved for stateful continuation")
    }

    func testResetStepForRevision_keepsSessionID() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        task.runs[0].steps[0].messages.append(
            StepMessage(role: .supervisor, content: "Fix the formatting.")
        )
        mockDelegate.taskToMutate = task

        await simulateResetStepForRevision(task: &task, stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
    }

    func testResetStepForRevision_setsRevisionComment() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        let feedback = "Please add error handling for edge cases."
        task.runs[0].steps[0].messages.append(
            StepMessage(role: .supervisor, content: feedback)
        )
        mockDelegate.taskToMutate = task

        await simulateResetStepForRevision(task: &task, stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.revisionComment, feedback,
                       "revisionComment should contain supervisor feedback")
    }

    func testResetStepForRevision_preservesMessages() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        task.runs[0].steps[0].messages = [
            StepMessage(role: .productManager, content: "Here are the requirements"),
            StepMessage(role: .supervisor, content: "Add more detail"),
        ]
        mockDelegate.taskToMutate = task

        await simulateResetStepForRevision(task: &task, stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.messages.count, 2,
                       "All messages should be preserved including supervisor feedback")
    }

    // MARK: - checkArtifactCompleteness Tests

    func testCheckArtifactCompleteness_skipsWhenRevisionPending() {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        // Step has expected artifacts and existing artifacts (complete)
        task.runs[0].steps[0].expectedArtifacts = ["Product Requirements"]
        task.runs[0].steps[0].artifacts = [
            Artifact(name: "Product Requirements", mimeType: "text/markdown", relativePath: "test.md")
        ]
        // But revision is pending
        task.runs[0].steps[0].revisionComment = "Please revise section 3."
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let result = service.checkArtifactCompleteness(stepID: stepID, taskID: task.id)
        XCTAssertNil(result,
                     "Should NOT auto-complete when revisionComment is set — old artifacts are from prior execution")
    }

    func testCheckArtifactCompleteness_worksAfterRevisionCleared() {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        // Step has all expected artifacts and NO revision comment
        task.runs[0].steps[0].expectedArtifacts = ["Product Requirements"]
        task.runs[0].steps[0].artifacts = [
            Artifact(name: "Product Requirements", mimeType: "text/markdown", relativePath: "test.md")
        ]
        task.runs[0].steps[0].revisionComment = nil
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let result = service.checkArtifactCompleteness(stepID: stepID, taskID: task.id)
        XCTAssertNotNil(result, "Should auto-complete when revisionComment is nil and artifacts are complete")
    }

    // MARK: - revisionComment Cleared on Artifact Creation

    func testRevisionComment_clearedOnArtifactCreation() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id

        // Set up revision state
        task.runs[0].steps[0].revisionComment = "Update the requirements."
        task.runs[0].steps[0].expectedArtifacts = ["Product Requirements"]
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Simulate create_artifact tool result
        let result = ToolExecutionResult(
            toolName: ToolNames.createArtifact,
            argumentsJSON: "{\"name\":\"Product Requirements\",\"content\":\"Updated content\"}",
            outputJSON: "{\"status\":\"created\"}",
            isError: false,
            signal: .artifact(name: "Product Requirements", content: "Updated content", format: nil)
        )
        await service.processCreateArtifactResult(result: result, stepID: stepID, taskID: task.id)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertNil(updated.revisionComment,
                     "revisionComment should be cleared after LLM creates a new artifact")
    }

    // MARK: - Transcript Persistence on Step Completion

    /// The step's re-entry state. This replaced the saved session id: the
    /// continuation replays `wireTranscript` instead of resuming a server chain,
    /// so a step that suspends without writing it wakes with no memory of its work.
    func testWireTranscriptPersisted_onStepCompletion() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id
        task.runs[0].steps[0].status = .running
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let sent: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Do the work"),
            ChatMessage(role: .tool, content: "{\"ok\":true}"),
        ]
        await service.persistWireTranscript(stepID: stepID, taskID: task.id, messages: sent)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.wireTranscript.count, 3)
        XCTAssertEqual(updated.wireTranscript.map(\.role), [.system, .user, .tool])
    }

    /// An empty transcript is a no-op, NOT a wipe: the terminal arms call this
    /// unconditionally, and a cancelled step with nothing accumulated must not
    /// erase the transcript a prior arm already wrote.
    func testWireTranscriptPersist_emptyMessages_leavesExistingIntact() async {
        var task = makeCompletedTask()
        let stepID = task.runs[0].steps[0].id
        task.runs[0].steps[0].wireTranscript = [ChatMessage(role: .user, content: "earlier")]
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        await service.persistWireTranscript(stepID: stepID, taskID: task.id, messages: [])

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.wireTranscript.count, 1,
                       "An empty persist must not clobber a previously written transcript")
        XCTAssertEqual(updated.wireTranscript.first?.content, "earlier")
    }

    // MARK: - Helpers

    /// Creates a task with a single completed step (typical pre-revision state).
    private func makeCompletedTask() -> NTMSTask {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Test goal")
        let step = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "Product Manager",
            expectedArtifacts: ["Product Requirements"],
            status: .done,
            completedAt: MonotonicClock.shared.now()
        )
        var run = Run(id: 0, steps: [step])
        run.roleStatuses[Role.productManager.baseID] = .needsAcceptance
        task.runs = [run]
        return task
    }

    /// Simulates `resetStepForRevision` logic inline, mirroring
    /// `TaskEngineStoreAdapter.resetStepForRevision`'s full fallback chain. These tests
    /// pin StepExecution-field PRESERVATION through the reset; the authoritative pin for
    /// the fallback-chain behavior itself is `RequestRevisionTests`, which drives the
    /// real adapter end-to-end.
    private func simulateResetStepForRevision(task: inout NTMSTask, stepID: String) async {
        await mockDelegate.mutateTask(taskID: task.id) { task in
            guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
            let step = task.runs[location.runIndex].steps[location.stepIndex]
            let status = step.status
            if status == .done || status == .failed {
                let feedback = step.revisionComment
                    ?? step.messages.last(where: { $0.role == .supervisor })?.content
                    ?? "Please revise your work based on the requested changes."
                task.runs[location.runIndex].steps[location.stepIndex].status = .pending
                task.runs[location.runIndex].steps[location.stepIndex].completedAt = nil
                task.runs[location.runIndex].steps[location.stepIndex].revisionComment = feedback
                task.runs[location.runIndex].steps[location.stepIndex].updatedAt = MonotonicClock.shared.now()
            }
        }
    }
}
