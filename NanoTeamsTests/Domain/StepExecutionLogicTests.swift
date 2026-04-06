import XCTest
@testable import NanoTeams

/// Tests for StepExecution logic and Supervisor input handling
final class StepExecutionLogicTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - StepExecution Initialization Tests

    func testStepExecutionDefaultValues() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO Step")

        XCTAssertEqual(step.status, .pending)
        XCTAssertTrue(step.expectedArtifacts.isEmpty)
        XCTAssertTrue(step.messages.isEmpty)
        XCTAssertTrue(step.artifacts.isEmpty)
        XCTAssertTrue(step.toolCalls.isEmpty)
        XCTAssertNil(step.workNotes)
        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertNil(step.supervisorQuestion)
        XCTAssertNil(step.supervisorAnswer)
        XCTAssertNil(step.supervisorCommentForNext)
        XCTAssertTrue(step.llmConversation.isEmpty)
    }

    func testStepExecutionWithAllFields() {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer Step",
            expectedArtifacts: ["Engineering Notes"],
            status: .running,
            messages: [StepMessage(role: .softwareEngineer, content: "Working")],
            artifacts: [],
            toolCalls: [StepToolCall(name: "read_file", argumentsJSON: "{}")],
            workNotes: "Some notes",
            needsSupervisorInput: true,
            supervisorQuestion: "What should I do?",
            supervisorAnswer: "Do this",
            supervisorCommentForNext: "Pass this to next step",
            llmConversation: [LLMMessage(role: .user, content: "Start")]
        )

        XCTAssertEqual(step.role, .softwareEngineer)
        XCTAssertEqual(step.title, "Engineer Step")
        XCTAssertEqual(step.expectedArtifacts.count, 1)
        XCTAssertEqual(step.status, .running)
        XCTAssertEqual(step.messages.count, 1)
        XCTAssertEqual(step.toolCalls.count, 1)
        XCTAssertEqual(step.workNotes, "Some notes")
        XCTAssertTrue(step.needsSupervisorInput)
        XCTAssertEqual(step.supervisorQuestion, "What should I do?")
        XCTAssertEqual(step.supervisorAnswer, "Do this")
        XCTAssertEqual(step.supervisorCommentForNext, "Pass this to next step")
        XCTAssertEqual(step.llmConversation.count, 1)
    }

    // MARK: - Supervisor Input Handling Tests

    func testSupervisorInputNotNeededByDefault() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO")
        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertNil(step.supervisorQuestion)
    }

    func testSupervisorInputNeededWithQuestion() {
        var step = StepExecution(id: "test_step", role: .productManager, title: "PO")
        step.needsSupervisorInput = true
        step.supervisorQuestion = "Should I proceed with option A or B?"

        XCTAssertTrue(step.needsSupervisorInput)
        XCTAssertEqual(step.supervisorQuestion, "Should I proceed with option A or B?")
        XCTAssertNil(step.supervisorAnswer)
    }

    func testSupervisorInputAnswered() {
        var step = StepExecution(id: "test_step", role: .productManager, title: "PO")
        step.needsSupervisorInput = true
        step.supervisorQuestion = "Should I proceed?"
        step.supervisorAnswer = "Yes, proceed with option A"

        XCTAssertTrue(step.needsSupervisorInput)
        XCTAssertNotNil(step.supervisorQuestion)
        XCTAssertEqual(step.supervisorAnswer, "Yes, proceed with option A")
    }

    func testSupervisorCommentForNextStep() {
        var step = StepExecution(id: "test_step", role: .productManager, title: "PO")
        step.supervisorCommentForNext = "Make sure to consider edge cases"

        XCTAssertNotNil(step.supervisorCommentForNext)
        XCTAssertEqual(step.supervisorCommentForNext, "Make sure to consider edge cases")
    }

    // MARK: - Supervisor Input Resolution Logic Tests
    // Tests the isResolved / filter logic used by TeamActivityFeedView and WatchtowerView

    /// Helper: mirrors TeamActivityFeedView.supervisorInputNotification isResolved logic
    private func isResolved(_ step: StepExecution?) -> Bool {
        step?.supervisorAnswer != nil || !(step?.needsSupervisorInput ?? false)
    }

    /// Helper: mirrors WatchtowerView notification filter
    private func watchtowerFindsStep(_ steps: [StepExecution]) -> StepExecution? {
        steps.first(where: { $0.needsSupervisorInput && $0.supervisorAnswer == nil })
    }

    func testIsResolved_activeQuestion_notResolved() {
        let step = StepExecution(
            id: "test_step",
            role: .questMaster, title: "QM",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "What happens next?"
        )

        XCTAssertFalse(isResolved(step))
    }

    func testIsResolved_pausedWithPendingQuestion_notResolved() {
        // Key fix: paused step with needsSupervisorInput=true should NOT be treated as resolved
        let step = StepExecution(
            id: "test_step",
            role: .questMaster, title: "QM",
            status: .paused,
            needsSupervisorInput: true,
            supervisorQuestion: "What happens next?"
        )

        XCTAssertFalse(isResolved(step))
    }

    func testIsResolved_answeredQuestion_resolved() {
        let step = StepExecution(
            id: "test_step",
            role: .questMaster, title: "QM",
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "What happens next?",
            supervisorAnswer: "Go left"
        )

        XCTAssertTrue(isResolved(step))
    }

    func testIsResolved_noQuestion_resolved() {
        let step = StepExecution(
            id: "test_step",
            role: .questMaster, title: "QM",
            status: .done,
            needsSupervisorInput: false
        )

        XCTAssertTrue(isResolved(step))
    }

    func testIsResolved_nilStep_resolved() {
        XCTAssertTrue(isResolved(nil))
    }

    func testWatchtowerFilter_findsActiveQuestion() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PM", status: .done),
            StepExecution(
                id: "test_step",
                role: .questMaster, title: "QM",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "What next?"
            )
        ]

        let found = watchtowerFindsStep(steps)
        XCTAssertEqual(found?.role, .questMaster)
    }

    func testWatchtowerFilter_findsPausedStepWithPendingQuestion() {
        // Key fix: Watchtower should find paused steps with needsSupervisorInput=true
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PM", status: .done),
            StepExecution(
                id: "test_step",
                role: .questMaster, title: "QM",
                status: .paused,
                needsSupervisorInput: true,
                supervisorQuestion: "What next?"
            )
        ]

        let found = watchtowerFindsStep(steps)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.role, .questMaster)
    }

    func testWatchtowerFilter_skipsAnsweredQuestion() {
        let steps = [
            StepExecution(
                id: "test_step",
                role: .questMaster, title: "QM",
                status: .running,
                needsSupervisorInput: false,
                supervisorQuestion: "What next?",
                supervisorAnswer: "Go left"
            )
        ]

        XCTAssertNil(watchtowerFindsStep(steps))
    }

    func testWatchtowerFilter_skipsStepWithNoQuestion() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PM", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
        ]

        XCTAssertNil(watchtowerFindsStep(steps))
    }

    // MARK: - StepStatus Tests

    func testAllStepStatusCases() {
        let allCases = StepStatus.allCases

        XCTAssertEqual(allCases.count, 7)
        XCTAssertTrue(allCases.contains(.pending))
        XCTAssertTrue(allCases.contains(.running))
        XCTAssertTrue(allCases.contains(.paused))
        XCTAssertTrue(allCases.contains(.needsSupervisorInput))
        XCTAssertTrue(allCases.contains(.needsApproval))
        XCTAssertTrue(allCases.contains(.failed))
        XCTAssertTrue(allCases.contains(.done))
    }

    func testStepStatusTransitions() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")

        // Pending -> Running
        XCTAssertEqual(step.status, .pending)
        step.status = .running
        XCTAssertEqual(step.status, .running)

        // Running -> NeedsApproval
        step.status = .needsApproval
        XCTAssertEqual(step.status, .needsApproval)

        // NeedsApproval -> Done
        step.status = .done
        XCTAssertEqual(step.status, .done)
    }

    func testStepStatusCanBeSetToFailed() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .running)
        step.status = .failed
        XCTAssertEqual(step.status, .failed)
    }

    func testStepStatusCanBeSetToPaused() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .running)
        step.status = .paused
        XCTAssertEqual(step.status, .paused)
    }

    // MARK: - StepMessage Tests

    func testStepMessageInitialization() {
        let message = StepMessage(role: .softwareEngineer, content: "Hello world")

        XCTAssertEqual(message.role, .softwareEngineer)
        XCTAssertEqual(message.content, "Hello world")
        XCTAssertNotNil(message.id)
        XCTAssertNotNil(message.createdAt)
    }

    func testStepMessageIdentifiable() {
        let message1 = StepMessage(role: .supervisor, content: "Test")
        let message2 = StepMessage(role: .supervisor, content: "Test")

        XCTAssertNotEqual(message1.id, message2.id)
    }

    func testStepMessageWithDifferentRoles() {
        let supervisorMessage = StepMessage(role: .supervisor, content: "Supervisor says")
        let engineerMessage = StepMessage(role: .softwareEngineer, content: "Engineer says")
        let customMessage = StepMessage(role: .custom(id: "myRole"), content: "Custom says")

        XCTAssertEqual(supervisorMessage.role, .supervisor)
        XCTAssertEqual(engineerMessage.role, .softwareEngineer)
        XCTAssertEqual(customMessage.role, .custom(id: "myRole"))
    }

    // MARK: - StepToolCall Tests

    func testStepToolCallInitialization() {
        let toolCall = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )

        XCTAssertEqual(toolCall.name, "read_file")
        XCTAssertEqual(toolCall.argumentsJSON, "{\"path\": \"test.swift\"}")
        XCTAssertNil(toolCall.resultJSON)
        XCTAssertNil(toolCall.isError)
        XCTAssertNil(toolCall.providerID)
    }

    func testStepToolCallWithResult() {
        let toolCall = StepToolCall(
            providerID: "call_123",
            name: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"content\": \"file contents\"}",
            isError: false
        )

        XCTAssertEqual(toolCall.providerID, "call_123")
        XCTAssertEqual(toolCall.resultJSON, "{\"content\": \"file contents\"}")
        XCTAssertEqual(toolCall.isError, false)
    }

    func testStepToolCallWithError() {
        let toolCall = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"nonexistent.swift\"}",
            resultJSON: "{\"error\": \"File not found\"}",
            isError: true
        )

        XCTAssertEqual(toolCall.isError, true)
    }

    // MARK: - LLMMessage Tests

    func testLLMMessageInitialization() {
        let message = LLMMessage(role: .assistant, content: "Hello")

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "Hello")
        XCTAssertNotNil(message.id)
    }

    func testLLMMessageRoles() {
        let systemMessage = LLMMessage(role: .system, content: "You are an assistant")
        let userMessage = LLMMessage(role: .user, content: "Help me")
        let assistantMessage = LLMMessage(role: .assistant, content: "Sure!")
        let toolMessage = LLMMessage(role: .tool, content: "{\"result\": true}")

        XCTAssertEqual(systemMessage.role, .system)
        XCTAssertEqual(userMessage.role, .user)
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertEqual(toolMessage.role, .tool)
    }

    // MARK: - StepExecution Collections Tests

    func testAddingMessages() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")

        step.messages.append(StepMessage(role: .softwareEngineer, content: "Starting work"))
        step.messages.append(StepMessage(role: .softwareEngineer, content: "Made progress"))

        XCTAssertEqual(step.messages.count, 2)
    }

    func testAddingToolCalls() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")

        step.toolCalls.append(StepToolCall(name: "read_file", argumentsJSON: "{}"))
        step.toolCalls.append(StepToolCall(name: "write_file", argumentsJSON: "{}"))

        XCTAssertEqual(step.toolCalls.count, 2)
    }

    func testAddingArtifacts() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")

        step.artifacts.append(Artifact(name: "Notes"))

        XCTAssertEqual(step.artifacts.count, 1)
    }

    func testAddingLLMConversation() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")

        step.llmConversation.append(LLMMessage(role: .system, content: "System prompt"))
        step.llmConversation.append(LLMMessage(role: .user, content: "User input"))
        step.llmConversation.append(LLMMessage(role: .assistant, content: "Response"))

        XCTAssertEqual(step.llmConversation.count, 3)
    }

    // MARK: - isArtifactComplete Tests

    func testIsArtifactComplete_noExpected_returnsFalse() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng")
        XCTAssertFalse(step.isArtifactComplete)
    }

    func testIsArtifactComplete_onlyBuildDiagnostics_returnsFalse() {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer, title: "Eng",
            expectedArtifacts: ["Build Diagnostics"]
        )
        XCTAssertFalse(step.isArtifactComplete)
    }

    func testIsArtifactComplete_missingArtifacts_returnsFalse() {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer, title: "Eng",
            expectedArtifacts: ["Engineering Notes", "Build Diagnostics"]
        )
        XCTAssertFalse(step.isArtifactComplete)
    }

    func testIsArtifactComplete_allPresent_returnsTrue() {
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer, title: "Eng",
            expectedArtifacts: ["Engineering Notes", "Build Diagnostics"]
        )
        step.artifacts = [Artifact(name: "Engineering Notes")]
        XCTAssertTrue(step.isArtifactComplete)
    }

    func testIsArtifactComplete_multipleExpected_partiallyPresent_returnsFalse() {
        var step = StepExecution(
            id: "test_step",
            role: .productManager, title: "PM",
            expectedArtifacts: ["Product Requirements", "User Stories"]
        )
        step.artifacts = [Artifact(name: "Product Requirements")]
        XCTAssertFalse(step.isArtifactComplete)
    }

    func testIsArtifactComplete_multipleExpected_allPresent_returnsTrue() {
        var step = StepExecution(
            id: "test_step",
            role: .productManager, title: "PM",
            expectedArtifacts: ["Product Requirements", "User Stories"]
        )
        step.artifacts = [
            Artifact(name: "Product Requirements"),
            Artifact(name: "User Stories")
        ]
        XCTAssertTrue(step.isArtifactComplete)
    }

    // MARK: - StepExecution with Expected Artifacts Tests

    func testStepWithExpectedArtifacts() {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer",
            expectedArtifacts: ["Engineering Notes", "Build Diagnostics"]
        )

        XCTAssertEqual(step.expectedArtifacts.count, 2)
        XCTAssertTrue(step.expectedArtifacts.contains("Engineering Notes"))
        XCTAssertTrue(step.expectedArtifacts.contains("Build Diagnostics"))
    }

    func testStepWithExpectedArtifactNames() {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer",
            expectedArtifacts: ["Engineering Notes", "Build Diagnostics"]
        )

        XCTAssertEqual(step.expectedArtifacts.count, 2)
        XCTAssertTrue(step.expectedArtifacts.contains("Engineering Notes"))
        XCTAssertTrue(step.expectedArtifacts.contains("Build Diagnostics"))
    }

    // MARK: - WorkNotes Tests

    func testWorkNotesInitiallyNil() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")
        XCTAssertNil(step.workNotes)
    }

    func testWorkNotesCanBeSet() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer")
        step.workNotes = "These are my work notes for this step."

        XCTAssertEqual(step.workNotes, "These are my work notes for this step.")
    }

    func testWorkNotesCanBeCleared() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", workNotes: "Initial notes")
        XCTAssertNotNil(step.workNotes)

        step.workNotes = nil
        XCTAssertNil(step.workNotes)
    }

    // MARK: - Timestamps Tests

    func testCreatedAtTimestamp() {
        let before = Date()
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO")

        // MonotonicClock may return timestamps slightly ahead of system time
        XCTAssertGreaterThanOrEqual(step.createdAt, before)
        XCTAssertLessThan(step.createdAt.timeIntervalSince(before), 1.0)
    }

    func testUpdatedAtTimestamp() {
        let before = Date()
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO")

        // MonotonicClock may return timestamps slightly ahead of system time
        XCTAssertGreaterThanOrEqual(step.updatedAt, before)
        XCTAssertLessThan(step.updatedAt.timeIntervalSince(before), 1.0)
    }

    func testCustomTimestamps() {
        let customDate = Date(timeIntervalSince1970: 1000)
        let step = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PO",
            createdAt: customDate,
            updatedAt: customDate
        )

        XCTAssertEqual(step.createdAt, customDate)
        XCTAssertEqual(step.updatedAt, customDate)
    }

    // MARK: - completedAt Tests

    func testCompletedAtNilByDefault() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO")
        XCTAssertNil(step.completedAt)
    }

    @MainActor func testCompletedAtSetOnDone() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let stepID = "test_step"
        let step = StepExecution(id: stepID, role: .productManager, title: "PO", status: .running)
        task.runs = [Run(id: 0, steps: [step])]

        TaskMutationService.updateStepStatus(.done, stepID: stepID, in: &task)

        let updated = task.runs[0].steps[0]
        XCTAssertNotNil(updated.completedAt)
        XCTAssertEqual(updated.status, StepStatus.done)
        XCTAssertEqual(updated.completedAt, updated.updatedAt)
    }

    @MainActor func testCompletedAtSetOnFailed() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let stepID = "test_step"
        let step = StepExecution(id: stepID, role: .productManager, title: "PO", status: .running)
        task.runs = [Run(id: 0, steps: [step])]

        TaskMutationService.updateStepStatus(.failed, stepID: stepID, in: &task)

        let updated = task.runs[0].steps[0]
        XCTAssertNotNil(updated.completedAt)
        XCTAssertEqual(updated.status, StepStatus.failed)
    }

    @MainActor func testCompletedAtNotOverwrittenOnSecondCall() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let stepID = "test_step"
        let step = StepExecution(id: stepID, role: .productManager, title: "PO", status: .running)
        task.runs = [Run(id: 0, steps: [step])]

        TaskMutationService.updateStepStatus(.done, stepID: stepID, in: &task)
        let firstCompletedAt = task.runs[0].steps[0].completedAt

        // Second call should NOT change completedAt
        TaskMutationService.updateStepStatus(.done, stepID: stepID, in: &task)
        let secondCompletedAt = task.runs[0].steps[0].completedAt

        XCTAssertEqual(firstCompletedAt, secondCompletedAt)
    }

    @MainActor func testCompletedAtNilForRunningStatus() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let stepID = "test_step"
        let step = StepExecution(id: stepID, role: .productManager, title: "PO", status: .pending)
        task.runs = [Run(id: 0, steps: [step])]

        TaskMutationService.updateStepStatus(.running, stepID: stepID, in: &task)

        XCTAssertNil(task.runs[0].steps[0].completedAt)
    }

    func testCompletedAtCodableRoundTrip() throws {
        let now = MonotonicClock.shared.now()
        var step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
        step.completedAt = now

        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: data)

        XCTAssertEqual(decoded.completedAt, now)
    }

    func testCompletedAtDecodesAsNilFromOldData() throws {
        // Simulate old data without completedAt field
        var step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
        step.completedAt = nil

        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: data)

        XCTAssertNil(decoded.completedAt)
    }
}
