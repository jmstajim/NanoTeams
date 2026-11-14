import XCTest

@testable import NanoTeams

/// The orchestrator's half of the MCP approval gate: what the feed is shown while a call is
/// held, and what a button press does to the held call.
@MainActor
final class NTMSOrchestratorMCPApprovalTests: XCTestCase {

    private var directory: URL!
    private var catalogue: MCPServerCatalogueStore!
    private var scripted: ScriptedMCPEnvironment!
    private var sut: NTMSOrchestrator!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-approval-\(UUID().uuidString)", isDirectory: true)
        catalogue = MCPServerCatalogueStore(directory: directory)
        scripted = ScriptedMCPEnvironment(trustDirectory: directory)
        sut = TestOrchestrator.make(
            mcpEnvironment: scripted.environment, mcpCatalogueStore: catalogue)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await sut?.tearDownMCPServerManager(budget: 0)
        sut?.stopAllEngines()
        sut = nil
        scripted?.cleanUp()
        try? FileManager.default.removeItem(at: directory)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        directory = nil
        catalogue = nil
        scripted = nil
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func request(
        taskID: Int = 1,
        stepID: String = "engineer",
        toolName: String = "mcp__folio__get_metadata",
        slug: String = "folio",
        arguments: String = #"{"node":"1:2"}"#,
        pinHash: String = "h1",
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> MCPApprovalRequest {
        MCPApprovalRequest(
            taskID: taskID,
            stepID: stepID,
            callKey: LLMExecutionService.mcpCallKey(toolName: toolName, argumentsJSON: arguments),
            toolName: toolName,
            serverSlug: slug,
            serverDisplayName: "Folio Desktop",
            toolTitle: "get_metadata",
            toolDescription: "Reads a node's metadata.",
            outgoing: MCPDynamicTool.OutgoingCall(
                arguments: JSONValue(json: arguments) ?? .object([:]), headerParameters: [:]),
            annotations: MCPToolAnnotations(title: nil, stated: [
                .readOnly: true, .destructive: false, .idempotent: false, .openWorld: false,
            ]),
            serverTrusted: false,
            pinHash: pinHash,
            offerAlways: true,
            createdAt: createdAt)
    }

    private var key: TaskStepKey { TaskStepKey(taskID: 1, stepID: "engineer") }

    // MARK: - Publishing

    func testAHeldCallBecomesAPublishedCard() {
        sut.mcpApprovalDidBegin(request())
        XCTAssertEqual(sut.mcpApprovalRequests[key]?.toolName, "mcp__folio__get_metadata")
        XCTAssertEqual(sut.mcpApprovalRequests[key]?.outgoing.arguments, .object(["node": .string("1:2")]))
    }

    func testEndingTheHoldWithdrawsTheCard() {
        let held = request()
        sut.mcpApprovalDidBegin(held)
        sut.mcpApprovalDidEnd(
            taskID: 1, stepID: "engineer", callKey: held.callKey, createdAt: held.createdAt)
        XCTAssertNil(sut.mcpApprovalRequests[key])
    }

    /// The `createdAt` discriminator, not the bare call key: a late end from a
    /// cancelled-then-re-prompted hold of the SAME call must not wipe the freshly-republished
    /// card and wedge the step.
    func testALateEndFromAPriorHoldDoesNotWipeAFreshCard() {
        let fresh = request(createdAt: Date(timeIntervalSince1970: 200))
        sut.mcpApprovalDidBegin(fresh)
        sut.mcpApprovalDidEnd(
            taskID: 1, stepID: "engineer", callKey: fresh.callKey,
            createdAt: Date(timeIntervalSince1970: 100))
        XCTAssertNotNil(sut.mcpApprovalRequests[key])
    }

    func testAnEndForADifferentCallLeavesTheCardAlone() {
        let held = request()
        sut.mcpApprovalDidBegin(held)
        sut.mcpApprovalDidEnd(
            taskID: 1, stepID: "engineer", callKey: "another call", createdAt: held.createdAt)
        XCTAssertNotNil(sut.mcpApprovalRequests[key])
    }

    /// Task ids are reused across folders, so a card that outlived its run would render under
    /// a same-numbered task in the next one.
    func testFullTeardownDropsEveryCard() {
        sut.mcpApprovalDidBegin(request())
        sut.mcpApprovalDidBegin(request(taskID: 2))
        sut.clearAllMCPApprovalRequests()
        XCTAssertTrue(sut.mcpApprovalRequests.isEmpty)
    }

    // MARK: - The buttons

    func testResolvingACallThatIsNotHeldIsANoOp() async {
        await sut.resolveMCPApproval(
            taskID: 1, stepID: "engineer", callKey: "nothing", choice: .allow)
        XCTAssertTrue(sut.mcpApprovalRequests.isEmpty)
    }

    /// A key that does not match the published card is a stale button press — from a card the
    /// UI had not redrawn yet — and must not resolve the hold that IS live.
    func testAMismatchedKeyIsIgnored() async {
        sut.mcpApprovalDidBegin(request())
        await sut.resolveMCPApproval(
            taskID: 1, stepID: "engineer", callKey: "stale", choice: .deny)
        XCTAssertNotNil(sut.mcpApprovalRequests[key])
    }

    func testAllowAndDenyBothReachTheGate() async {
        for choice in [MCPApprovalChoice.allow, .deny] {
            let held = request()
            sut.mcpApprovalDidBegin(held)
            await sut.resolveMCPApproval(
                taskID: 1, stepID: "engineer", callKey: held.callKey, choice: choice)
            // Nothing is holding the waiter, so the resolve is a no-op on the service side;
            // what this pins is that the orchestrator reached it without throwing and left
            // the card for the gate's own `didEnd` to withdraw.
            XCTAssertNotNil(sut.mcpApprovalRequests[key])
            sut.clearAllMCPApprovalRequests()
        }
    }

    /// Holds one call of `entry` the way the gate does — through the service, which publishes the
    /// card — presses `choice` on that card, and returns what the gate was handed: what the
    /// held call does next.
    private func press(_ choice: MCPApprovalChoice, on entry: MCPToolsSnapshot.Entry) async throws -> MCPApprovalDecision {
        let service: LLMExecutionService = sut.llmExecutionService
        let hold = Task { @MainActor in
            await service.awaitMCPApproval(
                taskID: 1, stepID: "engineer",
                call: StepToolCall(name: entry.modelFacingName, argumentsJSON: #"{"node":"1:2"}"#),
                entry: entry,
                outgoing: MCPDynamicTool.OutgoingCall(arguments: .object(["node": .string("1:2")]), headerParameters: [:]),
                offerAlways: true)
        }
        for _ in 0..<200 where sut.mcpApprovalRequests[key] == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let card = try XCTUnwrap(sut.mcpApprovalRequests[key], "the held call published no card")
        await sut.resolveMCPApproval(taskID: 1, stepID: "engineer", callKey: card.callKey, choice: choice)
        let decision = await hold.value
        XCTAssertNil(sut.mcpApprovalRequests[key], "the gate withdrew the card once the call was released")
        return decision
    }

    /// With no manager there is no trust file to write to, so the standing grant is not
    /// recorded — and the call is still released, as an allow, because the person did approve
    /// it ("always" is the orchestrator's write alone). The next one asks again, which is the
    /// honest outcome.
    func testAlwaysAllowWithNoManagerStillReleasesTheCall() async throws {
        XCTAssertNil(sut.mcpServerManager)
        let entry = try MCPToolsSnapshotTests.makeEntry(slug: "folio", tool: "get_metadata", serverID: UUID())
        let decision = try await press(.alwaysAllow, on: entry)
        XCTAssertEqual(decision, .allow)
    }

    /// The server was switched off or removed while the card was on screen: nothing to record
    /// the grant through, and the call is still released as an allow.
    func testAlwaysAllowForAServerThatIsGoneStillReleasesTheCall() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.mcpServerManager)
        let entry = try MCPToolsSnapshotTests.makeEntry(slug: "vanished", tool: "get_metadata", serverID: UUID())
        let decision = try await press(.alwaysAllow, on: entry)
        XCTAssertEqual(decision, .allow)
    }

    /// Connects a server publishing `get_metadata` through the orchestrator's own manager and
    /// approves it, the way a person would in Settings.
    private func connectAndApproveGetMetadata() async throws -> (MCPServerManager, MCPServerConfig) {
        let url = "https://approval.test/mcp"
        scripted.register(
            url: url, transport: await ScriptedMCPEnvironment.modernTransport(toolNames: ["get_metadata"]))
        // Semi-automatic: the only mode whose card offers "Always allow", and so the only one
        // a standing grant is recorded under.
        let config = MCPServerConfig(
            id: UUID(), slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio Desktop",
            transport: .http(MCPHTTPConfig(urlString: url)), isEnabled: true, approvalMode: .semiAutomatic)
        try catalogue.save(MCPServerCatalogueFile(servers: [config]))

        await sut.openWorkFolder(tempDir)
        let manager = try XCTUnwrap(sut.mcpServerManager)
        for _ in 0..<200 where manager.snapshot.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
            if let connection = manager.connection(for: config.id),
               connection.pinState(of: "get_metadata") != nil {
                try? connection.approveNewTools(connection.newTools)
            }
        }
        return (manager, config)
    }

    /// The whole path, through a live connection: the grant is written to the trust file
    /// under the SERVER's own name for the tool, because the model-facing fold is lossy and
    /// two of a server's tools can fold to one name.
    func testAlwaysAllowRecordsTheGrantUnderTheServersOwnToolName() async throws {
        let (manager, config) = try await connectAndApproveGetMetadata()
        let entry = try XCTUnwrap(manager.snapshot.entry(named: "mcp__folio__get_metadata"))
        XCTAssertFalse(entry.alwaysAllowed)

        let held = request(pinHash: entry.descriptor.pinHash)
        sut.mcpApprovalDidBegin(held)
        await sut.resolveMCPApproval(
            taskID: 1, stepID: "engineer", callKey: held.callKey, choice: .alwaysAllow)

        let connection = try XCTUnwrap(manager.connection(for: config.id))
        XCTAssertTrue(connection.isAlwaysAllowed(tool: "get_metadata"))
    }

    /// The grant is bound to the text the CARD showed. A card drawn for another text — the
    /// server rewrote the tool and the person re-approved it in Settings while the old card
    /// was still up — records nothing, and the call still runs as a plain allow.
    func testAlwaysAllowIsBoundToTheCardsHash() async throws {
        let (manager, config) = try await connectAndApproveGetMetadata()
        XCTAssertNotNil(manager.snapshot.entry(named: "mcp__folio__get_metadata"))

        let held = request(pinHash: "the-hash-of-a-text-this-card-showed-earlier")
        sut.mcpApprovalDidBegin(held)
        await sut.resolveMCPApproval(
            taskID: 1, stepID: "engineer", callKey: held.callKey, choice: .alwaysAllow)

        let connection = try XCTUnwrap(manager.connection(for: config.id))
        XCTAssertFalse(connection.isAlwaysAllowed(tool: "get_metadata"))
    }

    // MARK: - A refused grant records nothing, whatever refused it (2026-10-28)

    /// "Always allow" pressed for a server whose approval mode was made Manual while the card was
    /// up: the connection refuses the standing grant (`.standingGrantsNotAllowed`), and nothing is
    /// recorded — the trust file holds no grant. The call itself goes out: the person approved it.
    func testAlwaysAllowUnderAModeThatAllowsNoGrantRecordsNothing() async throws {
        let (manager, config) = try await connectAndApproveGetMetadata()
        let entry = try XCTUnwrap(manager.snapshot.entry(named: "mcp__folio__get_metadata"))
        var manual = config
        manual.approvalMode = .manual
        try await manager.save(manual, secrets: MCPServerSecretEdit())
        let connection = try XCTUnwrap(manager.connection(for: config.id))
        XCTAssertEqual(connection.config.approvalMode, .manual, "premise: the mode is taken in place")

        let held = request(pinHash: entry.descriptor.pinHash)
        sut.mcpApprovalDidBegin(held)
        await sut.resolveMCPApproval(taskID: 1, stepID: "engineer", callKey: held.callKey, choice: .alwaysAllow)

        XCTAssertFalse(connection.isAlwaysAllowed(tool: "get_metadata"), "a grant was recorded under Manual")
        XCTAssertFalse(MCPTrustStore(directory: directory).record(for: config.id).toolPins["get_metadata"]?.alwaysAllow ?? false)
    }

    /// A server stopped while the card was up no longer ships the tool, so "Always allow" finds
    /// nothing to record the grant against and records nothing — the trust file holds no grant —
    /// while the call is still released as the allow it is. What stops it is the snapshot: a
    /// stopped connection of a switched-on server reads `.connecting`, and only a connected
    /// server's tools are in the snapshot, so the write never reaches the connection. The
    /// connection's own refusal of a write through it once stopped (`.connectionStopped`) is the
    /// backstop behind that, and is pinned where it is reachable
    /// (`MCPServerManagerTests.testAConnectionStoppedForGoodRecordsNoGrant`).
    func testAStoppedServerNoLongerShipsTheToolSoAlwaysAllowRecordsNothing() async throws {
        let (manager, config) = try await connectAndApproveGetMetadata()
        let entry = try XCTUnwrap(manager.snapshot.entry(named: "mcp__folio__get_metadata"))
        let connection = try XCTUnwrap(manager.connection(for: config.id))
        await connection.stop(budget: 0)
        XCTAssertTrue(manager.connections.contains { $0 === connection }, "premise: the stopped connection is still listed")
        XCTAssertNil(manager.snapshot.entry(named: "mcp__folio__get_metadata"), "premise: the tool no longer ships")

        let decision = try await press(.alwaysAllow, on: entry)

        XCTAssertEqual(decision, .allow, "the person approved this call")
        XCTAssertFalse(MCPTrustStore(directory: directory).record(for: config.id).toolPins["get_metadata"]?.alwaysAllow ?? false,
                       "a grant was recorded for a server that no longer ships the tool")
    }

    /// "Allow" lets this ONE call out and "Deny" refuses it; neither records a standing grant —
    /// only "Always allow" does. Since the gate's decision lost its "always" arm, the orchestrator's
    /// switch is the one place the three choices differ, so it is pinned through a live
    /// Semi-automatic connection — the one mode a grant can be recorded under — at the live hash,
    /// where every guard that could refuse the write would let it through.
    func testAPlainAllowOrDenyRecordsNoStandingGrant() async throws {
        let (manager, config) = try await connectAndApproveGetMetadata()
        let entry = try XCTUnwrap(manager.snapshot.entry(named: "mcp__folio__get_metadata"))
        let connection = try XCTUnwrap(manager.connection(for: config.id))
        func recorded() -> Bool {
            MCPTrustStore(directory: directory).record(for: config.id).toolPins["get_metadata"]?.alwaysAllow ?? false
        }
        for (choice, expected) in [(MCPApprovalChoice.allow, MCPApprovalDecision.allow), (.deny, .deny)] {
            let decision = try await press(choice, on: entry)
            XCTAssertEqual(decision, expected, "\(choice)")
            XCTAssertFalse(connection.isAlwaysAllowed(tool: "get_metadata"), "\(choice) recorded a standing grant")
            XCTAssertFalse(recorded(), "\(choice) wrote a grant to the trust file")
        }
        // At the same hash, through the same connection, "Always allow" does record it.
        let always = try await press(.alwaysAllow, on: entry)
        XCTAssertEqual(always, .allow)
        XCTAssertTrue(connection.isAlwaysAllowed(tool: "get_metadata"))
        XCTAssertTrue(recorded())
    }

    // MARK: - On-demand "Ask AI" judge advice (D-M14)

    /// Pressing "Ask AI" on a held MCP approval card evaluates the held call through
    /// `MCPJudgeService.judge` and returns the verdict read-only WITHOUT resolving or
    /// withdrawing the held call.
    func testRequestMCPJudgeAdviceEvaluatesHeldCallReadOnlyWithoutResolvingTheHold() async throws {
        _ = try await connectAndApproveGetMetadata()
        let held = request()
        sut.mcpApprovalDidBegin(held)

        let mismatched = await sut.requestMCPJudgeAdvice(
            taskID: 1, stepID: "engineer", callKey: "other-key")
        XCTAssertNil(mismatched, "mismatched callKey must not evaluate")

        let defaultClientVerdict = await sut.requestMCPJudgeAdvice(
            taskID: 1, stepID: "engineer", callKey: held.callKey)
        XCTAssertEqual(defaultClientVerdict?.allowed, false)

        let stubClient = StubMCPAdviceLLMClient(
            reply: #"{"decision":"DENY","reason":"Exfiltrates workspace node id"}"#)
        let verdict = await sut.requestMCPJudgeAdvice(
            taskID: 1, stepID: "engineer", callKey: held.callKey, client: stubClient)
        XCTAssertEqual(
            verdict,
            MCPJudgeService.Decision(allowed: false, reason: "Exfiltrates workspace node id"))
        XCTAssertNotNil(
            sut.mcpApprovalRequests[key],
            "Ask AI is read-only — the held card must stay published for the human")
    }
}

private final class StubMCPAdviceLLMClient: LLMClient, @unchecked Sendable {
    let reply: String

    init(reply: String) {
        self.reply = reply
    }

    func modelContextLength(config _: LLMConfig) async -> Int? { 16_384 }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let text = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
