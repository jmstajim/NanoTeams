import XCTest
@testable import NanoTeams

/// Service-layer tests for the three Pause-and-Decide follow-up handlers
/// (`handleCancelDelegation` / `handleResumeDelegation` / `handleForwardToTeam`).
/// These complement `DelegationFollowupToolsTests` (which exercises the
/// thin signal-emitting tool handlers) by verifying the actual
/// orchestration: validation against `activeDelegationChildID`, engine
/// stop/resume calls, envelope shapes.
///
/// Hallucination guard is the security boundary here — without strict
/// child-id validation the LLM could pass any integer and stop unrelated
/// running tasks. Each handler validates that
/// `delegate.activeDelegationChildID(taskID:roleID:) == childTaskID` and
/// returns `INVALID_ARGS` on mismatch.
@MainActor
final class DelegationFollowupHandlersTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - cancel_delegation

    func testHandleCancelDelegation_mismatchedChildID_rejectsAsInvalidArgs() async {
        service._testRegisterStepTask(stepID: "coding_agent", taskID: 1)
        delegate.activeDelegationChildStub["1:coding_agent"] = 7  // real child

        // LLM passes a different (hallucinated) child id
        let envelope = await service.handleCancelDelegation(
            stepID: "coding_agent",
            taskID: 1,
            childTaskID: 999,
            reason: "stop"
        )

        XCTAssertTrue(envelope.contains("INVALID_ARGS"),
                      "Mismatched child_task_id must surface as INVALID_ARGS, not silently stop the wrong task; got envelope: \(envelope)")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "Mismatched cancel must NOT call stopEngineForTask — that would tear down a child the role didn't actually delegate to")
    }

    func testHandleCancelDelegation_matchingChildID_callsStopEngine() async {
        service._testRegisterStepTask(stepID: "coding_agent", taskID: 1)
        delegate.activeDelegationChildStub["1:coding_agent"] = 7

        let envelope = await service.handleCancelDelegation(
            stepID: "coding_agent",
            taskID: 1,
            childTaskID: 7,
            reason: "looping"
        )

        XCTAssertFalse(envelope.contains("INVALID_ARGS"),
                       "Matching child id must succeed; got envelope: \(envelope)")
        XCTAssertEqual(delegate.stopEngineCalls, [7],
                       "stopEngineForTask must be called with the validated child id")
        XCTAssertTrue(envelope.contains("\"status\":\"cancelled\"") || envelope.contains("\"status\" : \"cancelled\""),
                      "Envelope must mark cancellation status so the role's LLM picks the right next-step branch")
    }

    func testHandleCancelDelegation_noStepRegistered_rejects() async {
        // No execution state exists for this (taskID, stepID): the `isExecutionLive`
        // barrier rejects with the "no task context" envelope before any delegation
        // validation runs — an orphaned/hallucinated cancel must never stop an engine.
        let envelope = await service.handleCancelDelegation(
            stepID: "ghost_step",
            taskID: 1,
            childTaskID: 7,
            reason: nil
        )
        XCTAssertTrue(envelope.contains("no task context"),
                      "Unregistered (taskID, stepID) must be rejected by the liveness barrier; got envelope: \(envelope)")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "Unknown step/task context must NOT stop any engine")
    }

    func testHandleCancelDelegation_noActiveDelegation_rejects() async {
        service._testRegisterStepTask(stepID: "coding_agent", taskID: 1)
        // No `activeDelegationChildStub` entry — role has no in-flight delegation
        let envelope = await service.handleCancelDelegation(
            stepID: "coding_agent",
            taskID: 1,
            childTaskID: 7,
            reason: nil
        )
        XCTAssertTrue(envelope.contains("INVALID_ARGS"),
                      "Cancelling without an active delegation must not silently stopEngine on the passed id")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty)
    }

    // MARK: - resume_delegation

    func testHandleResumeDelegation_mismatchedChildID_rejectsAsInvalidArgs() async {
        service._testRegisterStepTask(stepID: "coding_agent", taskID: 1)
        delegate.activeDelegationChildStub["1:coding_agent"] = 7

        let envelope = await service.handleResumeDelegation(
            stepID: "coding_agent",
            childTaskID: 999,
            initiatingRole: .codingAgent,
            task: makeTask(taskID: 1),
            client: StubLLMClient(),
            config: stubConfig()
        )

        XCTAssertTrue(envelope.contains("INVALID_ARGS"))
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty,
                      "Mismatched resume must NOT call resumeRun — the wrong child engine would be unpaused")
    }

    // MARK: - forward_to_team

    func testHandleForwardToTeam_mismatchedChildID_rejectsAsInvalidArgs() async {
        service._testRegisterStepTask(stepID: "coding_agent", taskID: 1)
        delegate.activeDelegationChildStub["1:coding_agent"] = 7

        let envelope = await service.handleForwardToTeam(
            stepID: "coding_agent",
            childTaskID: 999,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeTask(taskID: 1),
            client: StubLLMClient(),
            config: stubConfig()
        )

        XCTAssertTrue(envelope.contains("INVALID_ARGS"))
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty,
                      "Mismatched forward must NOT inject the message into an unrelated child team")
    }

    // MARK: - Helpers

    private func makeTask(taskID: Int) -> NTMSTask {
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "x")
        task.runs = [Run(id: 0, steps: [
            StepExecution(id: "coding_agent", role: .codingAgent, title: "Step")
        ])]
        return task
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost",
            modelName: "stub",
            temperature: nil
        )
    }

    private final class StubLLMClient: LLMClient, @unchecked Sendable {
        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
