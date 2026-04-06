import XCTest

@testable import NanoTeams

final class ToolsMemoryTests: XCTestCase {
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

    // MARK: - Tool Registration

    func testUpdateScratchpadRegistered() {
        let toolNames = registry.registeredToolNames

        XCTAssertTrue(toolNames.contains("update_scratchpad"))
    }

    // MARK: - update_scratchpad Basic Functionality

    func testUpdateScratchpad_validContent() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"My notes for this step\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("updated"))
        XCTAssertTrue(results[0].outputJSON.contains("true"))
    }

    func testUpdateScratchpad_contentLengthReported() {
        let content = "This is a test content with specific length"
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        // The output should contain content_length
        XCTAssertTrue(results[0].outputJSON.contains("content_length"))
        XCTAssertTrue(results[0].outputJSON.contains("\(content.count)"))
    }

    func testUpdateScratchpad_emptyContent() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        // Empty content is valid - it clears the scratchpad
        XCTAssertTrue(results[0].outputJSON.contains("content_length\":0") ||
                      results[0].outputJSON.contains("content_length\": 0"))
    }

    func testUpdateScratchpad_missingContent() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - update_scratchpad Content Resolution Fallbacks

    func testUpdateScratchpad_textArgFallback() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"text\": \"My notes via text arg\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"updated\":true"))
    }

    func testUpdateScratchpad_planArgFallback() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"plan\": \"Step 1: Do something\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_bodyArgFallback() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"body\": \"Some body content\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_emptyArgsStillFails() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - update_scratchpad Content Types

    func testUpdateScratchpad_multilineContent() {
        let content = "Line 1\\nLine 2\\nLine 3"
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_jsonContent() {
        let content = "{\\\"key\\\": \\\"value\\\", \\\"nested\\\": {\\\"a\\\": 1}}"
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_codeContent() {
        let content = "func hello() {\\n    print(\\\"Hello, World!\\\")\\n}"
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_unicodeContent() {
        let content = "Notes: 日本語テスト 🎉 émojis"
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_largeContent() {
        let content = String(repeating: "x", count: 10000)
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("10000"))
    }

    // MARK: - Output Format Tests

    func testUpdateScratchpad_outputIsValidJSON() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"test\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)

        let outputData = results[0].outputJSON.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: outputData))
    }

    func testUpdateScratchpad_outputContainsOk() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"test\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outputJSON.contains("\"ok\":true") ||
                      results[0].outputJSON.contains("\"ok\": true"))
    }

    // MARK: - Error Cases

    func testUpdateScratchpad_invalidJSON_recoversViaRawInput() {
        // Invalid JSON is recovered — plain string treated as content
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "not valid json"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testUpdateScratchpad_nullContent() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": null}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        // null is not a string, so this should fail
        XCTAssertTrue(results[0].isError)
    }

    func testUpdateScratchpad_numericContent() {
        let call = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": 12345}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        // Number is not a string, so this should fail
        XCTAssertTrue(results[0].isError)
    }

    // MARK: - Multiple Calls

    func testUpdateScratchpad_multipleCalls() {
        let call1 = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"First update\"}"
        )
        let call2 = StepToolCall(
            name: "update_scratchpad",
            argumentsJSON: "{\"content\": \"Second update\"}"
        )

        let results1 = runtime.executeAll(context: context, toolCalls: [call1])
        let results2 = runtime.executeAll(context: context, toolCalls: [call2])

        XCTAssertFalse(results1[0].isError)
        XCTAssertFalse(results2[0].isError)

        // Second call should show different content length
        XCTAssertTrue(results1[0].outputJSON.contains("12"))  // "First update".count
        XCTAssertTrue(results2[0].outputJSON.contains("13"))  // "Second update".count
    }
}
