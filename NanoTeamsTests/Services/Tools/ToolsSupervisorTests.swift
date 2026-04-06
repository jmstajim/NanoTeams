import XCTest

@testable import NanoTeams

final class ToolsSupervisorTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var registry: ToolRegistry!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (reg, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        registry = reg
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        registry = nil
//        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - ask_supervisor Tool Registration

    func testAskSupervisorToolRegistered() {
        let toolNames = registry.registeredToolNames

        XCTAssertTrue(toolNames.contains("ask_supervisor"))
    }

    // MARK: - ask_supervisor Basic Functionality

    func testAskSupervisor_withQuestion() {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Should we proceed with the refactoring?\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("Should we proceed with the refactoring?"))
    }

    func testAskSupervisor_alwaysPauses() {
        // Even if LLM passes "required": false, the step always pauses
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Any preferences?\", \"required\": false}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("Any preferences?"))
        // Output should contain "pending" status (always pauses)
        XCTAssertTrue(results[0].outputJSON.contains("pending"))
    }

    // MARK: - ask_supervisor Error Cases

    func testAskSupervisor_missingQuestion() {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
        XCTAssertTrue(results[0].outputJSON.contains("question"))
    }

    func testAskSupervisor_emptyQuestion() {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        // Empty string is still a valid string, tool should accept it
        // (Validation of empty questions would be a business logic concern)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion(""))
    }

    func testAskSupervisor_invalidJSON_recoversViaRawInput() {
        // Invalid JSON is recovered — plain string treated as the question
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "invalid json"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("invalid json"))
    }

    // MARK: - ask_supervisor Output Format

    func testAskSupervisor_outputContainsPendingStatus() {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Test question?\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outputJSON.contains("pending"))
    }

    func testAskSupervisor_outputContainsQuestion() {
        let question = "What color should the button be?"
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(question)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outputJSON.contains(question))
    }

    func testAskSupervisor_outputIsValidJSON() {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Test?\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)

        // Verify output is valid JSON
        let outputData = results[0].outputJSON.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: outputData))
    }

    // MARK: - ask_supervisor with Special Characters

    func testAskSupervisor_questionWithSpecialCharacters() {
        let question = "Should we use 'single quotes' or \"double quotes\"?"
        let escapedQuestion = question
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(escapedQuestion)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion(question))
    }

    func testAskSupervisor_questionWithNewlines() {
        let question = "Line 1\\nLine 2\\nLine 3"
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(question)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testAskSupervisor_questionWithUnicode() {
        let question = "Should we support emoji? 🎉"
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(question)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion(question))
    }

    // MARK: - AskSupervisorData Structure Tests

    func testAskSupervisorData_codable() throws {
        let data = AskSupervisorData(
            question: "Test question",
            status: "pending"
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(data)
        let decoded = try JSONDecoder().decode(AskSupervisorData.self, from: encoded)

        XCTAssertEqual(decoded.question, "Test question")
        XCTAssertEqual(decoded.status, "pending")
    }
}
