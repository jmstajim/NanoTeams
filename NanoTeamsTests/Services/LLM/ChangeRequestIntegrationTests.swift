import XCTest

@testable import NanoTeams

/// Integration tests for the `request_changes` LLM tool flow.
///
/// Covers:
/// - `executeAmendment`: snapshot artifacts, record amendment, inject context, set revisionRequested
/// - `propagateAmendmentDownstream`: downstream done roles get revisionRequested, working roles get context
/// - `recordChangeRequest`: upsert behavior (insert new, update existing)
@MainActor
final class ChangeRequestIntegrationTests: XCTestCase {

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

    // MARK: - executeAmendment Tests

    func testExecuteAmendment_setsRevisionRequested() async {
        let (task, team) = makeTaskWithDoneStep()
        let targetRoleID = "engineer"
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: task.runs[0].steps[0].id, taskID: task.id)

        _ = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: targetRoleID,
            changes: "Add error handling",
            reasoning: "Missing null checks",
            requestingRoleID: "code_reviewer",
            meetingID: nil,
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].roleStatuses[targetRoleID], .revisionRequested,
                       "Target role should be set to revisionRequested")
    }

    func testExecuteAmendment_recordsAmendment() async {
        let (task, team) = makeTaskWithDoneStep()
        let targetRoleID = "engineer"
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: task.runs[0].steps[0].id, taskID: task.id)

        _ = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: targetRoleID,
            changes: "Add error handling",
            reasoning: "Missing null checks",
            requestingRoleID: "code_reviewer",
            meetingID: UUID(),
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        let step = updated.runs[0].steps[0]
        XCTAssertEqual(step.amendments.count, 1, "Should record an amendment")
        XCTAssertEqual(step.amendments[0].requestedByRoleID, "code_reviewer")
        XCTAssertEqual(step.amendments[0].reason, "Add error handling")
    }

    func testExecuteAmendment_injectsContextMessage() async {
        let (task, team) = makeTaskWithDoneStep()
        let targetRoleID = "engineer"
        let originalMessageCount = task.runs[0].steps[0].messages.count
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: task.runs[0].steps[0].id, taskID: task.id)

        _ = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: targetRoleID,
            changes: "Add error handling",
            reasoning: "Missing null checks",
            requestingRoleID: "code_reviewer",
            meetingID: nil,
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        let step = updated.runs[0].steps[0]
        XCTAssertGreaterThan(step.messages.count, originalMessageCount,
                             "Should inject amendment context message")

        let lastMessage = step.messages.last!
        XCTAssertEqual(lastMessage.role, .supervisor)
        XCTAssertTrue(lastMessage.content.contains("AMENDMENT REQUEST"))
        XCTAssertTrue(lastMessage.content.contains("Add error handling"))
    }

    func testExecuteAmendment_snapshotsArtifacts() async {
        let (task, team) = makeTaskWithDoneStep()
        let targetRoleID = "engineer"
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: task.runs[0].steps[0].id, taskID: task.id)

        _ = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: targetRoleID,
            changes: "Refactor code",
            reasoning: "Code quality",
            requestingRoleID: "code_reviewer",
            meetingID: nil,
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        let amendment = updated.runs[0].steps[0].amendments[0]
        XCTAssertEqual(amendment.previousArtifactSnapshots.count, 1,
                       "Should snapshot existing artifacts")
        XCTAssertEqual(amendment.previousArtifactSnapshots[0].artifactName, "Engineering Notes")
    }

    func testExecuteAmendment_failsWhenStepNotFound() async {
        // Task with no steps matching target role
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let step = StepExecution(
            id: "pm",
            role: .productManager,
            title: "PM",
            status: .done
        )
        task.runs = [Run(id: 0, steps: [step])]
        mockDelegate.taskToMutate = task

        let result = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: "nonexistent_role",
            changes: "Changes",
            reasoning: "Reason",
            requestingRoleID: "reviewer",
            meetingID: nil,
            team: nil
        )

        XCTAssertTrue(result.contains("failed"), "Should return failure message when target step not found")
    }

    // MARK: - propagateAmendmentDownstream Tests

    func testPropagateDownstream_amendsCompletedDownstreamRoles() async {
        let (task, team) = makeTaskWithDownstreamRoles()
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        // code_reviewer depends on engineer's artifacts → should be set to revisionRequested
        XCTAssertEqual(updated.runs[0].roleStatuses["code_reviewer"], .revisionRequested,
                       "Done downstream role should be set to revisionRequested")
        XCTAssertTrue(result.contains("Downstream amendments triggered"))
    }

    func testPropagateDownstream_injectsContextForWorkingRoles() async {
        let (task, team) = makeTaskWithDownstreamRoles(codeReviewerStatus: .running, codeReviewerRoleStatus: .working)
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        let crStep = updated.runs[0].steps.first(where: { $0.effectiveRoleID == "code_reviewer" })!
        XCTAssertFalse(crStep.messages.isEmpty, "Working role should get context message injected")
        // Working roles get a "NOTE:" context injection (not "UPSTREAM AMENDMENT NOTICE" which is for done roles)
        XCTAssertTrue(crStep.messages.last!.content.contains("Upstream role"))
        XCTAssertTrue(crStep.messages.last!.content.contains("Updated implementation"))
        XCTAssertTrue(result.contains("Context injected"))
    }

    func testPropagateDownstream_noActionForIdleRoles() async {
        let (task, team) = makeTaskWithDownstreamRoles(codeReviewerStatus: .pending, codeReviewerRoleStatus: .idle)
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        // Idle role should not be touched
        XCTAssertEqual(updated.runs[0].roleStatuses["code_reviewer"], .idle)
        XCTAssertTrue(result.contains("No downstream roles needed updates"))
    }

    func testPropagateDownstream_noDownstreamRoles() async {
        // Use a team where engineer has no downstream consumers
        let team = makeMinimalTeam(withDownstream: false)
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer",
            status: .done
        )
        task.runs = [Run(id: 0, steps: [step])]
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Changes",
            team: team
        )

        XCTAssertTrue(result.contains("No downstream roles affected"))
    }

    // MARK: - recordChangeRequest Tests

    func testRecordChangeRequest_appendsNew() async {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [Run(id: 0, steps: [])]
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: "test_step", taskID: task.id)

        let cr = ChangeRequest(
            requestingRoleID: "code_reviewer",
            targetRoleID: "engineer",
            changes: "Add tests",
            reasoning: "Coverage low",
            status: .approved
        )
        await service.recordChangeRequest(taskID: task.id, changeRequest: cr)

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].changeRequests.count, 1)
        XCTAssertEqual(updated.runs[0].changeRequests[0].changes, "Add tests")
    }

    func testRecordChangeRequest_upsertsExisting() async {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        var existingCR = ChangeRequest(
            requestingRoleID: "code_reviewer",
            targetRoleID: "engineer",
            changes: "Original changes",
            reasoning: "Original reason",
            status: .pending
        )
        var run = Run(id: 0, steps: [])
        run.changeRequests = [existingCR]
        task.runs = [run]
        mockDelegate.taskToMutate = task

        // Update the same CR (same id)
        existingCR.status = .approved
        existingCR.changes = "Updated changes"
        await service.recordChangeRequest(taskID: task.id, changeRequest: existingCR)

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].changeRequests.count, 1, "Should update in place, not append")
        XCTAssertEqual(updated.runs[0].changeRequests[0].status, .approved)
        XCTAssertEqual(updated.runs[0].changeRequests[0].changes, "Updated changes")
    }

    // MARK: - Helpers

    /// Creates a task with a single done step for the "engineer" role, with an artifact.
    private func makeTaskWithDoneStep() -> (NTMSTask, Team) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build feature")
        let artifact = Artifact(
            name: "Engineering Notes",
            mimeType: "text/markdown",
            relativePath: "steps/test/engineering_notes.md"
        )
        let step = StepExecution(
            id: "engineer",
            role: .softwareEngineer,
            title: "Software Engineer",
            expectedArtifacts: ["Engineering Notes"],
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            artifacts: [artifact]
        )
        var run = Run(id: 0, steps: [step])
        run.roleStatuses["engineer"] = .done
        task.runs = [run]

        let team = makeMinimalTeam(withDownstream: true)
        return (task, team)
    }

    /// Creates a task with an engineer step (done) and a code_reviewer step (configurable status).
    private func makeTaskWithDownstreamRoles(
        codeReviewerStatus: StepStatus = .done,
        codeReviewerRoleStatus: RoleExecutionStatus = .done
    ) -> (NTMSTask, Team) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build feature")

        let engArtifact = Artifact(
            name: "Engineering Notes",
            mimeType: "text/markdown",
            relativePath: "steps/test/engineering_notes.md"
        )
        let engStep = StepExecution(
            id: "engineer",
            role: .softwareEngineer,
            title: "Engineer",
            expectedArtifacts: ["Engineering Notes"],
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            artifacts: [engArtifact]
        )

        let crStep = StepExecution(
            id: "code_reviewer",
            role: .codeReviewer,
            title: "Code Reviewer",
            expectedArtifacts: ["Code Review"],
            status: codeReviewerStatus,
            completedAt: codeReviewerStatus == .done ? MonotonicClock.shared.now() : nil
        )

        var run = Run(id: 0, steps: [engStep, crStep])
        run.roleStatuses["engineer"] = .done
        run.roleStatuses["code_reviewer"] = codeReviewerRoleStatus
        task.runs = [run]

        let team = makeMinimalTeam(withDownstream: true)
        return (task, team)
    }

    /// Creates a minimal team with engineer and optionally code_reviewer as downstream.
    private func makeMinimalTeam(withDownstream: Bool) -> Team {
        var roles: [TeamRoleDefinition] = []

        let engineerRole = TeamRoleDefinition(
            id: "engineer",
            name: "Software Engineer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Engineering Notes"]
            ),
            llmOverride: nil,
            isSystemRole: true,
            systemRoleID: Role.softwareEngineer.baseID,
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )
        roles.append(engineerRole)

        if withDownstream {
            let crRole = TeamRoleDefinition(
                id: "code_reviewer",
                name: "Code Reviewer",
                prompt: "",
                toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: ["Engineering Notes"],
                    producesArtifacts: ["Code Review"]
                ),
                llmOverride: nil,
                isSystemRole: true,
                systemRoleID: Role.codeReviewer.baseID,
                createdAt: Date(),
                updatedAt: Date()
            )
            roles.append(crRole)
        }

        return Team(
            name: "Test Team",
            roles: roles,
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout()
        )
    }
}
