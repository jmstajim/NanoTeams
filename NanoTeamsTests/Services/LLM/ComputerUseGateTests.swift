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

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.snapshot = nil  // → not under Autovisor (isUnderAutovisor returns false)
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        try await super.tearDown()
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
        XCTAssertNotNil(results[0], "the click must be refused (no human), not passed through to execution")
        XCTAssertTrue(results[0]?.outputJSON.contains(ToolErrorCode.approvalUnavailable.rawValue) == true,
                      "nobody decided — the refusal carries its own code, got: \(results[0]?.outputJSON ?? "nil")")
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

    /// Ask Supervisor mode Off counts as a human present (same contract as the bash gate):
    /// a semi-automatic click is held for the human — the judge is never consulted and the
    /// action is not denied as unattended. The hold publishes an approval request.
    func testSemiAutomatic_mutatingAction_offTeam_isHeldForTheHumanNotDenied() async {
        let client = RecordingJudgeClient()
        let gateTask = Task { [service, delegate] in
            delegate!.computerUsePolicy = ComputerUsePolicy(mode: .semiAutomatic)
            return await service!.gateComputerUseCalls(
                resolvedToolCalls: [self.clickCall()],
                allowedToolNames: ToolHandlerRegistry.computerUseTools,
                stepID: "step1", taskID: 1, supervisorMode: .off, task: self.task(),
                client: client, config: LLMConfig(), networkLogger: nil)
        }
        var held = false
        for _ in 0..<500 {
            if !delegate.computerUseApprovalBeganRequests.isEmpty { held = true; break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(held, "Off must hold the click for the human, as manual does")
        XCTAssertEqual(client.callCount, 0, "the judge is never consulted while a human is present")
        gateTask.cancel()
        _ = await gateTask.value
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

    /// A Pause while the Auto judge is being asked: the cancellation envelope, never
    /// `COMPUTER_USE_DENIED` — twin of the human hold's `.cancelled` arm. Until 2026-09-23 the
    /// cut-short call read as an empty reply: "Judge returned no verdict; denied."
    func testAuto_judgeCutShortByCancellation_synthesizesCancelledNotDenied() async {
        let client = ScriptedToolCallClient(script: [.hang])
        let gateTask = Task {
            await self.gate(
                [self.clickCall()], policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
                supervisorMode: .manual, client: client)
        }
        for _ in 0..<500 where client.callCount < 1 { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(client.callCount, 1, "premise: the judge was being asked")
        gateTask.cancel()
        let results = await gateTask.value

        let output = results[0]?.outputJSON ?? ""
        XCTAssertTrue(output.contains(ToolErrorCode.cancelled.rawValue), output)
        XCTAssertFalse(output.contains(ToolErrorCode.computerUseDenied.rawValue), output)
        XCTAssertEqual(results[0]?.providerID, "c1", "the synthetic result still answers the call")
    }

    /// Twin of the `bash` gate's: two actions that need a verdict, paused while the FIRST is
    /// being judged — the second is answered as cancelled without a judge request of its own.
    func testAuto_pauseDuringTheFirstJudge_asksNoFurtherJudgeInTheBatch() async {
        let client = ScriptedToolCallClient(script: [.hang, .text(#"{"decision":"OK"}"#)])
        let calls = [clickCall(providerID: "c1"), clickCall(providerID: "c2")]
        let gateTask = Task {
            await self.gate(
                calls, policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
                supervisorMode: .manual, client: client)
        }
        for _ in 0..<500 where client.callCount < 1 { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(client.callCount, 1, "premise: the first judge was being asked")
        gateTask.cancel()
        let results = await gateTask.value

        XCTAssertEqual(client.callCount, 1, "a stopped run asks no further judge")
        for (idx, providerID) in [(0, "c1"), (1, "c2")] {
            let output = results[idx]?.outputJSON ?? ""
            XCTAssertTrue(output.contains(ToolErrorCode.cancelled.rawValue), "\(providerID): \(output)")
            XCTAssertEqual(results[idx]?.providerID, providerID, "each call is still answered")
        }
    }

    /// Reached with the run already stopped: no judge is asked and none is noted on the
    /// prompt-prefix ledger.
    func testAuto_runAlreadyStopped_notesNoJudgeOnTheLedger_andAsksNone() async {
        let client = ScriptedToolCallClient(script: [.text(#"{"decision":"OK"}"#)])
        await recordStepRequest()
        let results = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.gate(
                [self.clickCall()], policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
                supervisorMode: .manual, client: client)
        }.value

        let output = results[0]?.outputJSON ?? ""
        XCTAssertTrue(output.contains(ToolErrorCode.cancelled.rawValue), output)
        XCTAssertEqual(client.callCount, 0, "a stopped run asks no judge")
        let suspect = await recordStepRequest()
        XCTAssertNil(suspect, "a judge that was never asked was noted on the ledger as \(suspect ?? "")")
    }

    /// The other side of the guard: a judge that IS asked is noted, under its own label.
    func testAuto_judgeAsked_isNotedOnTheLedger() async {
        let client = ScriptedToolCallClient(script: [.text(#"{"decision":"OK"}"#)])
        await recordStepRequest()
        _ = await gate(
            [clickCall()], policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
            supervisorMode: .manual, client: client)
        XCTAssertEqual(client.callCount, 1, "premise: the judge was asked")
        let suspect = await recordStepRequest()
        XCTAssertEqual(suspect, LLMCallOwner.oneShot(label: "computer-use judge").key)
    }

    /// Records one request of this test's step on the ledger, on the (server, model) the gate
    /// is handed, and returns who else the ledger saw on it since the step's previous request.
    @discardableResult
    private func recordStepRequest() async -> String? {
        let config = LLMConfig()
        return await service.prefixLedger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: .step(taskID: 1, stepID: "step1"),
            messages: [ChatMessage(role: .user, content: "brief")], toolSchemaText: ""
        ).suspect
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

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
}
