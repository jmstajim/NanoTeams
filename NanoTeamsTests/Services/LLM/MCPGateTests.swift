import XCTest

@testable import NanoTeams

/// The third approval gate: whether one MCP call may leave the machine.
///
/// Mirrors `BashGateTests` in shape because the two gates are the same design — a pure policy
/// answer, then, where that answer is "ask", a person's, taken OUTSIDE the model. What differs
/// is what the decision is about: `bash` runs a command on this machine, and this sends the
/// model's arguments to somebody else's.
///
/// `@MainActor` + `async` test methods per the documented sync-test abort gotcha (constructing
/// the `@MainActor` `LLMExecutionService` from a sync test aborts on CI).
@MainActor
final class MCPGateTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private static let folioID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.snapshot = nil  // → not under Autovisor
        service.attach(delegate: delegate)
        deniedCards = 0
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func entry(
        tool: String = "get_metadata",
        approvalMode: MCPApprovalMode = .manual,
        serverTrusted: Bool = false,
        alwaysAllowed: Bool = false,
        readOnly: Bool = false,
        destructive: Bool = true,
        hash: String = "hash",
        serverDisplayName: String = "Folio Desktop",
        serverID: UUID? = nil
    ) throws -> MCPToolsSnapshot.Entry {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: "folio", toolName: tool))
        let annotations = MCPToolAnnotations(title: nil, stated: [
            .readOnly: readOnly, .destructive: destructive, .idempotent: false, .openWorld: true,
        ])
        return MCPToolsSnapshot.Entry(
            serverID: serverID ?? Self.folioID,
            slug: slug,
            serverDisplayName: serverDisplayName,
            approvalMode: approvalMode,
            serverTrusted: serverTrusted,
            alwaysAllowed: alwaysAllowed,
            runsUnattended: true,
            descriptor: MCPToolDescriptorTests.makeDescriptor(
                originalName: tool, modelFacingName: name, annotations: annotations,
                pinHash: hash), era: .modern)
    }

    /// An entry whose descriptor is built the way a server's listing is — through the factory,
    /// from the tool as sent — so its annotations carry only what the server stated.
    private func entry(
        sentAnnotations annotations: [String: JSONValue],
        approvalMode: MCPApprovalMode,
        serverTrusted: Bool
    ) throws -> MCPToolsSnapshot.Entry {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let outcome = try MCPToolDescriptorFactory.build(
            rawTools: [.object([
                "name": .string("get_metadata"),
                "description": .string("Reads metadata."),
                "inputSchema": .object(["type": .string("object")]),
                "annotations": .object(annotations),
            ])],
            slug: slug, era: .modern)
        return MCPToolsSnapshot.Entry(
            serverID: Self.folioID,
            slug: slug,
            serverDisplayName: "Folio Desktop",
            approvalMode: approvalMode,
            serverTrusted: serverTrusted,
            alwaysAllowed: false,
            runsUnattended: true,
            descriptor: try XCTUnwrap(outcome.descriptors.first), era: .modern)
    }

    /// The step's frozen copy — and, until a test moves it with `goLive`, the live catalogue
    /// too: the gate decides from what the server list says NOW, not from what it said when
    /// the step began.
    private func resolved(_ entries: [MCPToolsSnapshot.Entry]) -> MCPResolvedTools {
        let snapshot = MCPToolsSnapshot(entries: entries, revision: 1)
        delegate.mcpTools = snapshot
        return snapshot.resolved(humanPresent: true)
    }

    /// Moves the live catalogue under a running step, the way a Settings edit, a refresh or a
    /// reconnect does. The manager bumps the revision on every rebuild. `status` is the folio
    /// server's; `nil` is a server no longer in the list at all. `rereading`, when given, puts
    /// its list in a re-read, its last committed listing having approved those entries.
    private func goLive(
        _ entries: [MCPToolsSnapshot.Entry], revision: Int = 2, status: MCPServerStatus? = nil,
        rereading lastCommitted: [MCPToolsSnapshot.Entry]? = nil
    ) {
        delegate.mcpTools = MCPToolsSnapshot(
            entries: entries,
            statusByServerID: status.map { [Self.folioID: $0] } ?? [:],
            lastCommittedApprovalsOfUnverifiedServers: lastCommitted.map { approved in
                [Self.folioID: Dictionary(
                    approved.map { ($0.modelFacingName, $0.descriptor.pinHash) },
                    uniquingKeysWith: { first, _ in first })]
            } ?? [:],
            revision: revision)
    }

    private func call(
        _ name: String = "mcp__folio__get_metadata",
        arguments: String = #"{"node":"1:2"}"#,
        providerID: String = "call_1"
    ) -> StepToolCall {
        StepToolCall(providerID: providerID, name: name, argumentsJSON: arguments)
    }

    private func task() -> NTMSTask { NTMSTask(id: 1, title: "t", supervisorTask: "g", runs: []) }

    private func gate(
        _ calls: [StepToolCall],
        tools: MCPResolvedTools,
        allowed: Set<String> = ["mcp__folio__get_metadata"],
        supervisorMode: SupervisorMode = .autonomous
    ) async -> [Int: ToolExecutionResult] {
        await service.gateMCPCalls(
            resolvedToolCalls: calls, allowedToolNames: allowed, mcpTools: tools,
            stepID: "step1", taskID: 1, supervisorMode: supervisorMode, task: task())
    }

    /// Starts the gate, waits for it to HOLD, and hands back the running task plus the hold's
    /// key so the test can resolve it. Fails if no hold appears in time.
    private func gateHolding(
        _ calls: [StepToolCall],
        tools: MCPResolvedTools,
        isPlanningPhase: Bool = false
    ) async -> (task: Task<[Int: ToolExecutionResult], Never>, callKey: String) {
        let running = Task { [service, fixture = task()] in
            await service!.gateMCPCalls(
                resolvedToolCalls: calls, allowedToolNames: ["mcp__folio__get_metadata"],
                mcpTools: tools, isPlanningPhase: isPlanningPhase,
                stepID: "step1", taskID: 1, supervisorMode: .manual, task: fixture)
        }
        for _ in 0..<500 {
            if let request = delegate.mcpApprovalBeganRequests.first {
                return (running, request.callKey)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("gate did not hold a call for approval")
        return (running, "")
    }

    /// Runs the gate and fails — rather than hanging — if it holds a card: a call the gate must
    /// not ask a person about is answered by a refusal or passed through, never held.
    ///
    /// Waits for whichever comes first, the gate returning or a card (a held card is denied, so
    /// the gate returns either way); then drains the main actor — where a card is posted — and
    /// looks again, which catches a card a straggler posts just after the gate returned ("refused
    /// AND held"). Until 2026-10-28 this watched a fixed 100 × 2 ms window whatever the gate did,
    /// ~0.25 s per call, and a gate that returned in a millisecond still paid all of it.
    private func gateExpectingNoCard(
        _ calls: [StepToolCall],
        tools: MCPResolvedTools,
        allowed: Set<String> = ["mcp__folio__get_metadata"]
    ) async -> [Int: ToolExecutionResult] {
        let returned = GateReturned()
        let running = Task { [service, fixture = task()] in
            let results = await service!.gateMCPCalls(
                resolvedToolCalls: calls, allowedToolNames: allowed, mcpTools: tools,
                stepID: "step1", taskID: 1, supervisorMode: .manual, task: fixture)
            returned.isSet = true
            return results
        }
        // A ceiling that fails, never a silent continue: a gate that neither returns nor holds a
        // card in 10 s is a gate stuck on something this test did not stage.
        let ceiling = Date().addingTimeInterval(10)
        while !returned.isSet, delegate.mcpApprovalBeganRequests.isEmpty {
            guard Date() < ceiling else {
                XCTFail("the gate neither returned nor held a card within 10 s")
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        denyEveryCard("the gate held a card for")
        let results = await running.value
        for _ in 0..<50 { await Task.yield() }
        await MainActor.run {}
        denyEveryCard("a card was posted after the gate returned, for")
        return results
    }

    /// Set by the gate's own task once `gateMCPCalls` returned — both on the main actor.
    @MainActor
    private final class GateReturned {
        var isSet = false
    }

    /// Fails for, and denies, every card not denied yet — so a held gate returns and a straggler's
    /// card does not outlive the test.
    private func denyEveryCard(_ failure: String) {
        for request in delegate.mcpApprovalBeganRequests.dropFirst(deniedCards) {
            XCTFail("\(failure) \(request.toolName)")
            service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: request.callKey, decision: .deny)
        }
        deniedCards = delegate.mcpApprovalBeganRequests.count
    }

    /// How many cards `denyEveryCard` has already failed and denied in this test.
    private var deniedCards = 0

    /// Waits for a card for `toolName`; `nil` when none appears in time.
    private func heldCard(for toolName: String) async -> MCPApprovalRequest? {
        for _ in 0..<500 {
            if let request = delegate.mcpApprovalBeganRequests.first(where: { $0.toolName == toolName }) {
                return request
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    private func executorCode(_ result: ToolExecutionResult) throws -> String {
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        return try XCTUnwrap(dict["error"] as? String)
    }

    private func errorCode(_ result: ToolExecutionResult) throws -> String {
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        let error = try XCTUnwrap(dict["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? String)
    }

    private func message(_ result: ToolExecutionResult) throws -> String {
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        let error = try XCTUnwrap(dict["error"] as? [String: Any])
        return try XCTUnwrap(error["message"] as? String)
    }

    // MARK: - Nothing to gate

    func testARunWithNoMCPToolsGatesNothing() async throws {
        let results = await gate([call()], tools: .empty)
        XCTAssertTrue(results.isEmpty)
    }

    func testATurnWithNoMCPCallGatesNothing() async throws {
        let tools = resolved([try entry()])
        let results = await gate(
            [StepToolCall(name: ToolNames.readFile, argumentsJSON: "{}")],
            tools: tools, allowed: [ToolNames.readFile, "mcp__folio__get_metadata"])
        XCTAssertTrue(results.isEmpty)
    }

    /// A name the step did not ship — withheld, drifted, or another role's — belongs to the
    /// executor's classifier, which has the facts to say WHICH. Answering it here with an
    /// approval verdict would decide a call that was never going to run.
    func testACallOutsideTheAllowedSetIsLeftToTheClassifier() async throws {
        let tools = resolved([try entry()])
        let results = await gate([call()], tools: tools, allowed: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - The policy's answer, without anyone being asked

    func testAStandingGrantPassesThrough() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true)])
        let results = await gate([call()], tools: tools)
        XCTAssertTrue(results.isEmpty)
    }

    /// The one place a server's own claim about itself lowers friction, and it takes a switch
    /// a person threw by hand.
    func testATrustedServersReadOnlyToolPassesThrough() async throws {
        let tools = resolved([
            try entry(approvalMode: .semiAutomatic, serverTrusted: true, readOnly: true, destructive: false),
        ])
        let results = await gate([call()], tools: tools)
        XCTAssertTrue(results.isEmpty)
    }

    func testAnUntrustedServersReadOnlyClaimDoesNotClearACall() async throws {
        let tools = resolved([
            try entry(approvalMode: .semiAutomatic, serverTrusted: false, readOnly: true, destructive: false),
        ])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.approvalUnavailable.rawValue)
    }

    /// The trusted bypass end to end: a server that states only `readOnlyHint` — the usual way
    /// to mark a read tool — has the call go out with nobody asked, because the spec reads
    /// `destructiveHint` only for a tool that writes.
    ///
    /// RED until 2026-09-24: the destructive default counted, the policy asked, and with nobody
    /// to answer the call was refused as needing approval.
    func testATrustedServersToolStatingOnlyReadOnlyPassesThroughTheGate() async throws {
        let tools = resolved([try entry(
            sentAnnotations: ["readOnlyHint": .bool(true)], approvalMode: .semiAutomatic, serverTrusted: true)])
        let results = await gate([call()], tools: tools)
        XCTAssertTrue(results.isEmpty, "\(results.mapValues(\.outputJSON))")
    }

    /// Untrusted, the same tool is refused — and the model reads why: the server is not marked
    /// trusted, not that it contradicted itself.
    ///
    /// RED until 2026-09-24: the refusal said "read-only and as destructive at once".
    func testAnUntrustedServersToolStatingOnlyReadOnlyIsRefusedAsNotTrusted() async throws {
        let tools = resolved([try entry(
            sentAnnotations: ["readOnlyHint": .bool(true)], approvalMode: .semiAutomatic, serverTrusted: false)])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.approvalUnavailable.rawValue)
        let text = try message(result)
        XCTAssertTrue(text.contains("not marked trusted"), text)
        XCTAssertFalse(text.contains("at once"), text)
    }

    /// A server that states read-only AND destructive gets no bypass from its trust mark.
    func testATrustedServerStatingBothIsRefusedWithTheContradictionNamed() async throws {
        let tools = resolved([try entry(
            sentAnnotations: ["readOnlyHint": .bool(true), "destructiveHint": .bool(true)],
            approvalMode: .semiAutomatic, serverTrusted: true)])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.approvalUnavailable.rawValue)
        let text = try message(result)
        XCTAssertTrue(text.contains("at once"), text)
    }

    // MARK: - Nobody to ask

    func testWithNoHumanAnAskBecomesApprovalUnavailable() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic)])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.approvalUnavailable.rawValue)
        XCTAssertTrue(result.isError)
        // The policy's own reason is composed in, so the model is told WHY approval was
        // needed rather than only that it was.
        let text = try message(result)
        XCTAssertTrue(text.contains("making destructive changes"), text)
    }

    /// The refusal the model receives says what the SERVER said only where it said it. A tool
    /// its server sent no annotations for is described by how the app treats it; the same tool
    /// stated destructive is the server's claim, and says so.
    ///
    /// RED until 2026-10-28: the no-annotations tool was refused "(the server marks this tool
    /// as making destructive changes)" — both values were the spec's defaults (F54, the half the
    /// model reads).
    func testTheNoHumanRefusalAttributesToTheServerOnlyWhatItStated() async throws {
        let silent = resolved([try entry(sentAnnotations: [:], approvalMode: .semiAutomatic, serverTrusted: true)])
        let silentResults = await gate([call()], tools: silent)
        let silentText = try message(try XCTUnwrap(silentResults[0]))
        XCTAssertTrue(silentText.contains(
            "(\(MCPPermissionService.reasonForAsking(.writesAssumed)))"), silentText)
        XCTAssertFalse(silentText.contains("the server marks"), silentText)

        let stated = resolved([try entry(
            sentAnnotations: ["destructiveHint": .bool(true)], approvalMode: .semiAutomatic, serverTrusted: true)])
        let statedResults = await gate([call()], tools: stated)
        let statedText = try message(try XCTUnwrap(statedResults[0]))
        XCTAssertTrue(statedText.contains(
            "(\(MCPPermissionService.reasonForAsking(.destructiveStated)))"), statedText)
    }

    /// The reader is the model, and the escalation channel it holds reaches the same answerer
    /// that cannot approve (KNOWN_ISSUES A15).
    func testTheNoHumanRefusalIsThirdPersonAndOffersNoChannel() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic)])
        let results = await gate([call()], tools: tools)
        let text = try message(try XCTUnwrap(results[0]))
        XCTAssertFalse(text.lowercased().contains("your approval"), text)
        XCTAssertFalse(text.contains(ToolNames.askSupervisor), text)
        XCTAssertTrue(text.contains("take a different step"), text)
    }

    /// The chain: every synthetic result carries the call's `providerID`, or the wire has an
    /// orphaned tool call and the request fails with HTTP 400.
    func testEverySyntheticResultCarriesTheCallsProviderID() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic)])
        let results = await gate([call(providerID: "call_xyz")], tools: tools)
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(result.providerID, "call_xyz")
    }

    // MARK: - Held, and then decided

    func testManualModeHoldsEvenAToolThePolicyWouldOtherwiseClear() async throws {
        // Trusted server, read-only, not destructive — step 3's allow — but Manual asks
        // ABOVE that bypass, because the user asked to see every call.
        let tools = resolved([
            try entry(approvalMode: .manual, serverTrusted: true, readOnly: true, destructive: false),
        ])
        let held = await gateHolding([call()], tools: tools)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .allow)
        let results = await held.task.value
        XCTAssertTrue(results.isEmpty, "Allow must let the call run for real")
    }

    func testDenyProducesTheMCPDeniedEnvelope() async throws {
        let tools = resolved([try entry()])
        let held = await gateHolding([call()], tools: tools)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        let results = await held.task.value
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.mcpDenied.rawValue)
        // Third person: "you" everywhere else in this tree means the model itself.
        XCTAssertEqual(try message(result), "The Supervisor declined this call.")
    }

    /// No card is held for a call the send path refuses before anything leaves. A document that
    /// is not a JSON object — prose, a list, a number — is refused by the tool
    /// (`MCPDynamicTool.preflight` runs that refusal), so the gate passes it on to it instead of
    /// holding a card whose Allow would change nothing. A `null` document is no arguments, sent
    /// as `{}`, and is asked about like any other call.
    ///
    /// RED until 2026-10-28: the gate held a card for "hello"; the person's Allow released a
    /// call the tool then refused without sending.
    func testACallWhoseArgumentsCannotBeSentIsNeverHeldForAPerson() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        for document in ["hello", "[]", "5", "{not json}", "Null"] {
            let results = await gateExpectingNoCard([call(arguments: document)], tools: tools)
            XCTAssertNil(results[0], "\(document): passed on to the tool's own refusal, with no card")
        }

        let held = await gateHolding([call(arguments: "null")], tools: tools)
        XCTAssertEqual(delegate.mcpApprovalBeganRequests.first?.hasNoArguments, true,
                       "a null document is a call that is sent — with no arguments — and is asked about")
        service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        let results = await held.task.value
        XCTAssertEqual(try errorCode(try XCTUnwrap(results[0])), ToolErrorCode.mcpDenied.rawValue)
    }

    /// Not a denial: the run was paused while the call was held. `MCP_DENIED` would earn the
    /// don't-retry direction for a block that does not exist — and this envelope is PERSISTED
    /// into the step's conversation, so it would still be telling the model on resume that a
    /// person had refused, while the same call is re-held.
    func testAnAbandonedHoldIsCancelledAndNotDenied() async throws {
        let tools = resolved([try entry()])
        let held = await gateHolding([call()], tools: tools)
        service.failPendingMCPApprovals(stepID: "step1", taskID: 1)
        let results = await held.task.value
        let result = try XCTUnwrap(results[0])
        XCTAssertTrue(result.isCancellationEnvelope)
        XCTAssertFalse(result.outputJSON.contains(ToolErrorCode.mcpDenied.rawValue))
    }

    /// Idempotent by construction: a decision that landed first is never overwritten by a
    /// teardown sweep.
    func testATeardownDoesNotOverwriteADecisionThatLandedFirst() async throws {
        let tools = resolved([try entry()])
        let held = await gateHolding([call()], tools: tools)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        service.failPendingMCPApprovals(stepID: "step1", taskID: 1)
        let results = await held.task.value
        let result = try XCTUnwrap(results[0])
        XCTAssertEqual(try errorCode(result), ToolErrorCode.mcpDenied.rawValue)
    }

    func testResolvingAnUnheldCallIsANoOp() {
        service.resolveMCPApproval(
            taskID: 99, stepID: "nope", callKey: "nothing", decision: .allow)
    }

    // MARK: - The policy as it stands now, not as it stood at step entry (F20)

    /// A person withdraws "Always allow" in Settings while a step runs. The step's frozen copy
    /// still says "always"; the next call must be decided by what the person said since.
    func testWithdrawnAlwaysAllowMidStepAsksAgain() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true)])
        goLive([try entry(approvalMode: .semiAutomatic, alwaysAllowed: false)])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "a withdrawn grant must not clear the next call")
        XCTAssertEqual(try errorCode(result), ToolErrorCode.approvalUnavailable.rawValue)
    }

    /// Switching the server to Manual mid-step: the very next call is held for a person, and
    /// Manual offers no standing grant on its card.
    func testManualModeSwitchMidStepHoldsNextCall() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true)])
        goLive([try entry(approvalMode: .manual, alwaysAllowed: true)])
        let held = await gateHolding([call()], tools: tools)
        XCTAssertEqual(delegate.mcpApprovalBeganRequests.first?.offerAlways, false)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        let results = await held.task.value
        XCTAssertEqual(try errorCode(try XCTUnwrap(results[0])), ToolErrorCode.mcpDenied.rawValue)
    }

    /// Un-marking a server trusted withdraws the one bypass the mark bought — mid-step too.
    func testUntrustingAServerMidStepWithdrawsTheReadOnlyBypass() async throws {
        let tools = resolved([
            try entry(approvalMode: .semiAutomatic, serverTrusted: true, readOnly: true, destructive: false),
        ])
        goLive([
            try entry(approvalMode: .semiAutomatic, serverTrusted: false, readOnly: true, destructive: false),
        ])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "an untrusted server's read-only claim clears nothing")
        XCTAssertEqual(try errorCode(result), ToolErrorCode.approvalUnavailable.rawValue)
    }

    /// The rule reads both ways: a grant a person gave in Settings mid-step clears the next
    /// call — it is the person's decision, made outside the model, like any other.
    func testAStandingGrantGivenMidStepClearsTheNextCall() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic)])
        goLive([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true)])
        let results = await gate([call()], tools: tools)
        XCTAssertTrue(results.isEmpty, "the live grant must clear the call")
    }

    /// The card shows the server as it stands now — renamed, or its trust changed — while the
    /// tool text on it is still the one the model called against (the hashes agree, or the
    /// call would not have reached a card).
    func testTheCardShowsTheServerAsItStandsNow() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        goLive([try entry(approvalMode: .manual, serverTrusted: true, serverDisplayName: "Folio")])
        let held = await gateHolding([call()], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        XCTAssertEqual(request.serverDisplayName, "Folio")
        XCTAssertTrue(request.serverTrusted)
        XCTAssertEqual(request.pinHash, "hash")
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    // MARK: - The text the model called against

    /// The server rewrote the tool AFTER the iteration's drift check — while the model was
    /// generating the turn that calls it. The call was written against the old text, so it is
    /// refused as changed, whatever the policy of the new text would say, and nobody is asked.
    func testAToolRewrittenSinceTheIterationBeganIsRefusedAsChanged() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true, hash: "h1")])
        goLive([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true, hash: "h2")])
        let results = await gate([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "a call made against another text must not go out")
        XCTAssertEqual(try executorCode(result), "mcp_tool_changed")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.providerID, "call_1")
    }

    /// Under Manual, with a person watching: the rewritten tool is still refused BEFORE a card —
    /// a card would show the person a text other than the one the model called against.
    func testARewrittenToolIsNeverPutInFrontOfAPerson() async throws {
        let tools = resolved([try entry(approvalMode: .manual, hash: "h1")])
        goLive([try entry(approvalMode: .manual, hash: "h2")])
        let results = await gateExpectingNoCard([call()], tools: tools)
        XCTAssertEqual(try executorCode(try XCTUnwrap(results[0])), "mcp_tool_changed")
    }

    // MARK: - A tool the live catalogue no longer publishes

    /// Connected, and the tool has left its catalogue since the iteration began — withdrawn by
    /// the server, or its approval revoked. There is no current policy to decide the call
    /// under, so the gate answers it itself, as the drift check would have, and asks nobody.
    ///
    /// RED until 2026-09-23 (review of A2): the gate passed such a call on to the invoker,
    /// which checks the route and the text and never the approval mode.
    func testACallWhoseToolLeftItsConnectedServersCatalogueIsRefusedAsChanged() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        goLive([], status: .connected(era: .modern))
        let results = await gateExpectingNoCard([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "a call with no current policy must not pass the gate")
        XCTAssertEqual(try executorCode(result), "mcp_tool_changed")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.providerID, "call_1")
    }

    /// The gate is the last component that applies a POLICY: past it, the invoker checks only
    /// that a route exists and carries the called text. A server between sessions can hold a
    /// route its catalogue entry has already left — a listing that lands on a session that
    /// failed — so a Manual call passed on here would go out with no card. Every status that
    /// is not a live session is answered here, the way the drift check answers it.
    func testACallWhoseServerIsNotConnectedIsRefusedHereAndNeverPassedOn() async throws {
        let statuses: [MCPServerStatus] = [.connecting, .failed(reason: "timed out")]
        for status in statuses {
            let tools = resolved([try entry(approvalMode: .manual)])
            goLive([], status: status)
            let results = await gateExpectingNoCard([call()], tools: tools)
            let result = try XCTUnwrap(results[0], "\(status): the call must not pass the gate")
            XCTAssertEqual(try executorCode(result), "mcp_server_not_connected", "\(status)")
        }
    }

    /// A server that waits for a person — a rejected credential, a refused address, a server
    /// this client cannot speak to, a server switched off — is refused here too, with no card,
    /// and with the refusal that says so: "not connected … call it again later" would invite a
    /// call nothing in the step can make succeed.
    ///
    /// RED until 2026-09-23 (A2 verification): the first two answered `mcp_server_not_connected`;
    /// the other two until the status could tell them from a reconnect (group C, item 13).
    func testACallWhoseServerNeedsAPersonIsRefusedAsNeedingAttentionWithNoCard() async throws {
        let statuses: [MCPServerStatus] = [
            .needsAuth(reason: "401"), .unsupportedTransport(reason: "http"),
            .incompatible(reason: "2027-01-01"), .disabled,
        ]
        for status in statuses {
            let tools = resolved([try entry(approvalMode: .manual)])
            goLive([], status: status)
            let results = await gateExpectingNoCard([call()], tools: tools)
            let result = try XCTUnwrap(results[0], "\(status): the call must not pass the gate")
            XCTAssertEqual(try executorCode(result), "mcp_server_needs_attention", "\(status)")
            XCTAssertTrue(result.isError, "\(status)")
        }
    }

    /// A connected server re-reading its tool list after its listing failed: refused here with
    /// the reason that says so, and never put in front of a person — nothing says which text a
    /// card would be showing. Refused even for an entry that still reads as published under a
    /// Manual policy, which would otherwise hold a card: the re-read is read first.
    ///
    /// RED until 2026-09-24 (group C): refused as `mcp_tool_changed`, and a published entry of
    /// an unverified server would have been held for a person.
    func testACallWhoseServerRereadsItsToolsIsRefusedAsBeingRereadWithNoCard() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        goLive(
            [try entry(approvalMode: .manual)], status: .connected(era: .modern),
            rereading: [try entry(approvalMode: .manual)])
        let results = await gateExpectingNoCard([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "the call must not pass the gate")
        XCTAssertEqual(try executorCode(result), "mcp_tools_being_reread")
        XCTAssertTrue(result.isError)
    }

    /// The gate reads the same committed verdict as the drift check: a frozen tool the last
    /// committed listing had rewritten out of its approval is refused as changed while its
    /// server's list is being read again — not invited back — and nobody is asked.
    ///
    /// RED until 2026-09-24 (group C, C-5): refused as `mcp_tools_being_reread`.
    func testACallToAToolTheLastCommitRewroteStaysChangedWhileTheListIsReadAgain() async throws {
        let tools = resolved([try entry(approvalMode: .manual, hash: "h1")])
        goLive(
            [], status: .connected(era: .modern),
            rereading: [try entry(approvalMode: .manual, hash: "h2")])
        let results = await gateExpectingNoCard([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "the call must not pass the gate")
        XCTAssertEqual(try executorCode(result), "mcp_tool_changed")
    }

    /// A server removed from the list does not come back under the same id — a server added
    /// later is another one — so its tool is gone for the rest of the step: changed, not
    /// "not connected", whose text invites a later call.
    func testACallToARemovedServerIsRefusedAsChanged() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true)])
        goLive([], status: nil)
        let results = await gate([call()], tools: tools)
        XCTAssertEqual(try executorCode(try XCTUnwrap(results[0])), "mcp_tool_changed")
    }

    /// No live catalogue at all (no manager) grants nothing: the call is refused, not passed on.
    func testNoLiveCatalogueAtAllRefusesTheCallRatherThanPassingItOn() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic, alwaysAllowed: true)])
        delegate.mcpTools = nil
        let results = await gate([call()], tools: tools)
        XCTAssertEqual(try executorCode(try XCTUnwrap(results[0])), "mcp_tool_changed")
    }

    /// The same model-facing name, now published by ANOTHER server: one server was renamed
    /// away from the slug and another took it. The call is routed by the step's frozen entry
    /// to the server it was set up with, so deciding it under the new owner's policy would
    /// apply neither server's rules to it. Refused as changed, and nobody is asked.
    func testTheSameNameOnAnotherServerIsNotDecidedUnderThatServersPolicy() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        goLive([try entry(
            approvalMode: .semiAutomatic, serverTrusted: true, alwaysAllowed: true, serverID: UUID())])
        let results = await gateExpectingNoCard([call()], tools: tools)
        let result = try XCTUnwrap(results[0], "another server's standing grant must not clear this call")
        XCTAssertEqual(try executorCode(result), "mcp_tool_changed")
    }

    /// A held card is minutes of the world moving on. The NEXT call of the same batch is
    /// decided against the catalogue as it stands after the wait, not as it stood before it.
    func testTheNextCallOfABatchIsDecidedAgainstThePolicyAfterTheHold() async throws {
        let first = try entry(tool: "get_metadata", approvalMode: .semiAutomatic)
        let second = try entry(tool: "get_screenshot", approvalMode: .semiAutomatic, alwaysAllowed: true)
        let tools = resolved([first, second])
        let calls = [call(), call("mcp__folio__get_screenshot", providerID: "call_2")]
        let allowed: Set<String> = ["mcp__folio__get_metadata", "mcp__folio__get_screenshot"]
        let running = Task { [service, fixture = task()] in
            await service!.gateMCPCalls(
                resolvedToolCalls: calls, allowedToolNames: allowed, mcpTools: tools,
                stepID: "step1", taskID: 1, supervisorMode: .manual, task: fixture)
        }
        let firstCard = await heldCard(for: "mcp__folio__get_metadata")
        XCTAssertNotNil(firstCard, "premise: the first call is held")
        // While the first card waits, the person withdraws the second tool's grant.
        goLive([first, try entry(tool: "get_screenshot", approvalMode: .semiAutomatic)])
        if let firstCard {
            service.resolveMCPApproval(
                taskID: 1, stepID: "step1", callKey: firstCard.callKey, decision: .allow)
        }
        let secondCard = await heldCard(for: "mcp__folio__get_screenshot")
        XCTAssertNotNil(secondCard, "the second call must be asked about under the grant as it stands now")
        if let secondCard {
            service.resolveMCPApproval(
                taskID: 1, stepID: "step1", callKey: secondCard.callKey, decision: .deny)
        }
        let results = await running.value
        XCTAssertNil(results[0], "the first call was allowed")
        XCTAssertEqual(try errorCode(try XCTUnwrap(results[1])), ToolErrorCode.mcpDenied.rawValue)
    }

    // MARK: - What the card carries

    /// The one thing a decider about an outbound call must be able to read in full: what is
    /// leaving the machine. The documented exfiltration route is an argument carrying more
    /// than the task needs.
    func testTheCardCarriesTheWholeArgumentsDocument() async throws {
        let arguments = #"{"node":"1:2","note":"a long value the card must not elide"}"#
        let tools = resolved([try entry()])
        let held = await gateHolding([call(arguments: arguments)], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        XCTAssertEqual(request.outgoing.arguments, JSONValue(json: arguments), "every member, whole")
        XCTAssertEqual(
            request.argumentsDisplay.display,
            "{\n  \"node\": \"1:2\",\n  \"note\": \"a long value the card must not elide\"\n}")
        XCTAssertEqual(request.callKey, LLMExecutionService.mcpCallKey(toolName: request.toolName, argumentsJSON: arguments),
                       "the document the model wrote is the hold's identity")
        XCTAssertEqual(request.toolName, "mcp__folio__get_metadata")
        XCTAssertEqual(request.serverSlug, "folio")
        XCTAssertEqual(request.serverDisplayName, "Folio Desktop")
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    func testTwoCallsOfOneToolWithDifferentArgumentsAreTwoDecisions() {
        let first = LLMExecutionService.mcpCallKey(
            toolName: "mcp__folio__get_metadata", argumentsJSON: #"{"node":"1"}"#)
        let second = LLMExecutionService.mcpCallKey(
            toolName: "mcp__folio__get_metadata", argumentsJSON: #"{"node":"2"}"#)
        XCTAssertNotEqual(first, second)
    }

    /// Manual mode means every call is reviewed individually, so nothing may persist a
    /// standing allow there.
    func testAlwaysIsNotOfferedUnderManualApproval() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        let held = await gateHolding([call()], tools: tools)
        XCTAssertEqual(delegate.mcpApprovalBeganRequests.first?.offerAlways, false)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    /// A standing grant takes effect AFTER the planning boundary, under the full toolset,
    /// with no further review — and it is created inside the transcript the boundary discards.
    func testAlwaysIsNotOfferedDuringThePlanningPhase() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic)])
        let held = await gateHolding([call()], tools: tools, isPlanningPhase: true)
        XCTAssertEqual(delegate.mcpApprovalBeganRequests.first?.offerAlways, false)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    func testAlwaysIsOfferedUnderSemiAutomaticOutsideThePhase() async throws {
        let tools = resolved([try entry(approvalMode: .semiAutomatic)])
        let held = await gateHolding([call()], tools: tools)
        XCTAssertEqual(delegate.mcpApprovalBeganRequests.first?.offerAlways, true)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    /// A card outliving its run would render under a same-numbered task in the next folder.
    func testTheCardIsWithdrawnWhenTheHoldEnds() async throws {
        let tools = resolved([try entry()])
        let held = await gateHolding([call()], tools: tools)
        XCTAssertEqual(delegate.mcpApprovalBeganRequests.count, 1)
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)
    }

    /// A Pause cancels the step task, and the cancellation handler is what resolves the
    /// waiter — not `failPendingMCPApprovals`, which is the teardown route. Both fail safe;
    /// this pins that the await returns promptly rather than hanging on a continuation
    /// nothing will resume.
    func testCancellingTheStepTaskResolvesTheHoldAsCancelled() async throws {
        let tools = resolved([try entry()])
        let held = await gateHolding([call()], tools: tools)
        held.task.cancel()
        let results = await held.task.value
        let result = try XCTUnwrap(results[0])
        XCTAssertTrue(result.isCancellationEnvelope)
    }

    /// The card carries the tool's annotations WHOLE — every hint, and which ones the server
    /// stated — so it reads them exactly as the review sheet does. Until 2026-09-24 the request
    /// carried two hints and rebuilt the other two as `false`: a tool the server marked open-world
    /// lost that chip on the card while the review sheet showed it (F31, F54).
    func testTheCardCarriesTheToolsWholeAnnotations() async throws {
        let tools = resolved([try entry(readOnly: true, destructive: true)])
        let held = await gateHolding([call()], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        let frozen = try XCTUnwrap(tools.shipped.first).descriptor.annotations

        XCTAssertEqual(request.annotations, frozen)
        XCTAssertTrue(request.annotations.openWorldHint, "the open-world claim reaches the card")
        XCTAssertEqual(request.annotationChips, frozen.chips, "the card and the review sheet read one source")
        XCTAssertEqual(request.id, "1:step1:\(held.callKey)")
        service.resolveMCPApproval(
            taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    func testFullTeardownDropsEveryPublishedCard() async throws {
        let tools = resolved([try entry()])
        let held = await gateHolding([call()], tools: tools)
        service.cancelAllExecutions()
        _ = await held.task.value
        XCTAssertEqual(delegate.clearAllMCPApprovalRequestsCallCount, 1)
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)
    }

    // MARK: - One preflight: whether a card is held, and what it shows (2026-10-28)

    /// Records every call that reached the invoker — the last seam before the wire.
    private final class RecordingInvoker: MCPToolInvoking, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [MCPToolCall] = []
        var received: [MCPToolCall] { lock.withLock { calls } }

        func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult {
            lock.withLock { calls.append(call) }
            return MCPCallToolResult(contentBlocks: [])
        }
    }

    /// A Manual server's `get_metadata` whose schema declares `properties` and mirrors
    /// `headerParams` into headers (in `era`) — the shape the runtime's type gate and the
    /// coercion read.
    private func declaringEntry(
        properties: [String: JSONSchemaProperty], headerParams: [MCPHeaderParam] = [],
        era: MCPProtocolEra = .modern
    ) throws -> MCPToolsSnapshot.Entry {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        return MCPToolsSnapshot.Entry(
            serverID: Self.folioID,
            slug: slug,
            serverDisplayName: "Folio Desktop",
            approvalMode: .manual,
            serverTrusted: false,
            alwaysAllowed: false,
            runsUnattended: true,
            descriptor: MCPToolDescriptor(
                originalName: "get_metadata",
                modelFacingName: "mcp__folio__get_metadata",
                displayDescription: "Reads metadata.",
                inputSchema: JSONSchema.object(properties: properties, required: []),
                outputSchema: nil,
                annotations: .specDefaults,
                headerParams: headerParams,
                callShapeDependsOnEra: !headerParams.isEmpty,
                pinHash: "hash",
                rawTool: .object(["name": .string("get_metadata")]),
                strippedHiddenCharacters: false), era: era)
    }

    /// The step's frozen copy carrying `invoker`, so the runtime built from it sends through it.
    private func resolved(_ entries: [MCPToolsSnapshot.Entry], invoker: any MCPToolInvoking) -> MCPResolvedTools {
        let snapshot = MCPToolsSnapshot(entries: entries, revision: 1, invoker: invoker)
        delegate.mcpTools = snapshot
        return snapshot.resolved(humanPresent: true)
    }

    /// What the runtime a step builds from `tools` answers for `call` — the half after the gate.
    private func runtimeResult(_ call: StepToolCall, tools: MCPResolvedTools) async throws -> ToolExecutionResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: root, toolCallsLogURL: nil, mcpTools: tools)
        let results = await runtime.executeAll(
            context: ToolExecutionContext(workFolderRoot: root, taskID: 1, runID: 0, roleID: "step1"),
            toolCalls: [call])
        return try XCTUnwrap(results.first)
    }

    /// A call the runtime's argument type gate refuses — `"ten"` for an integer the server's
    /// schema declares — is refused before anything is sent, so a person is not asked about it:
    /// no card, the call passed on, and the runtime's own `INVALID_ARGS` is what the model reads.
    ///
    /// RED until 2026-10-28: the gate read only whether the document was a JSON object, held
    /// a card for it, and the person's Allow released a call the type gate then refused.
    func testACallTheTypeGateRefusesIsNeverHeldAndNothingIsSent() async throws {
        let invoker = RecordingInvoker()
        let tools = resolved([try declaringEntry(properties: ["limit": JSONSchema.integer()])], invoker: invoker)
        let refused = call(arguments: #"{"limit":"ten"}"#)

        let results = await gateExpectingNoCard([refused], tools: tools)
        XCTAssertNil(results[0], "passed on to the runtime's own refusal, with no card")
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)

        let result = try await runtimeResult(refused, tools: tools)
        XCTAssertEqual(try errorCode(result), ToolErrorCode.invalidArgs.rawValue, result.outputJSON)
        XCTAssertTrue(invoker.received.isEmpty, "nothing reached the wire")
    }

    /// A header parameter given a value no header can carry — an object, or an integer outside
    /// the spec's safe range — fails the call in the coercion before anything is sent, so it is
    /// not put to a person either. (A line break is not among them: the spec sends it
    /// through its Base64 sentinel — `testAHeaderValueTheSpecEncodesIsHeldSpelledOutAndSentWhole`.)
    ///
    /// RED until 2026-10-28: a card was held; its Allow released only the coercion's refusal.
    func testACallTheCoercionRefusesIsNeverHeldAndNothingIsSent() async throws {
        let invoker = RecordingInvoker()
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let n = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        let tools = resolved(
            [try declaringEntry(properties: ["account": JSONSchema.string(), "n": JSONSchema.integer()],
                                headerParams: [account, n])],
            invoker: invoker)
        let cases: [(String, MCPArgumentCoercion.Failure)] = [
            (#"{"account":{"id":1},"node":"1"}"#, .headerValueNotAScalar(argument: "account")),
            (#"{"n":9007199254740992}"#, .headerValueOutsideSafeIntegerRange(argument: "n")),
        ]
        for (document, failure) in cases {
            let results = await gateExpectingNoCard([call(arguments: document)], tools: tools)
            XCTAssertNil(results[0], "\(document): passed on to the coercion's own refusal, with no card")
            let result = try await runtimeResult(call(arguments: document), tools: tools)
            XCTAssertTrue(result.isError, document)
            XCTAssertTrue(result.outputJSON.contains(failure.message), "\(document): \(result.outputJSON)")
        }
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)
        XCTAssertTrue(invoker.received.isEmpty, "nothing reached the wire")
    }

    /// The card shows what the server will receive, not the document as the model wrote it: an
    /// envelope around the arguments is shown as the arguments inside it, a key the runtime drops
    /// is not shown, a key it trims is shown trimmed — laid out as the sent value, keys in order.
    ///
    /// RED until 2026-10-28: the card showed the raw document — the envelope whole, the
    /// empty key and the untrimmed one as written.
    func testTheCardShowsTheArgumentsTheServerWillReceive() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        let sent = "{\n  \"node\": \"9\"\n}"
        for document in [
            #"{"name":"mcp__folio__get_metadata","arguments":{"node":"9"}}"#,
            #"{"":"x","node":"9"}"#,
            #"{" node ":"9"}"#,
            #"{"node":"9"}"#,
        ] {
            delegate.mcpApprovalBeganRequests.removeAll()
            let held = await gateHolding([call(arguments: document)], tools: tools)
            let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first, document)
            XCTAssertEqual(request.argumentsDisplay.display, sent, document)
            XCTAssertFalse(request.hasNoArguments, document)
            service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
            _ = await held.task.value
        }
    }

    /// A header parameter of a modern-era server leaves the machine twice — in the body and,
    /// mirrored, as a request header every intermediary can read — so the card shows it in both:
    /// the body, then the header under its own heading.
    ///
    /// RED until 2026-10-28: the card showed the document, and nothing said the value would
    /// travel as a header, or the value was shown — and sent — as a header ALONE.
    func testTheCardShowsAHeaderParameterInTheBodyAndAsTheHeaderItIsMirroredInto() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let tools = resolved([try declaringEntry(properties: ["account": JSONSchema.string()], headerParams: [account])])
        let held = await gateHolding([call(arguments: #"{"account":"X1","node":"1:2"}"#)], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        XCTAssertEqual(request.outgoing, MCPDynamicTool.OutgoingCall(
            arguments: .object(["account": .string("X1"), "node": .string("1:2")]),
            headerParameters: ["Mcp-Param-Account": "X1"]))
        XCTAssertEqual(
            request.argumentsDisplay.display,
            "{\n  \"account\": \"X1\",\n  \"node\": \"1:2\"\n}\n\n\(MCPApprovalRequest.headerParametersHeading)\nMcp-Param-Account: \"X1\"")
        service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    // MARK: - The era, what the box spells out, and the order the gate asks in (2026-10-28)

    /// With nobody to approve it, a call the runtime would refuse is passed on to that refusal —
    /// the model reads what is wrong with its arguments — rather than told nobody can approve a
    /// call that could never be sent. The preflight runs first; only a call that would be sent
    /// meets the presence check.
    ///
    /// RED until 2026-10-28: the gate checked presence before the preflight and answered
    /// `APPROVAL_UNAVAILABLE`.
    func testWithNoHumanACallTheRuntimeRefusesIsPassedOnToThatRefusal() async throws {
        let invoker = RecordingInvoker()
        let tools = resolved([try declaringEntry(properties: ["limit": JSONSchema.integer()])], invoker: invoker)
        let refused = call(arguments: #"{"limit":"ten"}"#)

        let results = await gate([refused], tools: tools, supervisorMode: .autonomous)
        XCTAssertNil(results[0], "passed on to the runtime's own refusal: \(results[0]?.outputJSON ?? "")")
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)

        let result = try await runtimeResult(refused, tools: tools)
        XCTAssertEqual(try errorCode(result), ToolErrorCode.invalidArgs.rawValue, result.outputJSON)
        XCTAssertTrue(invoker.received.isEmpty, "nothing reached the wire")
    }

    /// A call that WOULD be sent, with nobody to approve it, is still `APPROVAL_UNAVAILABLE`.
    func testWithNoHumanACallThatWouldBeSentIsStillApprovalUnavailable() async throws {
        let invoker = RecordingInvoker()
        let tools = resolved([try declaringEntry(properties: ["limit": JSONSchema.integer()])], invoker: invoker)
        let results = await gate([call(arguments: #"{"limit":10}"#)], tools: tools, supervisorMode: .autonomous)
        XCTAssertEqual(try errorCode(try XCTUnwrap(results[0])), ToolErrorCode.approvalUnavailable.rawValue)
        XCTAssertTrue(invoker.received.isEmpty)
    }

    /// A header value carrying characters that hide — a variation selector from the supplement
    /// (a byte of hidden payload each) and a Hangul filler — passes the coercion, so it is SHOWN:
    /// spelled out on its header line, with the warning, like the body.
    ///
    /// Pins that the header lines are not appended to the box unescaped.
    func testAHeaderValueThatHidesCharactersIsSpelledOutOnItsHeaderLine() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let tools = resolved([try declaringEntry(properties: ["account": JSONSchema.string()], headerParams: [account])])
        let held = await gateHolding([call(arguments: #"{"account":"X1\udb40\udd01\u3164"}"#)], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        XCTAssertEqual(request.outgoing.headerParameters, ["Mcp-Param-Account": "X1\u{E0101}\u{3164}"], "premise")
        let shown = request.argumentsDisplay
        XCTAssertTrue(shown.hadHidden)
        XCTAssertTrue(shown.display.hasSuffix("\nMcp-Param-Account: \"X1\\u{E0101}\\u{3164}\""), shown.display)
        service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    /// A header value the spec says to Base64-encode — a line separator, CR/LF, a ZWNJ — is put to
    /// a person like any other call: its header line prints the value as a JSON string, the body's
    /// own quoting, so a separator is spelled out and flagged and a CR/LF reads as its escape on
    /// ONE line; and the call the person allows reaches the invoker with the value whole, for the
    /// transport's sentinel.
    ///
    /// RED until 2026-10-28: such a call was refused before a card (the spec's Value Encoding says
    /// "clients MUST use Base64 encoding", not refuse).
    func testAHeaderValueTheSpecEncodesIsHeldSpelledOutAndSentWhole() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        for (document, value, line, flagged) in [
            (#"{"account":"alex Mcp-Param-Locale: en"}"#, "alex\u{2028}Mcp-Param-Locale: en",
             "Mcp-Param-Account: \"alex\\u{2028}Mcp-Param-Locale: en\"", true),
            (#"{"account":"a\r\nX-Evil: 1"}"#, "a\r\nX-Evil: 1", "Mcp-Param-Account: \"a\\r\\nX-Evil: 1\"", false),
            (#"{"account":"نام‌خانوادگی"}"#, "نام\u{200C}خانوادگی", "Mcp-Param-Account: \"نام\\u{200C}خانوادگی\"", true),
        ] {
            delegate.mcpApprovalBeganRequests.removeAll()
            let invoker = RecordingInvoker()
            let tools = resolved(
                [try declaringEntry(properties: ["account": JSONSchema.string()], headerParams: [account])], invoker: invoker)
            let held = await gateHolding([call(arguments: document)], tools: tools)
            let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first, document)
            XCTAssertEqual(request.outgoing.headerParameters, ["Mcp-Param-Account": value], document)
            let shown = request.argumentsDisplay
            XCTAssertTrue(shown.display.hasSuffix("\n" + line), "\(document): \(shown.display)")
            XCTAssertEqual(shown.display.split(separator: "\n").filter { $0.hasPrefix("Mcp-Param-") }.count, 1, document)
            XCTAssertEqual(shown.hadHidden, flagged, document)
            service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .allow)
            _ = await held.task.value
            let result = try await runtimeResult(call(arguments: document), tools: tools)
            XCTAssertFalse(result.isError, "\(document): \(result.outputJSON)")
            XCTAssertEqual(invoker.received.last?.headerParameters, ["Mcp-Param-Account": value], "\(document): sent whole")
        }
    }

    /// A body value with a line separator is sent — it is data — and the card spells the
    /// separator out and warns, rather than drawing a line break nothing distinguishes from a
    /// soft wrap.
    ///
    /// RED until 2026-10-28: the separator drew as a line break, with no warning.
    func testABodyValueWithALineSeparatorIsSpelledOutAndFlagged() async throws {
        let tools = resolved([try entry(approvalMode: .manual)])
        let held = await gateHolding([call(arguments: #"{"text":"ok\u2028Mcp-Param-Locale: en"}"#)], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        XCTAssertTrue(request.argumentsDisplay.hadHidden)
        XCTAssertEqual(request.argumentsDisplay.display, "{\n  \"text\": \"ok\\u{2028}Mcp-Param-Locale: en\"\n}")
        service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    /// On a LEGACY-era server a header parameter travels in the body — that era has no header
    /// channel — so the card shows it there and has no headers section.
    ///
    /// RED until 2026-10-28: the card said "Sent as request headers: Mcp-Param-Account: X1"
    /// for a value the legacy transport sent nowhere.
    func testOnALegacyServerTheCardShowsAHeaderParameterInTheBody() async throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let tools = resolved([try declaringEntry(
            properties: ["account": JSONSchema.string()], headerParams: [account], era: .legacy)])
        let held = await gateHolding([call(arguments: #"{"account":"X1","node":"1:2"}"#)], tools: tools)
        let request = try XCTUnwrap(delegate.mcpApprovalBeganRequests.first)
        XCTAssertEqual(request.argumentsDisplay.display, "{\n  \"account\": \"X1\",\n  \"node\": \"1:2\"\n}")
        XCTAssertEqual(request.outgoing.headerParameters, [:])
        service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: held.callKey, decision: .deny)
        _ = await held.task.value
    }

    // MARK: - Cross-server flow control in a step (D-M4)

    /// Once a step has called MCP server A (Folio Desktop), a call in the same step to a second
    /// MCP server B (GitHub) under `.semiAutomatic` — even if B is trusted and its tool is
    /// `readOnlyHint: true` or `alwaysAllow: true` — must be held on an approval card carrying a
    /// cross-server transfer note and `offerAlways: false`. A second call to server A in the same
    /// step is still allowed without holding.
    func testACallToASecondServerInTheSameStepIsHeldWithATransferNoteAndNoAlwaysAllow() async throws {
        let githubID = UUID()
        let githubSlug = try XCTUnwrap(MCPServerSlug("github"))
        let githubToolName = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: "github", toolName: "search_issues"))
        let readOnlyAnnotations = MCPToolAnnotations(title: nil, stated: [
            .readOnly: true, .destructive: false, .idempotent: true, .openWorld: true,
        ])
        let folioEntry = try entry(
            tool: "get_metadata", approvalMode: .semiAutomatic,
            serverTrusted: true, alwaysAllowed: true, readOnly: true, destructive: false,
            serverDisplayName: "Folio Desktop", serverID: Self.folioID)
        let githubEntry = MCPToolsSnapshot.Entry(
            serverID: githubID,
            slug: githubSlug,
            serverDisplayName: "GitHub",
            approvalMode: .semiAutomatic,
            serverTrusted: true,
            alwaysAllowed: true,
            runsUnattended: true,
            descriptor: MCPToolDescriptorTests.makeDescriptor(
                originalName: "search_issues", modelFacingName: githubToolName,
                annotations: readOnlyAnnotations, pinHash: "gh-hash"),
            era: .modern)
        let tools = resolved([folioEntry, githubEntry])
        let allowed: Set<String> = [folioEntry.modelFacingName, githubEntry.modelFacingName]

        // 1. First call to Folio Desktop passes without holding.
        let first = await service.gateMCPCalls(
            resolvedToolCalls: [call(folioEntry.modelFacingName, arguments: #"{"node":"1:2"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step1", taskID: 1, supervisorMode: .manual, task: task())
        XCTAssertTrue(first.isEmpty, "first server call should pass under semiAutomatic")
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)

        // 2. Another call to the SAME server (Folio Desktop) also passes without holding.
        let sameServer = await service.gateMCPCalls(
            resolvedToolCalls: [call(folioEntry.modelFacingName, arguments: #"{"node":"3:4"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step1", taskID: 1, supervisorMode: .manual, task: task())
        XCTAssertTrue(sameServer.isEmpty, "same-server call should pass without holding")

        // 3. Call to a SECOND server (GitHub) in the same step is held on an approval card
        //    with the transfer note and without offering a standing grant.
        let githubCall = call(githubEntry.modelFacingName, arguments: #"{"q":"secret-from-folio"}"#, providerID: "call_gh")
        let running = Task { [service, fixture = task()] in
            await service!.gateMCPCalls(
                resolvedToolCalls: [githubCall], allowedToolNames: allowed,
                mcpTools: tools, isPlanningPhase: false,
                stepID: "step1", taskID: 1, supervisorMode: .manual, task: fixture)
        }
        var capturedRequest: MCPApprovalRequest?
        for _ in 0..<500 {
            if let req = delegate.mcpApprovalBeganRequests.first {
                capturedRequest = req
                break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let request = try XCTUnwrap(capturedRequest, "second server call must be held for human approval")
        XCTAssertEqual(request.priorServerNames, ["Folio Desktop"])
        XCTAssertEqual(
            request.crossServerTransferNote,
            "This step already read from Folio Desktop. Approving sends the arguments below to GitHub.")
        XCTAssertFalse(request.offerAlways, "cross-server hold must never offer Always allow")
        service.resolveMCPApproval(taskID: 1, stepID: "step1", callKey: request.callKey, decision: .deny)
        let synthetic = await running.value
        XCTAssertEqual(synthetic.count, 1)

        // 4. Crossing the planning→implementation boundary resets `mcpServersContactedInStep`,
        //    so the implementation phase starts with no prior MCP server contact.
        service._testRegisterStepTask(stepID: "step_plan", taskID: 1)
        _ = await service.gateMCPCalls(
            resolvedToolCalls: [call(folioEntry.modelFacingName, arguments: #"{"node":"1:2"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step_plan", taskID: 1, supervisorMode: .manual, task: task())
        XCTAssertEqual(
            service.priorContactedMCPServerNames(
                for: TaskStepKey(taskID: 1, stepID: "step_plan"), excluding: githubID),
            ["Folio Desktop"])
        service._testResetConversationScopedState(stepID: "step_plan", taskID: 1)
        XCTAssertTrue(
            service.priorContactedMCPServerNames(
                for: TaskStepKey(taskID: 1, stepID: "step_plan"), excluding: githubID).isEmpty)
        service.clearRunningTask(stepID: "step_plan", taskID: 1)
    }

    // MARK: - Auto mode with LLM judge (D-M14)

    /// Under `.auto`, calls that `MCPPermissionService` clears on its own (`alwaysAllow` or
    /// `trusted + readOnly`) pass straight through without invoking the LLM judge and without
    /// opening a human card.
    func testAutoModeAllowsStandingGrantsAndTrustedReadOnlyWithoutCallingJudge() async throws {
        let standingEntry = try entry(
            tool: "place_order", approvalMode: .auto, serverTrusted: false,
            alwaysAllowed: true, readOnly: false, destructive: true)
        let readOnlyEntry = try entry(
            tool: "get_metadata", approvalMode: .auto, serverTrusted: true,
            alwaysAllowed: false, readOnly: true, destructive: false)
        let tools = resolved([standingEntry, readOnlyEntry])
        let allowed: Set<String> = [standingEntry.modelFacingName, readOnlyEntry.modelFacingName]
        let judgeClient = GateStubJudgeClient(steps: [.reply(#"{"decision":"DENY","reason":"should not run"}"#)])

        let results = await service.gateMCPCalls(
            resolvedToolCalls: [
                call(standingEntry.modelFacingName, arguments: #"{"id":"1"}"#, providerID: "c1"),
                call(readOnlyEntry.modelFacingName, arguments: #"{"id":"2"}"#, providerID: "c2"),
            ],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step_auto_bypass", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: judgeClient)

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(judgeClient.requestCount, 0, "bypasses must not call the judge")
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)
    }

    /// Under `.auto`, an `.ask` call routes to `MCPJudgeService` (even when `humanPresent == false`
    /// under `.autonomous`), never opens a human card, and maps:
    /// - `OK` -> passes (`nil`)
    /// - model `DENY` -> `MCP_DENIED` with single-lined, third-person reason
    /// - fail-closed (transport failure / unparseable) -> `MCP_JUDGE_UNAVAILABLE`
    func testAutoModeRoutesAskCallsToJudgeAndDistinguishesModelDenyFromFailClosed() async throws {
        let writeEntry = try entry(
            tool: "place_order", approvalMode: .auto, serverTrusted: true,
            alwaysAllowed: false, readOnly: false, destructive: true)
        let tools = resolved([writeEntry])
        let allowed: Set<String> = [writeEntry.modelFacingName]

        // 1. Judge OK -> passes.
        let okClient = GateStubJudgeClient(steps: [.reply(#"{"decision":"OK","reason":"Scoped draft."}"#)])
        let okResults = await service.gateMCPCalls(
            resolvedToolCalls: [call(writeEntry.modelFacingName, arguments: #"{"id":"1"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step_auto_ok", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: okClient)
        XCTAssertTrue(okResults.isEmpty)
        XCTAssertEqual(okClient.requestCount, 1)
        XCTAssertTrue(delegate.mcpApprovalBeganRequests.isEmpty)

        // 2. Judge DENY -> MCP_DENIED with single-lined reason.
        let denyClient = GateStubJudgeClient(steps: [.reply("{\"decision\":\"DENY\",\"reason\":\"Deletes production\\ntable.\"}")])
        let denyResults = await service.gateMCPCalls(
            resolvedToolCalls: [call(writeEntry.modelFacingName, arguments: #"{"id":"2"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step_auto_deny", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: denyClient)
        let denyEnvelope = try XCTUnwrap(denyResults[0])
        XCTAssertEqual(try errorCode(denyEnvelope), ToolErrorCode.mcpDenied.rawValue)
        XCTAssertTrue(try message(denyEnvelope).contains("Deletes production table."))
        XCTAssertFalse(try message(denyEnvelope).contains("\n"))

        // 3. Fail-closed (transport failure) -> MCP_JUDGE_UNAVAILABLE (not MCP_DENIED).
        let failClient = GateStubJudgeClient(steps: [.fail(URLError(.timedOut))])
        let failResults = await service.gateMCPCalls(
            resolvedToolCalls: [call(writeEntry.modelFacingName, arguments: #"{"id":"3"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step_auto_fail", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: failClient)
        let failEnvelope = try XCTUnwrap(failResults[0])
        XCTAssertEqual(try errorCode(failEnvelope), ToolErrorCode.mcpJudgeUnavailable.rawValue)
        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: failEnvelope, allowedToolNames: [ToolNames.askSupervisor]))
        XCTAssertTrue(direction.contains("Auto judge could not verify"))
        XCTAssertFalse(direction.contains("declined"))

        // 4. Cancelled judge -> cancellation envelope.
        let cancelledClient = GateStubJudgeClient(steps: [.fail(CancellationError())])
        let cancelledResults = await service.gateMCPCalls(
            resolvedToolCalls: [call(writeEntry.modelFacingName, arguments: #"{"id":"4"}"#)],
            allowedToolNames: allowed, mcpTools: tools,
            stepID: "step_auto_cancel", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: cancelledClient)
        let cancelledEnvelope = try XCTUnwrap(cancelledResults[0])
        XCTAssertTrue(cancelledEnvelope.isCancellationEnvelope)
    }

    /// End-to-end over a real socket (`FakeMCPHTTPServer(mode: .modern)`): a server configured
    /// in `.auto` mode with `isTrusted: true` and two approved tools (`read_order` read-only,
    /// `place_order` destructive) runs `read_order` without calling the judge, runs `place_order`
    /// when the stubbed judge replies `OK`, and blocks `place_order` with `MCP_DENIED` (never
    /// hitting the HTTP server) when the stubbed judge replies `DENY`.
    func testAutoModeEndToEndWithFakeMCPHTTPServerAndStubbedJudge() async throws {
        let server = try FakeMCPHTTPServer(mode: .modern)
        server.toolNames = ["read_order", "place_order"]
        server.toolDescriptions = [
            "read_order": "Reads an order by ID.",
            "place_order": "Places or deletes an order by ID.",
        ]
        server.toolAnnotations = [
            "read_order": #"{"readOnlyHint":true,"destructiveHint":false}"#,
            "place_order": #"{"readOnlyHint":false,"destructiveHint":true}"#,
        ]
        let port = try await server.start()
        defer { server.stop() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-auto-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let catalogueStore = MCPServerCatalogueStore(directory: tempDir)
        let trustStore = MCPTrustStore(directory: tempDir)
        let env = MCPEnvironment(
            makeTransport: MCPEnvironment.live.makeTransport,
            secretStorage: InMemorySecureTokenStorage(),
            trustDirectory: tempDir,
            writesRPCLog: false,
            sweepsOrphanedSecrets: false)
        let manager = MCPServerManager(
            catalogueStore: catalogueStore, environment: env, trustStore: trustStore)
        defer { Task { await manager.shutdown(budget: 0) } }

        let serverConfig = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("desk")),
            displayName: "Order Desk",
            transport: .http(MCPHTTPConfig(urlString: server.url(port: port))),
            isEnabled: true,
            isTrusted: true,
            approvalMode: .auto,
            judgeStrictness: .standard)
        try catalogueStore.upsert(serverConfig)
        await manager.setWorkFolder(paths: nil)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if manager.connections.first?.status.isConnected == true { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        let connection = try XCTUnwrap(manager.connection(for: serverConfig.id))
        XCTAssertTrue(connection.status.isConnected)
        try connection.approveNewTools(connection.newTools)

        let liveSnapshot = manager.snapshot
        delegate.mcpTools = liveSnapshot
        let resolvedTools = liveSnapshot.resolved(humanPresent: false)
        XCTAssertEqual(
            Set(resolvedTools.shipped.map(\.modelFacingName)),
            ["mcp__desk__read_order", "mcp__desk__place_order"],
            "under Auto mode both tools ship even when humanPresent == false")

        let allowed: Set<String> = ["mcp__desk__read_order", "mcp__desk__place_order"]
        let judgeClient = GateStubJudgeClient(steps: [
            .reply(#"{"decision":"OK","reason":"Scoped order creation."}"#),
            .reply(#"{"decision":"DENY","reason":"Destructive order deletion."}"#),
        ])

        // 1. Read-only tool on trusted server bypasses judge and executes on FakeMCPHTTPServer.
        let readEntry = try XCTUnwrap(liveSnapshot.entry(named: "mcp__desk__read_order"))
        let readCall = call("mcp__desk__read_order", arguments: #"{"id":"ord-1"}"#, providerID: "c_read")
        let readGate = await service.gateMCPCalls(
            resolvedToolCalls: [readCall], allowedToolNames: allowed, mcpTools: resolvedTools,
            stepID: "step_e2e_1", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: judgeClient)
        XCTAssertTrue(readGate.isEmpty)
        XCTAssertEqual(judgeClient.requestCount, 0, "trusted read-only call must not invoke judge")
        let readTool = MCPDynamicTool(
            entry: readEntry, invoker: try XCTUnwrap(liveSnapshot.invoker),
            attachmentsDirectory: nil, workFolderRoot: tempDir)
        let readResult = await readTool.handle(args: ["id": "ord-1"])
        XCTAssertFalse(readResult.isError, readResult.outputJSON)

        let callCountAfterRead = server.requests.filter { $0.rpcMethod == MCPWire.toolsCallMethod }.count
        XCTAssertEqual(callCountAfterRead, 1)

        // 2. Write tool (`place_order`) asks judge -> OK -> executes on FakeMCPHTTPServer.
        let placeEntry = try XCTUnwrap(liveSnapshot.entry(named: "mcp__desk__place_order"))
        let placeOKCall = call("mcp__desk__place_order", arguments: #"{"id":"ord-2"}"#, providerID: "c_place_ok")
        let placeOKGate = await service.gateMCPCalls(
            resolvedToolCalls: [placeOKCall], allowedToolNames: allowed, mcpTools: resolvedTools,
            stepID: "step_e2e_2", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: judgeClient)
        XCTAssertTrue(placeOKGate.isEmpty)
        XCTAssertEqual(judgeClient.requestCount, 1)
        let placeTool = MCPDynamicTool(
            entry: placeEntry, invoker: try XCTUnwrap(liveSnapshot.invoker),
            attachmentsDirectory: nil, workFolderRoot: tempDir)
        let placeOKResult = await placeTool.handle(args: ["id": "ord-2"])
        XCTAssertFalse(placeOKResult.isError, placeOKResult.outputJSON)

        let callCountAfterPlaceOK = server.requests.filter { $0.rpcMethod == MCPWire.toolsCallMethod }.count
        XCTAssertEqual(callCountAfterPlaceOK, 2)

        // 3. Second write tool call asks judge -> DENY -> blocked with MCP_DENIED before hitting server.
        let placeDenyCall = call("mcp__desk__place_order", arguments: #"{"id":"ord-drop-all"}"#, providerID: "c_place_deny")
        let placeDenyGate = await service.gateMCPCalls(
            resolvedToolCalls: [placeDenyCall], allowedToolNames: allowed, mcpTools: resolvedTools,
            stepID: "step_e2e_3", taskID: 1, supervisorMode: .autonomous, task: task(),
            client: judgeClient)
        let deniedResult = try XCTUnwrap(placeDenyGate[0])
        XCTAssertEqual(try errorCode(deniedResult), ToolErrorCode.mcpDenied.rawValue)
        XCTAssertEqual(judgeClient.requestCount, 2)

        let callCountAfterPlaceDeny = server.requests.filter { $0.rpcMethod == MCPWire.toolsCallMethod }.count
        XCTAssertEqual(callCountAfterPlaceDeny, 2, "denied call must never reach the MCP HTTP server")
    }
}

private final class GateStubJudgeClient: LLMClient, @unchecked Sendable {
    enum Step {
        case reply(String)
        case fail(Error)
    }

    private let lock = NSLock()
    private let steps: [Step]
    private var _requestCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    var requestCount: Int { lock.withLock { _requestCount } }

    func modelContextLength(config _: LLMConfig) async -> Int? { 16_384 }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let step: Step = lock.withLock {
            let idx = min(_requestCount, steps.count - 1)
            _requestCount += 1
            return steps[idx]
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let text):
                continuation.yield(StreamEvent(contentDelta: text))
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
