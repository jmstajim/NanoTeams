import XCTest
@testable import NanoTeams

final class ToolCallContextualizerTests: XCTestCase {

    private typealias TN = ToolNames

    // MARK: - generateSummary

    func testGenerateSummary_emptyList_returnsNil() {
        XCTAssertNil(ToolCallContextualizer.generateSummary(from: []))
    }

    func testGenerateSummary_singleCall_formatsCorrectly() {
        let calls = [makeCall(TN.readFile, args: "main.swift", result: "200 lines", success: true)]
        let summary = ToolCallContextualizer.generateSummary(from: calls)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("read_file(main.swift) ✓"))
    }

    func testGenerateSummary_failedCall_showsFailureMarker() {
        let calls = [makeCall(TN.editFile, args: "file.swift", result: "ANCHOR_NOT_FOUND", success: false)]
        let summary = ToolCallContextualizer.generateSummary(from: calls)
        XCTAssertTrue(summary!.contains("✗"))
    }

    func testGenerateSummary_multipleCallsSameTool_groupsThem() {
        let calls = [
            makeCall(TN.readFile, args: "a.swift", result: "ok", success: true),
            makeCall(TN.readFile, args: "b.swift", result: "ok", success: true),
            makeCall(TN.readFile, args: "c.swift", result: "fail", success: false),
        ]
        let summary = ToolCallContextualizer.generateSummary(from: calls)!
        XCTAssertTrue(summary.contains("read_file: 3 calls (2 successful, 1 failed)"))
    }

    func testGenerateSummary_multipleCallsSameTool_showsLastResultForInfoTools() {
        let calls = [
            makeCall(TN.gitStatus, args: "", result: "on main, clean", success: true),
            makeCall(TN.gitStatus, args: "", result: "on main, 2 modified", success: true),
        ]
        let summary = ToolCallContextualizer.generateSummary(from: calls)!
        XCTAssertTrue(summary.contains("Last result:"))
        XCTAssertTrue(summary.contains("2 modified"))
    }

    func testGenerateSummary_sortedByToolName() {
        let calls = [
            makeCall(TN.writeFile, args: "z.swift", result: "ok", success: true),
            makeCall(TN.editFile, args: "a.swift", result: "ok", success: true),
        ]
        let summary = ToolCallContextualizer.generateSummary(from: calls)!
        let editIndex = summary.range(of: "edit_file")!.lowerBound
        let writeIndex = summary.range(of: "write_file")!.lowerBound
        XCTAssertLessThan(editIndex, writeIndex)
    }

    func testGenerateSummary_containsAvoidDuplicateWarning() {
        let calls = [makeCall(TN.readFile, args: "f.swift", result: "ok", success: true)]
        let summary = ToolCallContextualizer.generateSummary(from: calls)!
        XCTAssertTrue(summary.contains("Avoid re-calling"))
    }

    // MARK: - generateStateContext

    func testGenerateStateContext_emptyCalls_noScratchpad_returnsNil() {
        XCTAssertNil(ToolCallContextualizer.generateStateContext(from: []))
    }

    func testGenerateStateContext_gitStatus_extractsBranch() {
        let calls = [makeCall(TN.gitStatus, args: "", result: "on main, 2 files modified", success: true)]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Git branch: main"))
        XCTAssertFalse(context.contains("clean"))
    }

    func testGenerateStateContext_gitStatus_cleanStatus() {
        let calls = [makeCall(TN.gitStatus, args: "", result: "on main, clean", success: true)]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("(clean)"))
    }

    func testGenerateStateContext_gitBranchList_extractsBranch() {
        let json = """
        {"data": {"current": "feature/auth"}}
        """
        let calls = [makeCall(TN.gitBranchList, args: "", result: "branches", success: true, resultJSON: json)]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Git branch: feature/auth"))
    }

    func testGenerateStateContext_filesModified() {
        let calls = [
            makeCall(TN.editFile, args: "a.swift", result: "ok", success: true),
            makeCall(TN.writeFile, args: "b.swift", result: "ok", success: true),
        ]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Files modified:"))
        XCTAssertTrue(context.contains("a.swift"))
        XCTAssertTrue(context.contains("b.swift"))
    }

    func testGenerateStateContext_filesRead_noModifications() {
        let calls = [
            makeCall(TN.readFile, args: "readme.md", result: "ok", success: true),
        ]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Files read:"))
        XCTAssertTrue(context.contains("No changes made yet"))
    }

    func testGenerateStateContext_stagedFilesClearedAfterCommit() {
        let calls = [
            makeCall(TN.gitAdd, args: "file.swift", result: "ok", success: true),
            makeCall(TN.gitCommit, args: "fix: typo", result: "ok", success: true),
        ]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        // After commit, staged files should be cleared — only committed message shown
        XCTAssertTrue(context.contains("Committed: fix: typo"))
        XCTAssertFalse(context.contains("Staged: file.swift"))
    }

    func testGenerateStateContext_stagedFilesShownBeforeCommit() {
        let calls = [
            makeCall(TN.gitAdd, args: "file.swift", result: "ok", success: true),
        ]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Staged: file.swift"))
    }

    func testGenerateStateContext_moreThan5Files_showsSuffix() {
        var calls: [ToolCallCache.TrackedCall] = []
        for i in 0..<7 {
            calls.append(makeCall(TN.readFile, args: "file\(i).swift", result: "ok", success: true))
        }
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("(+2 more)"))
    }

    func testGenerateStateContext_buildStatus() {
        let calls = [makeCall(TN.runXcodebuild, args: "build", result: "Build succeeded", success: true)]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Last build: Build succeeded"))
    }

    func testGenerateStateContext_scratchpadSummary() {
        let context = ToolCallContextualizer.generateStateContext(from: [], scratchpadSummary: "Step 1 done")!
        XCTAssertTrue(context.contains("Plan: Step 1 done"))
    }

    func testGenerateStateContext_deleteFile_trackedAsChange() {
        let calls = [makeCall(TN.deleteFile, args: "old.swift", result: "ok", success: true)]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Deleted: old.swift"))
    }

    func testGenerateStateContext_gitCheckout_trackedAsChange() {
        let calls = [makeCall(TN.gitCheckout, args: "feature/new", result: "ok", success: true)]
        let context = ToolCallContextualizer.generateStateContext(from: calls)!
        XCTAssertTrue(context.contains("Switched to branch: feature/new"))
    }

    func testGenerateStateContext_failedCalls_ignored() {
        let calls = [makeCall(TN.gitStatus, args: "", result: "error", success: false)]
        XCTAssertNil(ToolCallContextualizer.generateStateContext(from: calls))
    }

    // MARK: - Helpers

    private func makeCall(
        _ toolName: String,
        args: String,
        result: String,
        success: Bool,
        resultJSON: String = "{}"
    ) -> ToolCallCache.TrackedCall {
        ToolCallCache.TrackedCall(
            toolName: toolName,
            argumentsSummary: args,
            resultSummary: result,
            resultJSON: resultJSON,
            timestamp: Date(),
            wasSuccessful: success
        )
    }
}
