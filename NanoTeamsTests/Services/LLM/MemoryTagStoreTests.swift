import XCTest

@testable import NanoTeams

final class MemoryTagStoreTests: XCTestCase {

    var sut: MemoryTagStore!

    override func setUp() {
        super.setUp()
        sut = MemoryTagStore()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Tag Generation

    func testNextTagIncrementsPerType() {
        XCTAssertEqual(sut.nextTag(.read), "<§R1§>")
        XCTAssertEqual(sut.nextTag(.read), "<§R2§>")
        XCTAssertEqual(sut.nextTag(.edit), "<§E1§>")
        XCTAssertEqual(sut.nextTag(.build), "<§B1§>")
        XCTAssertEqual(sut.nextTag(.read), "<§R3§>")
    }

    // MARK: - read_file Processing

    func testReadFileFirstRead_ReturnsTaggedContent() {
        let result = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged, got \(tagResult)")
            return
        }
        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"tag\":\"<§R1§>\""))
        XCTAssertTrue(content.contains("\"path\":\"Sorter.swift\""))
        XCTAssertTrue(content.contains("let x = 1"))
    }

    func testReadFileRepeatUnchanged_ReturnsReference() {
        let result = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        _ = sut.processToolResult(result, iteration: 1)

        let result2 = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference, got \(tagResult2)")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
        XCTAssertTrue(content.contains("\"ref\":\"<§R1§>\""))
    }

    func testReadFileAfterEdit_ReturnsNewBaseline() {
        let result1 = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        _ = sut.processToolResult(result1, iteration: 1)

        // Edit the file
        let editResult = makeEditResult(path: "Sorter.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        // Read again — should get new baseline even with same content
        let result3 = makeReadResult(path: "Sorter.swift", content: "let x = 2")
        let tagResult3 = sut.processToolResult(result3, iteration: 3)

        guard case .tagged(let content, let tag) = tagResult3 else {
            XCTFail("Expected .tagged, got \(tagResult3)")
            return
        }
        XCTAssertEqual(tag, "<§R2§>")
        XCTAssertTrue(content.contains("let x = 2"))

        // Old tag should be replaced
        if case .replaced(let by) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(by, "<§R2§>")
        } else {
            XCTFail("Expected R1 to be replaced")
        }
    }

    func testReadFileExternalChange_ReturnsNewBaseline() {
        let result1 = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        _ = sut.processToolResult(result1, iteration: 1)

        // Read again with DIFFERENT content (external change, no edit)
        let result2 = makeReadResult(path: "Sorter.swift", content: "let x = 99")
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .tagged(_, let tag) = tagResult2 else {
            XCTFail("Expected .tagged for external change")
            return
        }
        XCTAssertEqual(tag, "<§R2§>")
    }

    // MARK: - read_lines Processing

    func testReadLinesFirstRead_ReturnsTagged() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged")
            return
        }
        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"lines\":\"5-5\""))
    }

    func testReadLinesRepeatUnchanged_ReturnsReference() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        _ = sut.processToolResult(result, iteration: 1)

        let result2 = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
    }

    func testReadLinesInvalidatedByEdit() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        _ = sut.processToolResult(result, iteration: 1)

        // Edit the file
        let editResult = makeEditResult(path: "Sorter.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        // Read same lines — should get new baseline
        let result2 = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 2",
            startLine: 5, endLine: 5)
        let tagResult2 = sut.processToolResult(result2, iteration: 3)

        guard case .tagged(_, let tag) = tagResult2 else {
            XCTFail("Expected .tagged after edit")
            return
        }
        XCTAssertEqual(tag, "<§R2§>")
    }

    // MARK: - edit_file Processing

    func testEditFile_ReturnsTaggedAndInvalidatesRead() {
        // First read the file
        let readResult = makeReadResult(path: "Foo.swift", content: "original")
        _ = sut.processToolResult(readResult, iteration: 1)

        // Edit it
        let editResult = makeEditResult(path: "Foo.swift")
        let tagResult = sut.processToolResult(editResult, iteration: 2)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged for edit")
            return
        }
        XCTAssertEqual(tag, "<§E1§>")
        XCTAssertTrue(content.contains("\"status\":\"success\""))

        // Read tag should be outdated
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "<§E1§>")
        } else {
            XCTFail("Expected R1 to be outdated")
        }
    }

    func testEditFileError_ReturnsPassthrough() {
        let result = ToolExecutionResult(
            providerID: "call_1",
            toolName: "edit_file",
            argumentsJSON: "{\"path\":\"Foo.swift\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            outputJSON: "{\"error\":\"old_text not found\"}",
            isError: true
        )
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .passthrough = tagResult else {
            XCTFail("Expected .passthrough for failed edit")
            return
        }
    }

    // MARK: - write_file Processing

    func testWriteFile_CreatesNewBaseline() {
        // First read the file
        let readResult = makeReadResult(path: "Foo.swift", content: "original")
        _ = sut.processToolResult(readResult, iteration: 1)

        // Write new content
        let writeResult = makeWriteResult(path: "Foo.swift", content: "new content")
        let tagResult = sut.processToolResult(writeResult, iteration: 2)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged for write")
            return
        }
        XCTAssertEqual(tag, "<§W1§>")
        XCTAssertTrue(content.contains("\"status\":\"success\""))

        // Old read tag should be replaced
        if case .replaced(let by) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(by, "<§W1§>")
        } else {
            XCTFail("Expected R1 to be replaced by W1")
        }
    }

    // MARK: - delete_file Processing

    func testDeleteFile_OutdatesAllTagsForPath() {
        let readResult = makeReadResult(path: "Foo.swift", content: "content")
        _ = sut.processToolResult(readResult, iteration: 1)

        let deleteResult = ToolExecutionResult(
            providerID: "call_1",
            toolName: "delete_file",
            argumentsJSON: "{\"path\":\"Foo.swift\"}",
            outputJSON: "{\"ok\":true}",
            isError: false
        )
        let tagResult = sut.processToolResult(deleteResult, iteration: 2)

        guard case .passthrough = tagResult else {
            XCTFail("Expected .passthrough for delete")
            return
        }

        // Read tag should be outdated
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "deleted")
        } else {
            XCTFail("Expected R1 to be outdated [deleted]")
        }
    }

    // MARK: - Build Processing

    func testBuildFirstRun_ReturnsTagged() {
        let result = makeBuildResult(success: false, errorCount: 2, warningCount: 1, issues: [
            ["severity": "error", "message": "Cannot find type", "file": "Foo.swift", "line": 5],
            ["severity": "error", "message": "Expected '}'", "file": "Foo.swift", "line": 10],
            ["severity": "warning", "message": "Unused var", "file": "Foo.swift", "line": 3],
        ])
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged for build")
            return
        }
        XCTAssertEqual(tag, "<§B1§>")
        XCTAssertTrue(content.contains("<§B1§>"))
    }

    func testBuildRepeatSameResult_ReturnsReference() {
        let result = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        _ = sut.processToolResult(result, iteration: 1)

        let result2 = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference for unchanged build")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
    }

    func testBuildInvalidatedByEdit() {
        let result = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        _ = sut.processToolResult(result, iteration: 1)

        // Edit a file
        let editResult = makeEditResult(path: "Foo.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        // Build tag should be outdated
        if case .outdated = sut.entries["<§B1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected B1 to be outdated after edit")
        }
    }

    // MARK: - Test Processing

    func testTestsFirstRun_ReturnsTagged() {
        let result = makeTestResult(passed: 10, failed: 1, skipped: 0, failures: [
            ["scheme": "NanoTeams", "file": "FooTests.swift", "line": 15, "message": "XCTAssertEqual failed"],
        ])
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(_, let tag) = tagResult else {
            XCTFail("Expected .tagged for tests")
            return
        }
        XCTAssertEqual(tag, "<§B1§>")
    }

    // MARK: - Git Processing

    func testGitStatusFirstCall_ReturnsTagged() {
        let result = makeGitStatusResult()
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(_, let tag) = tagResult else {
            XCTFail("Expected .tagged for git_status")
            return
        }
        XCTAssertEqual(tag, "<§G1§>")
    }

    func testGitDiffFirstCall_ReturnsTagged() {
        let result = makeGitDiffResult(diff: "diff --git a/Foo.swift")
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(_, let tag) = tagResult else {
            XCTFail("Expected .tagged for git_diff")
            return
        }
        XCTAssertEqual(tag, "<§G1§>")
    }

    func testGitDiffRepeatUnchanged_ReturnsReference() {
        let diff = "diff --git a/Foo.swift b/Foo.swift"
        let result1 = makeGitDiffResult(diff: diff)
        _ = sut.processToolResult(result1, iteration: 1)

        let result2 = makeGitDiffResult(diff: diff)
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference for unchanged diff")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
    }

    func testGitInvalidatedByEdit() {
        let result = makeGitStatusResult()
        _ = sut.processToolResult(result, iteration: 1)

        let editResult = makeEditResult(path: "Foo.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        if case .outdated = sut.entries["<§G1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected G1 to be outdated after edit")
        }
    }

    // MARK: - Passthrough

    func testUnknownTool_ReturnsPassthrough() {
        let result = ToolExecutionResult(
            providerID: "call_1",
            toolName: "list_files",
            argumentsJSON: "{\"path\":\".\"}", outputJSON: "{\"files\":[\"a.txt\"]}",
            isError: false
        )
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .passthrough = tagResult else {
            XCTFail("Expected .passthrough for unknown tool")
            return
        }
    }

    // MARK: - Memories Generation

    func testGenerateMemories_ContainsAllTags() {
        let read = makeReadResult(path: "Foo.swift", content: "content")
        _ = sut.processToolResult(read, iteration: 1)

        let edit = makeEditResult(path: "Foo.swift")
        _ = sut.processToolResult(edit, iteration: 2)

        let memories = sut.generateMemories(version: 1)

        XCTAssertNotNil(memories)
        XCTAssertTrue(memories?.contains("=== MEMORIES v1 ===") == true)
        XCTAssertTrue(memories?.contains("<§R1§>") == true)
        XCTAssertTrue(memories?.contains("<§E1§>") == true)
        XCTAssertTrue(memories?.contains("=== END MEMORIES ===") == true)
    }

    func testGenerateMemories_WithPlanTag() {
        sut.registerPlanUpdate(content: "1. Step 1\n2. Step 2", iteration: 1)
        let memories = sut.generateMemories(version: 1)
        XCTAssertTrue(memories?.contains("<§P1§>") == true)
        XCTAssertTrue(memories?.contains("CURRENT") == true)
        XCTAssertTrue(memories?.contains("plan") == true)
    }

    func testGenerateMemories_ShowsCorrectStatuses() {
        // Read -> Edit -> Read (new baseline)
        let read1 = makeReadResult(path: "A.swift", content: "v1")
        _ = sut.processToolResult(read1, iteration: 1)

        let edit = makeEditResult(path: "A.swift")
        _ = sut.processToolResult(edit, iteration: 2)

        let read2 = makeReadResult(path: "A.swift", content: "v2")
        _ = sut.processToolResult(read2, iteration: 3)

        let memories = sut.generateMemories(version: 3)

        // R1 should be OUTDATED or REPLACED, E1 should be CURRENT, R2 should be CURRENT
        XCTAssertTrue(memories?.contains("OUTDATED") == true || memories?.contains("REPLACED") == true)
        XCTAssertTrue(memories?.contains("CURRENT") == true)
    }

    /// `generateMemories` returns nil when nothing has been tracked yet — the
    /// caller uses this to short-circuit the MEMORIES injection so an empty
    /// header/footer doesn't appear in every iteration of a no-file-reads role.
    func testGenerateMemories_emptyStore_returnsNil() {
        XCTAssertNil(sut.generateMemories(version: 1))
    }

    // MARK: - Cross-tool Interactions

    func testWriteInvalidatesBuildsAndGit() {
        let build = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        _ = sut.processToolResult(build, iteration: 1)

        let git = makeGitStatusResult()
        _ = sut.processToolResult(git, iteration: 1)

        let write = makeWriteResult(path: "Foo.swift", content: "new")
        _ = sut.processToolResult(write, iteration: 2)

        // Both build and git should be outdated
        if case .outdated = sut.entries["<§B1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected build tag to be outdated after write")
        }

        if case .outdated = sut.entries["<§G1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected git tag to be outdated after write")
        }
    }

    func testDeleteInvalidatesAllRangesForPath() {
        // Read full file and a range
        let readFull = makeReadResult(path: "Foo.swift", content: "full content")
        _ = sut.processToolResult(readFull, iteration: 1)

        let readRange = makeReadLinesResult(
            path: "Foo.swift", content: "1 │ line1", startLine: 1, endLine: 1)
        _ = sut.processToolResult(readRange, iteration: 1)

        // Delete file
        let deleteResult = ToolExecutionResult(
            providerID: "call_1",
            toolName: "delete_file",
            argumentsJSON: "{\"path\":\"Foo.swift\"}",
            outputJSON: "{\"ok\":true}",
            isError: false
        )
        _ = sut.processToolResult(deleteResult, iteration: 2)

        // Both full read and range read should be outdated
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "deleted")
        } else {
            XCTFail("Expected R1 (full read) to be outdated")
        }

        if case .outdated(let reason) = sut.entries["<§R2§>"]?.status {
            XCTAssertEqual(reason, "deleted")
        } else {
            XCTFail("Expected R2 (range read) to be outdated")
        }
    }

    // MARK: - Helpers

    private func makeReadResult(path: String, content: String) -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","content":\(jsonEscape(content)),"total_lines":\(content.components(separatedBy: "\n").count)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "read_file",
            argumentsJSON: "{\"path\":\"\(path)\"}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeReadLinesResult(
        path: String, content: String, startLine: Int, endLine: Int
    ) -> ToolExecutionResult {
        let totalLines = 100
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","content":\(jsonEscape(content)),"start_line":\(startLine),"end_line":\(endLine),"total_lines":\(totalLines)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "read_lines",
            argumentsJSON: "{\"path\":\"\(path)\",\"start_line\":\(startLine),\"end_line\":\(endLine)}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeEditResult(path: String) -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","status":"success"}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "edit_file",
            argumentsJSON: "{\"path\":\"\(path)\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeWriteResult(path: String, content: String) -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","status":"success"}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "write_file",
            argumentsJSON: "{\"path\":\"\(path)\",\"content\":\(jsonEscape(content))}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeBuildResult(
        success: Bool, errorCount: Int, warningCount: Int, issues: [[String: Any]]
    ) -> ToolExecutionResult {
        let issuesData = try! JSONSerialization.data(withJSONObject: issues)
        let issuesJSON = String(data: issuesData, encoding: .utf8)!
        let outputJSON = """
        {"ok":true,"data":{"success":\(success),"error_count":\(errorCount),"warning_count":\(warningCount),"issues":\(issuesJSON)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "run_xcodebuild",
            argumentsJSON: "{}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeTestResult(
        passed: Int, failed: Int, skipped: Int, failures: [[String: Any]]
    ) -> ToolExecutionResult {
        let failuresData = try! JSONSerialization.data(withJSONObject: failures)
        let failuresJSON = String(data: failuresData, encoding: .utf8)!
        let outputJSON = """
        {"ok":true,"data":{"success":\(failed == 0),"passed":\(passed),"failed":\(failed),"skipped":\(skipped),"failures":\(failuresJSON)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "run_xcodetests",
            argumentsJSON: "{}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeGitStatusResult() -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"branch":"feature/foo","clean":false,"staged":["Foo.swift"],"modified":[],"untracked":[]}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "git_status",
            argumentsJSON: "{}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeGitDiffResult(diff: String) -> ToolExecutionResult {
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "git_diff",
            argumentsJSON: "{}",
            outputJSON: diff,
            isError: false
        )
    }

    private func jsonEscape(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)
        return String(data: data, encoding: .utf8)!
    }
}
