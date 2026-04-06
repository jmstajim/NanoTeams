import XCTest

@testable import NanoTeams

/// Tests for supervisor continuation behavior:
/// - llmConversation preservation across supervisor Q&A cycles
/// - Supervisor answer message persistence with sourceContext
/// - Planning phase interaction with supervisor continuation
@MainActor
final class SupervisorContinuationTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try? FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - saveLLMConversation Preservation

    func testApplyPlanningPhaseSkipsSaveWhenStepHasPriorConversation() async {
        // Simulate a step that already has messages from a previous execution
        var task = makeTask()
        let stepID = task.runs[0].steps[0].id
        task.runs[0].steps[0].llmConversation = [
            LLMMessage(role: .system, content: "System prompt"),
            LLMMessage(role: .user, content: "User task"),
            LLMMessage(role: .assistant, content: "Tool call", thinking: "Thinking here"),
            LLMMessage(role: .tool, content: "Tool result"),
        ]
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Build a minimal conversation (supervisor continuation style)
        var conversation: [ChatMessage] = [
            ChatMessage(role: .tool, content: "{\"ok\":true}")
        ]

        let step = task.runs[0].steps[0]
        let memory = ToolCallCache()

        // applyPlanningPhase should NOT replace the conversation because hasPriorConversation = true
        _ = await service.applyPlanningPhase(
            stepID: stepID,
            roleForMessage: .questMaster,
            tools: [],
            step: step,
            memory: memory,
            conversationMessages: &conversation,
            roleDefinition: nil
        )

        // Verify the persisted conversation still has all 4 original messages
        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.llmConversation.count, 4,
                       "Prior conversation should be preserved, not replaced")
        XCTAssertEqual(updated.llmConversation[0].role, .system)
        XCTAssertEqual(updated.llmConversation[2].thinking, "Thinking here")
    }

    func testApplyPlanningPhaseSavesOnTrueFirstIteration() async {
        // Step with no prior conversation — saveLLMConversation should replace
        let task = makeTask()
        let stepID = task.runs[0].steps[0].id
        // llmConversation is empty (true first iteration)
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "User task"),
        ]

        let step = task.runs[0].steps[0]
        let memory = ToolCallCache()

        _ = await service.applyPlanningPhase(
            stepID: stepID,
            roleForMessage: .questMaster,
            tools: [],
            step: step,
            memory: memory,
            conversationMessages: &conversation,
            roleDefinition: nil
        )

        // Verify the conversation was saved (first iteration, no prior messages)
        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.llmConversation.count, 2,
                       "Should save initial conversation on true first iteration")
        XCTAssertEqual(updated.llmConversation[0].role, .system)
        XCTAssertEqual(updated.llmConversation[1].role, .user)
    }

    // MARK: - Supervisor Answer Persistence

    func testAppendSupervisorAnswerWithSourceContext() async {
        var task = makeTask()
        let stepID = task.runs[0].steps[0].id
        task.runs[0].steps[0].llmConversation = [
            LLMMessage(role: .assistant, content: "Calling ask_supervisor"),
        ]
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        // Append a supervisor answer message
        await service.appendLLMMessage(
            stepID: stepID, role: .user,
            content: "Supervisor answer: Yes, proceed",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.llmConversation.count, 2)

        let answerMsg = updated.llmConversation[1]
        XCTAssertEqual(answerMsg.role, .user)
        XCTAssertEqual(answerMsg.sourceRole, .supervisor)
        XCTAssertEqual(answerMsg.sourceContext, .supervisorAnswer)
        XCTAssertTrue(answerMsg.content.contains("Yes, proceed"))
    }

    // MARK: - MessageSourceContext Codable

    func testSupervisorAnswerContextCodable() throws {
        let context = MessageSourceContext.supervisorAnswer
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: data)
        XCTAssertEqual(decoded, .supervisorAnswer)
        XCTAssertEqual(context.rawValue, "supervisorAnswer")
    }

    // MARK: - Helpers

    private func makeTask() -> NTMSTask {
        var task = NTMSTask(id: 0, title: "Test Quest", supervisorTask: "Test goal")
        let step = StepExecution(
            id: "test_step",
            role: .questMaster,
            title: "Quest Master",
            status: .running
        )
        var run = Run(id: 0, steps: [step])
        run.id = 0
        task.runs = [run]
        return task
    }
}
