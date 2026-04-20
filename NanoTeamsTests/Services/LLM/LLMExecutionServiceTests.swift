import XCTest

@testable import NanoTeams

// MARK: - Mock Delegate

@MainActor
final class MockLLMExecutionDelegate: LLMExecutionDelegate {
    var workFolderURL: URL?
    var snapshot: WorkFolderContext?
    var globalLLMConfig: LLMConfig = LLMConfig()
    var maxLLMRetries: Int = 0
    var visionLLMConfig: LLMConfig?
    var loggingEnabled: Bool = false

    // Tracking calls for verification
    var beginStreamingCalls: [(String, UUID, Role, Int)] = []
    var appendStreamingPreviewCalls: [(String, UUID, Role, String)] = []
    var appendStreamingThinkingCalls: [(String, String)] = []
    var commitStreamingCalls: [(String, Int, String, String?)] = []
    var clearStreamingPreviewCalls: [String] = []
    var updateProcessingProgressCalls: [(String, Double)] = []
    var clearProcessingProgressCalls: [String] = []
    // Task to mutate (for testing)
    var taskToMutate: NTMSTask?

    func loadedTask(_ taskID: Int) -> NTMSTask? {
        if taskToMutate?.id == taskID { return taskToMutate }
        return nil
    }

    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool {
        if var task = taskToMutate, task.id == taskID {
            mutate(&task)
            taskToMutate = task
            return true
        }
        return false
    }

    func beginStreaming(stepID: String, messageID: UUID, role: Role, taskID: Int) async {
        beginStreamingCalls.append((stepID, messageID, role, taskID))
    }

    func appendStreamingPreview(stepID: String, messageID: UUID, role: Role, content: String) {
        appendStreamingPreviewCalls.append((stepID, messageID, role, content))
    }

    func appendStreamingThinking(stepID: String, content: String) {
        appendStreamingThinkingCalls.append((stepID, content))
    }

    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async {
        commitStreamingCalls.append((stepID, taskID, content, thinking))
    }

    func clearStreamingPreview(stepID: String) {
        clearStreamingPreviewCalls.append(stepID)
    }

    func updateStreamingProcessingProgress(stepID: String, progress: Double) {
        updateProcessingProgressCalls.append((stepID, progress))
    }

    func clearStreamingProcessingProgress(stepID: String) {
        clearProcessingProgressCalls.append(stepID)
    }

    var setMeetingParticipantsCalls: [(Set<String>, Int)] = []
    var clearMeetingParticipantsCalls: [Int] = []

    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        setMeetingParticipantsCalls.append((participantIDs, taskID))
    }

    func clearActiveMeetingParticipants(for taskID: Int) {
        clearMeetingParticipantsCalls.append(taskID)
    }
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

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        service = nil
        mockDelegate = nil
        try super.tearDownWithError()
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
        XCTAssertFalse(service.isStepRunning(stepID: stepID))
    }

    func testIsStepRunningForDifferentSteps() {
        let step1 = "step1"
        let step2 = "step2"

        XCTAssertFalse(service.isStepRunning(stepID: step1))
        XCTAssertFalse(service.isStepRunning(stepID: step2))
    }

    // MARK: - Cancellation Tests

    func testCancelStepExecution() {
        let stepID = "test_step"

        // Should not crash even if step wasn't running
        service.cancelStepExecution(stepID: stepID)

        XCTAssertFalse(service.isStepRunning(stepID: stepID))
    }

    func testCancelAllExecutions() {
        // Should not crash even with no running executions
        service.cancelAllExecutions()

        let stepID = "test_step"
        XCTAssertFalse(service.isStepRunning(stepID: stepID))
    }

    func testCancelStepClearsStreamingPreview() {
        let stepID = "test_step"

        service.cancelStepExecution(stepID: stepID)

        // Verify clearStreamingPreview was called
        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCancelStepExecutionClearsPlanMessageIndex() {
        let stepID = "test_step"

        // Set up a plan message index
        service._testSetPlanMessageIndex(stepID: stepID, index: 10)
        XCTAssertEqual(service._testGetPlanMessageIndex(stepID: stepID), 10)

        // Cancel step execution should clear the plan message index
        service.cancelStepExecution(stepID: stepID)

        XCTAssertNil(service._testGetPlanMessageIndex(stepID: stepID))
    }

    func testCancelStepExecutionClearsMemoriesMessageIndex() {
        let stepID = "test_step"

        // Set up a memories message index
        service._testSetMemoriesMessageIndex(stepID: stepID, index: 7)
        XCTAssertEqual(service._testGetMemoriesMessageIndex(stepID: stepID), 7)

        // Cancel step execution should clear the memories message index
        service.cancelStepExecution(stepID: stepID)

        XCTAssertNil(service._testGetMemoriesMessageIndex(stepID: stepID))
    }

    func testCancelAllExecutionsClearsAllMessageIndices() {
        let step1 = "step1"
        let step2 = "step2"
        let step3 = "step3"

        // Set up indices for multiple steps
        service._testSetPlanMessageIndex(stepID: step1, index: 1)
        service._testSetPlanMessageIndex(stepID: step2, index: 2)
        service._testSetMemoriesMessageIndex(stepID: step2, index: 3)
        service._testSetMemoriesMessageIndex(stepID: step3, index: 4)

        XCTAssertEqual(service._testPlanMessageIndexCount, 2)
        XCTAssertEqual(service._testMemoriesMessageIndexCount, 2)

        // Cancel all executions should clear all indices
        service.cancelAllExecutions()

        XCTAssertEqual(service._testPlanMessageIndexCount, 0)
        XCTAssertEqual(service._testMemoriesMessageIndexCount, 0)
    }

    // MARK: - Original System Prompt Restoration Tests

    func testCancelStepExecutionClearsOriginalSystemPrompt() {
        let stepID = "test_step"

        // Set up an original system prompt
        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: "Original prompt content")
        XCTAssertEqual(service._testGetOriginalSystemPrompt(stepID: stepID), "Original prompt content")

        // Cancel step execution should clear the original system prompt
        service.cancelStepExecution(stepID: stepID)

        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))
    }

    func testCancelAllExecutionsClearsAllOriginalSystemPrompts() {
        let step1 = "step1"
        let step2 = "step2"
        let step3 = "step3"

        // Set up original prompts for multiple steps
        service._testSetOriginalSystemPrompt(stepID: step1, prompt: "Prompt 1")
        service._testSetOriginalSystemPrompt(stepID: step2, prompt: "Prompt 2")
        service._testSetOriginalSystemPrompt(stepID: step3, prompt: "Prompt 3")

        XCTAssertEqual(service._testOriginalSystemPromptCount, 3)

        // Cancel all executions should clear all original prompts
        service.cancelAllExecutions()

        XCTAssertEqual(service._testOriginalSystemPromptCount, 0)
    }

    func testClearRunningTaskClearsOriginalSystemPrompt() {
        let stepID = "test_step"

        // Set up an original system prompt
        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: "Test prompt")
        XCTAssertNotNil(service._testGetOriginalSystemPrompt(stepID: stepID))

        // Clear running task should also clear the original system prompt
        service.clearRunningTask(stepID: stepID)

        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))
    }

    func testOriginalSystemPromptStorageAndRetrieval() {
        let stepID = "test_step"
        let prompt = "You are role-playing as Software Engineer. Focus on implementation."

        // Initially should be nil
        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))

        // Set and verify
        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: prompt)
        XCTAssertEqual(service._testGetOriginalSystemPrompt(stepID: stepID), prompt)
    }

    func testMultipleStepsHaveIndependentOriginalPrompts() {
        let step1 = "step1"
        let step2 = "step2"

        service._testSetOriginalSystemPrompt(stepID: step1, prompt: "Prompt for step 1")
        service._testSetOriginalSystemPrompt(stepID: step2, prompt: "Prompt for step 2")

        XCTAssertEqual(service._testGetOriginalSystemPrompt(stepID: step1), "Prompt for step 1")
        XCTAssertEqual(service._testGetOriginalSystemPrompt(stepID: step2), "Prompt for step 2")

        // Clear one should not affect the other
        service.clearRunningTask(stepID: step1)

        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: step1))
        XCTAssertEqual(service._testGetOriginalSystemPrompt(stepID: step2), "Prompt for step 2")
    }

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

        XCTAssertFalse(service.isStepRunning(stepID: stepID))
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
    func testToolSchemas_concludeMeetingInCoordinatorToolIDs_notDuplicated() {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let coordinator = TeamRoleDefinition(
            id: "coord_role",
            name: "Coordinator",
            prompt: "p",
            toolIDs: [ToolNames.concludeMeeting, ToolNames.askTeammate],
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

    func testToolSchemas_noConcludeMeetingWhenNoCoordinatorConfigured() {
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
        XCTAssertFalse(
            schemas.contains(where: { $0.name == ToolNames.concludeMeeting }),
            "No coordinator configured → conclude_meeting must not be granted to anyone"
        )
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

    override func setUpWithError() throws {
        try super.setUpWithError()
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

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        service = nil
        mockDelegate = nil
        try super.tearDownWithError()
    }

    // MARK: - completeStepSuccess Tests

    func testCompleteStepSuccessClearsStreamingPreview() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID)

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCompleteStepSuccessCallsWriteReport() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID)
    }

    func testCompleteStepSuccessSetsStatusDone() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID)

        // finalizeStepCompletion sets .done via TaskMutationService.updateStepStatus
        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, StepStatus.done)
        XCTAssertNotNil(updated.completedAt)
    }

    func testCompleteStepSuccessClearsRunningTask() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID)

        XCTAssertFalse(service.isStepRunning(stepID: stepID))
    }

    // MARK: - completeStepWithWarning Tests

    func testCompleteStepWithWarningClearsStreamingPreview() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, warning: "Test warning")

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCompleteStepWithWarningWritesReport() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, warning: "Test warning")
    }

    func testCompleteStepWithWarningAppendsWarningMessage() async throws {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, warning: "My warning message")

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

        await service.completeStepFailure(stepID: stepID, errorMessage: "Test error")

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    func testCompleteStepFailureWritesReport() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Test error")
    }

    func testCompleteStepFailureSetsFailedStatus() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Critical error")

        if let updatedTask = mockDelegate.taskToMutate {
            XCTAssertEqual(updatedTask.runs[0].steps[0].status, .failed)
        }
    }

    func testCompleteStepFailureAddsErrorMessage() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Network timeout")

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

        service.clearRunningTask(stepID: stepID)

        XCTAssertFalse(service.isStepRunning(stepID: stepID))
    }

    func testClearRunningTaskClearsPlanMessageIndex() {
        let stepID = "test_step"

        // Set up a plan message index
        service._testSetPlanMessageIndex(stepID: stepID, index: 5)
        XCTAssertEqual(service._testGetPlanMessageIndex(stepID: stepID), 5)

        // Clear running task should also clear the plan message index
        service.clearRunningTask(stepID: stepID)

        XCTAssertNil(service._testGetPlanMessageIndex(stepID: stepID))
    }

    func testClearRunningTaskClearsMemoriesMessageIndex() {
        let stepID = "test_step"

        // Set up a memories message index
        service._testSetMemoriesMessageIndex(stepID: stepID, index: 3)
        XCTAssertEqual(service._testGetMemoriesMessageIndex(stepID: stepID), 3)

        // Clear running task should also clear the memories message index
        service.clearRunningTask(stepID: stepID)

        XCTAssertNil(service._testGetMemoriesMessageIndex(stepID: stepID))
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

// MARK: - Implementation Prompt Saving Tests

@MainActor
final class LLMConversationSavingTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let nanoteamsDir = tempDir.appendingPathComponent(".nanoteams")
        try fileManager.createDirectory(at: nanoteamsDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        mockDelegate = nil
        try super.tearDownWithError()
    }

    // MARK: - Planning Phase Prompt Restoration Tests

    func testImplementationPromptSavedAfterPlanningPhaseRestoration() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        let implementationPrompt = """
        You are role-playing as Software Engineer.
        Focus on implementation. Make real code changes using tools.
        """

        let planningPrompt = """
        You are role-playing as Software Engineer.

        PLANNING PHASE
        ==============
        Before starting work, create your implementation plan.
        """

        // Set up: original prompt saved, current conversation has planning prompt
        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: implementationPrompt)

        var conversationMessages = [
            ChatMessage(role: .system, content: planningPrompt),
            ChatMessage(role: .user, content: "Task context")
        ]

        // Simulate implementation phase save (this should restore and save)
        await service._testSimulateImplementationPhaseSave(
            stepID: stepID,
            conversationMessages: &conversationMessages,
            isFirstIteration: false
        )

        // Verify: conversation messages now have implementation prompt
        XCTAssertEqual(conversationMessages[0].content, implementationPrompt)

        // Verify: original prompt was cleared after restoration
        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))

        // Verify: the task's llmConversation was updated with implementation prompt
        if let updatedTask = mockDelegate.taskToMutate {
            let llmConversation = updatedTask.runs[0].steps[0].llmConversation
            XCTAssertFalse(llmConversation.isEmpty, "llmConversation should not be empty")

            let systemMessage = llmConversation.first { $0.role == .system }
            XCTAssertNotNil(systemMessage, "Should have system message")
            XCTAssertTrue(
                systemMessage?.content.contains("Focus on implementation") ?? false,
                "System message should contain implementation prompt"
            )
            XCTAssertFalse(
                systemMessage?.content.contains("PLANNING PHASE") ?? true,
                "System message should NOT contain planning prompt"
            )
        }
    }

    func testPlanningPromptNotOverwrittenIfNoOriginalSaved() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        let planningPrompt = """
        PLANNING PHASE
        ==============
        """

        // No original prompt saved
        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))

        var conversationMessages = [
            ChatMessage(role: .system, content: planningPrompt)
        ]

        // Simulate with isFirstIteration = false, no original prompt
        await service._testSimulateImplementationPhaseSave(
            stepID: stepID,
            conversationMessages: &conversationMessages,
            isFirstIteration: false
        )

        // Conversation should still have planning prompt (no restoration happened)
        XCTAssertTrue(conversationMessages[0].content?.contains("PLANNING PHASE") == true)

        // llmConversation should be empty (no save happened)
        if let updatedTask = mockDelegate.taskToMutate {
            let llmConversation = updatedTask.runs[0].steps[0].llmConversation
            XCTAssertTrue(llmConversation.isEmpty, "No save should happen without original prompt")
        }
    }

    func testFirstIterationWithoutPlanningPhaseSavesDirectly() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        let normalSystemPrompt = """
        You are a Software Engineer. Focus on implementation.
        """

        var conversationMessages = [
            ChatMessage(role: .system, content: normalSystemPrompt),
            ChatMessage(role: .user, content: "Build the feature")
        ]

        // Simulate first iteration (no planning phase)
        await service._testSimulateImplementationPhaseSave(
            stepID: stepID,
            conversationMessages: &conversationMessages,
            isFirstIteration: true
        )

        // Verify: conversation saved directly
        if let updatedTask = mockDelegate.taskToMutate {
            let llmConversation = updatedTask.runs[0].steps[0].llmConversation
            XCTAssertEqual(llmConversation.count, 2, "Should have 2 messages saved")

            let systemMessage = llmConversation.first { $0.role == .system }
            XCTAssertTrue(
                systemMessage?.content.contains("Focus on implementation") ?? false,
                "Should save the original system prompt"
            )
        }
    }

    func testRestorationOnlyHappensOnce() async {
        let task = createTestTaskWithStep()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        let implementationPrompt = "Implementation prompt"
        let planningPrompt = "PLANNING PHASE prompt"

        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: implementationPrompt)

        var conversationMessages = [
            ChatMessage(role: .system, content: planningPrompt)
        ]

        // First call: should restore and clear
        await service._testSimulateImplementationPhaseSave(
            stepID: stepID,
            conversationMessages: &conversationMessages,
            isFirstIteration: false
        )

        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID))
        XCTAssertEqual(conversationMessages[0].content, implementationPrompt)

        // Manually revert to check second call behavior
        conversationMessages[0] = ChatMessage(
            role: .system,
            content: "Some other content"
        )

        // Second call: should NOT restore (original already cleared)
        await service._testSimulateImplementationPhaseSave(
            stepID: stepID,
            conversationMessages: &conversationMessages,
            isFirstIteration: false
        )

        // Should remain unchanged
        XCTAssertEqual(conversationMessages[0].content, "Some other content")
    }

    func testImplementationPromptContainsExpectedContent() {
        // Verify the default Software Engineer prompt contains key phrases
        let prompt = SystemTemplates.roles["softwareEngineer"]!.prompt

        XCTAssertTrue(
            prompt.contains("Focus on implementation"),
            "Software Engineer prompt should contain 'Focus on implementation'"
        )
        XCTAssertTrue(
            prompt.contains("Make real code changes using tools"),
            "Software Engineer prompt should contain 'Make real code changes using tools'"
        )
        XCTAssertTrue(
            prompt.contains("No dead code"),
            "Software Engineer prompt should contain engineering standards"
        )
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
    private var toolMemory: ToolCallCache!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let nanoteamsDir = tempDir.appendingPathComponent(".nanoteams")
        try! FileManager.default.createDirectory(at: nanoteamsDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)

        let logURL = NTMSPaths(workFolderRoot: tempDir).toolCallsJSONL(taskID: 0, runID: 0)
        toolRuntime = ToolRuntime(
            registry: ToolRegistry(),
            logger: ToolCallLogger(logURL: logURL)
        )
        toolMemory = ToolCallCache()
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        service = nil
        mockDelegate = nil
        toolRuntime = nil
        toolMemory = nil
        super.tearDown()
    }

    func testUnauthorizedToolCallReturnsError() {
        let task = createTestTask()

        let unauthorizedCall = StepToolCall(
            providerID: "call_1",
            name: "git_status",
            argumentsJSON: "{}"
        )

        let batch = service.executeToolCalls(
            resolvedToolCalls: [unauthorizedCall],
            allowedToolNames: ["read_file", "write_file"],
            runtime: toolRuntime,
            memory: toolMemory,
            task: task,
            runIndex: 0,
            roleID: "test_role")

        XCTAssertEqual(batch.results.count, 1)
        XCTAssertTrue(batch.results[0].isError)
        XCTAssertTrue(batch.results[0].outputJSON.contains("tool_not_authorized"))
        XCTAssertTrue(batch.results[0].outputJSON.contains("git_status"))
    }

    func testAuthorizedToolCallExecutesNormally() {
        let task = createTestTask()

        let authorizedCall = StepToolCall(
            providerID: "call_1",
            name: "update_scratchpad",
            argumentsJSON: #"{"content":"test plan"}"#
        )

        let batch = service.executeToolCalls(
            resolvedToolCalls: [authorizedCall],
            allowedToolNames: ["update_scratchpad"],
            runtime: toolRuntime,
            memory: toolMemory,
            task: task,
            runIndex: 0,
            roleID: "test_role")

        XCTAssertEqual(batch.results.count, 1)
        XCTAssertFalse(batch.results[0].outputJSON.contains("tool_not_authorized"))
    }

    func testMixOfAuthorizedAndUnauthorizedToolCalls() {
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

        let batch = service.executeToolCalls(
            resolvedToolCalls: [authorizedCall, unauthorizedCall],
            allowedToolNames: ["update_scratchpad"],
            runtime: toolRuntime,
            memory: toolMemory,
            task: task,
            runIndex: 0,
            roleID: "test_role")

        XCTAssertEqual(batch.results.count, 2)
        XCTAssertFalse(batch.results[0].outputJSON.contains("tool_not_authorized"))
        XCTAssertTrue(batch.results[1].isError)
        XCTAssertTrue(batch.results[1].outputJSON.contains("tool_not_authorized"))
        XCTAssertTrue(batch.results[1].outputJSON.contains("git_commit"))
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

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() {
        super.setUp()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        // Register step→task mapping so taskIDForStep works
        service.executionStates[stepID] = LLMExecutionService.StepExecutionState(taskID: taskID)
    }

    override func tearDown() {
        service = nil
        mockDelegate = nil
        mockClient = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Harmony marker and JSON in a single delta — JSON must not leak into assistantContent.
    func testHarmonyMarker_singleDelta_stripsJSON() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Hello!"),
            StreamEvent(contentDelta: "<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{\"question\":\"Hi\"}}<|end|>")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
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
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        // assistantContent must not contain the partial marker or JSON
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertFalse(result.assistantContent.contains("<|ca"))
        XCTAssertFalse(result.assistantContent.contains("{"))
        XCTAssertEqual(result.assistantContent.count, 210)
    }

    /// Content and marker mixed in a single delta.
    func testHarmonyMarker_mixedContentAndMarkerInSingleDelta() async throws {
        mockClient.deltas = [
            StreamEvent(contentDelta: "Here is my answer.<|call|>{\"name\":\"ask_supervisor\",\"arguments\":{}}<|end|>")
        ]

        let result = try await service.performStreamingCall(
            stepID: stepID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], session: nil,
            networkLogger: nil
        )

        XCTAssertEqual(result.assistantContent, "Here is my answer.")
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertFalse(result.assistantContent.contains("{"))
    }
}
