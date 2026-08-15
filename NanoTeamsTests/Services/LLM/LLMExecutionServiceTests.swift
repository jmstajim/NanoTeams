import XCTest

@testable import NanoTeams

// MARK: - Mock Delegate

@MainActor
final class MockLLMExecutionDelegate: LLMExecutionDelegate {
    var workFolderURL: URL?
    var snapshot: WorkFolderContext?
    var agentInstructions: AgentInstructionsSnapshot?
    var roleSkills: RoleSkillsSnapshot?
    var globalLLMConfig: LLMConfig = LLMConfig()
    var globalLLMContext: String = ""
    var maxLLMRetries: Int = 0
    var visionLLMConfig: LLMConfig?
    var bashPolicy: BashPolicy = BashPolicy()
    /// Records in-loop bash-approval requests published by the gate — tests poll
    /// this to know when a command is held, then resolve it.
    var bashApprovalBeganRequests: [BashApprovalRequest] = []
    func bashApprovalDidBegin(_ request: BashApprovalRequest) {
        bashApprovalBeganRequests.append(request)
    }
    func bashApprovalDidEnd(taskID: Int, stepID: String, commandKey: String, createdAt: Date) {
        bashApprovalBeganRequests.removeAll {
            $0.taskID == taskID && $0.stepID == stepID
                && $0.commandKey == commandKey && $0.createdAt == createdAt
        }
    }
    func clearAllBashApprovalRequests() { bashApprovalBeganRequests.removeAll() }
    var computerUsePolicy: ComputerUsePolicy = ComputerUsePolicy()
    var computerUseApprovalBeganRequests: [ComputerUseApprovalRequest] = []
    var clearAllComputerUseApprovalRequestsCallCount = 0
    func computerUseApprovalDidBegin(_ request: ComputerUseApprovalRequest) {
        computerUseApprovalBeganRequests.append(request)
    }
    func computerUseApprovalDidEnd(taskID: Int, stepID: String, actionKey: String, createdAt: Date) {
        computerUseApprovalBeganRequests.removeAll {
            $0.taskID == taskID && $0.stepID == stepID
                && $0.actionKey == actionKey && $0.createdAt == createdAt
        }
    }
    func clearAllComputerUseApprovalRequests() {
        clearAllComputerUseApprovalRequestsCallCount += 1
        computerUseApprovalBeganRequests.removeAll()
    }
    var loggingEnabled: Bool = false
    var exploratorySearchEnabled: Bool = false
    var searchExploratoryByDefault: Bool = false
    var readFileMaxLines: Int = AppDefaults.readFileMaxLines
    var searchMaxResults: Int = AppDefaults.searchMaxResults
    var searchContextBefore: Int = AppDefaults.searchContextBefore
    var searchContextAfter: Int = AppDefaults.searchContextAfter
    /// Scripted for tests — defaults to `true` so real-folder paths exercise.
    /// Flip to `false` to simulate default-storage exploratory-search on real folder.
    var hasRealWorkFolder: Bool = true
    /// Scripted index used by `awaitSearchIndex`. Tests install it directly.
    var scriptedSearchIndex: SearchIndex?
    var awaitSearchIndexCallCount: Int = 0
    /// Scripted expansion returned by `expandSearchQuery`. Tests install it
    /// directly — default is empty (unchanged posting-intersection behaviour).
    var scriptedExpansion: VocabVectorIndexService.ExpansionResult = .empty
    var expandSearchQueryCallCount: Int = 0

    func awaitSearchIndex() async -> SearchIndex? {
        awaitSearchIndexCallCount += 1
        return scriptedSearchIndex
    }

    func expandSearchQuery(
        query _: String,
        tokens _: [String]
    ) async -> VocabVectorIndexService.ExpansionResult {
        expandSearchQueryCallCount += 1
        return scriptedExpansion
    }

    // Tracking calls for verification
    var beginStreamingCalls: [(String, UUID, Role, Int)] = []
    var appendStreamingPreviewCalls: [(String, UUID, Role, String)] = []
    var replaceStreamingPreviewCalls: [(String, UUID, Role, String)] = []
    var appendStreamingThinkingCalls: [(String, String)] = []
    var commitStreamingCalls: [(String, Int, String, String?)] = []
    var clearStreamingPreviewCalls: [String] = []
    var updateProcessingProgressCalls: [(String, Double)] = []
    var clearProcessingProgressCalls: [String] = []
    var markStreamActivityCalls: [String] = []
    func markStreamActivity(stepID: String, taskID: Int) {
        markStreamActivityCalls.append(stepID)
        streamingTaskIDTrace.append(("markStreamActivity", stepID, taskID))
    }
    var markStreamingToolCallCalls: [String] = []
    func markStreamingToolCall(stepID: String, taskID: Int) {
        markStreamingToolCallCalls.append(stepID)
        streamingTaskIDTrace.append(("markStreamingToolCall", stepID, taskID))
    }
    /// Uniform (method, stepID, taskID) trace across every streaming-delegate call.
    /// The per-method arrays above keep their legacy shapes (stepID-keyed) for
    /// existing assertions — but that hides the taskID, so a production regression
    /// that passes the WRONG task's id would be invisible to them. Tests that care
    /// pin `streamingTaskIDTrace` instead (e.g. "every taskID recorded == task.id").
    var streamingTaskIDTrace: [(method: String, stepID: String, taskID: Int)] = []
    var notifyQueuedMessageBackstopCalls: [Int] = []
    func notifyQueuedMessageBackstop(taskID: Int) {
        notifyQueuedMessageBackstopCalls.append(taskID)
        eventLog.append("backstop:\(taskID)")
    }
    /// Cross-method call-sequence trace. Tests that need to pin ordering between
    /// `mutateTask` and `notifyQueuedMessageBackstop` (e.g. hook must fire AFTER
    /// the mutation persists, never inside the closure) append here.
    var eventLog: [String] = []
    // Task to mutate (for testing)
    var taskToMutate: NTMSTask?

    func loadedTask(_ taskID: Int) -> NTMSTask? {
        if taskToMutate?.id == taskID { return taskToMutate }
        return nil
    }

    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool {
        if var task = taskToMutate, task.id == taskID {
            eventLog.append("mutate-begin:\(taskID)")
            mutate(&task)
            taskToMutate = task
            eventLog.append("mutate-end:\(taskID)")
            return true
        }
        eventLog.append("mutate-miss:\(taskID)")
        return false
    }

    /// When true, replicate production `NTMSOrchestrator.beginStreaming`, which
    /// pre-creates an empty `.assistant` placeholder in `step.llmConversation`
    /// before every attempt. Off by default so existing tests that count
    /// conversation entries are unaffected; retry-collapse tests turn it on so the
    /// harness faithfully reproduces the production sequence.
    var plantsEmptyAssistantMessage = false
    func beginStreaming(stepID: String, taskID: Int, messageID: UUID, role: Role) async {
        beginStreamingCalls.append((stepID, messageID, role, taskID))
        streamingTaskIDTrace.append(("beginStreaming", stepID, taskID))
        if plantsEmptyAssistantMessage, var task = taskToMutate, task.id == taskID {
            TaskMutationService.appendLLMMessage(
                LLMMessage(id: messageID, role: .assistant, content: ""), to: stepID, in: &task)
            taskToMutate = task
        }
    }

    func appendStreamingPreview(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        appendStreamingPreviewCalls.append((stepID, messageID, role, content))
        streamingTaskIDTrace.append(("appendStreamingPreview", stepID, taskID))
    }

    func replaceStreamingPreview(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        replaceStreamingPreviewCalls.append((stepID, messageID, role, content))
        streamingTaskIDTrace.append(("replaceStreamingPreview", stepID, taskID))
    }

    func appendStreamingThinking(stepID: String, taskID: Int, content: String) {
        appendStreamingThinkingCalls.append((stepID, content))
        streamingTaskIDTrace.append(("appendStreamingThinking", stepID, taskID))
    }

    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async {
        commitStreamingCalls.append((stepID, taskID, content, thinking))
        streamingTaskIDTrace.append(("commitStreaming", stepID, taskID))
    }

    var discardStreamingCalls: [(stepID: String, messageID: UUID, taskID: Int)] = []
    func discardStreaming(stepID: String, messageID: UUID, taskID: Int) async {
        discardStreamingCalls.append((stepID, messageID, taskID))
    }

    var noteStreamLoopCalls: [(taskID: Int, stepID: String, signal: LoopSignal)] = []
    var noteStreamLoopReturn = true
    func noteStreamLoop(taskID: Int, stepID: String, signal: LoopSignal) -> Bool {
        noteStreamLoopCalls.append((taskID, stepID, signal))
        return noteStreamLoopReturn
    }

    func clearStreamingPreview(stepID: String, taskID: Int) {
        clearStreamingPreviewCalls.append(stepID)
        streamingTaskIDTrace.append(("clearStreamingPreview", stepID, taskID))
    }

    func updateStreamingProcessingProgress(stepID: String, taskID: Int, progress: Double) {
        updateProcessingProgressCalls.append((stepID, progress))
        streamingTaskIDTrace.append(("updateStreamingProcessingProgress", stepID, taskID))
    }

    func clearStreamingProcessingProgress(stepID: String, taskID: Int) {
        clearProcessingProgressCalls.append(stepID)
        streamingTaskIDTrace.append(("clearStreamingProcessingProgress", stepID, taskID))
    }

    var setMeetingParticipantsCalls: [(Set<String>, Int)] = []
    var clearMeetingParticipantsCalls: [Int] = []

    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        setMeetingParticipantsCalls.append((participantIDs, taskID))
    }

    func clearActiveMeetingParticipants(for taskID: Int) {
        clearMeetingParticipantsCalls.append(taskID)
    }

    // MARK: - Queued Supervisor Messages

    /// Scripted queue. Each entry is a (taskID, roleID?, content) triple — `roleID: nil`
    /// represents an untargeted (Team) message. Messages are popped in FIFO order with
    /// role-targeted entries preferred over untargeted ones (matches the real
    /// `NTMSOrchestrator.consumeQueuedSupervisorMessage` priority rules).
    var scriptedQueuedMessages: [(taskID: Int, roleID: String?, content: String)] = []
    /// Records every `consumeQueuedSupervisorMessage` delivery (taskID, roleID, stepID, content).
    var consumedQueuedMessages: [(Int, String, String, String)] = []
    /// Messages the planning-phase boundary handed back to the queue after discarding their wire
    /// turn. Order is delivery order, which is what the head-insert has to preserve.
    var requeuedSupervisorMessages: [(taskID: Int, roleID: String, text: String)] = []

    func requeueSupervisorMessageAtHead(taskID: Int, roleID: String, text: String) {
        requeuedSupervisorMessages.append((taskID: taskID, roleID: roleID, text: text))
    }

    func consumeQueuedSupervisorMessage(
        taskID: Int,
        roleID: String,
        stepID: String
    ) async -> String? {
        let roleMatchIdx = scriptedQueuedMessages.firstIndex {
            $0.taskID == taskID && $0.roleID == roleID
        }
        let untargetedMatchIdx = scriptedQueuedMessages.firstIndex {
            $0.taskID == taskID && $0.roleID == nil
        }
        let idx: Int
        if let roleMatchIdx { idx = roleMatchIdx }
        else if let untargetedMatchIdx { idx = untargetedMatchIdx }
        else { return nil }

        let entry = scriptedQueuedMessages.remove(at: idx)
        consumedQueuedMessages.append((taskID, roleID, stepID, entry.content))
        return entry.content
    }

    // MARK: - User-visible banners

    var lastInfoMessages: [String] = []
    func setLastInfoMessageForUI(_ message: String) {
        lastInfoMessages.append(message)
    }

    var lastErrorMessages: [String] = []
    func setLastErrorMessageForUI(_ message: String) {
        lastErrorMessages.append(message)
    }

    /// Prompt-prefix cache misses reported by the detector. The protocol default is a no-op, so
    /// only this shared mock implements it — the narrow doubles stay untouched.
    var prefixCacheMisses: [PrefixCacheMiss] = []

    func reportPrefixCacheMiss(_ miss: PrefixCacheMiss) {
        prefixCacheMisses.append(miss)
    }

    /// Records `holdDownstreamForRevision` invocations (engine-side teardown is not
    /// modelled by the mock — the orchestrator integration tests exercise the real path).
    var heldDownstreamCalls: [(taskID: Int, runningRoleIDs: [String], requesterRoleID: String)] = []
    func holdDownstreamForRevision(taskID: Int, runningRoleIDs: [String], requesterRoleID: String) async {
        heldDownstreamCalls.append((taskID, runningRoleIDs, requesterRoleID))
    }

    // MARK: - Delegation (LLMStateDelegate stubs)

    /// Scripted outcomes for `awaitTaskTerminalState`. Each call pops the next entry;
    /// when the queue is empty the mock returns `.terminal(.failed)` so test runs
    /// don't hang forever waiting for a continuation that will never fire.
    var scriptedAwaitOutcomes: [TaskCompletionAwaiter.WaitOutcome] = []
    var awaitedTaskIDs: [Int] = []
    func awaitTaskTerminalState(taskID: Int) async -> TaskCompletionAwaiter.WaitOutcome {
        awaitedTaskIDs.append(taskID)
        guard !scriptedAwaitOutcomes.isEmpty else { return .terminal(.failed) }
        return scriptedAwaitOutcomes.removeFirst()
    }

    var createDelegatedTaskStub: Int? = nil
    var createdDelegatedTaskRequests: [(parentTaskID: Int, parentRoleID: String, title: String, supervisorTask: String, preferredTeamID: NTMSID?, depth: Int)] = []
    func createDelegatedTask(
        parentTaskID: Int,
        parentRoleID: String,
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID?,
        depth: Int
    ) async -> Int? {
        createdDelegatedTaskRequests.append((parentTaskID, parentRoleID, title, supervisorTask, preferredTeamID, depth))
        return createDelegatedTaskStub
    }

    var startedRunForTaskIDs: [Int] = []
    func startRunForTask(taskID: Int) async { startedRunForTaskIDs.append(taskID) }

    var closeTaskStub: Bool = true
    var closedTaskIDs: [Int] = []
    func closeTask(taskID: Int) async -> Bool {
        closedTaskIDs.append(taskID)
        return closeTaskStub
    }

    var lastErrorPerTaskStub: [Int: String] = [:]
    func lastErrorMessageForTask(_ taskID: Int) -> String? { lastErrorPerTaskStub[taskID] }

    var streamLastActivityStub: [String: Date] = [:]
    func streamLastActivityAt(stepID: String, taskID: Int) -> Date? { streamLastActivityStub[stepID] }

    var streamLiveTextStub: [String: String] = [:]
    func streamLiveText(stepID: String, taskID: Int) -> String? { streamLiveTextStub[stepID] }

    var stopEngineCalls: [Int] = []
    func stopEngineForTask(_ taskID: Int) { stopEngineCalls.append(taskID) }

    var pauseRunCalls: [Int] = []
    func pauseRun(taskID: Int) async { pauseRunCalls.append(taskID) }

    var resumeRunCalls: [Int] = []
    func resumeRun(taskID: Int) async { resumeRunCalls.append(taskID) }

    var activeDelegationChildStub: [String: Int] = [:]
    func activeDelegationChildID(taskID: Int, roleID: String) -> Int? {
        activeDelegationChildStub["\(taskID):\(roleID)"]
    }

    var answerSupervisorCalls: [(taskID: Int, stepID: String, answer: String)] = []
    func answerSupervisorQuestion(taskID: Int, stepID: String, answer: String) async -> Bool {
        answerSupervisorCalls.append((taskID, stepID, answer))
        return true
    }

    var autovisorActions: [AutovisorAction] = []
    var autovisorActionResult: AutovisorActionResult = .success("ok")
    func performAutovisorAction(_ action: AutovisorAction) async -> AutovisorActionResult {
        autovisorActions.append(action)
        return autovisorActionResult
    }
    var persistedAutovisorMemory: [String] = []
    var persistAutovisorMemoryResult = true
    func persistAutovisorMemory(_ text: String) async -> Bool {
        persistedAutovisorMemory.append(text)
        return persistAutovisorMemoryResult
    }
    func autovisorLoadTask(_ taskID: Int) async -> NTMSTask? { loadedTask(taskID) }
}

// MARK: - Test Helpers

/// Creates a minimal TeamRoleDefinition for testing
private func makeTestRole(id: String, name: String) -> TeamRoleDefinition {
    let isBuiltIn = Role.builtInRole(for: id) != nil
    return TeamRoleDefinition(
        id: id,
        name: name,
        prompt: "",
        toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(),
        llmOverride: nil,
        isSystemRole: isBuiltIn,
        systemRoleID: isBuiltIn ? id : nil,
        createdAt: Date(),
        updatedAt: Date()
    )
}

/// Creates a minimal Team for testing validation logic
private func makeTestTeam(name: String, roleIDs: [String], settings: TeamSettings) -> Team {
    let roles = roleIDs.map { makeTestRole(id: $0, name: $0) }
    return Team(
        name: name,
        roles: roles,
        artifacts: [],
        settings: settings,
        graphLayout: TeamGraphLayout()
    )
}

// MARK: - Tests

@MainActor
final class LLMExecutionServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testServiceInitialization() {
        XCTAssertNotNil(service)
    }
    
    let newService1 = LLMExecutionService(repository: NTMSRepository())

    func testServiceInitializationWithRepository() {
        XCTAssertNotNil(newService1)
    }

    // MARK: - Delegate Attachment Tests

    func testAttachDelegate() {
//        newService = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()

        service.attach(delegate: delegate)

        // No direct way to verify, but should not crash
        XCTAssertNotNil(service)
    }

    func testReattachDelegate() {
        let delegate1 = MockLLMExecutionDelegate()
        let delegate2 = MockLLMExecutionDelegate()

        service.attach(delegate: delegate1)
        service.attach(delegate: delegate2)

        // Should use the latest delegate
        XCTAssertNotNil(service)
    }

    // MARK: - Step Running State Tests

    func testIsStepRunningReturnsFalseInitially() {
        let stepID = "test_step"
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: 0))
    }

    func testIsStepRunningForDifferentSteps() {
        let step1 = "step1"
        let step2 = "step2"

        XCTAssertFalse(service.isStepRunning(stepID: step1, taskID: 0))
        XCTAssertFalse(service.isStepRunning(stepID: step2, taskID: 0))
    }

    // MARK: - Cancellation Tests

    func testCancelStepExecution() async {
        let stepID = "test_step"

        // Should not crash even if step wasn't running
        await service.cancelStepExecution(stepID: stepID, taskID: 0)

        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: 0))
    }

    func testCancelAllExecutions() {
        // Should not crash even with no running executions
        service.cancelAllExecutions()

        let stepID = "test_step"
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: 0))
    }

    func testCancelStepClearsStreamingPreview() async {
        let stepID = "test_step"

        await service.cancelStepExecution(stepID: stepID, taskID: 0)

        // Verify clearStreamingPreview was called
        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCancelStepExecutionClearsPerStepState() async {
        let stepID = "test_step"

        // Seed a per-step state entry through a live field (`activeModelKey`).
        service._testSetActiveModel(stepID: stepID, taskID: 0, base: "http://x", model: "m")
        XCTAssertFalse(service.activeModelKeys().isEmpty)

        // Cancel step execution should drop the per-step state entry.
        await service.cancelStepExecution(stepID: stepID, taskID: 0)

        XCTAssertTrue(service.activeModelKeys().isEmpty)
    }

    func testCancelAllExecutionsClearsAllPerStepState() {
        // Seed state entries for multiple steps through a live field.
        service._testSetActiveModel(stepID: "step1", taskID: 0, base: "http://x", model: "m1")
        service._testSetActiveModel(stepID: "step2", taskID: 0, base: "http://x", model: "m2")
        service._testSetActiveModel(stepID: "step3", taskID: 0, base: "http://x", model: "m3")

        XCTAssertEqual(service.activeModelKeys().count, 3)

        // Cancel all executions should drop every per-step state entry.
        service.cancelAllExecutions()

        XCTAssertTrue(service.activeModelKeys().isEmpty)
    }

    // MARK: - Original System Prompt Restoration Tests






    // MARK: - Start Step Execution Guards Tests

    func testStartStepExecutionRequiresProjectFolder() {
        mockDelegate.workFolderURL = nil

        let task = createTestTask()
        let stepID = task.runs[0].steps[0].id

        // Should not start execution without project folder
        service.startStepExecution(
            stepID: stepID,
            taskID: task.id,
            task: task,
            runIndex: 0,
            stepIndex: 0
        )

        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: 0))
    }

    func testStartStepExecutionRequiresRunningStatus() {
        var task = createTestTask()
        let stepID = task.runs[0].steps[0].id

        // Set step status to something other than running
        task.runs[0].steps[0].status = .done

        service.startStepExecution(
            stepID: stepID,
            taskID: task.id,
            task: task,
            runIndex: 0,
            stepIndex: 0
        )

        // Step with .done status should not start
        // This verifies the guard statement
        XCTAssertNotNil(service)
    }

    // MARK: - Helper Methods

    private func createTestTask() -> NTMSTask {
        let stepExecution = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Test Step",
            status: .running
        )

        let run = Run(
            id: 0,
            steps: [stepExecution]
        )

        return NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            runs: [run]
        )
    }
}

// MARK: - LLMStepStop Tests

final class LLMStepStopTests: XCTestCase {

    func testCompletedCase() {
        let stop = LLMStepStop.completed

        switch stop {
        case .completed:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected .completed")
        }
    }

    func testNeedsSupervisorInputCase() {
        let stop = LLMStepStop.needsSupervisorInput(question: "What color?")

        switch stop {
        case .needsSupervisorInput(let question):
            XCTAssertEqual(question, "What color?")
        default:
            XCTFail("Expected .needsSupervisorInput")
        }
    }

    func testContinueLoopCase() {
        let stop = LLMStepStop.continueLoop

        switch stop {
        case .continueLoop:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected .continueLoop")
        }
    }

    func testToolFailureCase() {
        let stop = LLMStepStop.toolFailure(message: "Network error")

        switch stop {
        case .toolFailure(let message):
            XCTAssertEqual(message, "Network error")
        default:
            XCTFail("Expected .toolFailure")
        }
    }
}

// MARK: - Tool Definitions Tests

@MainActor
final class LLMExecutionServiceToolDefinitionsTests: XCTestCase {

    func testDefaultToolsContainExpectedTools() {
        let tools = ToolHandlerRegistry.allSchemas
        let toolNames = Set(tools.map { $0.name })

        // File system tools
        XCTAssertTrue(toolNames.contains("read_file"))
        XCTAssertTrue(toolNames.contains("write_file"))
        XCTAssertTrue(toolNames.contains("list_files"))
        XCTAssertTrue(toolNames.contains("search"))
        XCTAssertTrue(toolNames.contains("delete_file"))

        // Git tools
        XCTAssertTrue(toolNames.contains("git_status"))
        XCTAssertTrue(toolNames.contains("git_add"))
        XCTAssertTrue(toolNames.contains("git_commit"))
        XCTAssertTrue(toolNames.contains("git_pull"))
        XCTAssertTrue(toolNames.contains("git_diff"))
        XCTAssertTrue(toolNames.contains("git_log"))

        // Xcode tools
        XCTAssertTrue(toolNames.contains("run_xcodebuild"))
        XCTAssertTrue(toolNames.contains("run_xcodetests"))

        // Supervisor tool
        XCTAssertTrue(toolNames.contains("ask_supervisor"))

        // Artifact tool
        XCTAssertTrue(toolNames.contains("create_artifact"))
    }

    func testToolDefinitionHasDescription() {
        let tools = ToolHandlerRegistry.allSchemas

        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty)
        }
    }

    func testToolDefinitionHasParameters() {
        let tools = ToolHandlerRegistry.allSchemas

        for tool in tools {
            // All tools should have parameters (even if empty object)
            XCTAssertEqual(tool.parameters.type, "object")
        }
    }

    // MARK: - unavailableToRoles filter
    //
    // `create_team` has a dedicated invocation path (TeamGenerationService) and must
    // never appear in any role's tool schema, even if a misconfigured role definition
    // explicitly lists it. This is the schema-level enforcement of `availableToRoles=false`.

    func testToolSchemas_filtersUnavailableToRoles_evenWhenExplicitlyListed() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        // Build a custom role that explicitly lists create_team in its toolIDs.
        let customRole = TeamRoleDefinition(
            id: "rogue_role",
            name: "Rogue",
            prompt: "p",
            toolIDs: ["read_file", ToolNames.createTeam, "list_files"],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [customRole], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "rogue_role"), team: team)
        let names = Set(schemas.map(\.name))

        XCTAssertTrue(names.contains("read_file"), "Other listed tools should pass through")
        XCTAssertTrue(names.contains("list_files"))
        XCTAssertFalse(names.contains(ToolNames.createTeam),
                       "create_team must be filtered out via unavailableToRoles")
    }

    // Regression test for the "custom role can't use create_artifact" bug: `Role.fromDefinition`
    // stores the role's `name` (not `id`) in `.custom(id:)`, so a custom-name role arriving at
    // `toolSchemas(for:team:)` has `role.baseID == definition.name`. The lookup must match by
    // name (via `Team.findRole(byIdentifier:)`), otherwise it silently falls through to
    // `fallbackCustomRoleToolIDs` and the role loses its configured tools + auto-injections.
    func testToolSchemas_customRoleResolvedByName_autoInjectsCreateArtifact() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        // Production shape: id is a UUID, name is the human-readable label, systemRoleID is nil.
        let customRole = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Контент-менеджер",
            prompt: "Write the post.",
            toolIDs: [
                ToolNames.readFile,
                ToolNames.writeFile,
                ToolNames.editFile,
                ToolNames.listFiles,
                ToolNames.updateScratchpad,
                ToolNames.askSupervisor,
            ],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["LinkedIn Post"]
            )
        )
        let team = Team(
            name: "LinkedIn Post Team", roles: [customRole], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )

        // `.custom(id: name)` matches the production shape from `Role.fromDefinition`.
        let schemas = service.toolSchemas(for: .custom(id: "Контент-менеджер"), team: team)
        let names = Set(schemas.map(\.name))

        // Configured tools pass through — proves roleDefinition was resolved (not fallback).
        XCTAssertTrue(names.contains(ToolNames.writeFile),
                      "write_file is in the role's toolIDs; must be present")
        XCTAssertTrue(names.contains(ToolNames.editFile),
                      "edit_file is in the role's toolIDs; must be present")

        // create_artifact is auto-injected for producing roles.
        XCTAssertTrue(names.contains(ToolNames.createArtifact),
                      "create_artifact must be auto-injected for producing custom roles")

        // Not in role's toolIDs → must NOT leak in via fallback. Guards against regression
        // back to `fallbackCustomRoleToolIDs` (which contains both of these).
        XCTAssertFalse(names.contains(ToolNames.askTeammate),
                       "ask_teammate is not in toolIDs; fallback set must not leak in")
        XCTAssertFalse(names.contains(ToolNames.requestTeamMeeting),
                       "request_team_meeting is not in toolIDs; fallback set must not leak in")
    }

    func testUnavailableToRoles_containsCreateTeam() {
        XCTAssertTrue(ToolHandlerRegistry.unavailableToRoles.contains(ToolNames.createTeam))
    }

    // MARK: - conclude_meeting auto-inject for Meeting Coordinator
    //
    // Regression: `conclude_meeting` was previously granted only via the `pmOnlyToolIDs`
    // fallback group, which meant it was effectively hardcoded to PM (and `theAgreeable`)
    // and only applied when a role had NO team config. In FAANG where the coordinator is
    // TPM, nobody could actually call `conclude_meeting` because the role templates
    // carried their own toolIDs (bypassing fallback). Fix: auto-inject at dispatch time
    // for whichever role `team.settings.meetingCoordinatorRoleID` points to.

    func testToolSchemas_autoInjectsConcludeMeetingForCoordinator() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let coordinator = TeamRoleDefinition(
            id: "coord_role",
            name: "Coordinator",
            prompt: "p",
            toolIDs: [ToolNames.askTeammate, ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let other = TeamRoleDefinition(
            id: "other_role",
            name: "Other",
            prompt: "p",
            toolIDs: [ToolNames.askTeammate, ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [coordinator, other],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "coord_role"),
            graphLayout: TeamGraphLayout()
        )

        let coordSchemas = service.toolSchemas(for: .custom(id: "coord_role"), team: team)
        let otherSchemas = service.toolSchemas(for: .custom(id: "other_role"), team: team)

        XCTAssertTrue(
            coordSchemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "conclude_meeting MUST be auto-injected for the meeting coordinator role"
        )
        XCTAssertFalse(
            otherSchemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "conclude_meeting must NOT leak to non-coordinator roles"
        )
    }

    // Dedup guard: if coordinator role ALREADY has conclude_meeting in toolIDs
    // (legitimate config that could come from team templates or LLM-generated
    // teams), the auto-inject must NOT add a second copy. Duplicate tool schemas
    // would either be rejected by the LM Studio API or silently confuse the model.
    // Coordinator must also have requestTeamMeeting so the auto-inject branch is
    // actually exercised under the gating rule (otherwise the auto-inject is
    // skipped entirely and the dedup guard isn't really tested).
    func testToolSchemas_concludeMeetingInCoordinatorToolIDs_notDuplicated() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let coordinator = TeamRoleDefinition(
            id: "coord_role",
            name: "Coordinator",
            prompt: "p",
            toolIDs: [ToolNames.concludeMeeting, ToolNames.requestTeamMeeting, ToolNames.askTeammate],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [coordinator],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "coord_role"),
            graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "coord_role"), team: team)
        let concludeCount = schemas.filter { $0.name == ToolNames.concludeMeeting }.count
        XCTAssertEqual(
            concludeCount, 1,
            "conclude_meeting must appear exactly once even when both explicit toolIDs and auto-inject would grant it. Got \(concludeCount) copies."
        )
    }

    // Regression: previously `conclude_meeting` was auto-injected for any role flagged
    // as the meeting coordinator, regardless of whether they could actually start
    // meetings. In single-role chat-mode templates (Coding Assistant), this surfaced
    // `conclude_meeting` in the role's tool list as "Auto" even though `request_team_meeting`
    // was unchecked — dead weight the LLM could never use. Fix: gate auto-inject on
    // the coordinator having `request_team_meeting` in their own toolIDs.
    func testToolSchemas_noConcludeMeetingWhenCoordinatorLacksRequestTeamMeeting() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let coordinator = TeamRoleDefinition(
            id: "coord_role",
            name: "Coordinator",
            prompt: "p",
            toolIDs: [ToolNames.askTeammate, ToolNames.readFile],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [coordinator],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "coord_role"),
            graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "coord_role"), team: team)
        XCTAssertFalse(
            schemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "conclude_meeting must NOT be auto-injected when the coordinator can't start meetings (no request_team_meeting in toolIDs)"
        )
    }

    // Template-level regression: Coding Assistant is single-role chat-mode and does not
    // grant request_team_meeting to its only role. Even though the role is the team's
    // meeting coordinator (coordinatorIndex: 1 in the factory), it must NOT see
    // conclude_meeting in its schemas.
    func testToolSchemas_codingAssistantTemplate_doesNotGetConcludeMeeting() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let team = TeamTemplateFactory.codingAssistant()
        guard let coordinatorID = team.settings.meetingCoordinatorRoleID,
              let coordinatorRole = team.roles.first(where: { $0.id == coordinatorID }) else {
            XCTFail("Coding Assistant must have a meeting coordinator configured")
            return
        }

        XCTAssertFalse(
            coordinatorRole.toolIDs.contains(ToolNames.requestTeamMeeting),
            "Precondition: Coding Assistant coordinator must not have request_team_meeting (single-role chat team)"
        )

        let schemas = service.toolSchemas(for: .custom(id: coordinatorID), team: team)
        XCTAssertFalse(
            schemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "conclude_meeting must not appear in Coding Assistant coordinator's schemas — there are no meetings to conclude"
        )
    }

    // Auto mode (no designated coordinator): any role that can start a meeting
    // (`request_team_meeting` in toolIDs) needs to be able to close it, so
    // `conclude_meeting` is auto-injected for them. This is the inverse of the
    // pre-Auto behavior where conclude_meeting was gated to a single named
    // coordinator role.
    func testToolSchemas_concludeMeetingAvailable_inAutoMode_forAnyMeetingRequester() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let role = TeamRoleDefinition(
            id: "r1",
            name: "R1",
            prompt: "p",
            toolIDs: [ToolNames.askTeammate, ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [role],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "r1"), team: team)
        XCTAssertTrue(
            schemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "Auto mode → any role with request_team_meeting must get conclude_meeting"
        )
    }

    // Coordinator mode: conclude_meeting is gated to the designated coordinator;
    // other roles with `request_team_meeting` do NOT get it.
    func testToolSchemas_concludeMeetingStillGatedToCoordinator_whenCoordinatorSet() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let roleA = TeamRoleDefinition(
            id: "a",
            name: "A (coordinator)",
            prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let roleB = TeamRoleDefinition(
            id: "b",
            name: "B (also can request meetings)",
            prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [roleA, roleB],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "a"),
            graphLayout: TeamGraphLayout()
        )

        let schemasA = service.toolSchemas(for: .custom(id: "a"), team: team)
        let schemasB = service.toolSchemas(for: .custom(id: "b"), team: team)
        XCTAssertTrue(
            schemasA.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "Designated coordinator must get conclude_meeting"
        )
        XCTAssertFalse(
            schemasB.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "Non-coordinator roles must NOT get conclude_meeting when a coordinator is set"
        )
    }

    // Regression pin for round-3 review CR.4 (silent-failure F2): the
    // schema-build path is the earliest universal detection point for an
    // orphan-coordinator team. Calling `toolSchemas` must surface the
    // one-shot info banner before the LLM ever decides to start a meeting.
    func testToolSchemas_orphanCoordinator_firesOrphanInfoBanner() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let role = TeamRoleDefinition(
            id: "live", name: "Live", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "MyTeam", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost"),
            graphLayout: TeamGraphLayout()
        )

        _ = service.toolSchemas(for: .custom(id: "live"), team: team)

        XCTAssertEqual(delegate.lastInfoMessages.count, 1,
                       "Orphan must be surfaced via schema-build, not gated on meeting actually starting")
        XCTAssertTrue(delegate.lastInfoMessages[0].contains("MyTeam"))
    }

    // Regression pin for round-2 review finding C2.1: an orphaned stored
    // coordinator ID must NOT trap `conclude_meeting` auto-inject in a
    // coord-mode-no-match state where no role gets the tool. Both the runtime
    // (`effectiveCoordinator`) and the picker self-heal to Auto for orphan
    // IDs; the schema-build path must agree. Otherwise the LLM can start
    // meetings (via `request_team_meeting`) but cannot close them
    // (`conclude_meeting` absent from the schema).
    func testToolSchemas_orphanCoordinator_treatedAsAutoMode_injectsConcludeMeeting() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let role = TeamRoleDefinition(
            id: "live",
            name: "Live",
            prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [role],
            artifacts: [],
            // Stored coordinator references a role that no longer exists.
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost-of-deleted-role"),
            graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "live"), team: team)
        XCTAssertTrue(
            schemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "Orphan stored coordinator ID must behave like Auto: any role with request_team_meeting gets conclude_meeting"
        )
    }

    // Orphan self-heal: an ID that references a deleted role must resolve to
    // nil (Auto mode), not silently fabricate a `.custom(id: "deleted-id")`.
    func testResolveCoordinatorRole_orphanedID_returnsNil() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let role = TeamRoleDefinition(
            id: "alive",
            name: "Alive",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [role],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost-of-deleted-role"),
            graphLayout: TeamGraphLayout()
        )
        XCTAssertNil(
            service.resolveCoordinatorRole(team: team),
            "Orphaned coordinator ID must resolve to nil, not .custom(id:)"
        )
    }

    // Supervisor cannot be a meeting coordinator (Supervisor is the user, not
    // an LLM). If `teams.json` somehow stores Supervisor's id as the
    // coordinator (hand edit / corruption), runtime must reject it and
    // self-heal to Auto — symmetric with the picker which never offers
    // Supervisor as an option. Regression pin for round-3 review MD.2.
    func testResolveCoordinatorRole_storedSupervisorID_rejected() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies(),
            systemRoleID: "supervisor"
        )
        let role = TeamRoleDefinition(
            id: "r", name: "R", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [supervisor, role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "sup"),
            graphLayout: TeamGraphLayout()
        )
        XCTAssertNil(
            service.resolveCoordinatorRole(team: team),
            "Stored Supervisor ID must be rejected (Supervisor can never be coordinator)"
        )
    }

    // Defensive: stored empty string resolves to nil. Parity with
    // `DesignatedCoordinatorResolver.normalize` since runtime now funnels
    // through it (CR.1 fix).
    func testResolveCoordinatorRole_emptyStoredID_returnsNil() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let role = TeamRoleDefinition(
            id: "r", name: "R", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: ""),
            graphLayout: TeamGraphLayout()
        )
        XCTAssertNil(service.resolveCoordinatorRole(team: team))
    }

    // Auto mode: nil coordinator ID resolves to nil — meeting runs leaderless.
    func testResolveCoordinatorRole_autoMode_returnsNil() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let role = TeamRoleDefinition(
            id: "r1", name: "R", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        XCTAssertNil(service.resolveCoordinatorRole(team: team))
    }

    // MARK: - effectiveCoordinator (designated ?? initiator)

    // Auto mode: when no coordinator is designated, the meeting's initiator
    // becomes the effective coordinator for that meeting.
    func testEffectiveCoordinator_autoMode_returnsInitiator() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let role = TeamRoleDefinition(
            id: "r", name: "R", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        let initiator: Role = .productManager
        XCTAssertEqual(
            service.effectiveCoordinator(team: team, initiator: initiator),
            initiator,
            "Auto mode (designated == nil): effective coordinator falls back to initiator"
        )
    }

    // Designated-coordinator mode: effective coordinator is the designated role,
    // not the initiator.
    func testEffectiveCoordinator_designatedSet_returnsDesignated() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let coord = TeamRoleDefinition(
            id: "user-coord",
            name: "User Coord",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [coord], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "user-coord"),
            graphLayout: TeamGraphLayout()
        )
        guard let resolved = service.effectiveCoordinator(team: team, initiator: .productManager) as Role? else {
            XCTFail("expected a Role"); return
        }
        XCTAssertEqual(resolved.baseID, "user-coord",
                       "Designated coordinator wins over initiator")
    }

    // Orphan ID falls through `resolveCoordinatorRole`'s self-heal to nil and
    // then `effectiveCoordinator` falls back to the initiator.
    func testEffectiveCoordinator_orphanedID_returnsInitiator() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let role = TeamRoleDefinition(
            id: "alive", name: "Alive", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost"),
            graphLayout: TeamGraphLayout()
        )
        let initiator: Role = .softwareEngineer
        XCTAssertEqual(
            service.effectiveCoordinator(team: team, initiator: initiator),
            initiator,
            "Orphaned designation self-heals; effective coordinator is the initiator"
        )
    }

    // MARK: - Orphan-coordinator info signal (round-2 review I2.1)

    // First detection on a team with an orphaned designated coordinator emits
    // a `lastInfoMessage` so the Supervisor learns their explicit pick was
    // silently substituted (the designated role was removed elsewhere).
    func testReportOrphanCoordinator_orphanedDesignation_emitsInfoOnce() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let role = TeamRoleDefinition(
            id: "live", name: "Live", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "FAANG", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost"),
            graphLayout: TeamGraphLayout()
        )

        service.reportOrphanCoordinatorIfNeeded(team: team)
        service.reportOrphanCoordinatorIfNeeded(team: team)

        XCTAssertEqual(delegate.lastInfoMessages.count, 1,
                       "Orphan info must surface exactly once per team")
        XCTAssertTrue(delegate.lastInfoMessages[0].contains("FAANG"),
                      "Info message must name the affected team")
    }

    // Nil designation (genuine Auto) is not an orphan — nothing surfaced.
    func testReportOrphanCoordinator_autoMode_noEmit() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let role = TeamRoleDefinition(
            id: "r", name: "R", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )

        service.reportOrphanCoordinatorIfNeeded(team: team)
        XCTAssertTrue(delegate.lastInfoMessages.isEmpty)
    }

    // Live designation (role exists) is not an orphan — nothing surfaced.
    func testReportOrphanCoordinator_designatedLive_noEmit() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let role = TeamRoleDefinition(
            id: "live", name: "Live", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "live"),
            graphLayout: TeamGraphLayout()
        )

        service.reportOrphanCoordinatorIfNeeded(team: team)
        XCTAssertTrue(delegate.lastInfoMessages.isEmpty)
    }

    // Re-arm: once the orphan is resolved (e.g. user picks a valid coord in
    // Settings), the throttle clears for that team so a NEW orphan emerges
    // later (a different role gets deleted) → banner fires again.
    // Regression pin for round-3 review CR.3 (silent-failure F1 / code-
    // reviewer S3.1 convergence): without re-arm, the throttle stale-sticks
    // after fix, suppressing future orphan signals for the team's lifetime.
    func testReportOrphanCoordinator_rearms_afterOrphanResolved() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let role = TeamRoleDefinition(
            id: "live", name: "Live", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let teamWithOrphan = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost-A"),
            graphLayout: TeamGraphLayout()
        )
        let teamWithLiveCoord = Team(
            id: teamWithOrphan.id,  // same team, just settings change
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "live"),
            graphLayout: TeamGraphLayout()
        )
        let teamWithNewOrphan = Team(
            id: teamWithOrphan.id,
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost-B"),
            graphLayout: TeamGraphLayout()
        )

        // 1. Orphan A → fires.
        service.reportOrphanCoordinatorIfNeeded(team: teamWithOrphan)
        XCTAssertEqual(delegate.lastInfoMessages.count, 1)

        // 2. User fixes designation → re-arm should clear throttle entry.
        service.reportOrphanCoordinatorIfNeeded(team: teamWithLiveCoord)
        XCTAssertEqual(delegate.lastInfoMessages.count, 1,
                       "Live coord must not emit a new info message")

        // 3. New orphan B emerges → fires again.
        service.reportOrphanCoordinatorIfNeeded(team: teamWithNewOrphan)
        XCTAssertEqual(delegate.lastInfoMessages.count, 2,
                       "After re-arm, a new orphan must surface a fresh info message")
    }

    // Different teams each get their own notification.
    func testReportOrphanCoordinator_differentTeams_eachEmitOnce() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let role = TeamRoleDefinition(
            id: "r", name: "R", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let teamA = Team(
            name: "A", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost"),
            graphLayout: TeamGraphLayout()
        )
        let teamB = Team(
            name: "B", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost"),
            graphLayout: TeamGraphLayout()
        )

        service.reportOrphanCoordinatorIfNeeded(team: teamA)
        service.reportOrphanCoordinatorIfNeeded(team: teamB)
        service.reportOrphanCoordinatorIfNeeded(team: teamA)  // already reported
        service.reportOrphanCoordinatorIfNeeded(team: teamB)  // already reported

        XCTAssertEqual(delegate.lastInfoMessages.count, 2)
    }

    // Non-system role (no systemRoleID) — must preserve role identity as
    // `.custom(id:)`.
    func testResolveCoordinatorRole_customRole_resolvesToCustom() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let role = TeamRoleDefinition(
            id: "user-defined",
            name: "User Defined Role",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "user-defined"),
            graphLayout: TeamGraphLayout()
        )
        guard let resolved = service.resolveCoordinatorRole(team: team) else {
            XCTFail("Should resolve to a Role")
            return
        }
        XCTAssertEqual(resolved.baseID, "user-defined")
    }

    func testUnavailableToRoles_doesNotContainNormalTools() {
        // Sanity: make sure we didn't accidentally exclude useful tools.
        let normalTools = ["read_file", "write_file", "git_status", "ask_supervisor", "create_artifact"]
        for name in normalTools {
            XCTAssertFalse(
                ToolHandlerRegistry.unavailableToRoles.contains(name),
                "\(name) should be available to roles"
            )
        }
    }
}

// MARK: - Role Definition Tool Access Tests

@MainActor
final class RoleToolAccessTests: XCTestCase {

    func testSoftwareEngineerHasWriteTools() {
        let toolIDs = (SystemTemplates.fallbackToolIDs[Role.softwareEngineer.baseID] ?? [])

        XCTAssertTrue(toolIDs.contains("read_file"))
        XCTAssertTrue(toolIDs.contains("write_file"))
        XCTAssertTrue(toolIDs.contains("git_add"))
        XCTAssertTrue(toolIDs.contains("git_commit"))
    }

    func testQAHasReadOnlyTools() {
        let toolIDs = (SystemTemplates.fallbackToolIDs[Role.sre.baseID] ?? [])

        // QA should have read tools
        XCTAssertTrue(toolIDs.contains("read_file"))
        XCTAssertTrue(toolIDs.contains("list_files"))
        XCTAssertTrue(toolIDs.contains("search"))

        // QA should NOT have write tools
        XCTAssertFalse(toolIDs.contains("write_file"))
        XCTAssertFalse(toolIDs.contains("edit_code_in_file"))
        XCTAssertFalse(toolIDs.contains("delete_file"))
    }

    func testSupervisorHasNoTools() {
        let toolIDs = (SystemTemplates.fallbackToolIDs[Role.supervisor.baseID] ?? [])

        // Supervisor should have minimal or no tools
        XCTAssertTrue(toolIDs.isEmpty || toolIDs.allSatisfy { $0 == "ask_supervisor" })
    }

    func testProductOwnerHasLimitedTools() {
        let toolIDs = (SystemTemplates.fallbackToolIDs[Role.productManager.baseID] ?? [])

        // PO should have read access but not write access
        XCTAssertFalse(toolIDs.contains("write_file"))
        XCTAssertFalse(toolIDs.contains("git_commit"))
    }
}

// MARK: - Clean Harmony Tokens Tests

@MainActor
final class CleanHarmonyTokensTests: XCTestCase {

    // MARK: - Channel Marker Tests

    func testChannelFinalIsStripped() {
        let input = "Some text <|channel|>final more text"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Some text more text")
    }

    func testChannelCommentaryIsStripped() {
        let input = "<|channel|>commentary Here is my commentary"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Here is my commentary")
    }

    func testChannelWithoutSuffixIsStripped() {
        let input = "Text before <|channel|> text after"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Text before text after")
    }

    // MARK: - Constrain Marker Tests

    func testConstrainRequirementsIsStripped() {
        let input = "<|constrain|>requirements The requirements are..."
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "The requirements are...")
    }

    // MARK: - Call and End Markers Tests

    func testCallMarkerIsStripped() {
        let input = "Text <|call|> more text"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Text  more text")
    }

    func testEndMarkerIsStripped() {
        let input = "Text <|end|> more text"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Text  more text")
    }

    func testMessageMarkerIsStripped() {
        let input = "Text <|message|> more text"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Text  more text")
    }

    // MARK: - Start Functions Marker Tests

    func testStartFunctionsIncompleteCallIsStripped() {
        let input = "Text <|start|>functions.read_file incomplete"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Text  incomplete")
    }

    // MARK: - IM Start/End Markers Tests

    func testImStartAssistantIsStripped() {
        let input = "<|im_start|>assistant Hello world"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Hello world")
    }

    func testImEndIsStripped() {
        let input = "Hello world<|im_end|>"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - Multiple Tokens Tests

    func testMultipleTokensAreStripped() {
        let input = "<|channel|>commentary Some text <|call|> more <|end|> final"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "Some text  more  final")
    }

    // MARK: - Content Preservation Tests

    func testNormalContentIsPreserved() {
        let input = "This is normal content without any special tokens."
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, input)
    }

    func testMarkdownContentIsPreserved() {
        let input = """
        # Requirements Document

        | Requirement | Description |
        |-------------|-------------|
        | FR-1 | The app must print "Hello" |

        **Goal:** Update the greeting message.
        """
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, input)
    }

    func testCodeBlocksArePreserved() {
        let input = """
        Here is the code:
        ```swift
        print("Hello, World!")
        ```
        """
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, input)
    }

    // MARK: - Real-World Scenario Tests

    func testRealWorldScenarioWithChannelAndContent() {
        // This is the actual bug scenario - content after <|channel|> was being lost
        let input = """
        We need to produce Requirements artifact.
        <|channel|>commentary
        NanoTeamsSample
        **Goal:** Update the console greeting message.

        | Requirement | Description |
        |-------------|-------------|
        | **Functional** | The app must print "Hello, NanoTeams" |
        """
        let result = ConversationRepairService.cleanHarmonyTokens(input)

        // Should preserve the content, only removing the token
        XCTAssertTrue(result.contains("NanoTeamsSample"))
        XCTAssertTrue(result.contains("**Goal:** Update the console greeting message."))
        XCTAssertTrue(result.contains("| Requirement | Description |"))
        XCTAssertFalse(result.contains("<|channel|>"))
    }

    func testEmptyStringReturnsEmpty() {
        let input = ""
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "")
    }

    func testWhitespaceOnlyIsTrimmed() {
        let input = "   \n\t   "
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "")
    }

    func testOnlyTokensResultsInEmptyString() {
        let input = "<|channel|>final"
        let result = ConversationRepairService.cleanHarmonyTokens(input)
        XCTAssertEqual(result, "")
    }
}

// MARK: - Step Completion Extension Tests

@MainActor
final class LLMExecutionServiceStepCompletionTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create .nanoteams directory structure
        let nanoteamsDir = tempDir.appendingPathComponent(".nanoteams")
        try fileManager.createDirectory(at: nanoteamsDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    // MARK: - completeStepSuccess Tests

    func testCompleteStepSuccessClearsStreamingPreview() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID, taskID: task.id)

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCompleteStepSuccessCallsWriteReport() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID, taskID: task.id)
    }

    func testCompleteStepSuccessSetsStatusDone() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID, taskID: task.id)

        // finalizeStepCompletion sets .done via TaskMutationService.updateStepStatus
        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, StepStatus.done)
        XCTAssertNotNil(updated.completedAt)
    }

    func testCompleteStepSuccessClearsRunningTask() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID, taskID: task.id)

        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: 0))
    }

    // MARK: - completeStepWithWarning Tests

    func testCompleteStepWithWarningClearsStreamingPreview() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, taskID: task.id, warning: "Test warning")

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCompleteStepWithWarningWritesReport() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, taskID: task.id, warning: "Test warning")
    }

    func testCompleteStepWithWarningAppendsWarningMessage() async throws {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, taskID: task.id, warning: "My warning message")

        let updatedTask = try XCTUnwrap(mockDelegate.taskToMutate)
        let step = updatedTask.runs[0].steps[0]
        XCTAssertTrue(step.messages.contains {
            $0.role == step.role
                && $0.content.hasPrefix("LLM warning:")
                && $0.content.contains("My warning message")
        })
    }

    // MARK: - completeStepFailure Tests

    func testCompleteStepFailureClearsStreamingPreview() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, taskID: task.id, errorMessage: "Test error")

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCompleteStepFailureWritesReport() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, taskID: task.id, errorMessage: "Test error")
    }

    func testCompleteStepFailureSetsFailedStatus() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, taskID: task.id, errorMessage: "Critical error")

        if let updatedTask = mockDelegate.taskToMutate {
            XCTAssertEqual(updatedTask.runs[0].steps[0].status, .failed)
        }
    }

    func testCompleteStepFailureAddsErrorMessage() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, taskID: task.id, errorMessage: "Network timeout")

        if let updatedTask = mockDelegate.taskToMutate {
            let step = updatedTask.runs[0].steps[0]
            let hasErrorMessage = step.messages.contains { msg in
                msg.content.contains("Network timeout")
            }
            XCTAssertTrue(hasErrorMessage)
        }
    }

    // MARK: - clearRunningTask Tests

    func testClearRunningTaskRemovesEntry() {
        let stepID = "test_step"

        service.clearRunningTask(stepID: stepID, taskID: 0)

        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: 0))
    }

    func testClearRunningTaskClearsPerStepState() {
        let stepID = "test_step"

        // Seed a per-step state entry through a live field (`activeModelKey`).
        service._testSetActiveModel(stepID: stepID, taskID: 0, base: "http://x", model: "m")
        XCTAssertFalse(service.activeModelKeys().isEmpty)

        // Clear running task should also drop the per-step state entry.
        service.clearRunningTask(stepID: stepID, taskID: 0)

        XCTAssertTrue(service.activeModelKeys().isEmpty)
    }

    // MARK: - Team Member Validation Tests

    func testConsultationValidationRejectsNonTeamMemberWithAvailableList() {
        let settings = TeamSettings(
            invitableRoles: [Role.builtInID(.softwareEngineer), Role.builtInID(.uxDesigner)],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [Role.builtInID(.softwareEngineer), Role.builtInID(.uxDesigner)],
            settings: settings
        )

        let error = service._testConsultationValidationError(
            consultedRoleID: Role.builtInID(.sre),
            requestingRoleID: Role.builtInID(.softwareEngineer),
            team: team,
            teamSettings: settings
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("not a member of this team") == true)
        XCTAssertTrue(error?.contains("Available teammates:") == true)
        // availableTeammatesList returns systemRoleID (e.g., "uxDesigner") for LLM consumption
        XCTAssertTrue(error?.contains("uxDesigner") == true)
    }

    func testConsultationValidationRejectsSupervisorWhenNotInvitable() {
        let settings = TeamSettings(
            invitableRoles: [Role.builtInID(.softwareEngineer), Role.builtInID(.supervisor)],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [Role.builtInID(.softwareEngineer), Role.builtInID(.supervisor)],
            settings: settings
        )

        let error = service._testConsultationValidationError(
            consultedRoleID: Role.builtInID(.supervisor),
            requestingRoleID: Role.builtInID(.softwareEngineer),
            team: team,
            teamSettings: settings
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("Supervisor cannot be consulted") == true)
        XCTAssertTrue(error?.contains("Available teammates: none") == true)
    }

    func testConsultationValidationRejectsSelfConsultation() {
        let settings = TeamSettings(
            invitableRoles: [],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [Role.builtInID(.softwareEngineer), Role.builtInID(.uxDesigner)],
            settings: settings
        )

        let error = service._testConsultationValidationError(
            consultedRoleID: Role.builtInID(.softwareEngineer),
            requestingRoleID: Role.builtInID(.softwareEngineer),
            team: team,
            teamSettings: settings
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("cannot ask yourself") == true)
    }

    func testConsultationValidationRejectsRoleOutsideInvitableRoles() {
        let settings = TeamSettings(
            invitableRoles: [Role.builtInID(.softwareEngineer)],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [Role.builtInID(.softwareEngineer), Role.builtInID(.uxDesigner)],
            settings: settings
        )

        let error = service._testConsultationValidationError(
            consultedRoleID: Role.builtInID(.uxDesigner),
            requestingRoleID: Role.builtInID(.softwareEngineer),
            team: team,
            teamSettings: settings
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("not available for consultation") == true)
    }

    func testMeetingFilteringFiltersInvalidParticipants() {
        let settings = TeamSettings(
            invitableRoles: [Role.builtInID(.uxDesigner)],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [
                Role.builtInID(.softwareEngineer),
                Role.builtInID(.uxDesigner),
                Role.builtInID(.tpm),
                Role.builtInID(.supervisor),
            ],
            settings: settings
        )

        let filtered = MeetingParticipantResolver.filterParticipants(
            participantIDs: [
                Role.builtInID(.softwareEngineer),  // self
                Role.builtInID(.uxDesigner),        // valid
                Role.builtInID(.sre),               // not a team member
                Role.builtInID(.supervisor),               // Supervisor blocked
                Role.builtInID(.tpm),               // not in invitable roles
            ],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: settings
        )

        XCTAssertEqual(filtered.participants.map(\.baseID), [Role.builtInID(.uxDesigner)])
        XCTAssertTrue(filtered.rejectedReasons.contains(where: { $0.contains("you — the initiator") }))
        XCTAssertTrue(filtered.rejectedReasons.contains(where: { $0.contains("not a team member") }))
        XCTAssertTrue(filtered.rejectedReasons.contains(where: { $0.contains("Supervisor not invitable") }))
        XCTAssertTrue(filtered.rejectedReasons.contains(where: { $0.contains("not in invitable roles") }))
    }

    func testMeetingFilteringAllInvalidParticipantsLeavesEmptyList() {
        let settings = TeamSettings(
            invitableRoles: [Role.builtInID(.uxDesigner)],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [Role.builtInID(.softwareEngineer), Role.builtInID(.uxDesigner)],
            settings: settings
        )

        let filtered = MeetingParticipantResolver.filterParticipants(
            participantIDs: [
                Role.builtInID(.softwareEngineer),  // self
                Role.builtInID(.supervisor),               // not a team member + Supervisor blocked
                Role.builtInID(.sre),               // not a team member
            ],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: settings
        )

        XCTAssertTrue(filtered.participants.isEmpty)
        XCTAssertFalse(filtered.rejectedReasons.isEmpty)

        let available = MeetingParticipantResolver.availableTeammatesList(
            team: team,
            teamSettings: settings,
            excludeRoleID: Role.builtInID(.softwareEngineer)
        )
        // availableTeammatesList returns systemRoleID for LLM consumption
        XCTAssertEqual(available, "uxDesigner")
    }

    func testMeetingFilteringEmptyInvitableRolesMeansNoRestriction() {
        let settings = TeamSettings(
            invitableRoles: [],
            supervisorCanBeInvited: false
        )
        let team = makeTestTeam(
            name: "Validation Team",
            roleIDs: [
                Role.builtInID(.softwareEngineer),
                Role.builtInID(.uxDesigner),
                Role.builtInID(.sre),
            ],
            settings: settings
        )

        let filtered = MeetingParticipantResolver.filterParticipants(
            participantIDs: [Role.builtInID(.uxDesigner), Role.builtInID(.sre)],
            initiatingRole: .softwareEngineer,
            team: team,
            teamSettings: settings
        )

        XCTAssertEqual(Set(filtered.participants.map(\.baseID)), Set([Role.builtInID(.uxDesigner), Role.builtInID(.sre)]))
        XCTAssertTrue(filtered.rejectedReasons.isEmpty)
    }

    // MARK: - Helpers

    private func createTestTaskWithStep() -> NTMSTask {
        let stepExecution = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Test Step",
            status: .running
        )

        let run = Run(
            id: 0,
            steps: [stepExecution]
        )

        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            runs: [run]
        )
        service._testRegisterStepTask(stepID: stepExecution.id, taskID: task.id)
        return task
    }
}

// MARK: - Tool Authorization Tests

@MainActor
final class ToolAuthorizationTests: XCTestCase {
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var toolRuntime: ToolRuntime!
    private var toolTracker: ToolCallTracker!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let nanoteamsDir = tempDir.appendingPathComponent(".nanoteams")
        try! FileManager.default.createDirectory(at: nanoteamsDir, withIntermediateDirectories: true)
        // Seed a `.git` directory so the new tool-unavailability classifier
        // doesn't reroute git_status / git_commit (used as the "unauthorized"
        // canary in the tests below) onto the precondition_failed branch.
        // These tests are about the authorization mechanism — the rejection
        // envelope shape — not about precondition classification, which is
        // covered by `ToolUnavailabilityClassifierTests` /
        // `ToolUnavailabilityWiringTests`.
        try! FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)

        let logURL = NTMSPaths(workFolderRoot: tempDir).toolCallsJSONL(taskID: 0, runID: 0)
        toolRuntime = ToolRuntime(
            registry: ToolRegistry(),
            logger: ToolCallLogger(logURL: logURL)
        )
        toolTracker = ToolCallTracker()
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        service = nil
        mockDelegate = nil
        toolRuntime = nil
        toolTracker = nil
        try await super.tearDown()
    }

    func testUnauthorizedToolCallReturnsError() async {
        let task = createTestTask()

        let unauthorizedCall = StepToolCall(
            providerID: "call_1",
            name: "git_status",
            argumentsJSON: "{}"
        )

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [unauthorizedCall],
            allowedToolNames: ["read_file", "write_file"],
            runtime: toolRuntime,
            tracker: toolTracker,
            task: task,
            runIndex: 0,
            roleID: "test_role")

        XCTAssertEqual(batch.count, 1)
        XCTAssertTrue(batch[0].isError)
        XCTAssertTrue(batch[0].outputJSON.contains("tool_not_authorized"))
        XCTAssertTrue(batch[0].outputJSON.contains("git_status"))
    }

    func testAuthorizedToolCallExecutesNormally() async {
        let task = createTestTask()

        let authorizedCall = StepToolCall(
            providerID: "call_1",
            name: "update_scratchpad",
            argumentsJSON: #"{"content":"test plan"}"#
        )

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [authorizedCall],
            allowedToolNames: ["update_scratchpad"],
            runtime: toolRuntime,
            tracker: toolTracker,
            task: task,
            runIndex: 0,
            roleID: "test_role")

        XCTAssertEqual(batch.count, 1)
        XCTAssertFalse(batch[0].outputJSON.contains("tool_not_authorized"))
    }

    func testMixOfAuthorizedAndUnauthorizedToolCalls() async {
        let task = createTestTask()

        let authorizedCall = StepToolCall(
            providerID: "call_1",
            name: "update_scratchpad",
            argumentsJSON: #"{"content":"plan"}"#
        )
        let unauthorizedCall = StepToolCall(
            providerID: "call_2",
            name: "git_commit",
            argumentsJSON: #"{"message":"test"}"#
        )

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [authorizedCall, unauthorizedCall],
            allowedToolNames: ["update_scratchpad"],
            runtime: toolRuntime,
            tracker: toolTracker,
            task: task,
            runIndex: 0,
            roleID: "test_role")

        XCTAssertEqual(batch.count, 2)
        XCTAssertFalse(batch[0].outputJSON.contains("tool_not_authorized"))
        XCTAssertTrue(batch[1].isError)
        XCTAssertTrue(batch[1].outputJSON.contains("tool_not_authorized"))
        XCTAssertTrue(batch[1].outputJSON.contains("git_commit"))
    }

    private func createTestTask() -> NTMSTask {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Test Step", status: .running)
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: 0, title: "Test Task", supervisorTask: "Test goal", runs: [run])
    }
}

// MARK: - Streaming Harmony Marker Tests

/// Tests that harmony marker content (tool call JSON) is stripped from assistant content
/// during streaming, preventing `{"` from appearing in the activity feed.
@MainActor
final class LLMExecutionServiceStreamingHarmonyTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []
        /// When set, the stream throws this error AFTER yielding all `deltas`
        /// — simulates a cancellation / transport failure mid-generation.
        var finishError: Error?

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            let error = finishError
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish(throwing: error)
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        // Register the (taskID, stepID) execution state in the TaskStepKey-keyed registry
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        mockClient = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Harmony marker and JSON in a single delta — JSON must not leak into assistantContent.
    func testHarmonyMarker_singleDelta_stripsJSON() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Hello!"),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{\"question\":\"Hi\"}}<|end|>")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Hello!")
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertFalse(result.assistantContent.contains("{"))
    }

    /// Marker and JSON arrive as separate deltas.
    func testHarmonyMarker_separateDeltas_stripsJSON() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Hi "),
            StreamEvent(contentDelta: "<|call|>"),
            StreamEvent(contentDelta: "{\"name\":\"ask_supervisor\"}")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Hi ")
        XCTAssertTrue(result.sawHarmonyMarker)
    }

    /// No content before marker — assistantContent should be empty.
    func testHarmonyMarker_noContentBeforeMarker_emptyResult() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertTrue(result.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(result.sawHarmonyMarker)
    }

    /// Channel marker variant also strips JSON.
    func testChannelMarker_stripsJSON() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Sure."),
            StreamEvent(contentDelta: "<|channel|>commentary to=ask_supervisor <|constrain|>json<|message|>{\"question\":\"Hi\"}")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Sure.")
        XCTAssertTrue(result.sawHarmonyMarker)
    }

    /// Start-function marker variant also strips JSON.
    func testStartFunctionMarker_stripsJSON() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Working."),
            StreamEvent(contentDelta: "<|start|>functions.ask_supervisor{\"question\":\"Hi\"}")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Working.")
        XCTAssertTrue(result.sawHarmonyMarker)
    }

    /// Committed content (sent to delegate) must not contain marker JSON.
    func testHarmonyMarker_commitContentIsClean() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Response text."),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{\"question\":\"q\"}}<|end|>")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        // commitStreaming is called with cleaned content
        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        let committedContent = mockDelegate.commitStreamingCalls[0].2
        XCTAssertEqual(committedContent, "Response text.")
        XCTAssertFalse(committedContent.contains("{"))
    }

    /// Streaming preview (appendStreamingPreview) must not receive marker JSON.
    func testHarmonyMarker_streamingPreviewIsClean() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Hello"),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"tool\"}")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        // All preview content appended should be clean
        let allPreviewContent = mockDelegate.appendStreamingPreviewCalls.map { $0.3 }.joined()
        XCTAssertFalse(allPreviewContent.contains("{\"name"))
    }

    /// harmonyBuffer preserves full content (including marker) for tool call parsing.
    func testHarmonyMarker_harmonyBufferPreservedForParsing() async throws {
        let toolCallJSON = "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{\"question\":\"Hi\"}}<|end|>"
        mockClient.deltas = [
            StreamEvent(contentDelta: "Text."),
            StreamEvent(contentDelta: toolCallJSON)
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertTrue(result.harmonyBuffer.contains("<|call|>"))
        XCTAssertTrue(result.harmonyBuffer.contains("ask_supervisor"))
    }

    /// Marker split across flush boundary — partial marker flushed in one batch,
    /// rest arrives in next delta. uiBuffer-based truncation must handle this.
    func testHarmonyMarker_splitAcrossFlushBoundary_stripsJSON() async throws {
        // Send a large delta (>200 chars to exceed uiFlushCharThreshold) ending with partial marker
        let longPrefix = String(repeating: "A", count: 210) + "<|ca"
        mockClient.deltas = [
            StreamEvent(contentDelta: longPrefix),
            StreamEvent(contentDelta: "ll|>{\"name\":\"ask_supervisor\"}<|end|>")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        // assistantContent must not contain the partial marker or JSON
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertFalse(result.assistantContent.contains("<|ca"))
        XCTAssertFalse(result.assistantContent.contains("{"))
        XCTAssertEqual(result.assistantContent.count, 210)

        // Envelope-as-thinking pipe across the split: the flip iteration must
        // slice from `uiBuffer` (NOT the current delta), or the `<|ca` held
        // from the prior delta would be dropped from the thinking preview.
        // Exactly-once guards against double-piping (slice + raw delta).
        let thinkingFed = mockDelegate.appendStreamingThinkingCalls.map(\.1).joined()
        let envelope = "<|call|>{\"name\":\"ask_supervisor\"}<|end|>"
        XCTAssertTrue(thinkingFed.contains(envelope),
                      "Complete envelope (incl. the pre-detection partial marker) must reach the thinking preview — got: \(thinkingFed)")
        XCTAssertEqual(thinkingFed.components(separatedBy: envelope).count - 1, 1,
                       "Envelope must be piped exactly once — a second occurrence means the flip slice and the raw delta double-piped")
    }

    /// Content and marker mixed in a single delta.
    func testHarmonyMarker_mixedContentAndMarkerInSingleDelta() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Here is my answer.<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Here is my answer.")
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertFalse(result.assistantContent.contains("{"))
    }

    // MARK: - Preview Rewind (regression for stray `<` in activity feed)

    /// When a large first delta flushes a partial marker prefix to the UI
    /// preview (`<`, `<|`, etc.) and the completing bytes arrive in the next
    /// delta, the marker branch must rewind the preview to the pre-marker
    /// text via `replaceStreamingPreview` — otherwise the fragment lingers on
    /// screen until the next commit (observed: Personal Assistant bubble
    /// stuck displaying `<`).
    func testHarmonyMarker_rewindsStreamingPreview_whenSplitAcrossDeltas() async throws {
        let longPrefix = String(repeating: "A", count: 210) + "<|ca"
        mockClient.deltas = [
            StreamEvent(contentDelta: longPrefix),
            StreamEvent(contentDelta: "ll|>{\"name\":\"ask_supervisor\"}<|end|>")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        // The marker branch must issue exactly one rewind with the pre-marker text.
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        let rewound = mockDelegate.replaceStreamingPreviewCalls[0].3
        XCTAssertEqual(rewound, String(repeating: "A", count: 210))
        XCTAssertFalse(rewound.contains("<"))
    }

    /// Channel marker split across deltas — same rewind must happen.
    func testChannelMarker_rewindsStreamingPreview_whenSplitAcrossDeltas() async throws {
        // Leading content long enough to force a flush, ending with a partial
        // channel marker prefix that is not a complete `<|...|>` token.
        let longPrefix = String(repeating: "B", count: 210) + "<|chan"
        mockClient.deltas = [
            StreamEvent(contentDelta: longPrefix),
            StreamEvent(contentDelta: "nel|>commentary to=ask_supervisor<|message|>{\"question\":\"Hi\"}")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        let rewound = mockDelegate.replaceStreamingPreviewCalls[0].3
        XCTAssertEqual(rewound, String(repeating: "B", count: 210))
    }

    /// Marker at the very beginning of the first delta — rewind to empty string
    /// so the preview doesn't even briefly materialize any of the tool-call
    /// envelope. The single-delta zero-preamble shape exercises the
    /// `content.isEmpty` guard in `StreamingPreviewManager.replaceContent`.
    func testHarmonyMarker_rewindsStreamingPreview_toEmpty_whenMarkerAtStart() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        // Rewind must be called once with empty content (marker at position 0).
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.count, 1)
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls[0].3, "")
    }

    // MARK: - Corner cases: envelope-as-thinking pipe + streamingToolCall flag

    /// Joined thinking-pipe text — shared accessor for the corner pins below.
    private var thinkingFed: String {
        mockDelegate.appendStreamingThinkingCalls.map(\.1).joined()
    }

    /// Marker at position 0, no preamble at all (envelope-only turn): the
    /// FULL envelope must reach the thinking preview, content stays empty,
    /// and the flag fires — the bubble's only live surface is the
    /// animated Thinking row.
    func testMarkerAtStart_envelopeOnly_fullEnvelopePipedToThinking_flagSet() async throws {
        let envelope = "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>"
        mockClient.deltas = [StreamEvent(contentDelta: envelope)]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertTrue(result.assistantContent.isEmpty)
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertGreaterThanOrEqual(mockDelegate.markStreamingToolCallCalls.count, 1)
        XCTAssertTrue(thinkingFed.contains(envelope),
                      "Zero-preamble envelope must be piped whole into the thinking preview — got: \(thinkingFed)")
    }

    /// Flag breadth: the `<|channel|>` marker variant (not just `<|call|>`)
    /// must set the tool-call flag and pipe the envelope to thinking — the
    /// flag fires on ANY harmony marker, same granularity as
    /// `sawHarmonyMarker` itself.
    func testChannelMarker_setsToolCallFlag_andPipesEnvelopeToThinking() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Sure."),
            StreamEvent(contentDelta: "<|channel|>commentary to=ask_supervisor <|constrain|>json<|message|>{\"question\":\"Hi\"}")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertGreaterThanOrEqual(mockDelegate.markStreamingToolCallCalls.count, 1,
                                     "<|channel|> envelopes must fire the flag too")
        XCTAssertTrue(thinkingFed.contains("<|channel|>commentary"),
                      "Channel-variant envelope must stream into the thinking preview")
    }

    /// Text AFTER `<|end|>` (a model continuing prose past its tool call)
    /// belongs to the envelope side of the split: it must stay out of
    /// `assistantContent` (frozen at the pre-marker prose) and surface in
    /// the thinking preview instead — streamed text never just vanishes.
    func testPostEnvelopeProse_staysOutOfContent_reachesThinkingPreview() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Here is my answer."),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>"),
            StreamEvent(contentDelta: "And one more consideration."),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Here is my answer.",
                       "Content freezes at the marker — post-envelope prose must not reappear in the bubble text")
        XCTAssertTrue(thinkingFed.contains("And one more consideration."),
                      "Post-envelope prose lands in the harmony buffer and must surface via the thinking pipe")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
    }

    /// Two DISTINCT tool calls in one stream: both must resolve (the dedup
    /// break fires only on identical signatures) and both envelopes must
    /// stream into the thinking preview.
    func testTwoDistinctToolCalls_bothResolved_bothPipedToThinking() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.swift\"}}<|end|>"),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"b.swift\"}}<|end|>"),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(result.resolvedToolCalls.count, 2,
                       "Distinct calls must not trip the duplicate-signature loop break")
        XCTAssertTrue(thinkingFed.contains("a.swift"))
        XCTAssertTrue(thinkingFed.contains("b.swift"))
    }

    /// qwen-style reasoning-channel envelope (`<|call|>` inside
    /// `reasoning.delta`, NOT content): the call resolves via the
    /// post-stream thinking scan, the tool-call flag is NOT set (content
    /// channel never saw a marker — documented asymmetry), and the UX is
    /// still covered: the envelope streamed through the NORMAL thinking
    /// path, so the Thinking row was live the whole time (no content →
    /// `isThinkingStreaming` true without the flag).
    func testReasoningChannelEnvelope_resolvesCall_withoutToolCallFlag() async throws {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "I should ask the supervisor. "),
            StreamEvent(thinkingDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{\"question\":\"Hi\"}}<|end|>"),
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertFalse(result.sawHarmonyMarker, "Marker lived in the reasoning channel only")
        XCTAssertEqual(result.resolvedToolCalls.count, 1,
                       "Reasoning-channel fallback must still extract the call")
        XCTAssertTrue(mockDelegate.markStreamingToolCallCalls.isEmpty,
                      "Flag is a content-channel/toolCallDeltas signal — reasoning-channel envelopes are already visible via the normal thinking stream")
        XCTAssertTrue(thinkingFed.contains("<|call|>"),
                      "Envelope streamed through the regular thinking path — the Thinking row was the live indicator")
    }

    /// Cancellation mid-envelope: the partial commit must carry the frozen
    /// pre-marker prose and NO thinking (envelope text is preview-only on
    /// every exit path, not just clean stream end).
    func testCancellationMidEnvelope_commitsProse_thinkingNotPersisted() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Let me fix that."),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"edit_file\",\"arguments\":{\"path\":\"x.swift\","),
        ]
        mockClient.finishError = CancellationError()

        do {
            _ = try await service.performStreamingCall(
                stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
                client: mockClient, config: LLMConfig(),
                tools: [], conversationMessages: [],
                networkLogger: nil
            )
            XCTFail("Expected CancellationError to rethrow")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1,
                       "Cancellation must still commit the partial turn")
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].2, "Let me fix that.",
                       "Committed content is the frozen pre-marker prose")
        XCTAssertNil(mockDelegate.commitStreamingCalls[0].3,
                     "Partial envelope must not be persisted as thinking on the cancel path")
        XCTAssertTrue(thinkingFed.contains("edit_file"),
                      "The partial envelope WAS visible live via the thinking pipe before the cancel")
    }

    /// Whitespace-only `thinkingDelta` (e.g. an empty `[reasoning]\n\n[/reasoning]`
    /// block emitted by some models) must commit as `nil`, not a lone `\n` —
    /// otherwise the UI shows a Thinking disclosure that expands to nothing.
    func testWhitespaceOnlyThinking_commitsAsNil() async throws {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: "\n"),
            StreamEvent(thinkingDelta: "\n\n"),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertNil(mockDelegate.commitStreamingCalls[0].3,
                     "Whitespace-only thinking must be dropped, not persisted")
    }

    /// Real (non-whitespace) thinking must be preserved verbatim, including
    /// leading/trailing newlines inside the reasoning body.
    func testNonWhitespaceThinking_commitsPreservingFormatting() async throws {
        let reasoning = "\nThe user wants a poem.\n"
        mockClient.deltas = [
            StreamEvent(thinkingDelta: reasoning),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        XCTAssertEqual(mockDelegate.commitStreamingCalls.count, 1)
        XCTAssertEqual(mockDelegate.commitStreamingCalls[0].3, reasoning)
    }

    /// Commit must also be clean — the preview ends up empty-or-prefix after
    /// rewind, and the final commit replaces that with the trimmed accumulated
    /// pre-marker content. This pins the contract that the three buffers
    /// (local accumulator, pending UI, live preview) stay in sync.
    func testHarmonyMarker_commitAndRewindAgree() async throws {
        let longPrefix = String(repeating: "X", count: 210) + "<"
        mockClient.deltas = [
            StreamEvent(contentDelta: longPrefix),
            StreamEvent(contentDelta: "|call|>{\"name\":\"ask_supervisor\"}<|end|>")
        ]

        _ = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [],
            networkLogger: nil
        )

        let expected = String(repeating: "X", count: 210)
        XCTAssertEqual(mockDelegate.replaceStreamingPreviewCalls.last?.3, expected)
        XCTAssertEqual(mockDelegate.commitStreamingCalls.last?.2, expected)
    }
}

// MARK: - setNeedsSupervisorInput Backstop Hook Tests

/// Pins the new `LLMStateDelegate.notifyQueuedMessageBackstop` hook fired from
/// `LLMExecutionService.setNeedsSupervisorInput`. The hook closes a stranded-queue
/// gap when a parallel role (CLAUDE.md §45) lands a Supervisor question while the
/// engine is already `.needsSupervisorInput` (held there by another role): the
/// same-state re-entry guard in `TeamEngine.transition(to:)` (CLAUDE.md §39)
/// suppresses `onStateChanged`, so the SwiftUI `onChange(of: taskEngineStates)`
/// in `MainLayoutView.handleEngineStateChanged` doesn't fire, and the backstop
/// drain never runs. The hook fires the drain directly from the mutation side.
///
/// Eligibility gate is `mutated && didApply` (matches the method's return value):
/// the hook MUST NOT fire on closure short-circuits per CLAUDE.md §7.
@MainActor
final class SetNeedsSupervisorInputBackstopTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        mockDelegate = nil
        try await super.tearDown()
    }

    /// Happy path: step exists in the task, mutateTask persists, closure applies the
    /// question. The hook MUST fire with the correct taskID exactly once.
    func testSetNeedsSupervisorInput_firesBackstop_onMutationSuccess() async {
        let step = StepExecution(
            id: "test_step", role: .softwareEngineer, title: "Test", status: .running
        )
        let task = NTMSTask(
            id: 42, title: "T", supervisorTask: "G", runs: [Run(id: 0, steps: [step])]
        )
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: step.id, taskID: task.id)

        let success = await service.setNeedsSupervisorInput(
            stepID: step.id, taskID: task.id, question: "Confirm?"
        )

        XCTAssertTrue(success)
        XCTAssertEqual(
            mockDelegate.notifyQueuedMessageBackstopCalls, [42],
            "Hook must fire with the correct taskID on mutation success"
        )
    }

    /// `mutateTask` returns false: stepID is registered but `taskToMutate` is nil so
    /// the mock can't find the task. The hook MUST NOT fire.
    func testSetNeedsSupervisorInput_skipsBackstop_whenMutateTaskReturnsFalse() async {
        // taskToMutate intentionally nil.
        service._testRegisterStepTask(stepID: "ghost_step", taskID: 99)

        let success = await service.setNeedsSupervisorInput(
            stepID: "ghost_step", taskID: 99, question: "Q?"
        )

        XCTAssertFalse(success)
        XCTAssertTrue(
            mockDelegate.notifyQueuedMessageBackstopCalls.isEmpty,
            "Hook must NOT fire when mutateTask returns false"
        )
    }

    /// `mutateTask` persists (returns true) but the closure short-circuits because
    /// the stepID doesn't exist in the task's latest run — `didApply` stays false.
    /// Per CLAUDE.md §7, `mutateTask`'s `Bool` alone doesn't prove the closure did
    /// anything; the eligibility gate must combine both flags. The hook MUST NOT fire.
    func testSetNeedsSupervisorInput_skipsBackstop_whenClosureShortCircuits() async {
        let existingStep = StepExecution(
            id: "existing_step", role: .softwareEngineer, title: "T", status: .running
        )
        let task = NTMSTask(
            id: 42, title: "T", supervisorTask: "G", runs: [Run(id: 0, steps: [existingStep])]
        )
        mockDelegate.taskToMutate = task
        // Register a stepID that does NOT exist in the task's run.
        service._testRegisterStepTask(stepID: "wrong_step", taskID: task.id)

        let success = await service.setNeedsSupervisorInput(
            stepID: "wrong_step", taskID: task.id, question: "Q?"
        )

        XCTAssertFalse(success, "Eligibility gate (mutated && didApply) must fail")
        XCTAssertTrue(
            mockDelegate.notifyQueuedMessageBackstopCalls.isEmpty,
            "Hook must NOT fire on closure short-circuit (CLAUDE.md \"`mutateTask` returning `true` means \"persisted\", NOT \"the closure did something\"\")"
        )
    }

    /// Unknown task: `taskID` is now an explicit parameter (the pre-refactor
    /// `taskIDForStep` registry lookup is gone), so a step that was never
    /// registered surfaces as a `mutateTask` miss — the mock can't resolve the
    /// task, the mutation doesn't apply, and the hook MUST NOT fire.
    ///
    /// Catches "hook fires on every invocation regardless of whether the
    /// mutation even started".
    func testSetNeedsSupervisorInput_skipsBackstop_whenStepIDUnregistered() async {
        // No (taskID, stepID) execution registered → the `isExecutionLive` barrier
        // short-circuits BEFORE any mutation is attempted. This is the post-teardown
        // write barrier: an orphaned call must not flip a closed/paused task back to
        // `.needsSupervisorInput`, and must not fire the auto-resuming backstop.
        let success = await service.setNeedsSupervisorInput(
            stepID: "unknown_step", taskID: 0, question: "Q?"
        )

        XCTAssertFalse(success, "Unregistered (taskID, stepID) must reject the mutation")
        XCTAssertTrue(
            mockDelegate.notifyQueuedMessageBackstopCalls.isEmpty,
            "Hook must NOT fire when the execution is not live"
        )
        XCTAssertTrue(
            mockDelegate.eventLog.isEmpty,
            "The liveness barrier must drop the write before mutateTask is even attempted"
        )
    }

    /// Ordering invariant: hook MUST fire AFTER `mutateTask` completes
    /// (`mutate-end` event), never during the closure (`mutate-begin` event).
    /// Pins the call sequence so a refactor that pulls the backstop fire INSIDE
    /// the `mutateTask { task in ... }` closure cannot pass — even though all
    /// three eligibility-gate tests would still go green (the mock just records
    /// the call regardless of when it lands).
    ///
    /// The drain reads engine state and step state via the store; the step
    /// mutation MUST have persisted by the time the hook fires, otherwise the
    /// backstop reads stale state and may misclassify the task's engine state.
    func testSetNeedsSupervisorInput_firesBackstop_afterMutationCompletes() async {
        let step = StepExecution(
            id: "test_step", role: .softwareEngineer, title: "Test", status: .running
        )
        let task = NTMSTask(
            id: 77, title: "T", supervisorTask: "G", runs: [Run(id: 0, steps: [step])]
        )
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: step.id, taskID: task.id)

        _ = await service.setNeedsSupervisorInput(
            stepID: step.id, taskID: task.id, question: "Q?"
        )

        XCTAssertEqual(
            mockDelegate.eventLog,
            ["mutate-begin:77", "mutate-end:77", "backstop:77"],
            "Hook must fire strictly after mutateTask returns — refactor pulling it inside the closure must fail this test"
        )
    }

    /// Multi-call behavior: N consecutive calls must produce N independent hook
    /// fires, each correctly paired with its own mutation. Catches:
    ///   - hook accidentally moved out of the `if success` branch (would fire on
    ///     misses too, breaking the per-call invariant)
    ///   - any future batching / deduplication mechanism that coalesces hooks
    ///   - hook firing only once per process / cached "already-fired" flag
    func testSetNeedsSupervisorInput_consecutiveCalls_fireHookOncePerCall() async {
        let step = StepExecution(
            id: "test_step", role: .softwareEngineer, title: "Test", status: .running
        )
        let task = NTMSTask(
            id: 42, title: "T", supervisorTask: "G", runs: [Run(id: 0, steps: [step])]
        )
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: step.id, taskID: task.id)

        // Three consecutive Q&A rounds for the same step. After each answer the
        // production engine flips `needsSupervisorInput=false`; the LLM then
        // asks again, landing back at `setNeedsSupervisorInput`. The mock
        // doesn't model the engine, but the call surface is the same.
        for _ in 1...3 {
            let success = await service.setNeedsSupervisorInput(
                stepID: step.id, taskID: task.id, question: "Q?"
            )
            XCTAssertTrue(success)
        }

        XCTAssertEqual(
            mockDelegate.notifyQueuedMessageBackstopCalls, [42, 42, 42],
            "Hook must fire exactly once per call — no deduplication, no batching"
        )
        XCTAssertEqual(
            mockDelegate.eventLog,
            [
                "mutate-begin:42", "mutate-end:42", "backstop:42",
                "mutate-begin:42", "mutate-end:42", "backstop:42",
                "mutate-begin:42", "mutate-end:42", "backstop:42",
            ],
            "Per-call ordering invariant must hold across multiple invocations"
        )
    }

    /// Parallel-roles scenario at the unit level: two distinct steps on the
    /// SAME task each call `setNeedsSupervisorInput`. Each call must fire its
    /// own hook — this is exactly the production case the new hook is designed
    /// for (parallel roles per CLAUDE.md "`TeamEngine` runs ready roles in
    /// parallel, not serially"). The hook fires with the SAME taskID both
    /// times — the integration test in `QuickCaptureBackstopBatchTests` pins
    /// what happens downstream when both stepIDs are in the waiting set.
    func testSetNeedsSupervisorInput_twoStepsOnSameTask_eachFiresOwnHook() async {
        let stepA = StepExecution(
            id: "step_a", role: .softwareEngineer, title: "A", status: .running
        )
        let stepB = StepExecution(
            id: "step_b", role: .softwareEngineer, title: "B", status: .running
        )
        let task = NTMSTask(
            id: 99, title: "T", supervisorTask: "G",
            runs: [Run(id: 0, steps: [stepA, stepB])]
        )
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepA.id, taskID: task.id)
        service._testRegisterStepTask(stepID: stepB.id, taskID: task.id)

        // Role A asks first.
        let successA = await service.setNeedsSupervisorInput(
            stepID: stepA.id, taskID: task.id, question: "From A"
        )
        // Role B asks second — engine state would be unchanged in production
        // (already `.needsSupervisorInput` because of A), but the hook still
        // fires from the mutation side. This is the bug condition.
        let successB = await service.setNeedsSupervisorInput(
            stepID: stepB.id, taskID: task.id, question: "From B"
        )

        XCTAssertTrue(successA)
        XCTAssertTrue(successB)
        XCTAssertEqual(
            mockDelegate.notifyQueuedMessageBackstopCalls, [99, 99],
            "Both steps on the same task must each fire the hook with that taskID"
        )

        // Verify both step mutations actually landed (defends against a bug
        // where second `setNeedsSupervisorInput` finds A already there and
        // overwrites instead of independently mutating B).
        let mutatedTask = mockDelegate.taskToMutate!
        let mutatedStepA = mutatedTask.runs[0].steps.first { $0.id == "step_a" }
        let mutatedStepB = mutatedTask.runs[0].steps.first { $0.id == "step_b" }
        XCTAssertEqual(mutatedStepA?.status, .needsSupervisorInput)
        XCTAssertEqual(mutatedStepA?.supervisorQuestion, "From A")
        XCTAssertEqual(mutatedStepB?.status, .needsSupervisorInput)
        XCTAssertEqual(mutatedStepB?.supervisorQuestion, "From B")
    }
}
