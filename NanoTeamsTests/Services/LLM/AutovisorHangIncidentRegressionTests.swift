import XCTest

@testable import NanoTeams

/// The whole reported incident, turn by turn, in one place.
///
/// One Autovisor review pass (`openai/gpt-oss-20b`) burned twelve LLM round-trips in ~40
/// seconds and could not end; only a manual cancel stopped it. Four of its turns worked.
/// Of the rest, three were the model trying to call `wait_for_events` — the only way its
/// pass can terminate — in shapes the parser did not accept, and one named a tool that
/// does not exist. Each was answered with "you replied with text but did not call a tool".
///
/// Every payload below is verbatim from `network_log.json`. The point of keeping them
/// together is that no single fix covers them: turns 7/9/10 are `BareToolCallSalvage`,
/// turn 6 is the parser's zero-argument arm, and turns 1–4/8 are the shapes that already
/// worked and must keep working — note that not one of them uses the `<|call|>{…}<|end|>`
/// form the system prompt teaches.
@MainActor
final class AutovisorHangIncidentRegressionTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []
        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "autovisor_autovisor"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        mockClient = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    /// The manager's schema, reduced to the tools this pass actually reached for.
    private var managerTools: [ToolSchema] {
        [ToolNames.waitForEvents, ToolNames.listTasks, ToolNames.taskStatus,
         ToolNames.controlTask, ToolNames.updateScratchpad].map {
            ToolSchema(
                name: $0, description: "",
                parameters: JSONSchema(type: "object", properties: [:], required: []))
        }
    }

    private func resolve(_ content: String) async throws -> [StepToolCall] {
        mockClient.deltas = [StreamEvent(contentDelta: content)]
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: managerTools, conversationMessages: [], networkLogger: nil
        ).resolvedToolCalls
    }

    /// Turn number → (verbatim content, the tool it must resolve to, or nil for "no call").
    private static let incident: [(turn: Int, content: String, expected: String?)] = [
        // Turns 1–4 and 8 worked at the time and must keep working. Note `to=TOOL_NAME` on
        // turn 1: the model echoed the placeholder from the prompt's format line, and the
        // inner `name` is what rescues it.
        (1, ##"<|channel|>commentary to=TOOL_NAME <|constrain|>json<|message|>{"name":"list_tasks","arguments":{}}"##,
         ToolNames.listTasks),
        (2, ##"<|channel|>commentary to=task_status <|constrain|>json<|message|>{"task_id":10}"##,
         ToolNames.taskStatus),
        (3, ##"<|channel|>commentary to=control_task <|constrain|>json<|message|>{"action":"resume","task_id":10}"##,
         ToolNames.controlTask),
        (4, ##"<|channel|>commentary to=update_scratchpad <|constrain|>json<|message|>{"content":"1. M3 (in flight)"}"##,
         ToolNames.updateScratchpad),
        // Genuinely no call — prose. Must stay prose.
        (5, "Waiting for the M3 task to finish.", nil),
        // A tool that does not exist, with no body. Resolving it is the point: the runtime
        // then answers `tool_not_authorized` + "do not retry", instead of the parser
        // reporting malformed JSON for an envelope containing no JSON.
        (6, "<|channel|>commentary to=swift_build code<|message|>", "swift_build"),
        (7, "wait_for_events", ToolNames.waitForEvents),
        (8, ##"<|channel|>commentary to=task_status <|constrain|>json<|message|>{"task_id":10}"##,
         ToolNames.taskStatus),
        (9, "wait_for_events", ToolNames.waitForEvents),
        (10, ##"{"name":"wait_for_events","arguments":{}}"##, ToolNames.waitForEvents),
        (11, "Waiting for the M3 task to finish.", nil),
    ]

    func testEveryTurnOfTheIncident_resolvesAsItShould() async throws {
        for (turn, content, expected) in Self.incident {
            let calls = try await resolve(content)
            if let expected {
                XCTAssertEqual(calls.map(\.name), [expected],
                               "turn \(turn) must resolve to \(expected): \(content)")
            } else {
                XCTAssertTrue(calls.isEmpty,
                              "turn \(turn) is prose and must resolve to nothing: \(content)")
            }
        }
    }

    /// Three of the eleven turns were the model trying to end its pass. Before the fix all
    /// three resolved to nothing, so the pass had no way to terminate at all — which is
    /// the incident, stated as a property rather than a list.
    func testEveryAttemptToEndThePass_nowLands() async throws {
        let attempts = Self.incident.filter { $0.expected == ToolNames.waitForEvents }
        XCTAssertEqual(attempts.count, 3, "the pass tried to end itself three times")
        for (turn, content, _) in attempts {
            let calls = try await resolve(content)
            XCTAssertEqual(calls.map(\.name), [ToolNames.waitForEvents],
                           "turn \(turn) was an attempt to end the pass: \(content)")
        }
    }

    /// Not one working call in the whole pass used the form the system prompt documents.
    /// Kept as an assertion because it is the reason the fix is about ACCEPTING shapes
    /// rather than teaching one: a nudge naming `<|call|>{…}<|end|>` describes a syntax
    /// this model never emitted.
    func testTheDocumentedCallForm_neverAppearsInTheIncident() {
        for (turn, content, _) in Self.incident {
            XCTAssertFalse(content.contains("<|call|>"),
                           "turn \(turn) unexpectedly uses the canonical form")
        }
    }
}
