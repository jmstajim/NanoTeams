import XCTest
@testable import NanoTeams

/// Tests for StepStatus, StepExecution, StepMessage, StepToolCall, and LLMMessage
final class StepStatusTests: XCTestCase {

    // MARK: - StepStatus Enum Tests

    func testStepStatusAllCases() {
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

    func testStepStatusRawValues() {
        XCTAssertEqual(StepStatus.pending.rawValue, "pending")
        XCTAssertEqual(StepStatus.running.rawValue, "running")
        XCTAssertEqual(StepStatus.paused.rawValue, "paused")
        XCTAssertEqual(StepStatus.needsSupervisorInput.rawValue, "needsSupervisorInput")
        XCTAssertEqual(StepStatus.needsApproval.rawValue, "needsApproval")
        XCTAssertEqual(StepStatus.failed.rawValue, "failed")
        XCTAssertEqual(StepStatus.done.rawValue, "done")
    }

    func testStepStatusDisplayLabel() {
        XCTAssertEqual(StepStatus.pending.displayLabel, "Pending")
        XCTAssertEqual(StepStatus.running.displayLabel, "Running")
        XCTAssertEqual(StepStatus.paused.displayLabel, "Paused")
        XCTAssertEqual(StepStatus.needsSupervisorInput.displayLabel, "Needs Supervisor input")
        XCTAssertEqual(StepStatus.needsApproval.displayLabel, "Needs review")
        XCTAssertEqual(StepStatus.failed.displayLabel, "Failed")
        XCTAssertEqual(StepStatus.done.displayLabel, "Done")
    }

    func testStepStatusShortDisplayLabel() {
        // Most cases return the same as displayLabel
        XCTAssertEqual(StepStatus.pending.shortDisplayLabel, "Pending")
        XCTAssertEqual(StepStatus.running.shortDisplayLabel, "Running")
        XCTAssertEqual(StepStatus.paused.shortDisplayLabel, "Paused")
        XCTAssertEqual(StepStatus.failed.shortDisplayLabel, "Failed")
        XCTAssertEqual(StepStatus.done.shortDisplayLabel, "Done")

        // Special shortened versions
        XCTAssertEqual(StepStatus.needsSupervisorInput.shortDisplayLabel, "Needs Supervisor")
        XCTAssertEqual(StepStatus.needsApproval.shortDisplayLabel, "Needs review")
    }

    func testStepStatusSystemImageName() {
        XCTAssertEqual(StepStatus.pending.systemImageName, "circle.dotted")
        XCTAssertEqual(StepStatus.running.systemImageName, "circle.inset.filled")
        XCTAssertEqual(StepStatus.paused.systemImageName, "pause.circle.fill")
        XCTAssertEqual(StepStatus.needsSupervisorInput.systemImageName, "questionmark.bubble.fill")
        XCTAssertEqual(StepStatus.needsApproval.systemImageName, "checkmark.seal.fill")
        XCTAssertEqual(StepStatus.failed.systemImageName, "xmark.circle.fill")
        XCTAssertEqual(StepStatus.done.systemImageName, "checkmark.circle.fill")
    }

    func testStepStatusHashable() {
        var statusSet = Set<StepStatus>()
        statusSet.insert(.pending)
        statusSet.insert(.pending)
        statusSet.insert(.running)

        XCTAssertEqual(statusSet.count, 2)
    }

    func testStepStatusCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in StepStatus.allCases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(StepStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - StepExecution Tests

    func testStepExecutionDefaultInit() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Write code")

        XCTAssertEqual(step.role, .softwareEngineer)
        XCTAssertEqual(step.title, "Write code")
        XCTAssertTrue(step.expectedArtifacts.isEmpty)
        XCTAssertEqual(step.status, .pending)
        XCTAssertTrue(step.messages.isEmpty)
        XCTAssertTrue(step.artifacts.isEmpty)
        XCTAssertTrue(step.toolCalls.isEmpty)
        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertNil(step.supervisorQuestion)
        XCTAssertNil(step.supervisorAnswer)
        XCTAssertNil(step.supervisorCommentForNext)
        XCTAssertTrue(step.llmConversation.isEmpty)
    }

    func testStepExecutionFullInit() {
        let customID = "custom_step"
        let customDate = Date(timeIntervalSince1970: 1000)
        let message = StepMessage(role: .softwareEngineer, content: "Working on it")
        let artifact = Artifact(name: "Code")
        let toolCall = StepToolCall(name: "read_file", argumentsJSON: "{}")
        let llmMessage = LLMMessage(role: .assistant, content: "Done")

        let step = StepExecution(
            id: customID,
            role: .sre,
            title: "QA Testing",
            expectedArtifacts: ["Test Plan"],
            status: .running,
            createdAt: customDate,
            updatedAt: customDate,
            messages: [message],
            artifacts: [artifact],
            toolCalls: [toolCall],
            needsSupervisorInput: true,
            supervisorQuestion: "What should I test?",
            supervisorAnswer: "Test everything",
            supervisorCommentForNext: "Good job",
            llmConversation: [llmMessage]
        )

        XCTAssertEqual(step.id, customID)
        XCTAssertEqual(step.role, .sre)
        XCTAssertEqual(step.title, "QA Testing")
        XCTAssertEqual(step.expectedArtifacts, ["Test Plan"])
        XCTAssertEqual(step.status, .running)
        XCTAssertEqual(step.createdAt, customDate)
        XCTAssertEqual(step.messages.count, 1)
        XCTAssertEqual(step.artifacts.count, 1)
        XCTAssertEqual(step.toolCalls.count, 1)
        XCTAssertTrue(step.needsSupervisorInput)
        XCTAssertEqual(step.supervisorQuestion, "What should I test?")
        XCTAssertEqual(step.supervisorAnswer, "Test everything")
        XCTAssertEqual(step.supervisorCommentForNext, "Good job")
        XCTAssertEqual(step.llmConversation.count, 1)
    }

    func testStepExecutionCodable() throws {
        let original = StepExecution(
            id: "test_step",
            role: .uxDesigner,
            title: "Design UI",
            status: .done,
            scratchpad: "Design completed"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StepExecution.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.scratchpad, original.scratchpad)
    }

    func testStepExecutionDecodeWithMissingOptionals() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "role": "softwareEngineer",
            "title": "Minimal Step"
        }
        """

        let decoder = JSONDecoder()
        let step = try decoder.decode(StepExecution.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(step.title, "Minimal Step")
        XCTAssertEqual(step.role, .softwareEngineer)
        XCTAssertEqual(step.status, .pending) // default
        XCTAssertTrue(step.messages.isEmpty)
        XCTAssertFalse(step.needsSupervisorInput) // default
    }

    func testStepExecutionHashable() {
        let step1 = StepExecution(id: "test_step", role: .uxDesigner, title: "Design")
        let step2 = StepExecution(id: "test_step", role: .uxDesigner, title: "Design")

        var stepSet = Set<StepExecution>()
        stepSet.insert(step1)
        stepSet.insert(step2)

        // Different IDs means different hashes
        XCTAssertEqual(stepSet.count, 2)
    }

    // MARK: - StepMessage Tests

    func testStepMessageDefaultInit() {
        let message = StepMessage(role: .supervisor, content: "Please proceed")

        XCTAssertNotNil(message.id)
        XCTAssertEqual(message.role, .supervisor)
        XCTAssertEqual(message.content, "Please proceed")
    }

    func testStepMessageFullInit() {
        let customID = UUID()
        let customDate = Date(timeIntervalSince1970: 500)

        let message = StepMessage(
            id: customID,
            createdAt: customDate,
            role: .productManager,
            content: "Requirements defined"
        )

        XCTAssertEqual(message.id, customID)
        XCTAssertEqual(message.createdAt, customDate)
        XCTAssertEqual(message.role, .productManager)
        XCTAssertEqual(message.content, "Requirements defined")
    }

    func testStepMessageCodable() throws {
        let original = StepMessage(role: .tpm, content: "Planning complete")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StepMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
    }

    func testStepMessageHashable() {
        let msg1 = StepMessage(role: .sre, content: "Test")
        let msg2 = StepMessage(role: .sre, content: "Test")

        var msgSet = Set<StepMessage>()
        msgSet.insert(msg1)
        msgSet.insert(msg2)

        XCTAssertEqual(msgSet.count, 2) // Different IDs
    }

    // MARK: - StepToolCall Tests

    func testStepToolCallDefaultInit() {
        let toolCall = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"test.txt\"}")

        XCTAssertNotNil(toolCall.id)
        XCTAssertNil(toolCall.providerID)
        XCTAssertEqual(toolCall.name, "read_file")
        XCTAssertEqual(toolCall.argumentsJSON, "{\"path\": \"test.txt\"}")
        XCTAssertNil(toolCall.resultJSON)
        XCTAssertNil(toolCall.isError)
    }

    func testStepToolCallFullInit() {
        let customID = UUID()
        let customDate = Date(timeIntervalSince1970: 750)

        let toolCall = StepToolCall(
            id: customID,
            createdAt: customDate,
            providerID: "call_abc123",
            name: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"status\": \"clean\"}",
            isError: false
        )

        XCTAssertEqual(toolCall.id, customID)
        XCTAssertEqual(toolCall.createdAt, customDate)
        XCTAssertEqual(toolCall.providerID, "call_abc123")
        XCTAssertEqual(toolCall.name, "git_status")
        XCTAssertEqual(toolCall.argumentsJSON, "{}")
        XCTAssertEqual(toolCall.resultJSON, "{\"status\": \"clean\"}")
        XCTAssertEqual(toolCall.isError, false)
    }

    func testStepToolCallWithError() {
        let toolCall = StepToolCall(
            name: "edit_file",
            argumentsJSON: "{\"path\": \"invalid\"}",
            resultJSON: "Error: File not found",
            isError: true
        )

        XCTAssertEqual(toolCall.name, "edit_file")
        XCTAssertEqual(toolCall.isError, true)
    }

    func testStepToolCallCodable() throws {
        let original = StepToolCall(
            providerID: "call_xyz",
            name: "list_files",
            argumentsJSON: "{\"path\": \"/src\"}",
            resultJSON: "[\"file1.swift\", \"file2.swift\"]",
            isError: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StepToolCall.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.providerID, original.providerID)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.argumentsJSON, original.argumentsJSON)
        XCTAssertEqual(decoded.resultJSON, original.resultJSON)
        XCTAssertEqual(decoded.isError, original.isError)
    }

    func testStepToolCallHashable() {
        let call1 = StepToolCall(name: "git_status", argumentsJSON: "{}")
        let call2 = StepToolCall(name: "git_status", argumentsJSON: "{}")

        var callSet = Set<StepToolCall>()
        callSet.insert(call1)
        callSet.insert(call2)

        XCTAssertEqual(callSet.count, 2)
    }

    // MARK: - LLMMessage Tests

    func testLLMMessageDefaultInit() {
        let msg = LLMMessage(role: .user, content: "Hello")

        XCTAssertNotNil(msg.id)
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello")
    }

    func testLLMMessageFullInit() {
        let customID = UUID()
        let customDate = Date(timeIntervalSince1970: 2000)

        let msg = LLMMessage(
            id: customID,
            createdAt: customDate,
            role: .assistant,
            content: "I can help with that."
        )

        XCTAssertEqual(msg.id, customID)
        XCTAssertEqual(msg.createdAt, customDate)
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "I can help with that.")
    }

    func testLLMMessageRoles() {
        let systemMsg = LLMMessage(role: .system, content: "You are a helpful assistant.")
        let userMsg = LLMMessage(role: .user, content: "What is 2+2?")
        let assistantMsg = LLMMessage(role: .assistant, content: "2+2 equals 4.")
        let toolMsg = LLMMessage(role: .tool, content: "{\"result\": 4}")

        XCTAssertEqual(systemMsg.role, .system)
        XCTAssertEqual(userMsg.role, .user)
        XCTAssertEqual(assistantMsg.role, .assistant)
        XCTAssertEqual(toolMsg.role, .tool)
    }

    func testLLMMessageCodable() throws {
        let original = LLMMessage(role: .system, content: "You are a software engineer.")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LLMMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
    }

    func testLLMMessageHashable() {
        let msg1 = LLMMessage(role: .user, content: "Test")
        let msg2 = LLMMessage(role: .user, content: "Test")

        var msgSet = Set<LLMMessage>()
        msgSet.insert(msg1)
        msgSet.insert(msg2)

        XCTAssertEqual(msgSet.count, 2)
    }

    // MARK: - StepExecution Status Transition Tests

    func testStepExecutionStatusTransitions() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Code")

        XCTAssertEqual(step.status, .pending)

        step.status = .running
        XCTAssertEqual(step.status, .running)

        step.status = .needsSupervisorInput
        XCTAssertEqual(step.status, .needsSupervisorInput)

        step.status = .running
        XCTAssertEqual(step.status, .running)

        step.status = .needsApproval
        XCTAssertEqual(step.status, .needsApproval)

        step.status = .done
        XCTAssertEqual(step.status, .done)
    }

    func testStepExecutionWithSupervisorInteraction() {
        var step = StepExecution(id: "test_step", role: .productManager, title: "Product Requirements")

        step.needsSupervisorInput = true
        step.supervisorQuestion = "What features are most important?"
        step.status = .needsSupervisorInput

        XCTAssertTrue(step.needsSupervisorInput)
        XCTAssertEqual(step.supervisorQuestion, "What features are most important?")
        XCTAssertNil(step.supervisorAnswer)

        step.supervisorAnswer = "Focus on user authentication first."
        step.needsSupervisorInput = false
        step.status = .running

        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertEqual(step.supervisorAnswer, "Focus on user authentication first.")
    }

    // MARK: - Complex StepExecution Scenarios

    func testStepExecutionWithMultipleMessages() {
        let messages = [
            StepMessage(role: .supervisor, content: "Please start"),
            StepMessage(role: .softwareEngineer, content: "Starting implementation"),
            StepMessage(role: .softwareEngineer, content: "Implementation complete")
        ]

        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Implementation",
            status: .done,
            messages: messages
        )

        XCTAssertEqual(step.messages.count, 3)
        XCTAssertEqual(step.messages.first?.role, .supervisor)
        XCTAssertEqual(step.messages.last?.content, "Implementation complete")
    }

    func testStepExecutionWithMultipleToolCalls() {
        let toolCalls = [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"src/main.swift\"}", resultJSON: "file content"),
            StepToolCall(name: "edit_file", argumentsJSON: "{\"path\": \"src/main.swift\"}", resultJSON: "success"),
            StepToolCall(name: "git_status", argumentsJSON: "{}", resultJSON: "{\"clean\": false}")
        ]

        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Code changes",
            toolCalls: toolCalls
        )

        XCTAssertEqual(step.toolCalls.count, 3)
        XCTAssertEqual(step.toolCalls[0].name, "read_file")
        XCTAssertEqual(step.toolCalls[1].name, "edit_file")
        XCTAssertEqual(step.toolCalls[2].name, "git_status")
    }

    func testStepExecutionWithLLMConversation() {
        let conversation = [
            LLMMessage(role: .system, content: "You are a software engineer."),
            LLMMessage(role: .user, content: "Implement the login feature."),
            LLMMessage(role: .assistant, content: "I'll implement the login feature now.")
        ]

        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Login implementation",
            llmConversation: conversation
        )

        XCTAssertEqual(step.llmConversation.count, 3)
        XCTAssertEqual(step.llmConversation[0].role, .system)
        XCTAssertEqual(step.llmConversation[1].role, .user)
        XCTAssertEqual(step.llmConversation[2].role, .assistant)
    }
}
