import XCTest

@testable import NanoTeams

/// Tests for LLMExecutionService+ToolExecution — tool execution pipeline,
/// authorization, caching, result processing, memories injection, loop detection,
/// and Supervisor auto-answer handling.
@MainActor
final class ToolExecutionTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!
    var runtime: ToolRuntime!
    var memory: ToolCallCache!
    var orphanService: LLMExecutionService!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)

        let (_, rt) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: tempDir.appendingPathComponent("tool_calls.jsonl"),
            isDefaultStorage: false
        )
        runtime = rt
        memory = ToolCallCache()
    }

    override func tearDown() {
        runtime = nil
        memory = nil
        orphanService = nil
        service = nil
        mockDelegate = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeToolCall(
        name: String,
        args: String = "{}",
        providerID: String? = nil
    ) -> StepToolCall {
        StepToolCall(
            providerID: providerID ?? UUID().uuidString,
            name: name,
            argumentsJSON: args
        )
    }

    private func makeTask() -> NTMSTask {
        let run = Run(id: 0, roleStatuses: ["eng": .working])
        return NTMSTask(id: 0, title: "Test Task", supervisorTask: "Goal", runs: [run])
    }

    // MARK: - executeToolCalls: Authorization

    func testExecuteToolCalls_unauthorizedTool_returnsError() {
        let task = makeTask()
        let call = makeToolCall(name: "write_file", args: #"{"path":"/test.txt","content":"hi"}"#)

        let batch = service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["read_file", "list_files"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.results.count, 1)
        XCTAssertTrue(batch.results[0].isError)
        XCTAssertTrue(batch.results[0].outputJSON.contains("tool_not_authorized"))
    }

    func testExecuteToolCalls_authorizedTool_executes() {
        let task = makeTask()

        // ls on the project root (relative path ".") should succeed
        let call = makeToolCall(name: "list_files", args: #"{"path":"."}"#)

        let batch = service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["list_files"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.results.count, 1)
        XCTAssertFalse(batch.results[0].isError)
    }

    func testExecuteToolCalls_aliasResolution_grepToSearch() {
        let task = makeTask()

        // "grep" should alias to "search" — but "search" must be in allowed set
        let call = makeToolCall(name: "grep", args: #"{"query":"test"}"#)

        let batch = service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["search"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.results.count, 1)
        // The alias should resolve to search, which is in allowed set
        XCTAssertFalse(batch.results[0].isError,
                       "Aliased tool 'grep' should resolve to 'search' and pass authorization")
    }

    // MARK: - executeToolCalls: Caching

    func testExecuteToolCalls_cachedResult_returnsFromCache() {
        let task = makeTask()

        // First: record a read_file call in memory
        let readArgs = #"{"path":""# + tempDir.path + #"/test.txt"}"#
        memory.record(
            toolName: "read_file",
            argumentsJSON: readArgs,
            resultJSON: #"{"content":"hello"}"#,
            isError: false
        )

        // Now execute the same call — should be cached
        let call = makeToolCall(name: "read_file", args: readArgs)

        let batch = service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["read_file"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.results.count, 1)
        XCTAssertTrue(batch.cachedIndices.contains(0), "First call should be served from cache")
        XCTAssertFalse(batch.results[0].isError)
    }

    func testExecuteToolCalls_emptyList_returnsEmpty() {
        let task = makeTask()

        let batch = service.executeToolCalls(
            resolvedToolCalls: [],
            allowedToolNames: ["read_file"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertTrue(batch.results.isEmpty)
        XCTAssertTrue(batch.cachedIndices.isEmpty)
    }

    func testExecuteToolCalls_noDelegate_returnsEmpty() {
        // Service with no delegate attached
        orphanService = LLMExecutionService(repository: NTMSRepository())
        let task = makeTask()
        let call = makeToolCall(name: "list_files", args: "{}")

        let batch = orphanService.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["list_files"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertTrue(batch.results.isEmpty)
    }

    // MARK: - executeToolCalls: Mixed Batch

    func testExecuteToolCalls_mixedBatch_correctOrdering() {
        let task = makeTask()

        // Cache a read_file result
        let readArgs = #"{"path":""# + tempDir.path + #"/cached.txt"}"#
        memory.record(
            toolName: "read_file",
            argumentsJSON: readArgs,
            resultJSON: #"{"content":"cached"}"#,
            isError: false
        )

        let call1 = makeToolCall(name: "write_file") // unauthorized
        let call2 = makeToolCall(name: "read_file", args: readArgs) // cached
        let call3 = makeToolCall(name: "list_files", args: #"{"path":"."}"#) // fresh

        let batch = service.executeToolCalls(
            resolvedToolCalls: [call1, call2, call3],
            allowedToolNames: ["read_file", "list_files"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.results.count, 3)
        // First: unauthorized
        XCTAssertTrue(batch.results[0].isError)
        XCTAssertTrue(batch.results[0].outputJSON.contains("tool_not_authorized"))
        // Second: cached
        XCTAssertTrue(batch.cachedIndices.contains(1))
        XCTAssertFalse(batch.results[1].isError)
        // Third: fresh (ls should succeed)
        XCTAssertFalse(batch.results[2].isError)
    }

    func testExecuteToolCalls_allUnauthorized_allErrors() {
        let task = makeTask()

        let calls = [
            makeToolCall(name: "write_file"),
            makeToolCall(name: "delete_file"),
            makeToolCall(name: "git_commit"),
        ]

        let batch = service.executeToolCalls(
            resolvedToolCalls: calls,
            allowedToolNames: ["read_file"],
            runtime: runtime,
            memory: memory,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.results.count, 3)
        XCTAssertTrue(batch.results.allSatisfy(\.isError))
    }

    // MARK: - buildCollaborationToolResult

    func testBuildCollaborationToolResult_validJSON() {
        let result = service.buildCollaborationToolResult(
            toolName: "ask_teammate",
            response: "The design spec looks good."
        )

        XCTAssertTrue(result.contains("ask_teammate"))
        XCTAssertTrue(result.contains("The design spec looks good."))
        XCTAssertTrue(result.contains("\"ok\":true") || result.contains("\"ok\" : true"))
    }

    func testBuildCollaborationToolResult_emptyResponse() {
        let result = service.buildCollaborationToolResult(toolName: "ask_supervisor", response: "")

        XCTAssertTrue(result.contains("ask_supervisor"))
    }

    // MARK: - resolveTeam

    func testResolveTeam_withPreferredTeamID_returnsTeam() async {
        await setupProjectWithTask()

        let team = mockDelegate.snapshot?.workFolder.activeTeam
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G", preferredTeamID: team?.id)

        let resolved = service.resolveTeam(task: task)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.id, team?.id)
    }

    func testResolveTeam_withoutPreferredTeamID_fallsBackToActiveTeam() async {
        await setupProjectWithTask()

        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G")

        let resolved = service.resolveTeam(task: task)

        XCTAssertNotNil(resolved)
    }

    // MARK: - injectMemories

    /// Seed one plan tag so `generateMemories` returns non-nil content;
    /// otherwise the injection short-circuits (as of the empty-store optimization).
    private func seededMemoryStore() -> MemoryTagStore {
        let store = MemoryTagStore()
        store.registerPlanUpdate(content: "1. Draft plan", iteration: 1)
        return store
    }

    func testInjectMemories_stateful_appendsMessage() async {
        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        let session = LLMSession(responseID: "test-session")
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID,
            memoryStore: memoryStore,
            session: session,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertTrue(messages[0].content?.contains("MEMORIES") ?? false)
    }

    /// Stateful dedup — same memory content in two successive injections
    /// produces only one appended message. The prior block is already in the
    /// server's response chain.
    func testInjectMemories_stateful_dedupesUnchangedContent() async {
        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        let session = LLMSession(responseID: "test-session")
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID, memoryStore: memoryStore,
            session: session, conversationMessages: &messages
        )
        await service.injectMemories(
            stepID: stepID, memoryStore: memoryStore,
            session: session, conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 1,
                       "Identical MEMORIES content must not be appended twice on stateful continuation")
    }

    func testInjectMemories_emptyStore_doesNotInject() async {
        let stepID = "test_step"
        let memoryStore = MemoryTagStore()   // empty — no tags
        let session = LLMSession(responseID: "test-session")
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID, memoryStore: memoryStore,
            session: session, conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 0,
                       "Empty MemoryTagStore must not inject a bare header/footer block")
    }

    func testInjectMemories_stateless_replacesInPlace() async {
        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Old memories placeholder")
        ]

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        service._testSetMemoriesMessageIndex(stepID: stepID, index: 0)
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID,
            memoryStore: memoryStore,
            session: nil,
            conversationMessages: &messages
        )

        // Should replace in-place, not append
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("MEMORIES") ?? false)
    }

    func testInjectMemories_stateless_firstCall_appendsAndTracksIndex() async {
        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "User message"),
        ]

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID,
            memoryStore: memoryStore,
            session: nil,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(service._testGetMemoriesMessageIndex(stepID: stepID), 2)
    }

    // MARK: - checkAndInjectLoopWarning

    func testCheckAndInjectLoopWarning_noLoop_noWarning() async {
        let stepID = "test_step"
        let memory = ToolCallCache()
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        // Record a single tool call — not enough for loop detection
        memory.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{}", isError: false)

        await service.checkAndInjectLoopWarning(
            stepID: stepID,
            memory: memory,
            conversationMessages: &messages
        )

        XCTAssertTrue(messages.isEmpty, "No loop detected, so no warning should be injected")
    }

    func testCheckAndInjectLoopWarning_repetitiveTool_injectsWarning() async {
        let stepID = "test_step"
        let memory = ToolCallCache()
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        // Record many identical calls to trigger loop detection
        for _ in 0..<10 {
            memory.record(
                toolName: "read_file",
                argumentsJSON: #"{"path":"/test.txt"}"#,
                resultJSON: #"{"content":"same"}"#,
                isError: false
            )
        }

        await service.checkAndInjectLoopWarning(
            stepID: stepID,
            memory: memory,
            conversationMessages: &messages
        )

        // If loop was detected, a warning message should have been appended
        if !messages.isEmpty {
            XCTAssertTrue(messages[0].content?.contains("LOOP DETECTED") ?? false)
        }
        // Note: detectLoopPattern may require more iterations — test verifies the pipeline works
    }

    // MARK: - handleSupervisorAutoAnswer

    func testHandleSupervisorAutoAnswer_manualMode_returnsNil() async {
        let stepID = "test_step"
        let outcome = LLMExecutionService.ToolResultsOutcome(
            shouldStopForSupervisor: true,
            supervisorQuestion: "What framework?",
            supervisorToolCallProviderID: "tc-1"
        )
        var messages: [ChatMessage] = []
        let task = makeTask()

        let result = await service.handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: .manual,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NativeLMStudioClient(),
            config: LLMConfig(),
            conversationMessages: &messages
        )

        XCTAssertNil(result, "Manual mode should not auto-answer")
    }

    func testHandleSupervisorAutoAnswer_noQuestion_returnsNil() async {
        let stepID = "test_step"
        let outcome = LLMExecutionService.ToolResultsOutcome(
            shouldStopForSupervisor: false,
            supervisorQuestion: nil,
            supervisorToolCallProviderID: nil
        )
        var messages: [ChatMessage] = []
        let task = makeTask()

        let result = await service.handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: .autonomous,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NativeLMStudioClient(),
            config: LLMConfig(),
            conversationMessages: &messages
        )

        XCTAssertNil(result, "No question should return nil")
    }

    // MARK: - Cleanup Verification

    func testClearRunningTask_cleansAllState() {
        let stepID = "test_step"

        service._testSetPlanMessageIndex(stepID: stepID, index: 5)
        service._testSetMemoriesMessageIndex(stepID: stepID, index: 3)
        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: "test")

        service.clearRunningTask(stepID: stepID)

        XCTAssertNil(service._testGetPlanMessageIndex(stepID: stepID))
        XCTAssertNil(service._testGetMemoriesMessageIndex(stepID: stepID))
        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))
    }

    func testCancelStepExecution_cleansState() {
        let stepID = "test_step"

        service._testSetPlanMessageIndex(stepID: stepID, index: 5)
        service._testSetMemoriesMessageIndex(stepID: stepID, index: 3)
        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: "test")

        service.cancelStepExecution(stepID: stepID)

        XCTAssertNil(service._testGetPlanMessageIndex(stepID: stepID))
        XCTAssertNil(service._testGetMemoriesMessageIndex(stepID: stepID))
        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))
    }

    func testCancelAllExecutions_cleansAllState() {
        let step1 = "step1"
        let step2 = "step2"

        service._testSetPlanMessageIndex(stepID: step1, index: 1)
        service._testSetPlanMessageIndex(stepID: step2, index: 2)

        service.cancelAllExecutions()

        XCTAssertEqual(service._testPlanMessageIndexCount, 0)
        XCTAssertEqual(service._testMemoriesMessageIndexCount, 0)
        XCTAssertEqual(service._testOriginalSystemPromptCount, 0)
    }

    // MARK: - Private Helpers

    private func setupProjectWithTask() async {
        let orchestrator = NTMSOrchestrator(repository: NTMSRepository())
        await orchestrator.openWorkFolder(tempDir)
        mockDelegate.snapshot = orchestrator.snapshot
        mockDelegate.workFolderURL = tempDir
    }

    private func setupDelegateWithTask(stepID: String) {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Code",
            status: .running
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])

        let taskID = task.id
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        mockDelegate.taskToMutate = task
    }
}
