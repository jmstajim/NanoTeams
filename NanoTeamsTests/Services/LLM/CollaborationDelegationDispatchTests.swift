import XCTest

@testable import NanoTeams

/// The three delegation arms of `appendCollaborationResult`'s dispatch switch —
/// `delegate_to_team`, `resume_delegation`, `forward_to_team` — had never been
/// dispatched under test (only `cancel_delegation` had). The switch is the seam
/// where a signal's payload is unpacked and handed to its handler, so an arm that
/// passes the wrong associated value, or reflects the wrong way, is invisible to
/// handler-level tests.
///
/// Every case here drives a REJECTION: the handlers' happy paths block on a child
/// engine, which does not exist in a delegate mock. Rejections are the right
/// subject anyway — the reflect contract for delegation is asymmetric (failure
/// flips the card red, success leaves the placeholder for the graph layers), and
/// only the failure half is observable on the card.
@MainActor
final class CollaborationDelegationDispatchTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let stepID = "agent_step"
    private let taskID = 91

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - delegate_to_team

    /// A role whose team cannot be resolved must get a typed failure envelope on
    /// BOTH surfaces — the model's tool result and the red card — never a blank
    /// result or a green "pending" placeholder left behind.
    func testDelegateToTeam_unresolvableTeam_reflectsFailureOnCardAndWire() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.delegateToTeam)
        // No snapshot ⇒ `resolveTeam` returns nil ⇒ "Could not resolve parent team."

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .delegateToTeam(teamID: "some-team", taskBrief: "do the thing"),
            toolName: ToolNames.delegateToTeam, toolCallID: toolCallID,
            conversation: &conversation)

        let card = reflectedCard(toolCallID)
        XCTAssertEqual(card?.isError, true,
                       "a delegation that never launched must flip the card red")
        XCTAssertTrue(card?.resultJSON?.contains(#""ok":false"#) ?? false,
                      "got: \(card?.resultJSON ?? "nil")")
        XCTAssertFalse(card?.resultJSON?.contains("pending") ?? true,
                       "the synchronous placeholder must be replaced")

        XCTAssertEqual(conversation.count, 1, "exactly one tool result per tool call (chain protocol)")
        XCTAssertEqual(conversation.first?.role, .tool)
        XCTAssertEqual(conversation.first?.toolCallID, "tc_1",
                       "the tool result must resolve the assistant's tool_call by its provider id")
        XCTAssertEqual(conversation.first?.content, card?.resultJSON,
                       "the model and the card must see the SAME envelope — no double-wrapping")
    }

    /// Eligibility is a policy rejection, not an argument error: the envelope must
    /// carry `DELEGATION_DENIED` so `ToolErrorNotePolicy.direction` steers the model away
    /// from retrying rather than toward fixing its arguments.
    func testDelegateToTeam_nonPeerRole_isDeniedNotInvalidArgs() async {
        let toolCallID = UUID()
        let team = makeTeamWithSubordinateDelegator()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.delegateToTeam, team: team)

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .delegateToTeam(teamID: "target", taskBrief: "brief"),
            toolName: ToolNames.delegateToTeam, toolCallID: toolCallID,
            roleForMessage: .codingAgent, conversation: &conversation)

        let envelope = conversation.first?.content ?? ""
        XCTAssertTrue(envelope.contains(ToolErrorCode.delegationDenied.rawValue),
                      "a hierarchy rejection is a policy denial; got: \(envelope)")
        XCTAssertEqual(reflectedCard(toolCallID)?.isError, true)
    }

    // MARK: - resume_delegation

    /// The follow-up handlers validate the child id against the role's ACTUAL
    /// in-flight delegation — a hallucinated id must be rejected as `INVALID_ARGS`
    /// (fix the id) rather than acted on, which would resume an unrelated task.
    func testResumeDelegation_wrongChildID_isRejectedAsInvalidArgs() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.resumeDelegation)
        mockDelegate.activeDelegationChildStub["\(taskID):\(stepID)"] = 500

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .resumeDelegation(childTaskID: 999),
            toolName: ToolNames.resumeDelegation, toolCallID: toolCallID,
            conversation: &conversation)

        let envelope = conversation.first?.content ?? ""
        XCTAssertTrue(envelope.contains(ToolErrorCode.invalidArgs.rawValue), "got: \(envelope)")
        XCTAssertTrue(envelope.contains("999"),
                      "the rejected id must be echoed so the model can correct it; got: \(envelope)")
        XCTAssertTrue(mockDelegate.resumeRunCalls.isEmpty,
                      "a mismatched id must NOT resume any run — that is the whole point of the guard")
        XCTAssertEqual(reflectedCard(toolCallID)?.isError, true)
    }

    /// No in-flight delegation at all is the same rejection, reached differently
    /// (nil rather than a mismatch) — the `guard let … , … ==` is one condition
    /// with two failure modes.
    func testResumeDelegation_noActiveDelegation_isRejected() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.resumeDelegation)

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .resumeDelegation(childTaskID: 7),
            toolName: ToolNames.resumeDelegation, toolCallID: toolCallID,
            conversation: &conversation)

        XCTAssertTrue((conversation.first?.content ?? "").contains(ToolErrorCode.invalidArgs.rawValue),
                      "got: \(conversation.first?.content ?? "nil")")
        XCTAssertTrue(mockDelegate.resumeRunCalls.isEmpty)
    }

    // MARK: - forward_to_team

    /// `forward_to_team` carries a MESSAGE alongside the id; the arm must unpack
    /// both. A rejected id must not inject the message anywhere.
    func testForwardToTeam_wrongChildID_isRejected_andInjectsNothing() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.forwardToTeam)
        mockDelegate.activeDelegationChildStub["\(taskID):\(stepID)"] = 12

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .forwardToTeam(childTaskID: 34, message: "stop what you are doing"),
            toolName: ToolNames.forwardToTeam, toolCallID: toolCallID,
            conversation: &conversation)

        let envelope = conversation.first?.content ?? ""
        XCTAssertTrue(envelope.contains(ToolErrorCode.invalidArgs.rawValue), "got: \(envelope)")
        XCTAssertTrue(envelope.contains("34"), "got: \(envelope)")
        XCTAssertTrue(mockDelegate.resumeRunCalls.isEmpty,
                      "a rejected forward must not un-pause the child")
        XCTAssertEqual(reflectedCard(toolCallID)?.isError, true)
    }

    /// The message must be routed to the CHILD, never appended to the parent's own
    /// conversation. The only thing the parent's wire gains is the tool result.
    func testForwardToTeam_rejectedMessage_neverLandsInTheParentConversation() async {
        let toolCallID = UUID()
        seedStep(toolCallID: toolCallID, toolName: ToolNames.forwardToTeam)

        var conversation: [ChatMessage] = []
        await dispatch(
            signal: .forwardToTeam(childTaskID: 5, message: "SECRET-STEERING-TEXT"),
            toolName: ToolNames.forwardToTeam, toolCallID: toolCallID,
            conversation: &conversation)

        XCTAssertFalse(conversation.contains { ($0.content ?? "").contains("SECRET-STEERING-TEXT") },
                       "the forwarded text belongs to the child's conversation, not the parent's")
        let persisted = step()?.llmConversation.map(\.content) ?? []
        XCTAssertFalse(persisted.contains { $0.contains("SECRET-STEERING-TEXT") },
                       "…and it must not be persisted onto the parent step either; got: \(persisted)")
    }

    // MARK: - Shared contract across all three arms

    /// Whatever the outcome, every dispatched collaboration signal appends
    /// EXACTLY ONE `.tool` message at the tail — the append-at-`count` invariant
    /// the prompt-prefix cache depends on, and the tool_call/tool_result pairing
    /// the chat protocol requires.
    func testEveryDelegationArm_appendsExactlyOneToolResultAtTheTail() async {
        let signals: [(ToolSignal, String)] = [
            (.delegateToTeam(teamID: "t", taskBrief: "b"), ToolNames.delegateToTeam),
            (.resumeDelegation(childTaskID: 1), ToolNames.resumeDelegation),
            (.forwardToTeam(childTaskID: 1, message: "m"), ToolNames.forwardToTeam),
            (.cancelDelegation(childTaskID: 1, reason: nil), ToolNames.cancelDelegation),
        ]
        for (signal, toolName) in signals {
            let toolCallID = UUID()
            seedStep(toolCallID: toolCallID, toolName: toolName)
            var conversation: [ChatMessage] = [
                ChatMessage(role: .system, content: "sys"),
                ChatMessage(role: .user, content: "go"),
            ]
            await dispatch(signal: signal, toolName: toolName, toolCallID: toolCallID,
                           conversation: &conversation)

            XCTAssertEqual(conversation.count, 3, "\(toolName): appended more than one turn")
            XCTAssertEqual(conversation.last?.role, .tool, "\(toolName): the append must be the tool result")
            XCTAssertEqual(conversation[0].content, "sys", "\(toolName): head must be untouched")
            XCTAssertEqual(conversation[1].content, "go", "\(toolName): body must be untouched")
            XCTAssertFalse((conversation.last?.content ?? "").isEmpty,
                           "\(toolName): a blank tool result would leave the model guessing")
        }
    }

    // MARK: - Helpers

    private func dispatch(
        signal: ToolSignal,
        toolName: String,
        toolCallID: UUID,
        roleForMessage: Role = .codingAgent,
        conversation: inout [ChatMessage]
    ) async {
        let result = ToolExecutionResult(
            providerID: "tc_1", toolName: toolName, argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false, signal: signal)
        _ = await service.appendCollaborationResult(
            result: result, toolCallID: toolCallID, roleForMessage: roleForMessage,
            stepID: stepID, task: mockDelegate.taskToMutate!, runIndex: 0, stepIndex: 0,
            client: InertLLMClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &conversation)
    }

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func reflectedCard(_ id: UUID) -> StepToolCall? {
        step()?.toolCalls.first { $0.id == id }
    }

    private func seedStep(toolCallID: UUID, toolName: String, team: Team? = nil) {
        let placeholder = StepToolCall(
            id: toolCallID, providerID: "tc_1", name: toolName, argumentsJSON: "{}",
            resultJSON: #"{"ok":true,"data":{"status":"pending"}}"#, isError: false)
        let step = StepExecution(
            id: stepID, role: .codingAgent, title: "Agent",
            status: .running, toolCalls: [placeholder])
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        task.preferredTeamID = team?.id
        mockDelegate.taskToMutate = task
        if let team {
            mockDelegate.snapshot = WorkFolderContext(
                projection: WorkFolderProjection(
                    state: WorkFolderState(name: "T", activeTeamID: team.id),
                    settings: .defaults, teams: [team]),
                tasksIndex: TasksIndex(), toolDefinitions: [],
                activeTaskID: taskID, activeTask: task)
        } else {
            mockDelegate.snapshot = nil
        }
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    /// A delegator wired UNDER another role in the hierarchy — the shape
    /// `roleIsTopLevelDelegator` exists to reject.
    private func makeTeamWithSubordinateDelegator() -> Team {
        let agent = TeamRoleDefinition(
            id: stepID, name: "Coding Agent", prompt: "p",
            toolIDs: [ToolNames.delegateToTeam], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "codingAgent")
        var settings = TeamSettings()
        settings.hierarchy.reportsTo[agent.id] = "someone_above"
        return Team(
            name: "Sub", roles: [agent], artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout())
    }
}

// MARK: - Inert client

/// Never streams — the delegation arms under test all reject before any LLM call.
/// A client that DID reach the network would be the bug this stub makes visible.
private final class InertLLMClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
