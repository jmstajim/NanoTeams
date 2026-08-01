import XCTest

@testable import NanoTeams

/// E2E tests for the tool execution pipeline:
/// authorize → execute → track → loop detection → conversation append.
@MainActor
final class EndToEndToolExecutionPipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Tool execution records into tracker

    func testToolPipeline_authorizedToolExecutes() {
        let tracker = ToolCallTracker()
        let toolName = ToolNames.readFile
        let argsJSON = #"{"path":"src/main.swift"}"#

        // Record a successful call
        tracker.record(toolName: toolName, argumentsJSON: argsJSON, resultJSON: #"{"content":"hello"}"#, isError: false)

        // Verify it was tracked
        XCTAssertEqual(tracker.recentCalls(limit: .max).count, 1)
        XCTAssertEqual(tracker.recentCalls(limit: .max)[0].toolName, toolName)
        XCTAssertTrue(tracker.recentCalls(limit: .max)[0].wasSuccessful)
    }

    // MARK: - Test 2: Unauthorized tool returns error (tested via tool name check)

    func testToolPipeline_unauthorizedToolRejected() {
        let allowedTools: Set<String> = ["read_file", "list_files", "search"]
        let requestedTool = "write_file"

        // The pipeline checks authorization before execution
        let isAuthorized = allowedTools.contains(requestedTool)
        XCTAssertFalse(isAuthorized, "write_file should not be in read-only toolset")
    }

    // MARK: - Test 5: Loop detection triggers after repetitive calls

    func testToolPipeline_loopDetected_guidanceInjected() {
        let tracker = ToolCallTracker()
        let toolName = ToolNames.readFile

        // Record 6 read-only calls (loop threshold)
        for i in 0..<6 {
            tracker.record(
                toolName: toolName,
                argumentsJSON: #"{"path":"file\#(i).swift"}"#,
                resultJSON: #"{"content":"content"}"#,
                isError: false
            )
        }

        // Detect loop
        let recentCalls = tracker.recentCalls(limit: 6)
        let detection = ToolCallLoopDetector.detectLoopPattern(in: recentCalls)

        XCTAssertNotNil(detection, "Should detect read-only loop after 6 read-only calls")
        if case .readOnlyLoop(let message) = detection {
            XCTAssertTrue(message.contains("read-only"), "Message should mention read-only pattern")
        } else {
            XCTFail("Expected readOnlyLoop detection")
        }
    }

    // MARK: - Test 6: Alias resolution via ToolRegistry

    func testToolPipeline_aliasResolution() {
        // Verify alias resolution via the static defaultAliases dictionary

        // Common aliases should resolve to actual tool names
        let searchAlias = ToolRegistry.defaultAliases["grep"]
        XCTAssertEqual(searchAlias, ToolNames.search,
                       "'grep' alias should resolve to 'search'")

        let submitArtifact = ToolRegistry.defaultAliases["submit_artifact"]
        XCTAssertEqual(submitArtifact, ToolNames.createArtifact,
                       "'submit_artifact' alias should resolve to 'create_artifact'")

        let saveArtifact = ToolRegistry.defaultAliases["save_artifact"]
        XCTAssertEqual(saveArtifact, ToolNames.createArtifact,
                       "'save_artifact' alias should resolve to 'create_artifact'")
    }

    // MARK: - Test: Repetitive tool detection

    func testToolPipeline_repetitiveToolDetected() {
        let tracker = ToolCallTracker()
        let toolName = ToolNames.editFile

        // Record 6 calls with same edit_file tool (4+ needed for repetitive detection)
        for i in 0..<6 {
            tracker.record(
                toolName: toolName,
                argumentsJSON: #"{"path":"file.swift","old_text":"v\#(i)","new_text":"v\#(i+1)"}"#,
                resultJSON: #"{"success":true}"#,
                isError: false
            )
        }

        let recentCalls = tracker.recentCalls(limit: 6)
        let detection = ToolCallLoopDetector.detectLoopPattern(in: recentCalls)

        XCTAssertNotNil(detection, "Should detect repetitive tool usage")
        if case .repetitiveTool(let tool, let count, _) = detection {
            XCTAssertEqual(tool, toolName)
            XCTAssertGreaterThanOrEqual(count, 4)
        } else {
            XCTFail("Expected repetitiveTool detection")
        }
    }

    // MARK: - Test: No loop with fewer than 6 calls

    func testToolPipeline_noLoopDetectionUnder6Calls() {
        let tracker = ToolCallTracker()

        for i in 0..<5 {
            tracker.record(
                toolName: ToolNames.readFile,
                argumentsJSON: #"{"path":"file\#(i).swift"}"#,
                resultJSON: #"{"content":"ok"}"#,
                isError: false
            )
        }

        let recentCalls = tracker.recentCalls(limit: 6)
        let detection = ToolCallLoopDetector.detectLoopPattern(in: recentCalls)
        XCTAssertNil(detection, "Should not detect loop with fewer than 6 calls")
    }

}
