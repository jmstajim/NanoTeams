import XCTest

@testable import NanoTeams

/// The Supervisor-facing action behind the composer's fill indicator.
///
/// Its job is routing plus honesty: pick the mechanism that matches the step's state, and when
/// neither applies, SAY so. A click that quietly does nothing is the failure mode the whole
/// indicator exists to remove — the user's alternative today is restarting the role and losing
/// everything.
@MainActor
final class CompactRoleContextTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let roleID = "engineer"
    private var taskID = 0
    private var summaryClient: OrchestratorSummaryClient!

    override func setUp() async throws {
        try await super.setUp()
        // Rebuilt through the factory (never a bare `NTMSOrchestrator(`) with a step-execution
        // client that ANSWERS: the base's stub is an unreachable server, and the suspended
        // epoch is the one route here that actually opens a request.
        summaryClient = OrchestratorSummaryClient()
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient,
            stepExecutionClient: summaryClient)
        await sut.openWorkFolder(tempDir)
        taskID = await sut.createTask(title: "T", supervisorTask: "brief") ?? -1
        await registerRoles([roleID], onTeamOf: taskID)
    }

    override func tearDown() async throws {
        summaryClient = nil
        try await super.tearDown()
    }

    /// Installs a step for `roleID` in the task's latest run, in the given state.
    private func seedStep(status: StepStatus, wire: [ChatMessage] = []) async {
        await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution(id: self.roleID, role: .softwareEngineer, title: "work")
            step.status = status
            step.wireTranscript = wire
            // A task created but never started has no run yet, and every read path here goes
            // through `runs.last` — so the fixture supplies one rather than silently seeding
            // nothing and leaving the assertions to fail for the wrong reason.
            if let runIndex = task.runs.indices.last {
                task.runs[runIndex].steps = [step]
            } else {
                var run = Run(id: 0, teamID: NTMSID.from(name: "Team"))
                run.steps = [step]
                task.runs = [run]
            }
        }
    }

    /// No step for that role at all — a role that has never run.
    func testUnknownRole_refusesWithAReason() async {
        await seedStep(status: .needsSupervisorInput)
        sut.lastInfoMessage = nil
        let did = await sut.compactRoleContext(taskID: taskID, roleID: "nobody")
        XCTAssertFalse(did)
        XCTAssertNotNil(sut.lastInfoMessage)
    }

    /// A RUNNING step is armed rather than compacted on the spot: replacing the wire is only
    /// safe at the top of an iteration, never between a tool call and its results.
    func testRunningStep_isArmedForItsNextIteration() async {
        await seedStep(status: .running)
        sut.llmExecutionService._testInjectRunningTask(
            stepID: roleID, taskID: taskID,
            runningTask: Task { try? await Task.sleep(for: .seconds(60)) })

        let did = await sut.compactRoleContext(taskID: taskID, roleID: roleID)
        XCTAssertTrue(did)
        XCTAssertEqual(
            sut.llmExecutionService._testCompactRequested(stepID: roleID, taskID: taskID),
            .manual)
        XCTAssertNotNil(sut.lastInfoMessage, "the user is told the fold is queued, not done")
        sut.llmExecutionService.cancelExecutions(forTaskID: taskID)
    }

    /// A second click while an epoch is in flight must not open a second summary against the
    /// same wire — the two would race to write it.
    func testAlreadyCompacting_isRefused() async {
        await seedStep(status: .needsSupervisorInput, wire: [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: "work"),
        ])
        sut.llmExecutionService._testRegisterStepTask(stepID: roleID, taskID: taskID)
        sut.llmExecutionService._testSetCompactionEpochToken(stepID: roleID, taskID: taskID)

        sut.lastInfoMessage = nil
        let did = await sut.compactRoleContext(taskID: taskID, roleID: roleID)
        XCTAssertFalse(did)
        XCTAssertEqual(sut.lastInfoMessage, "This role is already compacting.")
    }

    /// A step in a status no epoch is defined for — `.done` — is refused with a reason rather
    /// than silently.
    func testFinishedStep_refusesWithAReason() async {
        await seedStep(status: .done, wire: [ChatMessage(role: .system, content: "sys")])
        sut.lastInfoMessage = nil
        let did = await sut.compactRoleContext(taskID: taskID, roleID: roleID)
        XCTAssertFalse(did)
        XCTAssertNotNil(sut.lastInfoMessage)
    }

    /// The projection is what the indicator reads, and it must not be left marked after a
    /// refused click — a stuck mark disables the control permanently.
    func testARefusedClick_leavesNoCompactingMark() async {
        await seedStep(status: .done)
        _ = await sut.compactRoleContext(taskID: taskID, roleID: roleID)
        XCTAssertFalse(sut.contextFill.isCompacting(stepID: roleID, taskID: taskID))
    }

    /// The success path, end to end through the router: a PARKED step has no loop, so the
    /// epoch runs on the spot, the wire is replaced with its head plus one seed, and the caller
    /// is told an epoch happened — which is what lets the indicator stop drawing the old
    /// number.
    func testParkedStep_isCompactedOnTheSpot() async {
        await seedStep(status: .needsSupervisorInput, wire: foldableWire())

        let did = await sut.compactRoleContext(taskID: taskID, roleID: roleID)

        XCTAssertTrue(did)
        let wire = sut.loadedTask(taskID)?.runs.last?.steps.first?.wireTranscript ?? []
        XCTAssertTrue(
            wire.contains { CompactionPolicy.isCompactionSeed($0) },
            "the epoch must have left its seed on the wire")
        XCTAssertLessThan(wire.count, foldableWire().count)
        XCTAssertFalse(
            sut.contextFill.isCompacting(stepID: roleID, taskID: taskID),
            "and the mark must be lowered when it finishes")
    }

    /// Long enough to have something after its pinned head — two turns the epoch may fold.
    private func foldableWire() -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: "You are an engineer."),
            ChatMessage(role: .user, content: "## Supervisor Task\nBuild it."),
            ChatMessage(role: .assistant, content: "Reading."),
            ChatMessage(role: .tool, content: #"{"ok":true}"#),
            ChatMessage(role: .assistant, content: "Read it."),
        ]
    }

    /// A `restartRole` destroys the transcript the fill measured, so the indicator must stop
    /// showing that conversation's occupancy rather than keeping a number about nothing.
    func testRestartRole_dropsTheStepsFill() async {
        await seedStep(status: .needsSupervisorInput)
        sut.contextFill.update(
            stepID: roleID, taskID: taskID,
            fill: ContextFill(promptTokens: 4200, window: 8192, budget: 2048))
        XCTAssertNotNil(sut.contextFill.fill(stepID: roleID, taskID: taskID))

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: nil)
        XCTAssertNil(sut.contextFill.fill(stepID: roleID, taskID: taskID))
    }
}

// MARK: - Scripted client

/// Answers the one request this suite opens — the compaction summary. The orchestrator's
/// factory stub is an unreachable server, which every other test here wants and this one
/// cannot use.
private final class OrchestratorSummaryClient: LLMClient, @unchecked Sendable {

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: "Read the parser; nothing written yet."))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelContextLength(config _: LLMConfig) async -> Int? { 8192 }
}
