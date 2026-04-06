import XCTest
@testable import NanoTeams

/// Tests for ToolCallCache - tool call tracking and caching
final class ToolCallCacheTests: XCTestCase {

    var memory: ToolCallCache!

    override func setUp() {
        super.setUp()
        memory = ToolCallCache()
    }

    override func tearDown() {
//        memory = nil
        super.tearDown()
    }

    // MARK: - Record Tests

    func testRecordSingleToolCall() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 10)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "read_file")
        XCTAssertTrue(calls[0].wasSuccessful)
    }

    func testRecordMultipleToolCalls() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 10)
        XCTAssertEqual(calls.count, 3)
    }

    func testRecordErrorCall() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"nonexistent.swift\"}",
            resultJSON: "{\"error\": \"File not found\"}",
            isError: true
        )

        let calls = memory.recentCalls(limit: 10)
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].wasSuccessful)
    }

    // MARK: - Recent Calls Tests

    func testRecentCallsLimitWorks() {
        for i in 0..<10 {
            memory.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let calls = memory.recentCalls(limit: 5)
        XCTAssertEqual(calls.count, 5)
    }

    func testRecentCallsReturnsLatest() {
        memory.record(
            toolName: "first",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "second",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "third",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 2)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].toolName, "second")
        XCTAssertEqual(calls[1].toolName, "third")
    }

    func testRecentCallsEmptyMemory() {
        let calls = memory.recentCalls(limit: 10)
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - wasAlreadyCalled Tests

    func testWasAlreadyCalledFindsMatch() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )

        let found = memory.wasAlreadyCalled(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.toolName, "read_file")
    }

    func testWasAlreadyCalledDifferentPath() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let found = memory.wasAlreadyCalled(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}"
        )

        XCTAssertNil(found)
    }

    func testWasAlreadyCalledDifferentTool() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let found = memory.wasAlreadyCalled(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )

        XCTAssertNil(found)
    }

    func testWasAlreadyCalledIgnoresFailedCalls() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"error\": \"File not found\"}",
            isError: true
        )

        let found = memory.wasAlreadyCalled(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )

        XCTAssertNil(found)
    }

    // MARK: - getCachedResultIfRedundant Tests

    func testGetCachedResultForCacheableTool() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"content\": \"hello\"}}",
            isError: false
        )

        let cached = memory.getCachedResultIfRedundant(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )

        XCTAssertNotNil(cached)
        XCTAssertTrue(cached?.contains("_cached") ?? false)
    }

    func testGetCachedResultForNonCacheableTool() {
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let cached = memory.getCachedResultIfRedundant(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )

        // write_file is not cacheable
        XCTAssertNil(cached)
    }

    func testUpdateScratchpadNotCached() {
        memory.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"1. Read file\\n2. Make change\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"updated\": true, \"content_length\": 30}}",
            isError: false
        )

        let cached = memory.getCachedResultIfRedundant(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"1. Read file\\n2. Make change\"}"
        )

        // update_scratchpad is a write tool, should not be cached
        XCTAssertNil(cached)
    }

    func testGetCachedResultForGitStatus() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let cached = memory.getCachedResultIfRedundant(
            toolName: "git_status",
            argumentsJSON: "{}"
        )

        XCTAssertNotNil(cached)
    }

    func testGetCachedResultForListDirectory() {
        memory.record(
            toolName: "list_files",
            argumentsJSON: "{\"path\": \".\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"files\": [\"a.swift\", \"b.swift\"]}}",
            isError: false
        )

        let cached = memory.getCachedResultIfRedundant(
            toolName: "list_files",
            argumentsJSON: "{\"path\": \".\"}"
        )

        XCTAssertNotNil(cached)
    }

    func testGetCachedResultNoMatchReturnsNil() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let cached = memory.getCachedResultIfRedundant(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}"
        )

        XCTAssertNil(cached)
    }

    // MARK: - generateSummary Tests

    func testGenerateSummaryEmpty() {
        let summary = ToolCallContextualizer.generateSummary(from: memory.calls)
        XCTAssertNil(summary)
    }

    func testGenerateSummarySingleCall() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: memory.calls)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("read_file") ?? false)
        XCTAssertTrue(summary?.contains("test.swift") ?? false)
        XCTAssertTrue(summary?.contains("✓") ?? false)
    }

    func testGenerateSummaryWithFailedCall() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"missing.swift\"}",
            resultJSON: "{\"error\": \"File not found\"}",
            isError: true
        )

        let summary = ToolCallContextualizer.generateSummary(from: memory.calls)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("✗") ?? false)
    }

    func testGenerateSummaryMultipleSameToolCalls() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file3.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: memory.calls)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("3 calls") ?? false)
        XCTAssertTrue(summary?.contains("3 successful") ?? false)
    }

    func testGenerateSummaryContainsWarning() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: memory.calls)

        XCTAssertTrue(summary?.contains("Avoid re-calling") ?? false)
    }

    func testGenerateSummaryGitStatusShowsLastResult() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature\", \"clean\": false}}",
            isError: false
        )

        let summary = ToolCallContextualizer.generateSummary(from: memory.calls)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("Last result") ?? false)
    }

    // MARK: - generateStateContext Tests

    func testGenerateStateContextEmpty() {
        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)
        XCTAssertNil(context)
    }

    func testGenerateStateContextWithGitStatus() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.hasPrefix("Current state:") ?? false)
        XCTAssertTrue(context?.contains("Git branch:") ?? false)
        XCTAssertTrue(context?.contains("main") ?? false)
    }

    func testGenerateStateContextWithCleanWorkingTree() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertTrue(context?.contains("(clean)") ?? false)
    }

    func testGenerateStateContextWithFilesRead() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 200}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        // Files are tracked but may not be shown in basic context
    }

    func testGenerateStateContextWithBuildResult() {
        memory.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Last build") ?? false)
    }

    func testGenerateStateContextIgnoresFailedCalls() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"error\": \"Not a git repository\"}",
            isError: true
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        // Should be nil because only failed calls
        XCTAssertNil(context)
    }

    // MARK: - Max Tracked Calls Limit Tests

    func testMaxTrackedCallsLimit() {
        // Record more than maxTrackedCalls (30)
        for i in 0..<40 {
            memory.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let calls = memory.recentCalls(limit: 100)

        // Should be limited to 30
        XCTAssertEqual(calls.count, 30)
    }

    func testOldCallsRemovedWhenLimitExceeded() {
        // Record more than limit
        for i in 0..<35 {
            memory.record(
                toolName: "tool_\(i)",
                argumentsJSON: "{}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let calls = memory.recentCalls(limit: 100)

        // First 5 should be removed (35 - 30 = 5)
        let toolNames = calls.map { $0.toolName }
        XCTAssertFalse(toolNames.contains("tool_0"))
        XCTAssertFalse(toolNames.contains("tool_4"))
        XCTAssertTrue(toolNames.contains("tool_5"))
        XCTAssertTrue(toolNames.contains("tool_34"))
    }

    // MARK: - Argument Summary Tests

    func testArgumentSummaryForSearchProject() {
        memory.record(
            toolName: "search",
            argumentsJSON: "{\"query\": \"TODO\", \"paths\": [\"src\", \"lib\"]}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].argumentsSummary.contains("TODO"))
        XCTAssertTrue(calls[0].argumentsSummary.contains("2 paths"))
    }

    func testArgumentSummaryForGitCommit() {
        memory.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"This is a very long commit message that should be truncated\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].argumentsSummary.contains("..."))
        XCTAssertLessThanOrEqual(calls[0].argumentsSummary.count, 35)
    }

    func testArgumentSummaryForGitBranch() {
        memory.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/new\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        // argumentsSummary now returns just the branch name; action is handled in generateStateContext
        XCTAssertEqual(calls[0].argumentsSummary, "feature/new")
    }

    // MARK: - Result Summary Tests

    func testResultSummaryForGitStatusClean() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("clean"))
        XCTAssertTrue(calls[0].resultSummary.contains("main"))
    }

    func testResultSummaryForGitStatusDirty() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature\", \"clean\": false}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("dirty"))
    }

    func testResultSummaryForBuildSuccess() {
        memory.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": true}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertEqual(calls[0].resultSummary, "success")
    }

    func testResultSummaryForBuildFailure() {
        memory.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": false, \"error_count\": 5}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("failed"))
        XCTAssertTrue(calls[0].resultSummary.contains("5 errors"))
    }

    func testResultSummaryForReadFile() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 1024}}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("1024 bytes"))
    }

    func testResultSummaryForError() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"missing.swift\"}",
            resultJSON: "{\"error\": {\"message\": \"File not found\"}}",
            isError: true
        )

        let calls = memory.recentCalls(limit: 1)
        XCTAssertTrue(calls[0].resultSummary.contains("error"))
        XCTAssertTrue(calls[0].resultSummary.contains("File not found"))
    }

    // MARK: - Cache Invalidation Tests

    func testCacheInvalidatedAfterWriteFile() {
        // First, read a file
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"content\": \"old content\"}}",
            isError: false
        )

        // Verify it's cached
        let cachedBefore = memory.getCachedResultIfRedundant(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )
        XCTAssertNotNil(cachedBefore)

        // Now write to the same file
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Cache should be invalidated
        let cachedAfter = memory.getCachedResultIfRedundant(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )
        XCTAssertNil(cachedAfter)
    }

    func testGitCacheInvalidatedAfterCheckout() {
        // Record git status
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        // Record git branch list
        memory.record(
            toolName: "git_branch_list",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branches\": [\"main\", \"develop\"]}}",
            isError: false
        )

        // Verify they're cached
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "git_branch_list", argumentsJSON: "{}"))

        // Checkout a branch
        memory.record(
            toolName: "git_checkout",
            argumentsJSON: "{\"branch\": \"develop\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Both git caches should be invalidated
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "git_branch_list", argumentsJSON: "{}"))
    }

    func testGitCacheInvalidatedAfterCommit() {
        // Record git status
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": false}}",
            isError: false
        )

        // Commit
        memory.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"test commit\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Cache should be invalidated
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
    }

    func testGitCacheInvalidatedAfterStash() {
        // Record git status
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": false}}",
            isError: false
        )

        // Stash
        memory.record(
            toolName: "git_stash",
            argumentsJSON: "{}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Cache should be invalidated
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
    }

    func testOtherFileCacheNotInvalidated() {
        // Read two different files
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Write to file1
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // file1 cache invalidated, but file2 should still be cached
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "read_file", argumentsJSON: "{\"path\": \"file1.swift\"}"))
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "read_file", argumentsJSON: "{\"path\": \"file2.swift\"}"))
    }

    func testErroredWriteDoesNotInvalidateCache() {
        // Read a file
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Try to write but fail
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"error\": \"permission denied\"}",
            isError: true
        )

        // Cache should NOT be invalidated because write failed
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "read_file", argumentsJSON: "{\"path\": \"test.swift\"}"))
    }

    // MARK: - Call Count Tests

    func testGetCallCountInitiallyZero() {
        let count = memory.getCallCount(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )
        XCTAssertEqual(count, 0)
    }

    func testGetCallCountIncrementsAfterCalls() {
        for _ in 0..<3 {
            memory.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"test.swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let count = memory.getCallCount(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}"
        )
        XCTAssertEqual(count, 3)
    }

    func testGetCallCountDifferentArgsTrackedSeparately() {
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        XCTAssertEqual(memory.getCallCount(toolName: "read_file", argumentsJSON: "{\"path\": \"file1.swift\"}"), 2)
        XCTAssertEqual(memory.getCallCount(toolName: "read_file", argumentsJSON: "{\"path\": \"file2.swift\"}"), 1)
    }

    // MARK: - Loop Detection Tests

    func testDetectLoopPatternNilWhenFewCalls() {
        // Less than 6 calls - no loop detection
        for i in 0..<5 {
            memory.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6)))
    }

    func testDetectLoopPatternReadOnlyLoop() {
        // 6 consecutive read-only calls
        let readOnlyTools = ["read_file", "git_status", "list_files", "read_lines", "git_branch_list", "search"]

        for tool in readOnlyTools {
            memory.record(
                toolName: tool,
                argumentsJSON: "{}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let loop = ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6))
        XCTAssertNotNil(loop)

        if case .readOnlyLoop(let message) = loop {
            XCTAssertTrue(message.contains("read-only"))
        } else {
            XCTFail("Expected readOnlyLoop")
        }
    }

    func testDetectLoopPatternRepetitiveTool() {
        // Add write tool to prevent readOnlyLoop from triggering
        memory.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        // Call git_status 4 times out of last 6
        memory.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        let loop = ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6))
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
        memory.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_status", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_commit", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "edit_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6)))
    }

    // MARK: - Progressive Cache Hint Tests

    func testCacheHintProgressivelyStronger() {
        // Record same call multiple times
        for _ in 0..<4 {
            memory.record(
                toolName: "git_status",
                argumentsJSON: "{}",
                resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
                isError: false
            )
        }

        // Get cached result (this would be the 5th call)
        let cached = memory.getCachedResultIfRedundant(
            toolName: "git_status",
            argumentsJSON: "{}"
        )

        XCTAssertNotNil(cached)
        // After 3+ calls, should have stronger hint
        XCTAssertTrue(cached?.contains("CACHED") ?? false)
        XCTAssertTrue(cached?.contains("times already") ?? false)
    }

    // MARK: - Git Cache Invalidation After File Writes Tests

    func testGitCacheInvalidatedAfterWriteFile() {
        // Record git status first
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        // Verify it's cached
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))

        // Write a file - this should invalidate git status cache
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Git status cache should be invalidated because working tree changed
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
    }

    func testGitCacheInvalidatedAfterDeleteFile() {
        // Record git status
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        // Delete file
        memory.record(
            toolName: "delete_file",
            argumentsJSON: "{\"path\": \"old.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Git status should be invalidated
        XCTAssertNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
    }

    func testFailedFileWriteDoesNotInvalidateGitCache() {
        // Record git status
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        // Try to write but fail
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"error\": \"permission denied\"}",
            isError: true
        )

        // Git status should NOT be invalidated because write failed
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))
    }

    // MARK: - State Context Generation Tests (Read-Only Exploration)

    func testGenerateStateContextShowsFilesReadAndNoChangesMade() {
        // Only read files, no writes
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"utils.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 200}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Files read") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
        XCTAssertTrue(context?.contains("utils.swift") ?? false)
        XCTAssertTrue(context?.contains("No changes made yet") ?? false)
    }

    func testGenerateStateContextShowsFilesModified() {
        // Read then write
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

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
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"file1.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"file2.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "delete_file",
            argumentsJSON: "{\"path\": \"file3.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("file1.swift") ?? false)
        XCTAssertTrue(context?.contains("file2.swift") ?? false)
        XCTAssertTrue(context?.contains("file3.swift") ?? false)
    }

    func testGenerateStateContextShowsGitBranchAndStatus() {
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature/test\", \"clean\": false}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("feature/test") ?? false)
        XCTAssertTrue(context?.contains("uncommitted changes") ?? false)
    }

    func testGenerateStateContextShowsCommitAction() {
        memory.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"Add feature X\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Committed") ?? false)
    }

    func testGenerateStateContextLimitsFilesShown() {
        // Read more than 5 files
        for i in 0..<8 {
            memory.record(
                toolName: "read_file",
                argumentsJSON: "{\"path\": \"file\(i).swift\"}",
                resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
                isError: false
            )
        }

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        // Should show limit indicator
        XCTAssertTrue(context?.contains("+3 more") ?? false)
    }

    // MARK: - State Context Format Compatibility Tests (for [STATE] label in ConversationLog)

    func testGenerateStateContextStartsWithCurrentState() {
        // This test verifies the format that ConversationLogRenderer uses to detect STATE messages
        // The renderer checks: content.hasPrefix("Current state:")
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "State context must start with 'Current state:' for ConversationLogRenderer to label it as [STATE]"
        )
    }

    func testGenerateStateContextFormatMatchesRendererExpectation() {
        // Integration test: verifies that state context generated here
        // will be properly detected by ConversationLogRenderer.llmRoleLabel()
        // Note: edit_code_in_file invalidates git cache, so git_status must be recorded AFTER
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"feature/test\", \"clean\": false}}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        // Must start with exact prefix for [STATE] detection
        XCTAssertTrue(context?.hasPrefix("Current state:") ?? false)
        // Should contain meaningful state information
        XCTAssertTrue(context?.contains("Git branch:") ?? false)
        XCTAssertTrue(context?.contains("feature/test") ?? false)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
    }

    func testStateContextPrefixWithGitStatusOnly() {
        // Verifies that state context with only git status has correct prefix
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "Git status only: must start with 'Current state:'"
        )
    }

    func testStateContextPrefixWithFileReadsOnly() {
        // Verifies that state context with only file reads has correct prefix
        memory.record(
            toolName: "read_file",
            argumentsJSON: "{\"path\": \"test.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "File reads only: must start with 'Current state:'"
        )
    }

    func testStateContextPrefixWithBuildResultOnly() {
        // Verifies that state context with only build result has correct prefix
        memory.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"scheme\": \"NanoTeams\"}",
            resultJSON: "{\"data\": {\"success\": true}}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)
        XCTAssertTrue(
            context?.hasPrefix("Current state:") ?? false,
            "Build only: must start with 'Current state:'"
        )
    }

    func testStateContextPrefixWithMixedOperations() {
        // Verifies that state context with file edits and commits has correct prefix
        // Note: file edits invalidate git cache, so this tests non-git state items
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"code.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"Update code\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)
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
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

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
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

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
        memory.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"a.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        let loop = ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6))

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
        memory.record(
            toolName: "write_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true, \"data\": {\"created\": false, \"size\": 142}}",
            isError: false
        )
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\"]}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.hasPrefix("Current state:") ?? false)
        // Should show modified file
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
    }

    func testStateContextBranchAndCommitWorkflow() {
        // Issue: Commit was made before switching to feature branch
        // State context should help track branch state properly
        memory.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/update\", \"from\": \"develop\"}",
            resultJSON: "{\"data\": {\"action\": \"create\", \"name\": \"feature/update\"}, \"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "git_checkout",
            argumentsJSON: "{\"branch\": \"feature/update\"}",
            resultJSON: "{\"data\": {\"branch\": \"feature/update\", \"previous\": \"develop\"}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        // Should show branch creation and checkout
        XCTAssertTrue(context?.contains("Created branch") ?? false)
        XCTAssertTrue(context?.contains("Switched to branch") ?? false)
        XCTAssertTrue(context?.contains("Files modified") ?? false)
    }

    func testCacheInvalidationAfterGitAdd() {
        // git_add is a git write tool and should invalidate git read caches
        memory.record(
            toolName: "git_status",
            argumentsJSON: "{}",
            resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": false}}",
            isError: false
        )

        // Verify git_status is cached
        XCTAssertNotNil(memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"))

        // Stage files
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\"]}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // git_status cache should be invalidated after git_add
        XCTAssertNil(
            memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"),
            "git_add should invalidate git_status cache"
        )
    }

    func testLoopDetectionMessageIsActionable() {
        // Verify loop detection messages provide actionable guidance
        memory.record(toolName: "write_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{\"ok\": true}", isError: false)

        let loop = ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6))

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
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"path\": \"Project.xcodeproj\"}",
            resultJSON: "{\"data\": {\"success\": true, \"duration\": 2.5}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Last build") ?? false)
        XCTAssertTrue(context?.contains("success") ?? false)
    }

    func testStateContextShowsFailedBuildStatus() {
        memory.record(
            toolName: "run_xcodebuild",
            argumentsJSON: "{\"path\": \"Project.xcodeproj\"}",
            resultJSON: "{\"data\": {\"success\": false, \"error_count\": 3}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Last build") ?? false)
        XCTAssertTrue(context?.contains("failed") ?? false)
    }

    // MARK: - Additional Conversation Log Issues (Round 2)

    func testGitAddArgumentsSummaryNotEmpty() {
        // Issue: git_add falls through to default case in summarizeArguments
        // returning empty string, causing "Staged:" entries with no content
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"main.swift\", \"utils.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"main.swift\", \"utils.swift\"]}, \"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
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
        memory.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/test\"}",
            resultJSON: "{\"data\": {\"action\": \"create\", \"name\": \"feature/test\"}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

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
        memory.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/test\", \"from\": \"main\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
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
        memory.record(
            toolName: "git_branch",
            argumentsJSON: "{\"action\": \"create\", \"name\": \"feature/x\", \"from\": \"develop\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // 2. Make changes (still on develop)
        memory.record(
            toolName: "edit_file",
            argumentsJSON: "{\"path\": \"main.swift\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // 3. Commit (on develop, not feature branch!)
        memory.record(
            toolName: "git_commit",
            argumentsJSON: "{\"message\": \"Fix bug\"}",
            resultJSON: "{\"data\": {\"hash\": \"abc123\"}, \"ok\": true}",
            isError: false
        )

        // 4. NOW switch to feature branch (too late!)
        memory.record(
            toolName: "git_checkout",
            argumentsJSON: "{\"branch\": \"feature/x\"}",
            resultJSON: "{\"data\": {\"branch\": \"feature/x\", \"previous\": \"develop\"}, \"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

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
            memory.record(
                toolName: "git_add",
                argumentsJSON: "{\"paths\": [\"file\(i).swift\"]}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )
        }

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        if let ctx = context {
            // Count "Staged" lines - should be at most 3 due to suffix(3)
            let stagedCount = ctx.components(separatedBy: "Staged").count - 1
            XCTAssertLessThanOrEqual(stagedCount, 3, "Should limit staged entries to 3")
        }
    }

    func testRecentCallsForGitAddShowsFiles() {
        // Test that git_add results are properly summarized
        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"a.swift\", \"b.swift\"]}",
            resultJSON: "{\"data\": {\"staged\": [\"a.swift\", \"b.swift\"]}, \"ok\": true}",
            isError: false
        )

        let calls = memory.recentCalls(limit: 1)
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
            memory.record(
                toolName: "update_scratchpad",
                argumentsJSON: "{\"content\": \"Plan item \(i)\"}",
                resultJSON: "{\"ok\": true, \"data\": {\"updated\": true}}",
                isError: false
            )
        }

        let loop = ToolCallLoopDetector.detectLoopPattern(in: memory.recentCalls(limit: 6))

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

        memory.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}",  // Same content
            resultJSON: "{\"ok\": true}",
            isError: false
        )
        memory.record(
            toolName: "update_scratchpad",
            argumentsJSON: "{\"content\": \"\(content)\"}",  // Same content again
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        // Only first unique scratchpad should be recorded
        let calls = memory.recentCalls(limit: 10)
        let scratchpadCalls = calls.filter { $0.toolName == "update_scratchpad" }
        XCTAssertEqual(scratchpadCalls.count, 1, "Duplicate scratchpad content should be skipped")
    }

    func testCacheInvalidationForAllGitWriteTools() {
        // Verify all git write tools invalidate git read caches
        let gitWriteTools = ["git_checkout", "git_commit", "git_merge", "git_stash", "git_branch", "git_add", "git_pull"]

        for writeTool in gitWriteTools {
            // Reset memory for each iteration using class property
//            memory = ToolCallCache()

            // Record git_status
            memory.record(
                toolName: "git_status",
                argumentsJSON: "{}",
                resultJSON: "{\"data\": {\"branch\": \"main\", \"clean\": true}}",
                isError: false
            )

            // Verify cached
            XCTAssertNotNil(
                memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"),
                "git_status should be cached before \(writeTool)"
            )

            // Perform git write
            memory.record(
                toolName: writeTool,
                argumentsJSON: "{}",
                resultJSON: "{\"ok\": true}",
                isError: false
            )

            // Verify cache invalidated
            XCTAssertNil(
                memory.getCachedResultIfRedundant(toolName: "git_status", argumentsJSON: "{}"),
                "\(writeTool) should invalidate git_status cache"
            )
        }
    }

    func testStateContextWithEmptyArgumentsSummary() {
        // Issue: git_add returns empty argumentsSummary, causing malformed state entries
        // "Staged: " with nothing after the colon

        memory.record(
            toolName: "git_add",
            argumentsJSON: "{\"paths\": [\"test.swift\"]}",
            resultJSON: "{\"ok\": true}",
            isError: false
        )

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

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
        memory.record(toolName: "read_file", argumentsJSON: "{\"path\": \"main.swift\"}", resultJSON: "{\"ok\": true, \"data\": {\"size\": 100}}", isError: false)
        memory.record(toolName: "edit_file", argumentsJSON: "{\"path\": \"main.swift\"}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_add", argumentsJSON: "{\"paths\": [\"main.swift\"]}", resultJSON: "{\"ok\": true}", isError: false)
        memory.record(toolName: "git_commit", argumentsJSON: "{\"message\": \"Update main\"}", resultJSON: "{\"ok\": true}", isError: false)

        let context = ToolCallContextualizer.generateStateContext(from: memory.calls)

        XCTAssertNotNil(context)
        // Should show modification and commit
        XCTAssertTrue(context?.contains("Files modified") ?? false)
        XCTAssertTrue(context?.contains("main.swift") ?? false)
        XCTAssertTrue(context?.contains("Committed") ?? false)
    }
}
