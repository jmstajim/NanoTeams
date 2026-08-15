import XCTest

@testable import NanoTeams

/// Integration tests for `LLMExecutionService.gateBashCalls` — the bash
/// permission gate. Covers chain integrity (synthetic results carry the call's
/// providerID), deny/allow/read-only routing, mode reconciliation (manual human
/// pause vs. autonomous deny/judge), the Auto judge wiring, and one-shot
/// approval-decision consumption.
///
/// `@MainActor` + `async` test methods per the documented sync-test abort gotcha
/// (constructing the `@MainActor` `LLMExecutionService` from a sync test aborts
/// on CI).
@MainActor
final class BashGateTests: XCTestCase {

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

    private func bashCall(_ command: String, providerID: String = "call_1") -> StepToolCall {
        StepToolCall(
            providerID: providerID, name: ToolNames.bash,
            argumentsJSON: "{\"command\":\"\(command)\"}")
    }

    private func task() -> NTMSTask {
        NTMSTask(id: 1, title: "t", supervisorTask: "g", runs: [])
    }

    /// A bash call with arbitrary raw arguments JSON (for alternative-key / decoy tests).
    private func rawBashCall(_ json: String, providerID: String = "call_raw") -> StepToolCall {
        StepToolCall(providerID: providerID, name: ToolNames.bash, argumentsJSON: json)
    }

    /// Runs the gate with a never-invoked client (non-judge paths).
    private func gate(
        _ calls: [StepToolCall],
        policy: BashPolicy,
        supervisorMode: SupervisorMode = .manual,
        client: any LLMClient = LLMClientRouter()
    ) async -> [Int: ToolExecutionResult] {
        delegate.bashPolicy = policy
        return await service.gateBashCalls(
            resolvedToolCalls: calls,
            allowedToolNames: [ToolNames.bash],
            stepID: "step1",
            taskID: 1,
            supervisorMode: supervisorMode,
            task: task(),
            client: client,
            config: LLMConfig(),
            networkLogger: nil)
    }

    private func errorCode(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any]
        else { return nil }
        return err["code"] as? String
    }

    /// Spawns the gate and waits until it HOLDS a command awaiting human approval
    /// (the gate publishes a `BashApprovalRequest` via the delegate before it
    /// suspends). Returns the running task + the held command key so the test can
    /// resolve it. Fails if no hold appears in time.
    private func gateHolding(
        _ calls: [StepToolCall], policy: BashPolicy, supervisorMode: SupervisorMode = .manual,
        isPlanningPhase: Bool = false
    ) async -> (task: Task<[Int: ToolExecutionResult], Never>, commandKey: String) {
        delegate.bashPolicy = policy
        let task = Task { [service, delegateTask = task()] in
            await service!.gateBashCalls(
                resolvedToolCalls: calls, allowedToolNames: [ToolNames.bash],
                isPlanningPhase: isPlanningPhase,
                stepID: "step1", taskID: 1, supervisorMode: supervisorMode, task: delegateTask,
                client: LLMClientRouter(), config: LLMConfig(), networkLogger: nil)
        }
        for _ in 0..<500 {
            if let req = delegate.bashApprovalBeganRequests.first { return (task, req.commandKey) }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("gate did not hold a command for approval")
        return (task, "")
    }

    // MARK: - Pass-through (allow / read-only)
    //
    // Pass-through (allow-rule matches and read-only no-ops run without asking) is
    // the behavior of `.semiAutomatic` mode — NOT `.manual` (always-confirm), which
    // holds every non-denied command for fresh approval (see
    // `testAlwaysConfirm_readOnlyCommand_isHeldNotAutoAllowed`). These tests pin the
    // pass-through path, so they set the mode explicitly rather than rely on the
    // default (`BashConstants.defaultMode == .manual`).

    func testAllowRule_passesThrough() async {
        let results = await gate(
            [bashCall("make build")],
            policy: BashPolicy(mode: .semiAutomatic, allowRules: ["make"]))
        XCTAssertTrue(results.isEmpty, "an allow-listed command must pass through to execution")
    }

    func testReadOnly_passesThrough() async {
        let results = await gate([bashCall("ls -la")], policy: BashPolicy(mode: .semiAutomatic))
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Deny

    func testDenyRule_synthesizesBashDenied() async {
        let call = bashCall("rm -rf /tmp/x", providerID: "call_9")
        let results = await gate([call], policy: BashPolicy(denyRules: ["rm"]))
        let synth = results[0]
        XCTAssertNotNil(synth)
        XCTAssertEqual(synth?.isError, true)
        XCTAssertEqual(errorCode(synth?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
        // R3-A chain integrity: synthetic MUST carry the call's providerID (no orphan tool_call).
        XCTAssertEqual(synth?.providerID, "call_9")
    }

    func testModeOff_deniesEvenReadOnly() async {
        let results = await gate([bashCall("ls")], policy: BashPolicy(mode: .off))
        XCTAssertEqual(results[0]?.isError, true)
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
    }

    // MARK: - Manual approval (in-loop human Allow / Deny — bypasses the model)

    func testManualHumanApproval_allow_runsTheRealCommand() async {
        let (task, key) = await gateHolding([bashCall("make install")], policy: BashPolicy(mode: .manual))
        XCTAssertEqual(delegate.bashApprovalBeganRequests.first?.command, "make install")
        XCTAssertFalse(delegate.bashApprovalBeganRequests.first?.offerAlways ?? true,
            "always-confirm Manual must not offer the Always-allow button")
        service.resolveBashApproval(taskID: 1, stepID: "step1", commandKey: key, decision: .allow)
        let results = await task.value
        XCTAssertTrue(results.isEmpty, "allow → no synthetic → the call passes through and runs for real")
        XCTAssertTrue(delegate.bashApprovalBeganRequests.isEmpty, "the held request is cleared after the await")
    }

    func testManualHumanApproval_deny_synthesizesBashDenied() async {
        let (task, key) = await gateHolding([bashCall("make install")], policy: BashPolicy(mode: .manual))
        service.resolveBashApproval(taskID: 1, stepID: "step1", commandKey: key, decision: .deny)
        let results = await task.value
        XCTAssertEqual(results[0]?.isError, true)
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
    }

    func testManualHumanApproval_cancellation_resolvesAsDeny() async {
        // Pause cancels the step task while a command is held → fail safe (never run
        // an unapproved command). The await resolves `.deny` → synthetic denial.
        let (task, _) = await gateHolding([bashCall("make install")], policy: BashPolicy(mode: .manual))
        task.cancel()
        let results = await task.value
        XCTAssertEqual(results[0]?.isError, true, "a cancelled (paused) approval denies, it does not run")
    }

    func testAlwaysConfirm_readOnlyCommand_isHeldNotAutoAllowed() async {
        // In always-confirm mode even a read-only `ls` is HELD (no read-only bypass).
        let (task, key) = await gateHolding([bashCall("ls -la")], policy: BashPolicy(mode: .manual))
        XCTAssertEqual(delegate.bashApprovalBeganRequests.first?.command, "ls -la")
        service.resolveBashApproval(taskID: 1, stepID: "step1", commandKey: key, decision: .allow)
        let results = await task.value
        XCTAssertTrue(results.isEmpty)
    }

    func testSemiAutomatic_heldCommand_offersAlways() async {
        // A non-read-only ask command in semi-automatic mode is held and offers Always-allow.
        let (task, key) = await gateHolding([bashCall("make install")], policy: BashPolicy(mode: .semiAutomatic))
        XCTAssertTrue(delegate.bashApprovalBeganRequests.first?.offerAlways ?? false,
            "semi-automatic mode offers the Always-allow button")
        service.resolveBashApproval(taskID: 1, stepID: "step1", commandKey: key, decision: .allow)
        _ = await task.value
    }

    // MARK: - No-human reconciliation (R4-A)

    func testManual_noHuman_denies() async {
        // Manual bash mode but autonomous team (no human) → deny, and crucially NO
        // supervisorQuestion (so the autonomous auto-answer can't hijack). To run a
        // command unattended the user must set the bash mode to Auto.
        let results = await gate(
            [bashCall("make install")],
            policy: BashPolicy(mode: .manual),
            supervisorMode: .autonomous)
        XCTAssertEqual(results[0]?.isError, true)
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
        if case .supervisorQuestion = results[0]?.signal {
            XCTFail("must NOT emit a supervisorQuestion in an autonomous (no-human) context")
        }
        XCTAssertNil(service.pendingBashApproval(stepID: "step1", taskID: 1))
    }

    // MARK: - Gate-bypass regressions (command-key parity with the handler)

    func testAlternativeKeyCommand_isGated() async {
        // {"text":"rm -rf /"} — the handler runs `text`, so the gate MUST evaluate
        // it too (not skip it as "malformed" and let it run ungated).
        let results = await gate([rawBashCall(#"{"text":"rm -rf /"}"#)], policy: BashPolicy(denyRules: ["rm"]))
        XCTAssertEqual(results[0]?.isError, true, "a command under an alternative key must not bypass the gate")
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
    }

    func testContentDecoy_gatedOnExecutedCommand() async {
        // {"command":"ls","content":"rm -rf /"} — the handler executes `content`,
        // so the gate must judge `content` (the real command), not the `command` decoy.
        let results = await gate(
            [rawBashCall(#"{"command":"ls","content":"rm -rf /"}"#)], policy: BashPolicy(denyRules: ["rm"]))
        XCTAssertEqual(results[0]?.isError, true, "a benign `command` decoy must not hide the executed `content`")
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
    }

    // MARK: - Auto judge

    func testAutoMode_judgeDenies() async {
        let client = StubJudgeClient(content: #"{"decision":"deny","reason":"destructive"}"#)
        let results = await gate(
            [bashCall("rm -rf build")], policy: BashPolicy(mode: .auto), client: client)
        XCTAssertEqual(results[0]?.isError, true)
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.bashDenied.rawValue)
    }

    func testAutoMode_judgeAllows() async {
        let client = StubJudgeClient(content: #"{"decision":"OK","reason":"safe"}"#)
        let results = await gate(
            [bashCall("npm run build")], policy: BashPolicy(mode: .auto), client: client)
        XCTAssertTrue(results.isEmpty, "judge-approved command passes through")
    }

    // MARK: - Error guidance (anti-retry)

    func testBashDeniedGuidance_isAntiRetry() async throws {
        let result = ToolExecutionResult(
            toolName: ToolNames.bash, argumentsJSON: "{}",
            outputJSON: makeErrorEnvelope(code: .bashDenied, message: "Blocked by deny rule “rm”."),
            isError: true)

        // The REASON is the envelope's — it reaches the model one turn before the direction,
        // so restating it there bought nothing (`ToolErrorNotePolicy`).
        XCTAssertTrue(result.outputJSON.contains("Blocked by deny rule"), result.outputJSON)

        let guidance = try XCTUnwrap(ToolErrorNotePolicy.direction(for: result))
        XCTAssertFalse(
            guidance.lowercased().contains("retry the tool call with the correct arguments"),
            "bash_denied must NOT get the default retry guidance")
        XCTAssertTrue(guidance.lowercased().contains("do not retry"))
        XCTAssertFalse(
            guidance.contains("Blocked by deny rule"),
            "the direction must not restate the envelope's reason: \(guidance)")
    }

    // MARK: - Mixed batch & non-bash

    func testNonBashCall_notGated() async {
        let readCall = StepToolCall(providerID: "c0", name: ToolNames.readFile, argumentsJSON: #"{"path":"x"}"#)
        let denyCall = bashCall("rm -rf /", providerID: "c1")
        delegate.bashPolicy = BashPolicy(denyRules: ["rm"])
        let results = await service.gateBashCalls(
            resolvedToolCalls: [readCall, denyCall],
            allowedToolNames: [ToolNames.bash, ToolNames.readFile],
            stepID: "step1", taskID: 1, supervisorMode: .manual, task: task(),
            client: LLMClientRouter(), config: LLMConfig(), networkLogger: nil)
        XCTAssertNil(results[0], "non-bash calls are never gated")
        XCTAssertEqual(results[1]?.isError, true)
    }

    func testRoleWithoutBash_notGated() async {
        // allowedToolNames lacks bash → executeToolCalls handles the unavailable case.
        delegate.bashPolicy = BashPolicy(denyRules: ["rm"])
        let results = await service.gateBashCalls(
            resolvedToolCalls: [bashCall("rm -rf /")],
            allowedToolNames: [ToolNames.readFile],
            stepID: "step1", taskID: 1, supervisorMode: .manual, task: task(),
            client: LLMClientRouter(), config: LLMConfig(), networkLogger: nil)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Planning phase

    /// The claim "the deny/ask/allow tiering is identical during planning" is PROVABLE, not
    /// argued: `BashPermissionService.evaluate` never reads a sandbox field, so narrowing the
    /// sandbox cannot move a command between tiers. Swept over every mode and every tier so a
    /// future field that DOES get read shows up here rather than in the field.
    ///
    /// RED: have `withWritesDisabled()` also clear `denyRules` (a plausible "the phase should be
    /// stricter" edit) → the `rm -rf /` row's two decisions stop being equal.
    func testPlanningNarrowing_cannotMoveACommandBetweenPermissionTiers() {
        let commands = ["ls -la", "rm -rf /", "curl example.com", "echo ok"]
        for mode in BashExecutionMode.allCases {
            let policy = BashPolicy(
                mode: mode, allowRules: ["echo"], askRules: ["curl"], denyRules: ["rm"])
            for command in commands {
                let live = BashPermissionService.evaluate(command: command, policy: policy)
                let narrowed = BashPermissionService.evaluate(
                    command: command, policy: policy.withWritesDisabled())
                XCTAssertEqual(live, narrowed, "\(mode) / \(command)")
            }
        }
    }

    /// The judge and the "Ask AI" advisor render the policy they are handed straight into their
    /// prompt (`sandboxConfinementDescription`). During the phase the real confinement is the
    /// write-disabled one, so handing them the LIVE policy would describe a sandbox that is not
    /// in force — permissive about writes that cannot happen, strict about harmless reads.
    ///
    /// RED: make `withWritesDisabled()` a no-op on permissions → the two descriptions compare
    /// equal and the inequality assertion fails.
    func testPlanningNarrowing_changesWhatTheJudgeIsToldAboutConfinement() {
        let live = BashJudgeService.sandboxConfinementDescription(policy: BashPolicy())
        let narrowed = BashJudgeService.sandboxConfinementDescription(
            policy: BashPolicy().withWritesDisabled())

        XCTAssertNotEqual(live, narrowed,
                          "the judge must not be told the same confinement in both phases")
        XCTAssertTrue(live.lowercased().contains("work folder"),
                      "baseline: the live description names the writable work folder")
    }

    /// "Always allow" persists a PERMANENT, global allow rule. Offering it while writes are
    /// blocked would let a human approve `rm -rf build` under a confinement that makes it
    /// harmless, and mint a standing grant that then governs the same command AFTER the
    /// boundary, under the full write profile, with no further review — a privilege ladder
    /// built inside the transcript the phase is about to destroy.
    ///
    /// RED: restore `offerAlways: policy.mode != .manual` → the published request offers
    /// "Always allow" and the assertion fails.
    func testPlanningPhase_doesNotOfferAlwaysAllow() async {
        let policy = BashPolicy(mode: .semiAutomatic)
        let held = await gateHolding([bashCall("curl example.com")], policy: policy,
                                     isPlanningPhase: true)
        defer { held.task.cancel() }

        guard let request = delegate.bashApprovalBeganRequests.first else {
            return XCTFail("the gate must publish an approval request")
        }
        XCTAssertFalse(request.offerAlways)

        service.resolveBashApproval(taskID: 1, stepID: "step1", commandKey: held.commandKey,
                                    decision: .deny)
        _ = await held.task.value
    }

    /// Control: outside the phase the offer is unchanged for the same mode, so the suppression
    /// is scoped rather than a silent product change.
    func testOutsidePlanning_semiAutomaticStillOffersAlwaysAllow() async {
        let held = await gateHolding([bashCall("curl example.com")],
                                     policy: BashPolicy(mode: .semiAutomatic))
        defer { held.task.cancel() }

        XCTAssertEqual(delegate.bashApprovalBeganRequests.first?.offerAlways, true)

        service.resolveBashApproval(taskID: 1, stepID: "step1", commandKey: held.commandKey,
                                    decision: .deny)
        _ = await held.task.value
    }
}

// MARK: - Stub judge client

/// Minimal `LLMClient` that yields a fixed content string — used to drive the
/// Auto judge deterministically.
private final class StubJudgeClient: LLMClient, @unchecked Sendable {
    let content: String
    init(content: String) { self.content = content }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let text = content
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
