import XCTest
@testable import NanoTeams

/// Tests for ToolCallTracker — per-step tool-call recording, recent-calls snapshot,
/// scratchpad-dedup, max-tracked eviction, and downstream contextualizer/loop-detector
/// integration. Result-caching/invalidation no longer exist (hard-off); identical-write
/// guard is exercised by `IdenticalWriteLoopGuardTests`.
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

    // MARK: - generateSummary Tests

    func testGenerateSummaryEmpty() {
        let summary = ToolCallContextualizer.generateSummary(from: tracker.snapshot())
        XCTAssertNil(summary)
    }

    func testGenerateSummarySingleCall() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: tracker.snapshot())

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("read_file") ?? false)
        XCTAssertTrue(summary?.contains("test.swift") ?? false)
        XCTAssertTrue(summary?.contains("✓") ?? false)
    }

    func testGenerateSummaryWithFailedCall() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"missing.swift\"}",
            resultJSON: "{\"error\": \"File not found\"}",
            isError: true
        )

        let summary = ToolCallContextualizer.generateSummary(from: tracker.snapshot())

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("✗") ?? false)
    }

    func testGenerateSummaryMultipleSameToolCalls() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file3.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: tracker.snapshot())

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("3 calls") ?? false)
        XCTAssertTrue(summary?.contains("3 successful") ?? false)
    }

    func testGenerateSummaryContainsWarning() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: tracker.snapshot())

        XCTAssertTrue(summary?.contains("Avoid re-calling") ?? false)
    }

    func testGenerateSummaryGitStatusShowsLastResult() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature\", \"clean\": false}}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: tracker.snapshot())

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("Last result") ?? false)
    }

    // MARK: - generateStateContext Tests

    func testGenerateStateContextEmpty() {
        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())
        XCTAssertNil(context)
    }

    func testGenerateStateContextWithGitStatus() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.hasPrefix("Current state:") ?? false)
        XCTAssertTrue(context?.contains("Git branch:") ?? false)
        XCTAssertTrue(context?.contains("main") ?? false)
    }

    func testGenerateStateContextWithCleanWorkingTree() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertTrue(context?.contains("(clean)") ?? false)
    }

    func testGenerateStateContextWithFilesRead() {
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 200}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // Files are tracked but may not be shown in basic context
    }

    func testGenerateStateContextWithBuildResult() {
        tracker.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Last build") ?? false)
    }

    func testGenerateStateContextIgnoresFailedCalls() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"error\": \"Not a git repository\"}",
            isError: true
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        // Should be nil because only failed calls
        XCTAssertNil(context)
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

    // MARK: - State Context Generation Tests (Read-Only Exploration)

    func testGenerateStateContextShowsFilesReadAndNoChangesMade() {
        // Only read files, no writes
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"utils.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 200}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Files read") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
        XCTAssertTrue(context?.contains("utils.swift") ?? false)
        XCTAssertTrue(context?.contains("No changes made yet") ?? false)
    }

    func testGenerateStateContextShowsFilesModified() {
        // Read then write
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
        // Should NOT show "No changes made yet" because we modified files
        XCTAssertFalse(context?.contains("No changes made yet") ?? true)
        // Should NOT show "Files read" when we have modifications
        XCTAssertFalse(context?.contains("Files read") ?? true)
    }

    func testGenerateStateContextShowsMultipleFilesModified() {
        // Modify multiple files
        tracker.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "delete_file",
            argumentsJSON: "{\"path\": \"file3.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("file1.swift") ?? false)
        XCTAssertTrue(context?.contains("file2.swift") ?? false)
        XCTAssertTrue(context?.contains("file3.swift") ?? false)
    }

    func testGenerateStateContextShowsGitBranchAndStatus() {
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature/test\", \"clean\": false}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("feature/test") ?? false)
        XCTAssertTrue(context?.contains("uncommitted changes") ?? false)
    }

    func testGenerateStateContextShowsCommitAction() {
        tracker.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"Add feature X\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Committed") ?? false)
    }

    func testGenerateStateContextLimitsFilesShown() {
        // Read more than 5 files
        for i in 0..<8 {
            tracker.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
                isError: false
            )
        }

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // Should show limit indicator
        XCTAssertTrue(context?.contains("+3 more") ?? false)
    }

    // MARK: - State Context Format Tests ("Current state:" prefix)

    func testGenerateStateContextStartsWithCurrentState() {
        // The state context is injected into the LLM conversation so the model can
        // track resource freshness; it must start with the "Current state:" prefix.
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "State context must start with 'Current state:' (the prefix the LLM keys on)"
        )
    }

    func testGenerateStateContextFormatMatchesRendererExpectation() {
        // Integration test: verifies the state context format the LLM keys on.
        // Note: edit_code_in_file invalidates git cache, so git_status must be recorded AFTER
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature/test\", \"clean\": false}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // Must start with the exact "Current state:" prefix
        XCTAssertTrue(context?.hasPrefix("Current state:") ?? false)
        // Should contain meaningful state information
        XCTAssertTrue(context?.contains("Git branch:") ?? false)
        XCTAssertTrue(context?.contains("feature/test") ?? false)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
    }

    func testStateContextPrefixWithGitStatusOnly() {
        // Verifies that state context with only git status has correct prefix
        tracker.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "Git status only: must start with 'Current state:'"
        )
    }

    func testStateContextPrefixWithFileReadsOnly() {
        // Verifies that state context with only file reads has correct prefix
        tracker.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "File reads only: must start with 'Current state:'"
        )
    }

    func testStateContextPrefixWithBuildResultOnly() {
        // Verifies that state context with only build result has correct prefix
        tracker.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": true}}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "Build only: must start with 'Current state:'"
        )
    }

    func testStateContextPrefixWithMixedOperations() {
        // Verifies that state context with file edits and commits has correct prefix
        // Note: file edits invalidate git cache, so this tests non-git state items
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"code.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"Update code\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "Mixed ops: must start with 'Current state:'"
        )
    }

    // MARK: - Conversation Log Issue Tests (from log analysis)
    // These tests are based on issues discovered in actual conversation logs

    func testGitAddShowsStagedPaths() {
        // Issue: git_add calls were showing "Staged: " with empty path
        // The argumentsSummary should include the staged file paths
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // Should show staged files, not empty "Staged:"
        if let ctx = context {
            // The staged entry should contain file information
            XCTAssertTrue(
                ctx.contains("Staged"),
                "Context should show staging action"
            )
            // Should NOT have empty "Staged:" entries
            let lines = ctx.split(separator: "\n").map(String.init)
            let stagedLines = lines.filter { $0.contains("Staged:") || $0.contains("Staged") }
            for line in stagedLines {
                // Each "Staged" line should have content after it
                XCTAssertFalse(
                    line.hasSuffix(": ") || line.hasSuffix(":"),
                    "Staged line should not be empty: '\(line)'"
                )
            }
        }
    }

    func testStateContextNoDuplicateStagedEntriesForSameFile() {
        // Issue: Multiple git_add calls for same file created duplicate "Staged:" lines
        // Expected: State should deduplicate or show meaningful summary
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        if let ctx = context {
            // Count how many "Staged" lines appear
            let lines = ctx.split(separator: "\n").map(String.init)
            let stagedLines = lines.filter { $0.contains("Staged") }

            // State context limits to suffix(3) so max 3 lines,
            // but ideally should deduplicate identical entries
            // At minimum, verify each line has content
            for line in stagedLines {
                XCTAssertFalse(
                    line.trimmingCharacters(in: .whitespaces).hasSuffix(":"),
                    "Staged line should have content: '\(line)'"
                )
            }
        }
    }

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

    func testStateContextWithFileModificationAndGitAdd() {
        // Realistic scenario: edit file then stage it
        tracker.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"created\": false, \"size\": 142}}",
            isError: false
        )
        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.hasPrefix("Current state:") ?? false)
        // Should show modified file
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
    }

    func testStateContextBranchAndCommitWorkflow() {
        // Issue: Commit was made before switching to feature branch
        // State context should help track branch state properly
        tracker.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/update\", \"from\": \"develop\"}",
            resultJSON: "{\"data\": {\"action\": \"create\", \"name\": \"feature/update\"}, \"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "git_checkout",
            argumentsJSON: "{\"branch\": \"feature/update\"}",
            resultJSON: "{\"data\": {\"branch\": \"feature/update\", \"previous\": \"develop\"}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // Should show branch creation and checkout
        XCTAssertTrue(context?.contains("Created branch") ?? false)
        XCTAssertTrue(context?.contains("Switched to branch") ?? false)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
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

    func testStateContextShowsBuildStatus() {
        // Verify build status is captured in state context
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        tracker.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"path\": \"Project.xcodeproj\"}",
            resultJSON: "{\"data\": {\"success\": true, \"duration\": 2.5}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Last build") ?? false)
        XCTAssertTrue(context?.contains("success") ?? false)
    }

    func testStateContextShowsFailedBuildStatus() {
        tracker.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"path\": \"Project.xcodeproj\"}",
            resultJSON: "{\"data\": {\"success\": false, \"error_count\": 3}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Last build") ?? false)
        XCTAssertTrue(context?.contains("failed") ?? false)
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

    func testGitBranchCreateDoesNotDuplicateAction() {
        // Issue: State shows "Created branch: create feature/name" - "create" appears twice
        // The argumentsSummary is "create feature/name", then prepended with "Created branch:"
        tracker.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/test\"}",
            resultJSON: "{\"data\": {\"action\": \"create\", \"name\": \"feature/test\"}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        if let ctx = context {
            // Should NOT contain "create" twice in the same line
            let lines = ctx.split(separator: "\n").map(String.init)
            for line in lines where line.contains("Created branch") {
                // Count occurrences of "create" (case insensitive)
                let createCount = line.lowercased().components(separatedBy: "create").count - 1
                XCTAssertLessThanOrEqual(
                    createCount, 1,
                    "Should not duplicate 'create' in branch creation line: '\(line)'"
                )
            }
        }
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

    func testStateContextCommitAndCheckoutSequence() {
        // Issue: Commit was made before checkout to feature branch
        // State should help track this sequence problem

        // 1. Create branch (but don't switch to it)
        tracker.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/x\", \"from\": \"develop\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // 2. Make changes (still on develop)
        tracker.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // 3. Commit (on develop, not feature branch!)
        tracker.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"Fix bug\"}",
            resultJSON: "{\"data\": {\"hash\": \"abc123\"}, \"ok\": true}",
            isError: false
        )

        // 4. NOW switch to feature branch (too late!)
        tracker.record(
            toolName: "git_checkout",
            argumentsJSON: "{\"branch\": \"feature/x\"}",
            resultJSON: "{\"data\": {\"branch\": \"feature/x\", \"previous\": \"develop\"}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // State should show both the commit and the checkout
        // This documents what happened, even if order was wrong
        XCTAssertTrue(context?.contains("Committed") ?? false)
        XCTAssertTrue(context?.contains("Switched to branch") ?? false)
    }

    func testStateContextLimitsPreviousActions() {
        // Issue: changesMade.suffix(3) limits to 3 items
        // Multiple git_add calls could overflow this

        // Record 5 git_add calls
        for i in 0..<5 {
            tracker.record(
                toolName: "git_add",
                argumentsJSON: "{\"paths\": [\"file\(i).swift\"]}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        if let ctx = context {
            // Count "Staged" lines - should be at most 3 due to suffix(3)
            let stagedCount = ctx.components(separatedBy: "Staged").count - 1
            XCTAssertLessThanOrEqual(stagedCount, 3, "Should limit staged entries to 3")
        }
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

    func testStateContextWithEmptyArgumentsSummary() {
        // Issue: git_add returns empty argumentsSummary, causing malformed state entries
        // "Staged: " with nothing after the colon

        tracker.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"test.swift\"]}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        if let ctx = context {
            // Check for malformed "Staged:" entries
            let lines = ctx.split(separator: "\n").map(String.init)
            for line in lines {
                if line.contains("Staged") {
                    // Line should not end with just ": " or ":"
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    XCTAssertFalse(
                        trimmed.hasSuffix(":") || trimmed.hasSuffix(": "),
                        "Malformed Staged entry found: '\(line)'"
                    )
                }
            }
        }
    }

    func testMultipleToolCallsInSingleStep() {
        // Realistic scenario: read, edit, add, commit in sequence
        tracker.record(toolName: "read_file", argumentsJSON: "{\"path\": \"main.swift\"}", resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}", isError: false)
        tracker.record(toolName: "edit_file", argumentsJSON: "{\"path\": \"main.swift\"}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"main.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        tracker.record(toolName: "git_commit", argumentsJSON: "{\"message\": \"Update main\"}", resultJSON: "{\"ok\": true}", isError: false)

        let context = ToolCallContextualizer.generateStateContext(from: tracker.snapshot())

        XCTAssertNotNil(context)
        // Should show modification and commit
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
        XCTAssertTrue(context?.contains("Committed") ?? false)
    }
}
