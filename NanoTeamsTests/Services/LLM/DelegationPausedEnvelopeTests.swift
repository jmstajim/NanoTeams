import XCTest
@testable import NanoTeams

/// Pins the wire contract of the `paused_by_supervisor` envelope produced
/// by `awaitDelegationCompletion` on a `parentMessageQueued` outcome and
/// verifies the message-injection path used by `forward_to_team`.
///
/// The envelope is what the LLM sees when its `delegate_to_team` /
/// `resume_delegation` / `forward_to_team` call returns from a Supervisor
/// interrupt. It must carry a stable shape so the model can branch on
/// `status: "paused_by_supervisor"` and reach for the right follow-up tool.
@MainActor
final class DelegationPausedEnvelopeTests: XCTestCase {

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

    // MARK: - Paused envelope JSON shape

    func testPausedEnvelope_carriesStatus_childTaskID_team_andMessage() throws {
        let envelope = service._testBuildPausedEnvelope(
            childTID: 42,
            targetTeamName: "Engineering Team",
            supervisorMessage: "team is looping, stop"
        )

        let dict = try parseJSON(envelope)
        XCTAssertEqual(dict["ok"] as? Bool, true,
                       "Paused envelope must be ok:true so the LLM doesn't treat it as a runtime failure — pause is a normal control-flow signal")
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["status"] as? String, "paused_by_supervisor",
                       "Status string is the LLM's branch key — drift here breaks every Coding Agent prompt that switches on it")
        XCTAssertEqual(data["child_task_id"] as? Int, 42,
                       "child_task_id must be the integer the LLM passes back into cancel/resume/forward")
        XCTAssertEqual(data["team"] as? String, "Engineering Team")
        XCTAssertEqual(data["supervisor_message"] as? String, "team is looping, stop",
                       "Supervisor message must round-trip verbatim — the role's LLM reads it to decide cancel vs forward vs resume")
        let nextActions = try XCTUnwrap(data["next_actions"] as? String)
        XCTAssertTrue(nextActions.contains("cancel_delegation"))
        XCTAssertTrue(nextActions.contains("resume_delegation"))
        XCTAssertTrue(nextActions.contains("forward_to_team"))
    }

    /// When the auto-detection path fires with no human message, the
    /// supervisor_message text comes from `MessageRepetitionDetector`'s
    /// diagnostic. Empty trimmed message must omit the field entirely
    /// rather than embedding an empty string (saves tokens, avoids the
    /// LLM treating "" as meaningful guidance).
    func testPausedEnvelope_emptySupervisorMessage_omitsField() throws {
        let envelope = service._testBuildPausedEnvelope(
            childTID: 7,
            targetTeamName: "X",
            supervisorMessage: ""
        )
        let dict = try parseJSON(envelope)
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertNil(data["supervisor_message"],
                     "Empty supervisor_message must be omitted, not sent as empty string")
    }

    // MARK: - Forwarded message injection

    /// `forward_to_team` injects a `Supervisor:`-prefixed `LLMMessage`
    /// into the working step's `llmConversation` on the child task. Pin
    /// the exact shape: role=.user, sourceRole=.supervisor,
    /// sourceContext=.supervisorMessage, prefix attached. Without these
    /// fields the child team's tool loop would either miss the message
    /// (no role match) or render it under wrong attribution.
    func testInjectForwardedMessageIntoChild_landsOnRunningStep_withProperShape() async {
        // Configure the mock to respond to mutateTask by mutating an
        // in-memory child task that has a .running step.
        var childTask = NTMSTask(id: 99, title: "Child", supervisorTask: "x")
        childTask.runs = [Run(id: 0, steps: [
            StepExecution(id: "child_engineer", role: .softwareEngineer, title: "Engineer", status: .running)
        ])]
        delegate.taskToMutate = childTask

        let injected = await service._testInjectForwardedMessageIntoChild(
            childTaskID: 99,
            message: "use library X instead",
            delegate: delegate
        )
        XCTAssertTrue(injected,
                      "Injection must report success when the child has a working step")

        // The mock applies `mutateTask` mutations onto its `taskToMutate`
        // field — verify the resulting child task carries the new LLMMessage.
        let mutatedChild = delegate.taskToMutate
        let conversation = mutatedChild?.runs.last?.steps.first?.llmConversation ?? []
        XCTAssertEqual(conversation.count, 1,
                       "Exactly one supervisor turn must be appended")
        let msg = conversation.first
        XCTAssertEqual(msg?.role, .user,
                       "Injected message MUST use .user role — chat-protocol invariant; .supervisor isn't a wire role")
        XCTAssertEqual(msg?.sourceRole, .supervisor,
                       "sourceRole must mark provenance for activity feed attribution")
        XCTAssertEqual(msg?.sourceContext, .supervisorMessage,
                       "sourceContext.supervisorMessage triggers the bubble's strip-prefix display branch")
        XCTAssertTrue(msg?.content.hasPrefix(MessageSourceContext.supervisorMessagePrefix) ?? false,
                      "Content MUST start with the canonical Supervisor: prefix so the child role's LLM identifies the speaker when the turn lands in a combined input string")
        XCTAssertTrue(msg?.content.contains("use library X instead") ?? false,
                      "Original message text must be preserved after the prefix")
    }

    func testInjectForwardedMessageIntoChild_noWorkingStep_returnsFalse() async {
        // Child task with no run → nothing to inject onto.
        var childTask = NTMSTask(id: 100, title: "Empty", supervisorTask: "x")
        childTask.runs = []
        delegate.taskToMutate = childTask

        let injected = await service._testInjectForwardedMessageIntoChild(
            childTaskID: 100,
            message: "anything",
            delegate: delegate
        )
        XCTAssertFalse(injected,
                       "Injection must report failure when there's no eligible step — caller surfaces COMMAND_FAILED to the parent role")
    }

    // MARK: - Integration: awaitDelegationCompletion → parentMessageQueued

    /// End-to-end of the Pause-and-Decide entry flow: handler is suspended
    /// on the awaiter, mock delivers `.parentMessageQueued("...")`, handler
    /// MUST pause the child engine (not stop), preserve delegation fields,
    /// and return a `paused_by_supervisor` envelope. This is the contract
    /// `cancel_delegation` / `resume_delegation` / `forward_to_team` rely
    /// on for re-entry.
    func testAwaitDelegationCompletion_parentMessageQueued_pausesAndReturnsPausedEnvelope() async throws {
        let parentRoleDef = TeamRoleDefinition(
            id: "coding_agent_coding_agent",
            name: "Coding Agent",
            prompt: "p",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
        let parentTeam = Team(
            name: "Parent", roles: [parentRoleDef], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let targetTeam = Team(
            name: "Engineering Team", roles: [], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )

        // Script the awaiter to deliver a parentMessageQueued on first call.
        delegate.scriptedAwaitOutcomes = [
            .parentMessageQueued(text: "team is looping, stop")
        ]

        let envelope = await service.awaitDelegationCompletion(
            childTID: 42,
            parentTID: 1,
            stepID: "coding_agent_coding_agent",
            parentRoleDef: parentRoleDef,
            parentTeam: parentTeam,
            targetTeam: targetTeam,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: StubLLMClient(),
            config: stubConfig(),
            delegate: delegate
        )

        // Pause-and-decide invariants:
        XCTAssertEqual(delegate.pauseRunCalls, [42],
                       "pauseRun MUST be called on the child task (not stopEngine — that would tear down the engine the role might want to resume)")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "stopEngine MUST NOT be called on parentMessageQueued — that's the reverted hard-stop semantics; current contract is pause-and-decide")

        // Envelope shape matches paused_by_supervisor.
        let dict = try parseJSON(envelope)
        XCTAssertEqual(dict["ok"] as? Bool, true)
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["status"] as? String, "paused_by_supervisor")
        XCTAssertEqual(data["child_task_id"] as? Int, 42)
        XCTAssertEqual(data["team"] as? String, "Engineering Team")
        XCTAssertEqual(data["supervisor_message"] as? String, "team is looping, stop")
    }

    // MARK: - Helpers

    private func parseJSON(_ s: String) throws -> [String: Any] {
        let data = Data(s.utf8)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(any as? [String: Any])
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
            AsyncThrowingStream { continuation in continuation.finish() }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
