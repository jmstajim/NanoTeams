import XCTest

@testable import NanoTeams

/// The MCP catalogue moving under a running step, driven through the whole tool loop: the
/// iteration's drift check, the gate and the executor's classifier, wired as they run.
///
/// The step freezes the catalogue at entry — its tool list is rendered into segment 0 of the
/// prompt and the wire is append-only — so everything that changes afterwards is answered per
/// CALL. What this suite pins is that each answer says what actually happened: a server that
/// is reconnecting is not a server that changed the tool (F32), and a policy a person changed
/// in Settings reaches the very next call rather than the next step (F20).
@MainActor
final class MCPToolIterationDriftTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var invoker: RecordingInvoker!
    private var tempDir: URL!

    private let stepID = "assistant"
    private let taskID = 61
    private static let folioID = UUID()
    private let toolName = "mcp__folio__get_metadata"

    /// Records what reached the server and answers every call.
    private final class RecordingInvoker: MCPToolInvoking, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [MCPToolCall] = []
        var received: [MCPToolCall] { lock.withLock { calls } }

        func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult {
            lock.withLock { calls.append(call) }
            return MCPCallToolResult(contentBlocks: [.object([
                "type": .string("text"), "text": .string("metadata"),
            ])])
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockDelegate = MockLLMExecutionDelegate()
        invoker = RecordingInvoker()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-iteration-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        invoker = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Why the call did not run (F32)

    /// A server that dropped its session — a legacy server restarting, a crash, a network blip
    /// — takes all its tools out of the live catalogue until it reconnects. A call in that
    /// window must not be told the server changed what the tool does, nor that it is gone for
    /// the rest of the step: seconds later it works again.
    ///
    /// RED before 2026-09-23: the envelope was `mcp_tool_changed` — "withheld for the
    /// remainder of this step: its server changed what this tool does".
    func testACallWhileItsServerReconnectsIsNotReportedAsChanged() async throws {
        let result = try await callAfterTheCatalogueMoved(to: snapshot(
            entries: [], status: .connecting, revision: 2))
        XCTAssertTrue(result.contains("mcp_server_not_connected"), result)
        XCTAssertFalse(result.contains("mcp_tool_changed"), result)
        XCTAssertFalse(result.contains("remainder of this step"), result)
        XCTAssertTrue(invoker.received.isEmpty, "nothing reached the server")
    }

    /// Switched off by a person: not a changed tool either — but nothing in the step switches
    /// it back on, so the answer does not invite a later call. The manager reads `.disabled`
    /// for a switched-off server and for a manager shut down with nothing left to run; a
    /// connection on its way to a reconnect reads `.connecting`.
    ///
    /// RED until 2026-09-23 (group C, item 13): answered `mcp_server_not_connected`, because a
    /// reconnect passed through `.disabled` too and the status could not tell the two apart.
    func testACallWhileItsServerIsOffIsNotReportedAsChangedNorInvitedToRetry() async throws {
        let result = try await callAfterTheCatalogueMoved(to: snapshot(
            entries: [], status: .disabled, revision: 2))
        XCTAssertTrue(result.contains("mcp_server_needs_attention"), result)
        XCTAssertFalse(result.contains("mcp_tool_changed"), result)
        XCTAssertFalse(result.contains("again later"), result)
    }

    /// A server whose credential was refused waits for a person: the connection does not retry
    /// it, so a later call in the step would meet the same refusal. The answer says so rather
    /// than inviting one.
    ///
    /// RED until 2026-09-23 (A2 verification): answered `mcp_server_not_connected` — "call it
    /// again later in this step".
    func testACallWhileItsServerNeedsAPersonIsNotInvitedToRetry() async throws {
        let result = try await callAfterTheCatalogueMoved(to: snapshot(
            entries: [], status: .needsAuth(reason: "401"), revision: 2))
        XCTAssertTrue(result.contains("mcp_server_needs_attention"), result)
        XCTAssertFalse(result.contains("mcp_server_not_connected"), result)
        XCTAssertFalse(result.contains("again later"), result)
        XCTAssertTrue(invoker.received.isEmpty, "nothing reached the server")
    }

    /// A server that left the catalogue altogether (removed in Settings) has no status at all
    /// and does not come back under the same id: its tool IS gone for the rest of the step, so
    /// the refusal says so rather than inviting a later call that cannot succeed.
    func testACallToAServerThatWasRemovedIsReportedAsChanged() async throws {
        let result = try await callAfterTheCatalogueMoved(to: MCPToolsSnapshot(
            entries: [], statusByServerID: [:], revision: 2, invoker: invoker))
        XCTAssertTrue(result.contains("mcp_tool_changed"), result)
        XCTAssertFalse(result.contains("mcp_server_not_connected"), result)
        XCTAssertTrue(invoker.received.isEmpty)
    }

    /// The control: the server is connected and publishes the tool at another hash — it DID
    /// change what the tool does.
    func testACallToAToolItsConnectedServerRewroteIsReportedAsChanged() async throws {
        let result = try await callAfterTheCatalogueMoved(to: snapshot(
            entries: [try entry(hash: "h2")], status: .connected(era: .modern),
            revision: 2))
        XCTAssertTrue(result.contains("mcp_tool_changed"), result)
        XCTAssertTrue(invoker.received.isEmpty)
    }

    /// Connected, and the tool is simply not there any more — withdrawn by the server, or its
    /// approval revoked. That is a change to what this step was set up with.
    func testACallToAToolItsConnectedServerNoLongerOffersIsReportedAsChanged() async throws {
        let result = try await callAfterTheCatalogueMoved(to: snapshot(
            entries: [], status: .connected(era: .modern), revision: 2))
        XCTAssertTrue(result.contains("mcp_tool_changed"), result)
    }

    // MARK: - A tool list being read again (group C, 2026-09-24)

    /// A listing asked after the server's `list_changed`, or once its stated catalogue lifetime
    /// ran out, failed, so the list is being read again. The call in that window is told exactly that,
    /// with a later call left open. The re-read commits the tool unchanged while the model does
    /// other work, and the SAME frozen tool, called again in the same step, runs: nothing
    /// latched.
    ///
    /// RED until 2026-09-24 (group C): the first call was told `mcp_tool_changed` — "withheld
    /// for the remainder of this step" — about the tool its second call then ran (R1.8.5).
    func testACallWhileItsServerRereadsItsToolsIsInvitedBackAndRunsOnceTheReadCommits() async throws {
        let results = try await callTwiceAcrossAReread(committing: [try entry()])
        XCTAssertTrue(results[0].contains("mcp_tools_being_reread"), results[0])
        XCTAssertFalse(results[0].contains("mcp_tool_changed"), results[0])
        XCTAssertTrue(results[0].contains("again later in this step"), results[0])
        XCTAssertFalse(results[1].contains("\"error\""), results[1])
        XCTAssertEqual(invoker.received.count, 1, "the second call reached the server")
    }

    /// The re-read commits a REWRITTEN tool: the second call is refused as changed — the one
    /// case the first refusal said would end that way — and nothing reaches the server.
    func testACallAfterAReReadThatRewroteTheToolIsReportedAsChanged() async throws {
        let results = try await callTwiceAcrossAReread(committing: [try entry(hash: "h2")])
        XCTAssertTrue(results[0].contains("mcp_tools_being_reread"), results[0])
        XCTAssertTrue(results[1].contains("mcp_tool_changed"), results[1])
        XCTAssertTrue(invoker.received.isEmpty, "nothing reached the server")
    }

    // MARK: - A policy change reaches the next call (F20)

    /// The person switches the server to Manual while the model is generating the turn that
    /// calls the tool. The call is held for them — the step's frozen "always allowed" does not
    /// carry it past the change.
    ///
    /// RED before 2026-09-23: the gate decided from the frozen entry, and the call ran.
    func testAModeSwitchDuringGenerationHoldsTheCallForAPerson() async throws {
        seed(frozen: [try entry(alwaysAllowed: true)])
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: toolName, argumentsJSON: "{}"),
            .hang,
        ])
        let delegate = mockDelegate!
        let manual = snapshot(
            entries: [try entry(approvalMode: .manual, alwaysAllowed: true)],
            status: .connected(era: .modern), revision: 2)
        client.onRequest = { index in
            guard index == 0 else { return }
            Task { @MainActor in delegate.mcpTools = manual }
        }
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.mockDelegate.mcpApprovalBeganRequests.isEmpty || self.mcpResult() != nil }
        let card = mockDelegate.mcpApprovalBeganRequests.first
        XCTAssertNotNil(card, "the call must be held under the mode the person switched to")
        if let card {
            service.resolveMCPApproval(
                taskID: taskID, stepID: stepID, callKey: card.callKey, decision: .deny)
        }
        try await waitUntil { self.mcpResult() != nil }
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        XCTAssertTrue(invoker.received.isEmpty, "the call must not have run")
        XCTAssertTrue(mcpResult()?.contains(ToolErrorCode.mcpDenied.rawValue) ?? false, mcpResult() ?? "")
    }

    // MARK: - Fixtures

    private func entry(
        approvalMode: MCPApprovalMode = .semiAutomatic,
        alwaysAllowed: Bool = true,
        hash: String = "h1"
    ) throws -> MCPToolsSnapshot.Entry {
        MCPToolsSnapshot.Entry(
            serverID: Self.folioID,
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            serverDisplayName: "Folio",
            approvalMode: approvalMode,
            serverTrusted: false,
            alwaysAllowed: alwaysAllowed,
            runsUnattended: alwaysAllowed,
            descriptor: MCPToolDescriptorTests.makeDescriptor(
                originalName: "get_metadata", modelFacingName: toolName, pinHash: hash), era: .modern)
    }

    private func snapshot(
        entries: [MCPToolsSnapshot.Entry], status: MCPServerStatus, revision: Int
    ) -> MCPToolsSnapshot {
        MCPToolsSnapshot(
            entries: entries, statusByServerID: [Self.folioID: status],
            revision: revision, invoker: invoker)
    }

    /// Turn 1 reads a file while the catalogue moves to `live`; turn 2 calls the MCP tool,
    /// which the iteration's drift check has by then withheld. Returns that call's result.
    private func callAfterTheCatalogueMoved(to live: MCPToolsSnapshot) async throws -> String {
        seed(frozen: [try entry()])
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"a.txt"}"#),
            .toolCall(name: toolName, argumentsJSON: "{}"),
            .hang,
        ])
        let delegate = mockDelegate!
        client.onRequest = { index in
            guard index == 0 else { return }
            Task { @MainActor in delegate.mcpTools = live }
        }
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.mcpResult() != nil }
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
        return try XCTUnwrap(mcpResult())
    }

    /// Turn 1 reads a file while the server's list goes into a re-read; turn 2 calls the MCP
    /// tool; turn 3 reads a file while the re-read commits `committing`; turn 4 calls the same
    /// tool again. Returns both calls' results, in order.
    private func callTwiceAcrossAReread(
        committing committed: [MCPToolsSnapshot.Entry]
    ) async throws -> [String] {
        seed(frozen: [try entry()])
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"a.txt"}"#),
            .toolCall(name: toolName, argumentsJSON: "{}"),
            .toolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"b.txt"}"#),
            .toolCall(name: toolName, argumentsJSON: "{}"),
            .hang,
        ])
        let connected = MCPServerStatus.connected(era: .modern)
        let rereading = MCPToolsSnapshot(
            entries: [], statusByServerID: [Self.folioID: connected],
            lastCommittedApprovalsOfUnverifiedServers: [Self.folioID: [toolName: "h1"]],
            revision: 2, invoker: invoker)
        let afterTheRead = snapshot(entries: committed, status: connected, revision: 3)
        let delegate = mockDelegate!
        client.onRequest = { index in
            switch index {
            case 0: Task { @MainActor in delegate.mcpTools = rereading }
            case 2: Task { @MainActor in delegate.mcpTools = afterTheRead }
            default: break
            }
        }
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.mcpResults().count == 2 }
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
        return mcpResults()
    }

    private func mcpResults() -> [String] {
        step()?.toolCalls.filter { $0.name == toolName }.compactMap(\.resultJSON) ?? []
    }

    private func mcpResult() -> String? {
        step()?.toolCalls.first { $0.name == toolName }?.resultJSON
    }

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func attach(_ client: ScriptedToolCallClient) {
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { client })
        service.retryDelaySeconds = 1
        service.attach(delegate: mockDelegate)
    }

    /// A chat role holding the folio server, a person present (`.manual` supervision), and the
    /// catalogue the step freezes at entry.
    private func seed(frozen: [MCPToolsSnapshot.Entry]) {
        mockDelegate.mcpTools = snapshot(
            entries: frozen, status: .connected(era: .modern), revision: 1)
        let role = TeamRoleDefinition(
            id: stepID, name: "Assistant", prompt: "p",
            toolIDs: [ToolNames.readFile, MCPToolNaming.serverGrant(slug: "folio")],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"],
                                           producesArtifacts: []))
        let team = Team(
            name: "Chat", roles: [role], artifacts: [],
            settings: TeamSettings(supervisorMode: .manual), graphLayout: TeamGraphLayout())
        let step = StepExecution(
            id: stepID, role: .custom(id: stepID), title: "Assistant",
            expectedArtifacts: [], status: .running,
            llmConversation: [LLMMessage(role: .system, content: "System prompt")])
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "Read the metadata",
            runs: [Run(id: 0, steps: [step], roleStatuses: [stepID: .working])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: ProjectSettings.defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: taskID, activeTask: task)
    }

    private func waitUntil(
        timeout: TimeInterval = 8.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw WaitTimeout(timeout: timeout) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct WaitTimeout: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? { "condition not met within \(timeout)s" }
    }
}
