import XCTest
@testable import NanoTeams

/// Tests for ToolCallTracker — per-step tool-call recording, recent-calls snapshot,
/// scratchpad-dedup, max-tracked eviction, and downstream loop-detector integration.
/// Result-caching/invalidation no longer exist (hard-off); identical-write guard is
/// exercised by `IdenticalWriteLoopGuardTests`.
final class ToolCallTrackerTests: XCTestCase {

    var tracker: ToolCallTracker!

    override func setUp() {
        super.setUp()
        tracker = ToolCallTracker()
    }

    override func tearDown() {
        tracker = nil
        super.tearDown()
    }

    // MARK: - Record Tests

    func testRecordSingleToolCall() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 10)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "read_file")
        XCTAssertTrue(calls[0].wasSuccessful)
    }

    func testRecordMultipleToolCalls() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 10)
        XCTAssertEqual(calls.count, 3)
    }

    func testRecordErrorCall() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"nonexistent.swift\"}",
            resultJSON: "{\"error\": \"File not found\"}",
            isError: true
        )

        let calls = tracker.recentCalls(limit: 10)
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].wasSuccessful)
    }

    // MARK: - Recent Calls Tests

    func testRecentCallsLimitWorks() {
        for i in 0..<10 {
            tracker.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let calls = tracker.recentCalls(limit: 5)
        XCTAssertEqual(calls.count, 5)
    }

    func testRecentCallsReturnsLatest() {
        tracker.record(
            toolName: "first",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "second",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "third",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 2)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].toolName, "second")
        XCTAssertEqual(calls[1].toolName, "third")
    }

    func testRecentCallsEmptyTracker() {
        let calls = tracker.recentCalls(limit: 10)
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Max Tracked Calls Limit Tests

    func testMaxTrackedCallsLimit() {
        // Record more than maxTrackedCalls (30)
        for i in 0..<40 {
            tracker.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let calls = tracker.recentCalls(limit: 100)

        // Should be limited to 30
        XCTAssertEqual(calls.count, 30)
    }

    func testOldCallsRemovedWhenLimitExceeded() {
        // Record more than limit
        for i in 0..<35 {
            tracker.record(
                toolName: "tool_\(i)",
                argumentsJSON: "{}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let calls = tracker.recentCalls(limit: 100)

        // First 5 should be removed (35 - 30 = 5)
        let toolNames = calls.map { $0.toolName }
        XCTAssertFalse(toolNames.contains("tool_0"))
        XCTAssertFalse(toolNames.contains("tool_4"))
        XCTAssertTrue(toolNames.contains("tool_5"))
        XCTAssertTrue(toolNames.contains("tool_34"))
    }

    // MARK: - Argument Summary Tests

    func testArgumentSummaryForSearchProject() {
        tracker.record(
            toolName: "search",
            argumentsJSON: "{\"query\": \"TODO\", \"paths\": [\"src\", \"lib\"]}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].argumentsSummary.contains("TODO"))
        XCTAssertTrue(calls[0].argumentsSummary.contains("2 paths"))
    }

    func testArgumentSummaryForGitCommit() {
        tracker.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"This is a very long commit message that should be truncated\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].argumentsSummary.contains("..."))
        XCTAssertLessThanOrEqual(calls[0].argumentsSummary.count, 35)
    }

    func testArgumentSummaryForGitBranch() {
        tracker.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/new\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        // argumentsSummary now returns just the branch name; action is handled in generateStateContext
        XCTAssertEqual(calls[0].argumentsSummary, "feature/new")
    }

    // MARK: - Result Summary Tests

    func testResultSummaryForGitStatusClean() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("clean"))
        XCTAssertTrue(calls[0].resultSummary.contains("main"))
    }

    func testResultSummaryForGitStatusDirty() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature\", \"clean\": false}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("dirty"))
    }

    func testResultSummaryForBuildSuccess() {
        tracker.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": true}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertEqual(calls[0].resultSummary, "success")
    }

    func testResultSummaryForBuildFailure() {
        tracker.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": false, \"error_count\": 5}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("failed"))
        XCTAssertTrue(calls[0].resultSummary.contains("5 errors"))
    }

    func testResultSummaryForReadFile() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"end_line\": 100, \"total_lines\": 250}}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("lines 1–100 of 250"))
    }

    func testResultSummaryForError() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"missing.swift\"}",
            resultJSON: "{\"error\": {\"message\": \"File not found\"}}",
            isError: true
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("error"))
        XCTAssertTrue(calls[0].resultSummary.contains("File not found"))
    }

    // MARK: - Loop Detection Tests

    func testDetectLoopPatternNilWhenFewCalls() {
        // Less than 6 calls - no loop detection
        for i in 0..<5 {
            tracker.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6)))
    }

    func testDetectLoopPatternReadOnlyLoop() {
        // 6 consecutive read-only calls
        let readOnlyTools = ["read_file", "git_status", "list_files", "read_lines", "git_branch_list", "search"]

        for tool in readOnlyTools {
            tracker.record(
                toolName: tool,
                argumentsJSON: "{}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let loop = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))
        XCTAssertNotNil(loop)

        if case .readOnlyLoop(let message) = loop {
            XCTAssertTrue(message.contains("read-only"))
        } else {
            XCTFail("Expected readOnlyLoop")
        }
    }

    func testDetectLoopPatternRepetitiveTool() {
        // Add write tool to prevent readOnlyLoop from triggering
        tracker.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        // Call git_status 4 times out of last 6
        tracker.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        let loop = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))
        XCTAssertNotNil(loop)

        if case .repetitiveTool(let tool, let count, _) = loop {
            XCTAssertEqual(tool, "git_status")
            XCTAssertEqual(count, 4)
        } else {
            XCTFail("Expected repetitiveTool")
        }
    }

    func testDetectLoopPatternNilWithMixedCalls() {
        // Mixed read and write calls - no loop
        tracker.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_commit", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "edit_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6)))
    }

    // MARK: - Conversation Log Issue Tests (from log analysis)
    // These tests are based on issues discovered in actual conversation logs

    func testRepetitiveToolDetectionForGitAdd() {
        // Issue: git_add was called 6+ times consecutively without commit
        // Loop detection should catch this
        tracker.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        let loop = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))

        XCTAssertNotNil(loop, "Should detect git_add being called repeatedly")
        if case .repetitiveTool(let tool, let count, _) = loop {
            XCTAssertEqual(tool, "git_add")
            XCTAssertGreaterThanOrEqual(count, 4)
        } else {
            XCTFail("Expected repetitiveTool detection")
        }
    }

    func testLoopDetectionMessageIsActionable() {
        // Verify loop detection messages provide actionable guidance
        tracker.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        let loop = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))

        XCTAssertNotNil(loop)
        let message = loop?.message ?? ""
        // Message should:
        // 1. Identify the tool
        XCTAssertTrue(message.contains("git_add"), "Message should identify the tool")
        // 2. Show count
        XCTAssertTrue(message.contains("4") || message.contains("5") || message.contains("6"), "Message should show count")
        // 3. Suggest trying a different approach
        XCTAssertTrue(message.lowercased().contains("different") || message.lowercased().contains("try"), "Message should suggest alternative")
    }

    // MARK: - Additional Conversation Log Issues (Round 2)

    func testGitAddArgumentsSummaryNotEmpty() {
        // Issue: git_add falls through to default case in summarizeArguments
        // returning empty string, causing "Staged:" entries with no content
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\", \"utils.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\", \"utils.swift\"]}, \"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertEqual(calls.count, 1)

        // argumentsSummary should NOT be empty for git_add
        // Currently it IS empty because git_add is not handled in summarizeArguments
        let summary = calls[0].argumentsSummary
        // This test documents the bug - currently fails because summary is ""
        // After fix, this should pass
        XCTAssertFalse(
            summary.isEmpty,
            "git_add argumentsSummary should not be empty, got: '\(summary)'"
        )
    }

    func testGitBranchArgumentsSummaryFormat() {
        // Verify git_branch argumentsSummary format
        tracker.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/test\", \"from\": \"main\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        XCTAssertEqual(calls.count, 1)

        let summary = calls[0].argumentsSummary
        // Current implementation returns "create feature/test"
        // This is used in generateStateContext which prepends "Created branch:"
        // Result: "Created branch: create feature/test" - problematic
        XCTAssertTrue(summary.contains("feature/test"), "Should contain branch name")
    }

    func testRecentCallsForGitAddShowsFiles() {
        // Test that git_add results are properly summarized
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"a.swift\", \"b.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"a.swift\", \"b.swift\"]}, \"ok\": true}",
            isError: false
        )

        let calls = tracker.recentCalls(limit: 1)
        let resultSummary = calls[0].resultSummary

        // Result summary should indicate success
        // Currently git_add falls through to default which returns "ok"
        XCTAssertEqual(resultSummary, "ok")
    }

    func testLoopDetectionExcludesUpdateScratchpad() {
        // Issue: Scratchpad was updated but LLM didn't mark items as complete
        // update_scratchpad should be excluded from loop detection

        // 6 update_scratchpad calls should NOT trigger loop detection
        for i in 0..<6 {
            tracker.record(
                toolName: "update_scratchpad",
                argumentsJSON: "{\"content\": \"Plan item \(i)\"}",
                resultJSON: "{\"ok\": true, \"data\": {\"updated\": true}}",
                isError: false
            )
        }

        let loop = ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))

        // Should not detect loop for update_scratchpad
        // (But note: current implementation skips duplicate scratchpad content)
        if let detected = loop {
            if case .repetitiveTool(let tool, _, _) = detected {
                XCTAssertNotEqual(tool, "update_scratchpad", "Should not flag update_scratchpad as loop")
            }
        }
    }

    func testDuplicateScratchpadContentSkipped() {
        // Issue: Identical scratchpad updates should be skipped to prevent false loop detection
        // Note: Use \\n for JSON-escaped newlines (not \n which creates invalid JSON)
        let content = "1. Read file\\n2. Edit file\\n3. Commit"

        tracker.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}",  // Same content
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}",  // Same content again
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Only first unique scratchpad should be recorded
        let calls = tracker.recentCalls(limit: 10)
        let scratchpadCalls = calls.filter { $0.toolName == "update_scratchpad" }
        XCTAssertEqual(scratchpadCalls.count, 1, "Duplicate scratchpad content should be skipped")
    }
}
