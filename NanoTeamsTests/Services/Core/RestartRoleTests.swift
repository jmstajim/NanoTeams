import XCTest

@testable import NanoTeams

/// Tests for `restartRole()` — cascading role reset with automatic engine start.
/// Verifies step/role cleanup, downstream cascade, closedAt clearing, and engine creation.
@MainActor
final class RestartRoleTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    private func createTaskWithRun(
        steps: [StepExecution],
        roleStatuses: [String: RoleExecutionStatus]
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: steps,
                roleStatuses: roleStatuses
            )
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        return taskID
    }

    // MARK: - Basic Reset

    func testRestartRole_resetsStepAndRoleStatus() async {
        let roleID = "pm-123"
        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            messages: [StepMessage(role: .productManager, content: "Done")]
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.steps.first?.status, .pending)
        XCTAssertNil(run?.steps.first?.completedAt)
        XCTAssertEqual(run?.roleStatuses[roleID], .idle)
    }

    // MARK: - Step Data Cleanup

    func testRestartRole_clearsStepData() async {
        let roleID = "swe-456"
        let step = StepExecution(
            id: roleID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            messages: [StepMessage(role: .softwareEngineer, content: "Working")],
            artifacts: [Artifact(name: "Engineering Notes")],
            toolCalls: [StepToolCall(name: "read_file", argumentsJSON: "{}", resultJSON: "ok")],
            scratchpad: "Plan here",
            consultations: [],
            meetingIDs: [UUID()],
            llmConversation: [LLMMessage(role: .assistant, content: "Hello")]
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)

        let updatedStep = sut.activeTask?.runs.last?.steps.first
        XCTAssertTrue(updatedStep?.messages.isEmpty ?? false)
        XCTAssertTrue(updatedStep?.artifacts.isEmpty ?? false)
        XCTAssertTrue(updatedStep?.toolCalls.isEmpty ?? false)
        XCTAssertNil(updatedStep?.scratchpad)
        XCTAssertTrue(updatedStep?.consultations.isEmpty ?? false)
        XCTAssertTrue(updatedStep?.meetingIDs.isEmpty ?? false)
        XCTAssertTrue(updatedStep?.llmConversation.isEmpty ?? false)
        XCTAssertFalse(updatedStep?.needsSupervisorInput ?? true)
        XCTAssertNil(updatedStep?.supervisorQuestion)
        XCTAssertNil(updatedStep?.supervisorAnswer)
    }

    // MARK: - Supervisor Comment

    func testRestartRole_injectsSupervisorComment() async {
        let roleID = "pm-789"
        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: "Please redo with more detail")

        let messages = sut.activeTask?.runs.last?.steps.first?.messages ?? []
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.content.contains("Please redo with more detail") ?? false)
        XCTAssertEqual(messages.first?.role, .supervisor)
    }

    func testRestartRole_noCommentWhenNil() async {
        let roleID = "pm-nil"
        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)

        let messages = sut.activeTask?.runs.last?.steps.first?.messages ?? []
        XCTAssertTrue(messages.isEmpty)
    }

    func testRestartRole_noCommentWhenEmpty() async {
        let roleID = "pm-empty"
        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: "")

        let messages = sut.activeTask?.runs.last?.steps.first?.messages ?? []
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Downstream Cascade

    func testRestartRole_cascadesDownstream() async {
        let pmRoleID = "pm-cascade"
        let sweRoleID = "swe-cascade"

        // PM produces "Product Requirements", SWE requires it
        let pmStep = StepExecution(
            id: pmRoleID,
            role: .productManager,
            title: "PM Step",
            status: .done,
            artifacts: [Artifact(name: "Product Requirements")]
        )
        let sweStep = StepExecution(
            id: sweRoleID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            messages: [StepMessage(role: .softwareEngineer, content: "Code written")]
        )

        let taskID = await createTaskWithRun(
            steps: [pmStep, sweStep],
            roleStatuses: [pmRoleID: .done, sweRoleID: .done]
        )

        // Configure team so SWE depends on PM's artifact
        await sut.mutateWorkFolder { wf in
            guard let teamIdx = wf.teams.indices.first else { return }
            // Find or add PM role
            if let pmIdx = wf.teams[teamIdx].roles.firstIndex(where: { $0.id == pmRoleID }) {
                wf.teams[teamIdx].roles[pmIdx].dependencies.producesArtifacts = ["Product Requirements"]
            } else {
                var pmRole = TeamRoleDefinition(id: pmRoleID, name: "PM", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Product Requirements"]))
                wf.teams[teamIdx].roles.append(pmRole)
            }
            if let sweIdx = wf.teams[teamIdx].roles.firstIndex(where: { $0.id == sweRoleID }) {
                wf.teams[teamIdx].roles[sweIdx].dependencies.requiredArtifacts = ["Product Requirements"]
            } else {
                let sweRole = TeamRoleDefinition(id: sweRoleID, name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(requiredArtifacts: ["Product Requirements"], producesArtifacts: []))
                wf.teams[teamIdx].roles.append(sweRole)
            }
        }

        // Restart PM — should cascade to SWE
        await sut.restartRole(taskID: taskID, roleID: pmRoleID, comment: nil)

        let run = sut.activeTask?.runs.last
        XCTAssertEqual(run?.roleStatuses[pmRoleID], .idle, "Primary role should be reset")
        XCTAssertEqual(run?.roleStatuses[sweRoleID], .idle, "Downstream role should be reset")
        XCTAssertEqual(run?.steps.first(where: { $0.id == sweRoleID })?.status, .pending)
        XCTAssertTrue(run?.steps.first(where: { $0.id == sweRoleID })?.messages.isEmpty ?? false)
    }

    // MARK: - ClosedAt Clearing

    func testRestartRole_clearsClosedAt() async {
        let roleID = "pm-closed"
        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        // Simulate closed task
        await sut.mutateTask(taskID: taskID) { task in
            task.closedAt = MonotonicClock.shared.now()
        }
        XCTAssertNotNil(sut.activeTask?.closedAt, "Precondition: task should be closed")

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)

        XCTAssertNil(sut.activeTask?.closedAt, "closedAt should be cleared after restart")
    }

    // MARK: - Engine Creation

    func testRestartRole_createsEngineIfMissing() async {
        let roleID = "pm-engine"
        let step = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done
        )
        let taskID = await createTaskWithRun(
            steps: [step],
            roleStatuses: [roleID: .done]
        )

        // Verify no engine exists before restart
        XCTAssertNil(sut.taskEngineStates[taskID], "Precondition: no engine should exist")

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)

        // Engine should have been created and started
        let engineState = sut.taskEngineStates[taskID]
        XCTAssertNotNil(engineState, "Engine should exist after restart")
        // Engine starts as .running, but may quickly transition to .done if no roles are ready.
        // The key assertion is that it was created (not nil).
    }

    // MARK: - Comment Only On Primary Role

    func testRestartRole_commentOnlyOnPrimaryRole() async {
        let pmRoleID = "pm-comment"
        let sweRoleID = "swe-comment"

        let pmStep = StepExecution(
            id: pmRoleID,
            role: .productManager,
            title: "PM Step",
            status: .done
        )
        let sweStep = StepExecution(
            id: sweRoleID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done
        )

        let taskID = await createTaskWithRun(
            steps: [pmStep, sweStep],
            roleStatuses: [pmRoleID: .done, sweRoleID: .done]
        )

        // Configure dependency so SWE depends on PM
        await sut.mutateWorkFolder { wf in
            guard let teamIdx = wf.teams.indices.first else { return }
            let pmRole = TeamRoleDefinition(id: pmRoleID, name: "PM", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Product Requirements"]))
            wf.teams[teamIdx].roles.append(pmRole)
            let sweRole = TeamRoleDefinition(id: sweRoleID, name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(requiredArtifacts: ["Product Requirements"], producesArtifacts: []))
            wf.teams[teamIdx].roles.append(sweRole)
        }

        await sut.restartRole(taskID: taskID, roleID: pmRoleID, comment: "Redo please")

        let run = sut.activeTask?.runs.last
        let pmMessages = run?.steps.first(where: { $0.id == pmRoleID })?.messages ?? []
        let sweMessages = run?.steps.first(where: { $0.id == sweRoleID })?.messages ?? []

        XCTAssertEqual(pmMessages.count, 1, "Primary role should have Supervisor comment")
        XCTAssertTrue(sweMessages.isEmpty, "Downstream role should NOT have Supervisor comment")
    }

    // MARK: - Queued-message preservation through restart

    /// Regression guard for the "restartRole preserves queue" invariant
    /// (plan §7a). `step.reset()` clears `llmSessionID`, so the injection
    /// hook's `iterationNumber > 1 || session == nil` guard is satisfied on
    /// iteration 1 of the restarted step, and the queued message delivers
    /// there. Must not be "fixed" by adding role-level queue cleanup.
    func testRestartRole_preservesQueuedMessages_deliversOnRestart() async {
        let formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState

        let roleID = "pm-queue-survives"
        let doneStep = StepExecution(
            id: roleID,
            role: .productManager,
            title: "PM Step",
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            llmConversation: [LLMMessage(role: .assistant, content: "finished")],
            llmSessionID: "stale-session"
        )
        let taskID = await createTaskWithRun(
            steps: [doneStep],
            roleStatuses: [roleID: .done]
        )

        // Queue a message AFTER the role is already done.
        let queued = QuickCaptureFormState.QueuedChatMessage(
            text: "доложи статус",
            attachments: [],
            clippedTexts: [],
            targetRoleID: roleID
        )!
        formState.appendQueuedMessage(queued, for: taskID)

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)

        // Queue must survive the restart.
        XCTAssertEqual(formState.queuedMessages(for: taskID).count, 1,
                       "restartRole must NOT clear the queue — it's the survival vehicle for post-restart delivery")
        // Reset cleared the stale session so iteration 1 of the restarted step
        // will pass the injection hook's `session == nil` guard.
        let step = sut.activeTask?.runs.last?.steps.first(where: { $0.id == roleID })
        XCTAssertNil(step?.llmSessionID, "reset() must null llmSessionID so the next run starts stateless")
        XCTAssertEqual(step?.status, .pending)

        // Simulate iteration-1 of the restarted step calling through the delegate.
        // Real production path is the same method, so this assertion pins end-to-end delivery.
        let prompt = await sut.consumeQueuedSupervisorMessage(
            taskID: taskID, roleID: roleID, stepID: roleID
        )
        XCTAssertEqual(prompt, "Supervisor:\nдоложи статус",
                       "Message must deliver on the restarted step with the Supervisor: attribution header")
        XCTAssertFalse(formState.hasQueuedMessage(for: taskID),
                       "Queue drained after successful delivery")
    }
}
