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
        var (context, _) = try repository.createTask(at: tempDir, title: "Test Task", supervisorTask: "Test Goal")
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

    // MARK: - appendOrReplaceRetryNotice Tests

    func testAppendOrReplaceRetryNotice_firstAppends_secondReplacesInPlace() throws {
        var (task, stepID) = try createTaskWithStep()
        let prefix = LLMConstants.llmServerErrorRetryNotePrefix

        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 1): Could not connect. Retrying…", to: stepID, in: &task)
        var step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.llmConversation.count, 1)
        XCTAssertEqual(step?.llmConversation.first?.sourceContext, .serverError,
                       "Retry note must be tagged .serverError so the feed renders a red bubble")
        let firstID = step?.llmConversation.first?.id

        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 2): Could not connect. Retrying…", to: stepID, in: &task)
        step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.llmConversation.count, 1,
                       "Consecutive retry notes must collapse into a single bubble")
        XCTAssertEqual(step?.llmConversation.first?.id, firstID,
                       "Same message id → the existing bubble updates in place (no flicker)")
        XCTAssertTrue(step?.llmConversation.first?.content.contains("attempt 2") ?? false,
                      "The single bubble shows the latest attempt count")
    }

    func testAppendOrReplaceRetryNotice_nonRetryMessageBetween_appendsFresh() throws {
        var (task, stepID) = try createTaskWithStep()
        let prefix = LLMConstants.llmServerErrorRetryNotePrefix

        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 1): boom", to: stepID, in: &task)
        // A real assistant turn lands after the retry note (e.g. a reconnect succeeded).
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: "Recovered output"), to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 1): boom again", to: stepID, in: &task)

        let conv = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation
        XCTAssertEqual(conv?.count, 3,
                       "A non-retry message breaks the burst → the next retry appends a fresh note")
        XCTAssertEqual(conv?[1].content, "Recovered output")
        XCTAssertTrue(conv?[2].content.contains("boom again") ?? false)
    }

    /// Production sequence: `beginStreaming` plants an empty `.assistant` placeholder
    /// before EACH attempt, so when the retry note is recorded the placeholder is
    /// `conv.last`. The helper must drop that dead placeholder so consecutive notes
    /// still collapse (this is the case the original collapse missed).
    func testAppendOrReplaceRetryNotice_dropsEmptyPlaceholder_andCollapsesAcrossAttempts() throws {
        var (task, stepID) = try createTaskWithStep()
        let prefix = LLMConstants.llmServerErrorRetryNotePrefix

        // Attempt 1: empty placeholder planted, then the stream errors → record note.
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 1): boom", to: stepID, in: &task)

        // Attempt 2: a NEW empty placeholder lands after the note, then errors.
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 2): boom", to: stepID, in: &task)

        let conv = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation
        XCTAssertEqual(conv?.count, 1,
                       "The empty placeholder must be dropped so the two notes collapse into one")
        XCTAssertTrue(conv?.first?.content.contains("attempt 2") ?? false,
                      "The single surviving bubble shows the latest attempt")
        XCTAssertFalse(conv?.contains { $0.content.isEmpty } ?? true,
                       "No empty placeholder should leak into the conversation")
    }

    func testAppendOrReplaceRetryNotice_emptyPlaceholderWithThinking_isNotDropped() throws {
        var (task, stepID) = try createTaskWithStep()
        let prefix = LLMConstants.llmServerErrorRetryNotePrefix

        // A reasoning-only assistant turn (empty content but real thinking) is a
        // genuine message, not a discardable streaming placeholder — keep it.
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: "", thinking: "let me think"),
            to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice(
            "\(prefix) 1): boom", to: stepID, in: &task)

        let conv = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation
        XCTAssertEqual(conv?.count, 2, "A reasoning-only turn must be preserved, not dropped")
        XCTAssertEqual(conv?.first?.thinking, "let me think")
    }

    func testAppendOrReplaceRetryNotice_unknownStepID_isNoOp() throws {
        var (task, stepID) = try createTaskWithStep()
        let beforeCount = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation.count

        TaskMutationService.appendOrReplaceRetryNotice("note", to: "no-such-step", in: &task)

        XCTAssertEqual(
            task.runs.last?.steps.first { $0.id == stepID }?.llmConversation.count, beforeCount,
            "An unknown stepID must be a no-op — no step mutated")
    }

    func testAppendOrReplaceRetryNotice_placeholderOnlyConversation_dropsAndAppends() throws {
        var (task, stepID) = try createTaskWithStep()
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice("note", to: stepID, in: &task)

        let conv = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation
        XCTAssertEqual(conv?.count, 1, "The lone empty placeholder is dropped; only the note remains")
        XCTAssertEqual(conv?.first?.content, "note")
        XCTAssertEqual(conv?.first?.sourceContext, .serverError)
    }

    func testAppendOrReplaceRetryNotice_trailingEmptyUserMessage_notDropped() throws {
        var (task, stepID) = try createTaskWithStep()
        // Only an empty ASSISTANT turn is the discardable beginStreaming placeholder;
        // an empty user message is left alone.
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .user, content: ""), to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice("note", to: stepID, in: &task)

        let conv = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation
        XCTAssertEqual(conv?.count, 2, "An empty USER message is not a streaming placeholder — keep it")
        XCTAssertEqual(conv?.first?.role, .user)
        XCTAssertEqual(conv?.last?.content, "note")
    }

    func testAppendOrReplaceRetryNotice_realResponseLast_appendsFreshNote() throws {
        var (task, stepID) = try createTaskWithStep()
        // A committed assistant response (non-empty, no .serverError tag) ends a burst.
        TaskMutationService.appendLLMMessage(
            LLMMessage(role: .assistant, content: "Recovered output"), to: stepID, in: &task)
        TaskMutationService.appendOrReplaceRetryNotice("note", to: stepID, in: &task)

        let conv = task.runs.last?.steps.first { $0.id == stepID }?.llmConversation
        XCTAssertEqual(conv?.count, 2, "A real response is not replaced — the note appends after it")
        XCTAssertEqual(conv?.first?.content, "Recovered output")
        XCTAssertEqual(conv?.last?.sourceContext, .serverError)
    }

    // MARK: - removeLLMMessage Tests

    func testRemoveLLMMessage_removesOnlyTargetedById() throws {
        var (task, stepID) = try createTaskWithStep()
        let keep = LLMMessage(role: .user, content: "keep")
        let drop = LLMMessage(role: .assistant, content: "")  // the pre-created empty turn shape
        TaskMutationService.appendLLMMessage(keep, to: stepID, in: &task)
        TaskMutationService.appendLLMMessage(drop, to: stepID, in: &task)

        TaskMutationService.removeLLMMessage(id: drop.id, from: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.llmConversation.count, 1)
        XCTAssertEqual(step?.llmConversation.first?.id, keep.id, "Only the targeted message is removed")
    }

    func testRemoveLLMMessage_missingStep_isSafeNoOp() throws {
        var (task, stepID) = try createTaskWithStep()
        let msg = LLMMessage(role: .user, content: "x")
        TaskMutationService.appendLLMMessage(msg, to: stepID, in: &task)

        // Unknown step id → locate fails → no-op (no crash, conversation intact).
        TaskMutationService.removeLLMMessage(id: msg.id, from: "no_such_step", in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        XCTAssertEqual(step?.llmConversation.count, 1, "Removing from a missing step must be a safe no-op")
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

    /// `beginStreaming` plants the empty assistant turn at stream START; the
    /// committed turn must be re-stamped to commit time (turn END) so the feed
    /// sorts its bubble adjacent to the tool call / artifact it produced instead
    /// of snapping back to the turn-start position (where a concurrent role's
    /// items would split it across the timeline).
    func testCommitStreamingContent_restampsLLMMessageCreatedAtToCommitTime() throws {
        var (task, stepID) = try createTaskWithStep()

        let messageID = UUID()
        let emptyMsg = LLMMessage(id: messageID, role: .assistant, content: "")
        TaskMutationService.appendLLMMessage(emptyMsg, to: stepID, in: &task)
        let startCreatedAt = task.runs.last!.steps[0]
            .llmConversation.first { $0.id == messageID }!.createdAt

        // Commit at a later monotonic tick (turn END).
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "Final answer", thinking: nil,
            role: .softwareEngineer, in: &task
        )

        let committed = task.runs.last?.steps.first { $0.id == stepID }?
            .llmConversation.first { $0.id == messageID }
        XCTAssertEqual(committed?.content, "Final answer")
        XCTAssertGreaterThan(
            committed!.createdAt, startCreatedAt,
            "Committed turn must be re-stamped to commit time so it sorts adjacent to its tool call, not back at turn-start")
    }

    /// The reported case: a reasoning model writes all prose into the reasoning
    /// channel and the deliverable into the tool call, so the committed content is
    /// empty but thinking is substantial. The turn must STILL be re-stamped so its
    /// content-less "Thinking" bubble groups with its create_artifact card.
    func testCommitStreamingContent_emptyContentWithThinking_restampsCreatedAt() throws {
        var (task, stepID) = try createTaskWithStep()

        let messageID = UUID()
        let emptyMsg = LLMMessage(id: messageID, role: .assistant, content: "")
        TaskMutationService.appendLLMMessage(emptyMsg, to: stepID, in: &task)
        let startCreatedAt = task.runs.last!.steps[0]
            .llmConversation.first { $0.id == messageID }!.createdAt

        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "", thinking: "All the reasoning lives here.",
            role: .softwareEngineer, in: &task
        )

        let committed = task.runs.last?.steps.first { $0.id == stepID }?
            .llmConversation.first { $0.id == messageID }
        XCTAssertEqual(committed?.content, "")
        XCTAssertEqual(committed?.thinking, "All the reasoning lives here.")
        XCTAssertGreaterThan(
            committed!.createdAt, startCreatedAt,
            "A content-empty reasoning+tool-call turn must re-stamp so its Thinking bubble groups with its tool call")
    }

    /// Corner case: committing against a `messageID` that isn't in the conversation
    /// must not re-stamp (or otherwise touch) an unrelated message. Empty content
    /// avoids creating a stray StepMessage, so the conversation is untouched (only
    /// `step.updatedAt` is bumped — not asserted here).
    func testCommitStreamingContent_unknownMessageID_doesNotRestampExistingMessage() throws {
        var (task, stepID) = try createTaskWithStep()

        let realID = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: realID, role: .assistant, content: ""), to: stepID, in: &task)
        let originalCreatedAt = task.runs.last!.steps[0]
            .llmConversation.first { $0.id == realID }!.createdAt

        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: UUID(),
            content: "", thinking: nil,
            role: .softwareEngineer, in: &task
        )

        let msg = task.runs.last?.steps.first { $0.id == stepID }?
            .llmConversation.first { $0.id == realID }
        XCTAssertEqual(
            msg?.createdAt, originalCreatedAt,
            "A commit for a different messageID must not re-stamp an unrelated message")
    }

    /// The load-bearing invariant the re-stamp depends on: `commitStreaming` runs
    /// BEFORE the iteration's `appendToolCalls`, so the re-stamped assistant turn's
    /// `createdAt` stays strictly less than the tool call it produces. This keeps
    /// the feed ordering (bubble → tool call) AND `emitItems`' thinking lookups
    /// (`assistant.createdAt <= call.createdAt`) correct.
    ///
    /// This test uses the singular `appendToolCall` helper as a stand-in for the
    /// production `appendToolCalls` flow: in both, the `StepToolCall` is constructed
    /// AFTER the commit, so it draws a strictly-later monotonic `createdAt`.
    func testCommitStreamingContent_thenAppendToolCall_messageSortsBeforeToolCall() throws {
        var (task, stepID) = try createTaskWithStep()

        let messageID = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: messageID, role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "", thinking: "reasoning, then a tool call",
            role: .softwareEngineer, in: &task)
        let toolCall = StepToolCall(
            name: ToolNames.createArtifact, argumentsJSON: #"{"name":"Research Report"}"#)
        TaskMutationService.appendToolCall(toolCall, to: stepID, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        let msg = step?.llmConversation.first { $0.id == messageID }
        let call = step?.toolCalls.first { $0.id == toolCall.id }
        XCTAssertNotNil(msg)
        XCTAssertNotNil(call)
        XCTAssertLessThan(
            msg!.createdAt, call!.createdAt,
            "Re-stamped assistant turn must sort before the tool call it produced (commit precedes appendToolCalls)")
    }

    /// Multi-iteration step: each turn re-stamps at its own commit, so later turns
    /// keep later timestamps — per-turn grouping/order is preserved, not collapsed.
    func testCommitStreamingContent_multipleIterations_preservePerTurnOrdering() throws {
        var (task, stepID) = try createTaskWithStep()

        let id1 = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: id1, role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: id1, content: "turn 1", thinking: nil,
            role: .softwareEngineer, in: &task)

        let id2 = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: id2, role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: id2, content: "turn 2", thinking: nil,
            role: .softwareEngineer, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        let c1 = step?.llmConversation.first { $0.id == id1 }?.createdAt
        let c2 = step?.llmConversation.first { $0.id == id2 }?.createdAt
        XCTAssertNotNil(c1)
        XCTAssertNotNil(c2)
        XCTAssertLessThan(
            c1!, c2!,
            "Later iterations must keep later commit timestamps so a multi-turn step stays ordered")
    }

    /// Unknown stepID → `locateStepInLatestRun` fails → no-op (no crash, no re-stamp).
    func testCommitStreamingContent_unknownStepID_isSafeNoOp() throws {
        var (task, stepID) = try createTaskWithStep()
        let messageID = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: messageID, role: .assistant, content: "original"), to: stepID, in: &task)
        let before = task.runs.last!.steps[0]
            .llmConversation.first { $0.id == messageID }!.createdAt

        TaskMutationService.commitStreamingContent(
            stepID: "no_such_step", messageID: messageID,
            content: "should not apply", thinking: nil, role: .softwareEngineer, in: &task)

        let msg = task.runs.last?.steps.first { $0.id == stepID }?
            .llmConversation.first { $0.id == messageID }
        XCTAssertEqual(msg?.content, "original", "Unknown stepID must be a no-op — no message mutated")
        XCTAssertEqual(msg?.createdAt, before, "Unknown stepID must not re-stamp")
    }

    /// Degenerate commit (cancelled before any tokens): empty content + nil thinking.
    /// The re-stamp is unconditional once the message is found, and no StepMessage is
    /// created for empty content (the existing rule). No crash.
    func testCommitStreamingContent_emptyContentNilThinking_restampsButCreatesNoStepMessage() throws {
        var (task, stepID) = try createTaskWithStep()
        let messageID = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: messageID, role: .assistant, content: ""), to: stepID, in: &task)
        let before = task.runs.last!.steps[0]
            .llmConversation.first { $0.id == messageID }!.createdAt

        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "", thinking: nil, role: .softwareEngineer, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        let msg = step?.llmConversation.first { $0.id == messageID }
        XCTAssertEqual(msg?.content, "")
        XCTAssertNil(msg?.thinking)
        XCTAssertGreaterThan(msg!.createdAt, before, "Re-stamp is unconditional once the message is found")
        XCTAssertEqual(step?.messages.count, 0, "Empty content must not create a StepMessage")
    }

    /// Deliberate asymmetry: commit re-stamps the `llmConversation` message's
    /// `createdAt` (the feed sort key) but must NOT re-stamp an existing
    /// `StepMessage`'s `createdAt`. `step.messages` ordering feeds PromptBuilder, not
    /// the activity feed — pinned so a future "consistency" refactor that re-stamps
    /// both doesn't silently reorder prompt history.
    func testCommitStreamingContent_existingStepMessage_createdAtNotRestamped() throws {
        var (task, stepID) = try createTaskWithStep()

        let messageID = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: messageID, role: .assistant, content: ""), to: stepID, in: &task)
        TaskMutationService.appendMessage(
            StepMessage(id: messageID, role: .softwareEngineer, content: "partial"),
            to: stepID, in: &task)
        let stepMsgBefore = task.runs.last!.steps[0].messages.first { $0.id == messageID }!.createdAt
        let llmMsgBefore = task.runs.last!.steps[0].llmConversation.first { $0.id == messageID }!.createdAt

        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "final", thinking: nil, role: .softwareEngineer, in: &task)

        let step = task.runs.last?.steps.first { $0.id == stepID }
        let stepMsg = step?.messages.first { $0.id == messageID }
        let llmMsg = step?.llmConversation.first { $0.id == messageID }
        XCTAssertEqual(stepMsg?.content, "final", "StepMessage content is updated")
        XCTAssertEqual(
            stepMsg?.createdAt, stepMsgBefore,
            "Existing StepMessage.createdAt must NOT be re-stamped — it feeds PromptBuilder ordering, not the feed")
        XCTAssertGreaterThan(
            llmMsg!.createdAt, llmMsgBefore,
            "But the llmConversation message (the feed sort key) IS re-stamped")
    }

    /// `thinking` is only written when non-empty (`if let thinking, !thinking.isEmpty`),
    /// but the createdAt re-stamp lives OUTSIDE that guard. So an empty-string `thinking`
    /// commit must preserve any prior thinking yet still re-stamp (exercises the
    /// `!isEmpty` half of the guard — the `nil` half is covered by the empty/nil test).
    func testCommitStreamingContent_emptyStringThinking_preservesPriorThinking_butStillRestamps() throws {
        var (task, stepID) = try createTaskWithStep()
        let messageID = UUID()
        TaskMutationService.appendLLMMessage(
            LLMMessage(id: messageID, role: .assistant, content: "", thinking: "prior reasoning"),
            to: stepID, in: &task)
        let before = task.runs.last!.steps[0]
            .llmConversation.first { $0.id == messageID }!.createdAt

        TaskMutationService.commitStreamingContent(
            stepID: stepID, messageID: messageID,
            content: "answer", thinking: "",   // empty string → must NOT overwrite
            role: .softwareEngineer, in: &task)

        let msg = task.runs.last?.steps.first { $0.id == stepID }?
            .llmConversation.first { $0.id == messageID }
        XCTAssertEqual(msg?.content, "answer")
        XCTAssertEqual(msg?.thinking, "prior reasoning",
                       "Empty-string thinking must not overwrite existing thinking")
        XCTAssertGreaterThan(msg!.createdAt, before, "Re-stamp happens regardless of the thinking guard")
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
        var (context, _) = try repository.createTask(at: tempDir, title: "Multi-Run Task", supervisorTask: "Goal")
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
