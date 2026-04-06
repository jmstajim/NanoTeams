import XCTest

@testable import NanoTeams

@MainActor
final class TaskMutationServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var repository: NTMSRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use standardizedFileURL to resolve symlinks (/var -> /private/var on macOS)
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repository = NTMSRepository()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        repository = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    private func createTaskWithStep() throws -> (task: NTMSTask, stepID: String) {
        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        var context = try repository.createTask(at: tempDir, title: "Test Task", supervisorTask: "Test Goal")
        var task = context.activeTask!

        let stepID = "test_step"
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Test Step"
        )
        let run = Run(id: 0, steps: [step])
        task.runs.append(run)
        _ = try repository.updateTask(at: tempDir, task: task)

        return (task, stepID)
    }

    // MARK: - mutateInMemory Tests

    func testMutateInMemory_appliesMutation() {
        var task = NTMSTask(id: 0, title: "Original", supervisorTask: "Goal")

        TaskMutationService.mutateInMemory(task: &task) { t in
            t.title = "Mutated"
        }

        XCTAssertEqual(task.title, "Mutated")
    }

    func testMutateInMemory_doesNotPersist() throws {
        var (task, _) = try createTaskWithStep()

        TaskMutationService.mutateInMemory(task: &task) { t in
            t.title = "In Memory Only"
        }

        // Re-read from disk - should still have original title
        let freshContext = try repository.openOrCreateWorkFolder(at: tempDir)
        XCTAssertNotEqual(freshContext.activeTask?.title, "In Memory Only")
    }

    // MARK: - updateSnapshot Tests

    func testUpdateSnapshot_updatesActiveTask() {
        var snapshot = WorkFolderContext(
            projection: WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: []),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )

        let task = NTMSTask(id: 0, title: "New Task", supervisorTask: "Goal")

        TaskMutationService.updateSnapshot(&snapshot, with: task, updateIndex: false)

        XCTAssertEqual(snapshot.activeTask?.title, "New Task")
        XCTAssertEqual(snapshot.activeTaskID, task.id)
    }

    func testUpdateSnapshot_updatesIndex() {
        var snapshot = WorkFolderContext(
            projection: WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: []),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )

        let task = NTMSTask(id: 0, title: "Indexed Task", supervisorTask: "Goal")

        TaskMutationService.updateSnapshot(&snapshot, with: task, updateIndex: true)

        XCTAssertEqual(snapshot.tasksIndex.tasks.count, 1)
        XCTAssertEqual(snapshot.tasksIndex.tasks[0].title, "Indexed Task")
    }

    func testUpdateSnapshot_replacesExistingInIndex() {
        let taskID = 0
        let existingSummary = TaskSummary(id: taskID, title: "Old Title", status: .running)
        var snapshot = WorkFolderContext(
            projection: WorkFolderProjection(state: WorkFolderState(name: "Test"), settings: .defaults, teams: []),
            tasksIndex: TasksIndex(tasks: [existingSummary]),
            toolDefinitions: [],
            activeTaskID: taskID,
            activeTask: nil
        )

        var task = NTMSTask(id: taskID, title: "Updated Title", supervisorTask: "Goal")
        task.status = .done

        TaskMutationService.updateSnapshot(&snapshot, with: task, updateIndex: true)

        XCTAssertEqual(snapshot.tasksIndex.tasks.count, 1)
        XCTAssertEqual(snapshot.tasksIndex.tasks[0].title, "Updated Title")
    }

    // MARK: - appendMessage Tests

    func testAppendMessage_addsToStep() throws {
        var (task, stepID) = try createTaskWithStep()

        let message = StepMessage(role: .softwareEngineer, content: "Test message")
        TaskMutationService.appendMessage(message, to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.messages.count, 1)
        XCTAssertEqual(step?.messages.first?.content, "Test message")
    }

    func testAppendMessage_updatesStepTimestamp() throws {
        var (task, stepID) = try createTaskWithStep()
        let originalUpdatedAt = task.runs.last!.steps[0].updatedAt

        Thread.sleep(forTimeInterval: 0.01)
        let message = StepMessage(role: .supervisor, content: "Another message")
        TaskMutationService.appendMessage(message, to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertGreaterThan(step!.updatedAt, originalUpdatedAt)
    }

    func testAppendMessage_noOpForInvalidStepID() throws {
        var (task, _) = try createTaskWithStep()
        let invalidStepID = "invalid_step"

        let message = StepMessage(role: .softwareEngineer, content: "Should not be added")
        TaskMutationService.appendMessage(message, to: invalidStepID, in: &task)

        // No change to existing step
        XCTAssertEqual(task.runs.last?.steps[0].messages.count, 0)
    }

    // MARK: - appendToolCall Tests

    func testAppendToolCall_addsToStep() throws {
        var (task, stepID) = try createTaskWithStep()

        let toolCall = StepToolCall(name: "read_file", argumentsJSON: #"{"path":"test.txt"}"#)
        TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.toolCalls.count, 1)
        XCTAssertEqual(step?.toolCalls.first?.name, "read_file")
    }

    // MARK: - updateToolCallResult Tests

    func testUpdateToolCallResult_updatesExisting() throws {
        var (task, stepID) = try createTaskWithStep()

        // First add a tool call
        let toolCall = StepToolCall(name: "write_file", argumentsJSON: "{}")
        TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)

        // Now update its result
        TaskMutationService.updateToolCallResult(
            toolCallID: toolCall.id,
            resultJSON: #"{"ok":true}"#,
            isError: false,
            stepID: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.toolCalls.first?.resultJSON, #"{"ok":true}"#)
        XCTAssertEqual(step?.toolCalls.first?.isError, false)
    }

    func testUpdateToolCallResult_setsErrorFlag() throws {
        var (task, stepID) = try createTaskWithStep()

        let toolCall = StepToolCall(name: "write_file", argumentsJSON: "{}")
        TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)

        TaskMutationService.updateToolCallResult(
            toolCallID: toolCall.id,
            resultJSON: #"{"error":"Failed"}"#,
            isError: true,
            stepID: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.toolCalls.first?.isError, true)
    }

    // MARK: - updateStepStatus Tests

    func testUpdateStepStatus_changesStatus() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.updateStepStatus(.running, stepID: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.status, .running)
    }

    func testUpdateStepStatus_allStatusValues() throws {
        let statuses: [StepStatus] = [.pending, .running, .paused, .needsSupervisorInput, .needsApproval, .failed, .done]

        for status in statuses {
            var (task, stepID) = try createTaskWithStep()
            TaskMutationService.updateStepStatus(status, stepID: stepID, in: &task)

            let step = task.runs.last?.steps.first { $0.id == stepID }
            XCTAssertEqual(step?.status, status, "Status should be \(status)")
        }
    }

    // MARK: - appendArtifacts Tests

    func testAppendArtifacts_addsToStep() throws {
        var (task, stepID) = try createTaskWithStep()

        let artifact = Artifact(name: "Product Requirements", isSystem: false)
        TaskMutationService.appendArtifacts([artifact], to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.artifacts.count, 1)
        XCTAssertEqual(step?.artifacts.first?.name, "Product Requirements")
    }

    func testAppendArtifacts_multipleArtifacts() throws {
        var (task, stepID) = try createTaskWithStep()

        let artifacts = [
            Artifact(name: "Product Requirements", isSystem: false),
            Artifact(name: "Design", isSystem: false),
        ]
        TaskMutationService.appendArtifacts(artifacts, to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.artifacts.count, 2)
    }

    // MARK: - attachBuildDiagnosticsArtifact Tests

    func testAttachBuildDiagnosticsArtifact_createsNew() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.attachBuildDiagnosticsArtifact(
            relativePath: "runs/abc/steps/xyz/build_diagnostics.json",
            stepID: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.artifacts.count, 1)
        XCTAssertEqual(step?.artifacts.first?.name, "Build Diagnostics")
        XCTAssertEqual(step?.artifacts.first?.relativePath, "runs/abc/steps/xyz/build_diagnostics.json")
    }

    func testAttachBuildDiagnosticsArtifact_updatesExisting() throws {
        var (task, stepID) = try createTaskWithStep()

        // Add initial build diagnostics
        TaskMutationService.attachBuildDiagnosticsArtifact(
            relativePath: "old/path.json",
            stepID: stepID,
            in: &task
        )

        // Update with new path
        TaskMutationService.attachBuildDiagnosticsArtifact(
            relativePath: "new/path.json",
            stepID: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.artifacts.count, 1) // Should not create duplicate
        XCTAssertEqual(step?.artifacts.first?.relativePath, "new/path.json")
    }

    // MARK: - setSupervisorQuestion Tests

    func testSetSupervisorQuestion_setsFields() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.setSupervisorQuestion(
            "What should we prioritize?",
            required: true,
            stepID: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.supervisorQuestion, "What should we prioritize?")
        XCTAssertTrue(step?.needsSupervisorInput ?? false)
    }

    func testSetSupervisorQuestion_notRequired() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.setSupervisorQuestion(
            "Optional question",
            required: false,
            stepID: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.supervisorQuestion, "Optional question")
        XCTAssertFalse(step?.needsSupervisorInput ?? true)
    }

    // MARK: - setSupervisorAnswer Tests

    func testSetSupervisorAnswer_setsAnswer() throws {
        var (task, stepID) = try createTaskWithStep()

        // First set a question
        TaskMutationService.setSupervisorQuestion("Question?", required: true, stepID: stepID, in: &task)

        // Then answer it
        TaskMutationService.setSupervisorAnswer("This is the answer", stepID: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.supervisorAnswer, "This is the answer")
    }

    func testSetSupervisorAnswer_clearsNeedsSupervisorInput() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.setSupervisorQuestion("Question?", required: true, stepID: stepID, in: &task)
        XCTAssertTrue(task.runs.last!.steps[0].needsSupervisorInput)

        TaskMutationService.setSupervisorAnswer("Answer", stepID: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertFalse(step?.needsSupervisorInput ?? true)
    }

    func testSetSupervisorAnswer_clearsStaleAttachmentPaths() throws {
        var (task, stepID) = try createTaskWithStep()

        // Simulate prior answer with attachments
        task.runs[task.runs.count - 1].steps[0].supervisorAnswerAttachmentPaths = [
            ".nanoteams/tasks/abc/attachments/old.png",
        ]

        TaskMutationService.setSupervisorAnswer("New answer", stepID: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.supervisorAnswer, "New answer")
        XCTAssertTrue(step?.supervisorAnswerAttachmentPaths.isEmpty ?? false)
    }

    // MARK: - updateWorkNotes Tests

    func testUpdateWorkNotes_setsNotes() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.updateWorkNotes("Work notes content", stepID: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.workNotes, "Work notes content")
    }

    func testUpdateWorkNotes_clearsNotes() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.updateWorkNotes("Initial notes", stepID: stepID, in: &task)
        TaskMutationService.updateWorkNotes(nil, stepID: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertNil(step?.workNotes)
    }

    // MARK: - appendLLMMessage Tests

    func testAppendLLMMessage_addsToConversation() throws {
        var (task, stepID) = try createTaskWithStep()

        let llmMessage = LLMMessage(role: .user, content: "Hello")
        TaskMutationService.appendLLMMessage(llmMessage, to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.llmConversation.count, 1)
        XCTAssertEqual(step?.llmConversation.first?.content, "Hello")
    }

    func testAppendLLMMessage_multipleMessages() throws {
        var (task, stepID) = try createTaskWithStep()

        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .system, content: "System prompt"),
            to: stepID,
            in: &task
        )
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .user, content: "User message"),
            to: stepID,
            in: &task
        )
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: "Assistant response"),
            to: stepID,
            in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.llmConversation.count, 3)
    }

    // MARK: - commitStreamingContent Tests

    func testCommitStreamingContent_updatesLLMMessageAndCreatesStepMessage() throws {
        var (task, stepID) = try createTaskWithStep()

        // Pre-create empty LLMMessage (like beginStreaming does)
        let messageID = UUID()
        let emptyMsg = LLMMessage(id: messageID, role: .assistant, content: "")
        TaskMutationService.appendLLMMessage(emptyMsg, to: stepID, in: &task)

        // Commit with final content
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "Full content here", thinking: "Some thinking",
            role: .softwareEngineer, in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        // LLMMessage updated in-place
        let llmMsg = step?.llmConversation.first { $0.id == messageID }
        XCTAssertEqual(llmMsg?.content, "Full content here")
        XCTAssertEqual(llmMsg?.thinking, "Some thinking")
        // StepMessage created
        XCTAssertEqual(step?.messages.count, 1)
        XCTAssertEqual(step?.messages.first?.content, "Full content here")
        XCTAssertEqual(step?.messages.first?.id, messageID)
    }

    func testCommitStreamingContent_updatesExistingStepMessage() throws {
        var (task, stepID) = try createTaskWithStep()

        // Pre-create LLMMessage and StepMessage
        let messageID = UUID()
        let emptyMsg = LLMMessage(id: messageID, role: .assistant, content: "")
        TaskMutationService.appendLLMMessage(emptyMsg, to: stepID, in: &task)
        let partialStepMsg = StepMessage(id: messageID, role: .softwareEngineer, content: "Partial...")
        TaskMutationService.appendMessage(partialStepMsg, to: stepID, in: &task)

        // Commit with final content
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "Updated content", thinking: nil,
            role: .softwareEngineer, in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.messages.count, 1)
        XCTAssertEqual(step?.messages.first?.content, "Updated content")
    }

    func testCommitStreamingContent_emptyContentDoesNotCreateStepMessage() throws {
        var (task, stepID) = try createTaskWithStep()

        let messageID = UUID()
        let emptyMsg = LLMMessage(id: messageID, role: .assistant, content: "")
        TaskMutationService.appendLLMMessage(emptyMsg, to: stepID, in: &task)

        // Commit with empty content (cancelled before any tokens)
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "", thinking: nil,
            role: .softwareEngineer, in: &task
        )

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.messages.count, 0)
    }

    // MARK: - Edge Cases

    func testMutationsOnTaskWithNoRuns() {
        var task = NTMSTask(id: 0, title: "Empty Task", supervisorTask: "Goal")
        let fakeStepID = "fake_step"

        // These should be no-ops, not crash
        TaskMutationService.appendMessage(
            StepMessage(role: .softwareEngineer, content: "Test"),
            to: fakeStepID,
            in: &task
        )

        TaskMutationService.updateStepStatus(.running, stepID: fakeStepID, in: &task)

        XCTAssertTrue(task.runs.isEmpty)
    }

    func testMutationsOnTaskWithMultipleRuns() throws {
        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        var context = try repository.createTask(at: tempDir, title: "Multi-Run Task", supervisorTask: "Goal")
        var task = context.activeTask!

        // Add first run with a step
        let step1ID = "step1"
        let step1 = StepExecution(id: step1ID, role: .softwareEngineer, title: "Step 1")
        let run1 = Run(id: 0, steps: [step1])
        task.runs.append(run1)

        // Add second run with a step
        let step2ID = "step2"
        let step2 = StepExecution(id: step2ID, role: .softwareEngineer, title: "Step 2")
        let run2 = Run(id: 0, steps: [step2])
        task.runs.append(run2)

        // Mutations should affect the latest run only
        TaskMutationService.updateStepStatus(.running, stepID: step2ID, in: &task)

        XCTAssertEqual(task.runs[0].steps[0].status, .pending) // First run unchanged
        XCTAssertEqual(task.runs[1].steps[0].status, .running) // Latest run updated
    }
}
