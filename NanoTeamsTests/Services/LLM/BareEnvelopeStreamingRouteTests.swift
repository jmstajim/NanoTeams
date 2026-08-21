import XCTest

@testable import NanoTeams

/// Route 4 of `performStreamingCall` — the sentinel-free salvage — driven end to end.
///
/// `BareToolCallSalvageTests` pins the RULE; this pins the WIRING, which is where the
/// defect actually lived: the rule had no home, so a reply carrying an unambiguous tool
/// call was answered with "you replied with text but did not call a tool".
@MainActor
final class BareEnvelopeStreamingRouteTests: XCTestCase {

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
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "step0"
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

    private var waitForEventsSchema: ToolSchema {
        ToolSchema(
            name: ToolNames.waitForEvents, description: "",
            parameters: JSONSchema(type: "object", properties: [:], required: []))
    }

    private func run(
        events: [StreamEvent], tools: [ToolSchema] = []
    ) async throws -> LLMExecutionService.StreamingResult {
        mockClient.deltas = events
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: tools, conversationMessages: [], networkLogger: nil)
    }

    // MARK: - The incident

    /// Turn 10, verbatim. The single highest-value assertion here: before route 4 this
    /// resolved zero calls, and the manager was told to call the tool it had just called.
    func testBareJSONReply_resolvesOneCall() async throws {
        let result = try await run(
            events: [StreamEvent(contentDelta: #"{"name":"wait_for_events","arguments":{}}"#)],
            tools: [waitForEventsSchema])
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.waitForEvents])
        XCTAssertFalse(result.sawHarmonyMarker, "no sentinel was present — that is the point")
    }

    /// Turns 7 and 9, verbatim.
    func testBareToolNameReply_resolvesOneCall() async throws {
        let result = try await run(
            events: [StreamEvent(contentDelta: "wait_for_events")],
            tools: [waitForEventsSchema])
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.waitForEvents])
    }

    /// Turns 5 and 11 — genuinely no call. The salvage must leave prose alone, content
    /// intact, so the ordinary no-tool nudge still owns that turn.
    func testProseReply_resolvesNothing_andKeepsItsContent() async throws {
        let result = try await run(
            events: [StreamEvent(contentDelta: "Waiting for the M3 task to finish.")],
            tools: [waitForEventsSchema])
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        XCTAssertEqual(result.assistantContent, "Waiting for the M3 task to finish.")
    }

    // MARK: - Route precedence and channel scope

    /// Route 1 wins: provider-native deltas are the strongest signal, so a stream carrying
    /// both must not double-dispatch.
    func testProviderDeltasWin_overBareJSONInContent() async throws {
        let result = try await run(
            events: [
                StreamEvent(toolCallDeltas: [
                    StreamEvent.ToolCallDelta(index: 0, id: "c1", name: ToolNames.gitStatus, argumentsDelta: "{}")
                ]),
                StreamEvent(contentDelta: #"{"name":"wait_for_events","arguments":{}}"#),
            ],
            tools: [waitForEventsSchema])
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.gitStatus])
    }

    /// A marker anywhere in the content means route 2 owns recovery — it can name the
    /// defect, which the salvage cannot.
    func testHarmonyMarkerPresent_suppressesTheSalvage() async throws {
        let result = try await run(
            events: [StreamEvent(
                contentDelta: "<|channel|>final<|message|>"
                    + #"{"name":"wait_for_events","arguments":{}}"#)],
            tools: [waitForEventsSchema])
        XCTAssertTrue(result.sawHarmonyMarker)
        // Whatever route 2 makes of it, route 4 must not be what answered.
        XCTAssertTrue(result.resolvedToolCalls.isEmpty
            || result.resolvedToolCalls.first?.name == ToolNames.waitForEvents)
    }

    /// Content channel only. A `<|…|>` marker means the same thing wherever it appears, so
    /// route 3 legitimately reads reasoning; bare JSON there is the model CONSIDERING a
    /// call, and dispatching it would act on a thought.
    func testBareJSONInReasoningOnly_isNotSalvaged() async throws {
        let result = try await run(
            events: [
                StreamEvent(thinkingDelta: #"Maybe {"name":"wait_for_events","arguments":{}}"#),
                StreamEvent(contentDelta: "Let me think about it."),
            ],
            tools: [waitForEventsSchema])
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
    }

    // MARK: - Display / wire agreement

    /// The promoted text must leave the content channel. Left in place the turn renders
    /// twice — a raw-JSON bubble AND a tool card — and, because
    /// `HarmonyToolCallEnvelope.appendedWireText` re-materializes the call on top of
    /// non-empty content, every stateless resend would carry the call twice as well.
    func testSalvagedReply_leavesNoAssistantContent() async throws {
        let result = try await run(
            events: [StreamEvent(contentDelta: #"{"name":"wait_for_events","arguments":{}}"#)],
            tools: [waitForEventsSchema])
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertTrue(result.assistantContent.isEmpty,
                      "the payload became a call; it must not also remain a message")
    }

    /// Arriving one character at a time must not change the answer — the salvage runs on
    /// the assembled content, after the final flush.
    func testBareJSONSplitAcrossDeltas_stillResolves() async throws {
        let payload = #"{"name":"wait_for_events","arguments":{}}"#
        let result = try await run(
            events: payload.map { StreamEvent(contentDelta: String($0)) },
            tools: [waitForEventsSchema])
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.waitForEvents])
    }
}
