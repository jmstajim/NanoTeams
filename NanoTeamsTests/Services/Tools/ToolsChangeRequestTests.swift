import XCTest

@testable import NanoTeams

final class ToolsChangeRequestTests: XCTestCase {
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
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Registration

    func testRequestChanges_isRegistered() {
        XCTAssertTrue(registry.registeredToolNames.contains("request_changes"))
    }

    // MARK: - Valid Requests

    func testRequestChanges_validRequest() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "softwareEngineer",
                "changes": "Add error handling for network failures",
                "reasoning": "The current code silently fails on timeout"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .changeRequest(targetRole: "softwareEngineer", changes: "Add error handling for network failures", reasoning: "The current code silently fails on timeout"))
    }

    func testRequestChanges_outputContainsPendingStatus() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "softwareEngineer",
                "changes": "Fix bug",
                "reasoning": "It crashes"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].outputJSON.contains("pending"))
    }

    // MARK: - Invalid Requests

    func testRequestChanges_unknownTargetRole_delegatesToService() {
        // Unknown role IDs are no longer rejected at the tool level — validation is
        // delegated to LLMExecutionService+ChangeRequest which has team context.
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "nonexistentRole",
                "changes": "Fix stuff",
                "reasoning": "Because"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .changeRequest(targetRole: "nonexistentRole", changes: "Fix stuff", reasoning: "Because"))
    }

    func testRequestChanges_missingTargetRole() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "changes": "Fix stuff",
                "reasoning": "Because"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    func testRequestChanges_missingChanges() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "softwareEngineer",
                "reasoning": "Because"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    func testRequestChanges_missingReasoning() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "softwareEngineer",
                "changes": "Fix bug"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - Signaling Fields

    func testRequestChanges_signalingFieldsNotSetOnOtherTools() {
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: """
            {
                "teammate": "softwareEngineer",
                "question": "How should I implement the caching layer?"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        // ask_teammate produces a teammateConsultation signal, not a changeRequest
        if case .changeRequest = results[0].signal { XCTFail("ask_teammate must not produce changeRequest signal") }
    }

    // MARK: - Data Structure Tests

    func testRequestChangesData_codable() throws {
        let data = RequestChangesData(
            targetRole: "softwareEngineer",
            changes: "Add retry logic",
            reasoning: "Network can fail",
            status: "pending"
        )

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(RequestChangesData.self, from: encoded)

        XCTAssertEqual(decoded.targetRole, "softwareEngineer")
        XCTAssertEqual(decoded.changes, "Add retry logic")
        XCTAssertEqual(decoded.reasoning, "Network can fail")
        XCTAssertEqual(decoded.status, "pending")
    }
}
