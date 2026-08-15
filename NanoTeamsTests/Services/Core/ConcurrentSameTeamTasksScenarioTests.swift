import XCTest

@testable import NanoTeams

/// End-to-end reproduction of the June 10 2026 production incident, as observed
/// by the user and confirmed by the diagnostic trace (`/tmp/nanoteams_status_trace.log`):
///
/// Two tasks on the SAME Startup team — "Phase 39" actively streaming (Thinking /
/// Processing visible), then the user starts "Phase 40". Trace timeline:
///
///     21:20:09.557  ENGINE task=39 state=running
///     21:20:09.717  EXEC   start step=startup_software_engineer task=39
///     21:20:12.883  ORCH   commit-stream task=39 step=startup_software_engineer
///     21:20:13.167  EXEC   end   step=startup_software_engineer task=39 via=cancelStep  ← THE KILL
///     21:20:13.216  ENGINE task=40 state=running
///     21:20:13.658  EXEC   start step=startup_software_engineer task=40
///
/// Starting task 40 cancelled task 39's live execution through the SHARED stepID
/// (`StepExecution.id` = Startup SWE role id) — task 39 became a zombie: sidebar
/// "Working", step `.running`, no LLM behind it, Thinking/Processing indicator gone
/// forever. These tests drive the REAL orchestrator + engine + streaming pipeline
/// through that exact sequence and assert task 39's survival.
@MainActor
final class ConcurrentSameTeamTasksScenarioTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var startupTeamID: NTMSID!
    private var sweRoleID: String!

    override func tearDown() async throws {
        startupTeamID = nil
        sweRoleID = nil
        try await super.tearDown()
    }

    /// Opens the work folder, activates the bundled Startup team (the team from the
    /// incident), and resolves its Software Engineer role id — the shared stepID.
    private func activateStartupTeam() async throws {
        await sut.openWorkFolder(tempDir)
        let startup = try XCTUnwrap(
            sut.snapshot?.projection.teams.first(where: { $0.name == "Startup" }),
            "Bundled Startup team must exist after bootstrap")
        let swe = try XCTUnwrap(
            startup.roles.first(where: {
                $0.dependencies.producesArtifacts.contains("Engineering Notes")
            }),
            "Startup team must have its Software Engineer role")
        startupTeamID = startup.id
        sweRoleID = swe.id
        await sut.mutateWorkFolder { projection in
            projection.setActiveTeam(startup.id)
        }
    }

    /// Seeds a task in the exact state task 39 was in: latest run with the SWE step
    /// `.running`, a live executionStates entry, and REAL streaming-indicator state
    /// in the orchestrator's `StreamingPreviewManager`.
    private func seedStreamingTask(title: String) async throws -> (taskID: Int, runningTask: Task<Void, Never>, messageID: UUID) {
        let created = await sut.createTask(title: title, supervisorTask: "Goal")
        let taskID = try XCTUnwrap(created)
        let stepID = sweRoleID!
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: [StepExecution(id: stepID, role: .softwareEngineer, title: "Implementation", status: .running)],
                roleStatuses: [stepID: .working]
            )
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        let runningTask = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(120))
        }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: stepID, taskID: taskID, runningTask: runningTask)

        // The live indicator exactly as the user saw it: streaming begun, thinking
        // flowing, activity flag set.
        let messageID = UUID()
        await sut.beginStreaming(stepID: stepID, taskID: taskID, messageID: messageID, role: .softwareEngineer)
        sut.appendStreamingThinking(stepID: stepID, taskID: taskID, content: "analyzing MainMenu.update() coordinates")
        sut.markStreamActivity(stepID: stepID, taskID: taskID)

        return (taskID, runningTask, messageID)
    }

    /// Polls until `condition` is true or the deadline passes.
    private func waitUntil(
        timeoutSeconds: Double = 10,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - The incident

    /// The user's exact action sequence: Phase 39 streaming → press Play on Phase 40
    /// (same team) → REAL `startRun` creates Phase 40's run and starts its engine,
    /// which executes `startStepExecution` on the SAME stepID. Phase 39 must keep
    /// its execution, its `.running` step, and its Thinking/Processing indicator.
    func testStartingPhase40_whilePhase39IsStreaming_keepsPhase39Alive() async throws {
        try await activateStartupTeam()
        // Titles mirror the incident: Phase 39 (Audio System) was the one streaming;
        // Phase 40 (Fix Menu) was the one the user started.
        let phase39 = try await seedStreamingTask(title: "Phase 39: Audio System Implementation")
        let createdPhase40 = await sut.createTask(
            title: "Phase 40: Fix Menu Button Click Detection", supervisorTask: "Fix menu")
        let phase40ID = try XCTUnwrap(createdPhase40)
        let stepID = sweRoleID!

        // THE user action: Play on the second same-team task. Real flow:
        // createNewRun (fresh run with the same SWE role id) + engine start +
        // engine-driven startStepExecution(stepID, taskID: phase40).
        await sut.startRun(taskID: phase40ID)

        // Phase 40's engine genuinely runs and registers its OWN execution on the
        // shared stepID — the collision is exercised for real, not simulated.
        await waitUntil {
            self.sut.llmExecutionService._testHasExecutionState(stepID: stepID, taskID: phase40ID)
        }
        XCTAssertTrue(
            sut.llmExecutionService._testHasExecutionState(stepID: stepID, taskID: phase40ID),
            "Precondition: Phase 40's engine must have started its own execution on the shared stepID")

        // ── The incident assertions ──────────────────────────────────────────
        // Pre-fix: at this point the trace showed `EXEC end task=39 via=cancelStep`
        // and Phase 39 never appeared in the log again.
        XCTAssertFalse(
            phase39.runningTask.isCancelled,
            "Phase 39's live LLM execution must NOT be cancelled by starting Phase 40 (the zombie-task kill)")
        XCTAssertTrue(
            sut.llmExecutionService._testHasExecutionState(stepID: stepID, taskID: phase39.taskID),
            "Phase 39's executionStates entry must survive Phase 40's start")

        // The user-visible symptom: the Thinking/Processing indicator. The bubble
        // reads exactly this snapshot — it must still show Phase 39 as generating.
        let snapshot = TeamActivityFeedView.makeStreamingSnapshot(
            manager: sut.streamingPreviewManager,
            messageID: phase39.messageID,
            stepID: stepID,
            taskID: phase39.taskID)
        XCTAssertTrue(snapshot.isStreaming, "Phase 39's bubble must still be streaming")
        XCTAssertTrue(
            snapshot.hasStreamActivity,
            "Phase 39's Thinking/Processing indicator must not disappear when Phase 40 starts")
        XCTAssertEqual(snapshot.thinking, "analyzing MainMenu.update() coordinates")

        // No zombie: the step the engine believes is working still has its backing
        // execution (pre-fix the step stayed `.running` with nothing behind it).
        let step39 = sut.loadedTask(phase39.taskID)?.runs.last?.steps.first(where: { $0.id == stepID })
        XCTAssertEqual(step39?.status, .running)
        XCTAssertTrue(
            sut.llmExecutionService.isStepRunning(stepID: stepID, taskID: phase39.taskID),
            "Phase 39's step must still have a live runningTask — 'Working' in the sidebar must not be a lie")

        // Cleanup: stop Phase 40's engine (it is retrying against a dead LLM server)
        // and Phase 39's injected stream.
        await sut.pauseRun(taskID: phase40ID)
        phase39.runningTask.cancel()
        await sut.pauseRun(taskID: phase39.taskID)
    }

    /// The second half of what the user watched: BOTH tasks streaming at once
    /// (Phase 39 and Phase 40 each showing live Thinking). Drives two REAL
    /// concurrent `performStreamingCall`s on the same stepID through the real
    /// orchestrator delegate + real `StreamingPreviewManager`, with the second
    /// stream committing while the first is still mid-flight — each task's content
    /// must land in its OWN conversation and the in-flight indicator must survive
    /// the other task's commit.
    func testBothTasksStreamingSimultaneously_indicatorsAndContentStayPerTask() async throws {
        try await activateStartupTeam()
        let stepID = sweRoleID!

        func seedTask(title: String) async throws -> Int {
            let created = await sut.createTask(title: title, supervisorTask: "Goal")
            let id = try XCTUnwrap(created)
            await sut.mutateTask(taskID: id) { task in
                var run = Run(
                    id: 0,
                    steps: [StepExecution(id: stepID, role: .softwareEngineer, title: "Impl", status: .running)],
                    roleStatuses: [stepID: .working]
                )
                run.updatedAt = MonotonicClock.shared.now()
                task.runs = [run]
            }
            sut.llmExecutionService._testRegisterStepTask(stepID: stepID, taskID: id)
            return id
        }

        let taskA = try await seedTask(title: "Phase 39")
        let taskB = try await seedTask(title: "Phase 40")

        let gateA = AsyncGate()
        let gateB = AsyncGate()
        let config = LLMConfig(
            provider: .lmStudio, baseURLString: "http://localhost",
            modelName: "stub")
        let service = sut.llmExecutionService

        let streamA = Task { @MainActor in
            try await service.performStreamingCall(
                stepID: stepID, taskID: taskA, roleForMessage: .softwareEngineer,
                client: GatedClient(gate: gateA, content: "alpha: phase 39 engineering notes"),
                config: config, tools: [], conversationMessages: [], networkLogger: nil)
        }
        await waitUntil { self.sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: stepID, taskID: taskA) }

        let streamB = Task { @MainActor in
            try await service.performStreamingCall(
                stepID: stepID, taskID: taskB, roleForMessage: .softwareEngineer,
                client: GatedClient(gate: gateB, content: "bravo: phase 40 audio system"),
                config: config, tools: [], conversationMessages: [], networkLogger: nil)
        }
        await waitUntil { self.sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: stepID, taskID: taskB) }

        // Both indicators live at once — what the user saw before one vanished.
        XCTAssertTrue(sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: stepID, taskID: taskA))
        XCTAssertTrue(sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: stepID, taskID: taskB))

        // Task B finishes its turn FIRST (the trace's interleaved commit order).
        gateB.open()
        _ = try await streamB.value

        XCTAssertTrue(
            sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: stepID, taskID: taskA),
            "Phase 40's commit must not wipe Phase 39's in-flight indicator (the reported symptom)")
        XCTAssertFalse(
            sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: stepID, taskID: taskB),
            "Phase 40's own indicator clears on its commit")

        gateA.open()
        _ = try await streamA.value

        // Each task's content landed in its OWN conversation — no cross-pollination.
        let convA = sut.loadedTask(taskA)?.runs.last?.steps.first?.llmConversation.map(\.content).joined() ?? ""
        let convB = sut.loadedTask(taskB)?.runs.last?.steps.first?.llmConversation.map(\.content).joined() ?? ""
        XCTAssertTrue(convA.contains("alpha: phase 39"), "Phase 39 must receive its own content; got: \(convA)")
        XCTAssertFalse(convA.contains("bravo"), "Phase 40's content must not leak into Phase 39")
        XCTAssertTrue(convB.contains("bravo: phase 40"), "Phase 40 must receive its own content; got: \(convB)")
        XCTAssertFalse(convB.contains("alpha"), "Phase 39's content must not leak into Phase 40")
    }

    // MARK: - Scripted streaming helpers

    /// Resumable gate: the scripted stream yields its delta, suspends until the
    /// test releases it, then finishes normally (a clean end-of-turn commit).
    @MainActor
    final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class GatedClient: LLMClient, @unchecked Sendable {
        let gate: AsyncGate
        let content: String
        init(gate: AsyncGate, content: String) {
            self.gate = gate
            self.content = content
        }
        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let gate = gate
            let content = content
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(StreamEvent(contentDelta: content))
                    await gate.wait()
                    continuation.finish()
                }
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
