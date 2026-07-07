import XCTest

@testable import NanoTeams

/// Integration tests for `LLMExecutionService.gateComputerUseCalls`, focused on the
/// Semi-automatic ROUTING contract that the pure `ComputerUsePermissionService`
/// tests can't reach: the human-vs-judge split lives in the gate
/// (`policy.mode == .auto` → judge; else → human / deny). The defining property of
/// Semi-automatic is that a mutating action (click/type/key) goes to the HUMAN,
/// never the unattended judge — so a regression changing the gate to
/// `mode == .auto || mode == .semiAutomatic` would silently defeat the mode while
/// every pure-evaluator test still passes.
///
/// `@MainActor` + `async` per the documented sync-test abort gotcha (constructing
/// the `@MainActor` `LLMExecutionService` from a sync test aborts on CI).
@MainActor
final class ComputerUseGateTests: XCTestCase {

    var service: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.snapshot = nil  // → not under Autovisor (isUnderAutovisor returns false)
        service.attach(delegate: delegate)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// A whole-screen click (target nil) — avoids all AppKit target resolution so
    /// the gate's decision comes purely from mode + supervisorMode.
    private func clickCall(providerID: String = "c1") -> StepToolCall {
        StepToolCall(providerID: providerID, name: ToolNames.uiClick,
                     argumentsJSON: #"{"x":10,"y":10,"button":"left"}"#)
    }

    private func captureCall(providerID: String = "cap1") -> StepToolCall {
        StepToolCall(providerID: providerID, name: ToolNames.screenCapture,
                     argumentsJSON: #"{"target":"screen"}"#)
    }

    private func task() -> NTMSTask {
        NTMSTask(id: 1, title: "t", supervisorTask: "g", runs: [])
    }

    private func gate(
        _ calls: [StepToolCall],
        policy: ComputerUsePolicy,
        supervisorMode: SupervisorMode,
        client: any LLMClient
    ) async -> [Int: ToolExecutionResult] {
        delegate.computerUsePolicy = policy
        return await service.gateComputerUseCalls(
            resolvedToolCalls: calls,
            allowedToolNames: ToolHandlerRegistry.computerUseTools,
            stepID: "step1",
            taskID: 1,
            supervisorMode: supervisorMode,
            task: task(),
            client: client,
            config: LLMConfig(),
            networkLogger: nil)
    }

    // MARK: - Semi-automatic routing

    func testSemiAutomatic_mutatingAction_noHuman_deniesWithoutConsultingJudge() async {
        // Semi-automatic + no human (autonomous): a click routes to the human
        // approval path, which denies because no human is available — and the judge
        // is NEVER consulted. If the gate wrongly routed Semi to the judge, the
        // client would be called (and the action might run unattended).
        let client = RecordingJudgeClient()
        let results = await gate(
            [clickCall()], policy: ComputerUsePolicy(mode: .semiAutomatic),
            supervisorMode: .autonomous, client: client)

        XCTAssertEqual(client.callCount, 0,
                       "Semi-automatic must NOT route a mutating action to the unattended judge")
        XCTAssertNotNil(results[0], "the click must be denied (no human), not passed through to execution")
    }

    func testSemiAutomatic_capture_noHuman_allows() async {
        // A capture is read-only — it auto-allows even autonomously, with no judge.
        let client = RecordingJudgeClient()
        let results = await gate(
            [captureCall()], policy: ComputerUsePolicy(mode: .semiAutomatic),
            supervisorMode: .autonomous, client: client)

        XCTAssertTrue(results.isEmpty, "capture is read-only → passes through to execution")
        XCTAssertEqual(client.callCount, 0, "a read never consults the judge")
    }

    func testAuto_mutatingAction_routesToJudge() async {
        // Contrast with Semi: in Auto the SAME click DOES consult the judge — this
        // is the exact branch (`policy.mode == .auto`) Semi-automatic must NOT take.
        let client = RecordingJudgeClient()
        _ = await gate(
            [clickCall()], policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
            supervisorMode: .autonomous, client: client)

        XCTAssertGreaterThan(client.callCount, 0, "Auto must route a mutating action to the judge")
    }
}

// MARK: - Stub

/// Counts `streamChat` invocations (i.e. judge consultations) and returns a benign
/// OK verdict so the Auto path resolves. The count is what the routing tests assert.
private final class RecordingJudgeClient: LLMClient, @unchecked Sendable {
    private(set) var callCount = 0

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: #"{"decision":"OK","reason":"ok"}"#))
            continuation.finish()
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
}
